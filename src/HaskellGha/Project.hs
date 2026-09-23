{-# LANGUAGE OverloadedStrings #-}

-- | The reader of the project: the local packages and the GHC versions that
-- each package is in the project for.
module HaskellGha.Project
  ( -- * Project
    Project (..)
  , Package (..)
  , MatrixEntry (..)

    -- * Reading
  , readProject
  ) where

import Control.Monad
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char
import Data.Either
import Data.Foldable
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Distribution.Compiler
import Distribution.Fields
import Distribution.PackageDescription
import Distribution.PackageDescription.Parsec
import Distribution.Parsec
import Distribution.Pretty
import Distribution.Simple.FileMonitor.Types
import Distribution.Simple.Glob
import Distribution.System
import Distribution.Version
import System.Directory
import System.FilePath

import HaskellGha.Check
import HaskellGha.Compat
import HaskellGha.Ghc

-- | A local package.
data Package = Package
  { name :: String
  , directory :: FilePath
  -- ^ Relative to the project directory.
  , ghcRange :: VersionRange
  -- ^ The union of the GHC entries of @tested-with@.
  , hasTestSuite :: Bool
  , description :: GenericPackageDescription
  }
  deriving stock (Eq, Show)

-- | An entry of the @ghc@ axis with the packages that are in the project for
-- it.
data MatrixEntry = MatrixEntry
  { ghc :: GhcEntry
  , packages :: [Package]
  }
  deriving stock (Eq, Show)

-- | The project.
data Project = Project
  { packages :: [Package]
  -- ^ All local packages.
  , matrix :: [MatrixEntry]
  -- ^ In version order.
  }
  deriving stock (Eq, Show)

-- | A part of @cabal.project@ that the reader uses.
data Part
  = -- | A @packages:@ or @optional-packages:@ field. The flag is true for
    -- @packages:@.
    Packages Bool [String]
  | -- | An @if@ section with its @elif@ and @else@ sections.
    Conditional Position (Condition ConfVar) [Part] [Part]

-- | Read the project in a directory.
readProject :: FilePath -> IO (Either [String] Project)
readProject dir = do
  let projectFile = dir </> "cabal.project"
  exists <- doesFileExist projectFile
  parts <-
    if exists
      then parseProjectFile projectFile <$> BS.readFile projectFile
      else pure $ Right [Packages True ["./*.cabal"]]
  case parts of
    Left errors -> pure $ Left errors
    Right ps -> do
      let tokens = L.nub [(required, t) | (required, t) <- allTokens ps]
      locations <- forM tokens $ \(required, t) -> (t,) <$> findPackages dir required t
      case runCheck $ traverse (\(t, r) -> (t,) <$> fromErrors r) locations of
        Left errors -> pure $ Left errors
        Right found -> do
          let cabalFiles = L.nub (concatMap snd found)
          if null cabalFiles
            then pure $ Left ["There are no packages in " ++ projectDescription exists dir ++ "."]
            else do
              pkgs <- forM cabalFiles $ \f -> readPackage (dir </> f) f
              pure . runCheck $
                traverse fromErrors pkgs `andThen` \packages ->
                  let byToken t = [p | f <- concat (lookup t found), Just p <- [L.find (\p -> p.directory == takeDirectory f) packages]]
                  in projectFrom exists dir packages byToken ps
  where
    allTokens :: [Part] -> [(Bool, String)]
    allTokens = concatMap $ \case
      Packages required ts -> map (required,) ts
      Conditional _ _ yes no -> allTokens yes ++ allTokens no

projectDescription :: Bool -> FilePath -> String
projectDescription exists dir =
  if exists then dir </> "cabal.project" else "the implicit project of " ++ dir

----------------------------------------
-- cabal.project

-- | Parse @cabal.project@.
parseProjectFile :: FilePath -> BS.ByteString -> Either [String] [Part]
parseProjectFile file input = case readFields input of
  Left e -> Left [file ++ ": " ++ show e]
  Right fields -> runCheck $ parts fields
  where
    parts :: [Field Position] -> Check [Part]
    parts = \case
      [] -> pure []
      Field (Name _ n) ls : rest
        | n == "packages" -> (:) (Packages True (fieldTokens ls)) <$> parts rest
        | n == "optional-packages" -> (:) (Packages False (fieldTokens ls)) <$> parts rest
        | otherwise -> parts rest
      Section (Name pos n) args body : rest
        | n == "if" -> conditional pos args body rest
        | n `elem` ["elif", "else"] -> failure (at pos $ BS8.unpack n ++ " without if") *> parts rest
        | otherwise -> parts rest

    -- The elif and else sections that follow an if section.
    conditional :: Position -> [SectionArg Position] -> [Field Position] -> [Field Position] -> Check [Part]
    conditional pos args body rest = case rest of
      Section (Name pos' "elif") args' body' : rest' ->
        (\c yes (no, others) -> Conditional pos c yes no : others)
          <$> condition pos args
          <*> parts body
          <*> fmap (\case p : ps -> ([p], ps); [] -> ([], [])) (conditional pos' args' body' rest')
      Section (Name _ "else") _ body' : rest' ->
        (\c yes no others -> Conditional pos c yes no : others)
          <$> condition pos args
          <*> parts body
          <*> parts body'
          <*> parts rest'
      _ ->
        (\c yes others -> Conditional pos c yes [] : others)
          <$> condition pos args
          <*> parts body
          <*> parts rest

    condition :: Position -> [SectionArg Position] -> Check (Condition ConfVar)
    condition pos = fromErrors . parseCondition file pos

    at :: Position -> String -> String
    at pos msg = showPError file (PError pos msg)

-- | Split the value of a @packages:@ field into its entries, as cabal does.
fieldTokens :: [FieldLine Position] -> [String]
fieldTokens ls = tokens . unwords $ [T.unpack (T.decodeUtf8Lenient l) | FieldLine _ l <- ls]
  where
    tokens :: String -> [String]
    tokens s = case dropWhile separator s of
      [] -> []
      s'@('"' : _) | [(t, rest)] <- reads s' -> t : tokens rest
      s' -> let (t, rest) = token (0 :: Int) s' in t : tokens rest

    token :: Int -> String -> (String, String)
    token depth = \case
      c : cs
        | depth == 0 && separator c -> ("", c : cs)
        | otherwise ->
            let depth' = case c of '{' -> depth + 1; '}' -> depth - 1; _ -> depth
                (t, rest) = token depth' cs
            in (c : t, rest)
      [] -> ("", "")

    separator :: Char -> Bool
    separator c = isSpace c || c == ','

----------------------------------------
-- Package locations

-- | Find the @.cabal@ files of an entry of @packages:@. The paths are
-- relative to the project directory.
findPackages :: FilePath -> Bool -> String -> IO (Either [String] [FilePath])
findPackages dir required t
  | "://" `L.isInfixOf` t = pure $ Left ["The package location " ++ show t ++ " is a URL. The tool supports only local packages."]
  | otherwise = case simpleParsec @RootedGlob t of
      Just glob -> do
        matches <- matchFileGlob dir glob
        if null matches
          then pure $ if required then Left ["The package location " ++ show t ++ " matches no files."] else Right []
          else collect <$> mapM (classify dir) matches
      Nothing -> do
        exists <- (||) <$> doesFileExist (dir </> t) <*> doesDirectoryExist (dir </> t)
        if exists
          then collect . pure <$> classify dir t
          else pure $ if required then Left ["The package location " ++ show t ++ " does not exist."] else Right []
  where
    collect :: [Either String FilePath] -> Either [String] [FilePath]
    collect results = case partitionEithers results of
      ([], files) -> Right files
      (errors, _) -> Left errors

-- | Classify a match of a package location.
classify :: FilePath -> FilePath -> IO (Either String FilePath)
classify dir path = do
  isDir <- doesDirectoryExist (dir </> path)
  if isDir
    then do
      cabalFiles <- filter ((== ".cabal") . takeExtension) <$> listDirectory (dir </> path)
      pure $ case cabalFiles of
        [f] -> Right (normalise $ path </> f)
        [] -> Left $ "The directory " ++ show path ++ " contains no .cabal file."
        _ -> Left $ "The directory " ++ show path ++ " contains more than one .cabal file."
    else pure $ case () of
      _
        | ".tar.gz" `L.isSuffixOf` path -> Left $ "The package location " ++ show path ++ " is a tarball. The tool supports only local packages."
        | takeExtension path == ".cabal" -> Right (normalise path)
        | otherwise -> Left $ "The package location " ++ show path ++ " is not a directory or a .cabal file."

-- | Match a glob, as cabal does (@matchFileGlob@ in
-- @cabal-install/src/Distribution/Client/Glob.hs@).
matchFileGlob :: FilePath -> RootedGlob -> IO [FilePath]
matchFileGlob relroot (RootedGlob globroot glob) = do
  root <- case globroot of
    FilePathRelative -> pure relroot
    FilePathRoot r -> pure r
    FilePathHomeDir -> getHomeDirectory
  matches <- matchGlob root glob
  pure $ case globroot of
    FilePathRelative -> matches
    _ -> map (root </>) matches

----------------------------------------
-- Packages

-- | Read a @.cabal@ file.
readPackage
  :: FilePath
  -- ^ The path to read.
  -> FilePath
  -- ^ The path relative to the project directory.
  -> IO (Either [String] Package)
readPackage path relative = do
  input <- BS.readFile path
  pure $ do
    gpd <- runCabalParser path (parseGenericPackageDescription input)
    let pd = packageDescription gpd
        pkgName' = unPackageName (pkgName (package pd))
    case [r | (GHC, r) <- testedWith pd] of
      [] -> Left ["Package " ++ pkgName' ++ " has no GHC version in tested-with."]
      r : rs ->
        Right
          Package
            { name = pkgName'
            , directory = takeDirectory relative
            , ghcRange = foldl' unionVersionRanges r rs
            , hasTestSuite = not (null (condTestSuites gpd))
            , description = gpd
            }

----------------------------------------
-- Matrix

-- | Make the project from its packages and parts.
projectFrom
  :: Bool
  -- ^ Whether @cabal.project@ exists.
  -> FilePath
  -> [Package]
  -> (String -> [Package])
  -- ^ The packages of an entry of @packages:@.
  -> [Part]
  -> Check Project
projectFrom exists dir packages byToken parts =
  traverse (\p -> fromErrors $ entriesFromRange p.name p.ghcRange) packages `andThen` \entries ->
    let axis = L.sort (L.nub (concat entries))
    in fmap (Project packages) . dedupe $ traverse matrixEntry axis
  where
    matrixEntry :: GhcEntry -> Check MatrixEntry
    matrixEntry entry =
      included entry parts `andThen` \pkgs ->
        let pkgs' = L.nubBy (\a b -> a.directory == b.directory) pkgs
        in MatrixEntry entry pkgs'
             <$ if null pkgs'
               then failure $ "There are no packages in " ++ projectDescription exists dir ++ " for GHC " ++ T.unpack (entryText entry) ++ "."
               else traverse_ (supports entry) pkgs'

    included :: GhcEntry -> [Part] -> Check [Package]
    included entry =
      fmap concat
        . traverse
          ( \case
              Packages _ ts -> pure (concatMap byToken ts)
              Conditional pos c yes no ->
                evaluate entry pos c `andThen` \b -> included entry (if b then yes else no)
          )

    supports :: GhcEntry -> Package -> Check ()
    supports entry p = case decide p.ghcRange entry of
      Included -> pure ()
      _ ->
        failure $
          unlines
            [ "Package "
                ++ p.name
                ++ " does not list GHC "
                ++ T.unpack (entryText entry)
                ++ " in tested-with, but "
                ++ projectDescription exists dir
                ++ " includes it for that GHC version. Move the package to a conditional block in cabal.project, e.g.:"
            , ""
            , "if impl(ghc " ++ prettyShow p.ghcRange ++ ")"
            , "  packages: " ++ p.directory
            ]

    -- The same error for several matrix entries is shown once.
    dedupe :: Check a -> Check a
    dedupe c = either (fromErrors . Left . L.nub) pure (runCheck c)

    evaluate :: GhcEntry -> Position -> Condition ConfVar -> Check Bool
    evaluate entry pos = \case
      Var (Impl GHC r) -> fromEither $ decideRange (location pos ++ "the condition impl(ghc " ++ prettyShow r ++ ")") r entry
      Var (Impl _ _) -> pure False
      Var (OS os) -> pure (os == Linux)
      Var (Arch arch) -> pure (arch == X86_64)
      Var (PackageFlag f) -> failure $ location pos ++ "the condition flag(" ++ unFlagName f ++ ") is not supported, because the tool does not know the value of the flag."
      Lit b -> pure b
      CNot c -> not <$> evaluate entry pos c
      COr a b -> (||) <$> evaluate entry pos a <*> evaluate entry pos b
      CAnd a b -> (&&) <$> evaluate entry pos a <*> evaluate entry pos b

    location :: Position -> String
    location pos = showPError (dir </> "cabal.project") (PError pos "")
