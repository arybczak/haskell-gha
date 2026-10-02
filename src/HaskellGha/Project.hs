{-# LANGUAGE ApplicativeDo #-}

-- | The reader of the project: the local packages and the GHC versions that
-- each package is in the project for.
module HaskellGha.Project
  ( -- * Project
    Project (..)
  , Package (..)
  , MatrixEntry (..)
  , Import (..)

    -- * Reading
  , readProject
  ) where

import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char
import Data.Foldable
import Data.Functor
import Data.List qualified as L
import Data.Maybe
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Distribution.Compiler
import Distribution.Fields
import Distribution.ModuleName qualified as ModuleName
import Distribution.PackageDescription
import Distribution.PackageDescription.Configuration hiding (parseCondition)
import Distribution.PackageDescription.Parsec
import Distribution.Parsec
import Distribution.Pretty
import Distribution.Simple.FileMonitor.Types
import Distribution.Simple.Glob
import Distribution.Simple.Glob.Internal
import Distribution.System
import Distribution.Utils.Path qualified as Path
import Distribution.Version
import System.Directory
import System.FilePath

import HaskellGha.Check
import HaskellGha.Compat
import HaskellGha.Ghc
import HaskellGha.Options

-- | A local package.
data Package = Package
  { name :: String
  , directory :: FilePath
  -- ^ Relative to the project directory.
  , ghcRange :: VersionRange
  -- ^ The union of the GHC entries of @tested-with@.
  , hasTestSuite :: Bool
  , doctestArgs :: [[String]]
  -- ^ The doctest arguments for the library and each sublibrary.
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
  , imports :: [Import]
  -- ^ In all conditional blocks.
  }
  deriving stock (Eq, Show)

-- | An @import:@ line of @cabal.project@.
data Import = Import
  { location :: String
  -- ^ The prefix of the error messages, with the file and the position.
  , target :: String
  }
  deriving stock (Eq, Show)

-- | An entry of a @packages:@ or @optional-packages:@ field.
data PackageEntry = PackageEntry
  { location :: String
  -- ^ The prefix of the error messages, with the file and the position.
  , target :: String
  }
  deriving stock (Eq)

-- | A part of @cabal.project@ that the reader uses.
data Part
  = -- | A @packages:@ or @optional-packages:@ field. The flag is true for
    -- @packages:@.
    Packages Bool [PackageEntry]
  | ImportLine Import
  | -- | An @if@ section with its @elif@ and @else@ sections.
    Conditional Position (Condition ConfVar) [Part] [Part]

-- | Read the project in a directory.
readProject
  :: FilePath
  -- ^ The root of the repository.
  -> FilePath
  -- ^ The project directory, relative to the root.
  -> IO (Either [String] Project)
readProject root dir = runExceptT $ do
  exists <- lift $ doesFileExist (root </> projectFile)
  parts <- ExceptT $ readParts exists
  found <- ExceptT $ locatePackages parts
  let cabalFiles = L.nub (concatMap snd found)
  when (null cabalFiles) $
    throwE ["There are no packages in " ++ projectDescription exists dir ++ "."]
  packages <-
    ExceptT $
      runCheck . traverse fromErrors <$> forM cabalFiles (\f -> readPackage root (dir </> f) f)
  except . runCheck $ projectFrom exists dir packages (byToken found packages) parts
  where
    projectFile :: FilePath
    projectFile = dir </> "cabal.project"

    readParts :: Bool -> IO (Either [String] [Part])
    readParts = \case
      True -> parseProjectFile projectFile <$> BS.readFile (root </> projectFile)
      -- The entry has no position in a file, so it is optional, and a project
      -- without packages gets the error for an empty project.
      False ->
        doesDirectoryExist (root </> dir) <&> \case
          True -> Right [Packages False [PackageEntry {location = "", target = "./*.cabal"}]]
          False -> Left ["The project directory " ++ show dir ++ " does not exist."]

    -- The .cabal files of each entry of packages:, relative to the project
    -- directory.
    locatePackages :: [Part] -> IO (Either [String] [(String, [FilePath])])
    locatePackages parts = do
      locations <- forM (L.nub (allEntries parts)) $ \(required, e) ->
        (e.target,) <$> findPackages root dir required e
      pure . runCheck $ traverse (\(t, r) -> (t,) <$> fromErrors r) locations

    -- A package is known by its directory. If two .cabal files in one
    -- directory are listed by name, both entries give the first package. Such
    -- a layout is rare, so the tool accepts this.
    byToken :: [(String, [FilePath])] -> [Package] -> String -> [Package]
    byToken found packages t =
      [ p
      | f <- concat (lookup t found)
      , Just p <- [L.find (\p -> p.directory == takeDirectory f) packages]
      ]

    allEntries :: [Part] -> [(Bool, PackageEntry)]
    allEntries = concatMap $ \case
      Packages required es -> map (required,) es
      ImportLine _ -> []
      Conditional _ _ yes no -> allEntries yes ++ allEntries no

projectDescription :: Bool -> FilePath -> String
projectDescription exists dir =
  if exists then dir </> "cabal.project" else "the implicit project of " ++ show dir

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
      Field (Name pos n) ls : rest
        | n == "packages" -> (:) (Packages True (fieldEntries ls)) <$> parts rest
        | n == "optional-packages" -> (:) (Packages False (fieldEntries ls)) <$> parts rest
        | n == "import" ->
            let i = Import {location = at pos "", target = unwords (map (.target) (fieldEntries ls))}
            in (:) (ImportLine i) <$> parts rest
        | otherwise -> parts rest
      Section (Name pos n) args body : rest
        | n == "if" -> conditional pos args body rest
        | n `elem` ["elif", "else"] ->
            failure (at pos $ BS8.unpack n ++ " without if") *> parts rest
        | otherwise -> parts rest

    -- The elif and else sections that follow an if section. ApplicativeDo
    -- joins the independent statements with <*>, so the errors of the
    -- condition and of the sections come back together.
    conditional
      :: Position
      -> [SectionArg Position]
      -> [Field Position]
      -> [Field Position]
      -> Check [Part]
    conditional pos args body rest = case rest of
      Section (Name pos' "elif") args' body' : rest' -> do
        c <- condition pos args
        yes <- parts body
        -- The elif section is the first part of the result.
        elif <- conditional pos' args' body' rest'
        pure $ case elif of
          p : others -> Conditional pos c yes [p] : others
          [] -> [Conditional pos c yes []]
      Section (Name _ "else") _ body' : rest' -> do
        c <- condition pos args
        yes <- parts body
        no <- parts body'
        others <- parts rest'
        pure $ Conditional pos c yes no : others
      _ -> do
        c <- condition pos args
        yes <- parts body
        others <- parts rest
        pure $ Conditional pos c yes [] : others

    condition :: Position -> [SectionArg Position] -> Check (Condition ConfVar)
    condition pos = fromErrors . parseCondition file pos

    at :: Position -> String -> String
    at pos msg = showPError file (PError pos msg)

    -- Split the value of a packages: field into its entries, as cabal does.
    -- An entry can continue on the next line, so the split runs on the joined
    -- lines, and the offset of an entry in them gives its position.
    fieldEntries :: [FieldLine Position] -> [PackageEntry]
    fieldEntries ls =
      [ PackageEntry {location = at (position i) "", target = t}
      | (i, t) <- tokens 0 (unwords texts)
      ]
      where
        texts :: [String]
        texts = [T.unpack (T.decodeUtf8Lenient l) | FieldLine _ l <- ls]

        -- The offset of each line in the joined lines, with its position.
        starts :: [(Int, Position)]
        starts = zip (scanl (\o t -> o + length t + 1) 0 texts) [p | FieldLine p _ <- ls]

        position :: Int -> Position
        position i = case [(o, p) | (o, p) <- starts, o <= i] of
          [] -> zeroPos
          before -> let (o, Position row col) = last before in Position row (col + i - o)

        tokens :: Int -> String -> [(Int, String)]
        tokens i s =
          let (skipped, s') = span separator s
              i' = i + length skipped
          in case s' of
               [] -> []
               '"' : _ | [(t, rest)] <- reads s' -> (i', t) : tokens (i' + length s' - length rest) rest
               _ -> let (t, rest) = token 0 s' in (i', t) : tokens (i' + length t) rest

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

-- | A path that a package location gives.
data LocationMatch
  = -- | A @.cabal@ file, relative to the project directory.
    MatchCabalFile FilePath
  | -- | A package that cabal reads and the tool does not support, with the
    -- error.
    MatchUnsupported String
  | -- | A path without a package, with the error.
    MatchNoPackage String

-- | Find the @.cabal@ files of an entry of @packages:@. The paths are relative
-- to the project directory.
findPackages
  :: FilePath
  -- ^ The root of the repository.
  -> FilePath
  -- ^ The project directory, relative to the root.
  -> Bool
  -> PackageEntry
  -> IO (Either [String] [FilePath])
findPackages root projectDir required entry
  | "://" `L.isInfixOf` t =
      pure $
        Left
          [ at $
              "the package location " ++ show t ++ " is a URL. The tool supports only local packages."
          ]
  | isAbsolute t = notRelative
  -- A glob component other than .. does not lead up, so the location itself
  -- decides for all its matches.
  | leadsAbove (projectDir </> t) =
      pure $
        Left
          [ at $
              "the package location "
                ++ show t
                ++ " is not in the repository. The tool supports only packages in the repository."
          ]
  | otherwise = case simpleParsec @RootedGlob t of
      Just (RootedGlob FilePathRelative glob) -> do
        matches <- matchGlob dir glob
        if null matches
          then pure $ missing (if literal glob then "does not exist" else "matches no files")
          else collect <$> mapM classify matches
      -- A glob from the root or the home directory.
      Just _ -> notRelative
      -- As in cabal, a location of packages: that is not a glob can still be a
      -- path, but a location of optional-packages: must be a glob.
      Nothing
        | required -> do
            exists <- (||) <$> doesFileExist (dir </> t) <*> doesDirectoryExist (dir </> t)
            if exists
              then collect . pure <$> classify t
              else pure $ missing "is not a valid glob, and no file or directory has this path"
        | otherwise ->
            pure $ Left [at $ "the package location " ++ show t ++ " is not a valid glob."]
  where
    t :: String
    t = entry.target

    -- An entry without a position starts the message itself.
    at :: String -> String
    at msg = case msg of
      c : cs | null entry.location -> toUpper c : cs
      _ -> entry.location ++ msg

    missing :: String -> Either [String] [FilePath]
    missing reason
      | required = Left [at $ "the package location " ++ show t ++ " " ++ reason ++ "."]
      | otherwise = Right []

    -- A glob without a wildcard or a union names one path.
    literal :: Glob -> Bool
    literal = \case
      GlobDir pieces rest -> all literalPiece pieces && literal rest
      GlobDirRecursive _ -> False
      GlobFile pieces -> all literalPiece pieces
      GlobDirTrailing -> True
      where
        literalPiece :: GlobPiece -> Bool
        literalPiece = \case
          Literal _ -> True
          _ -> False

    dir :: FilePath
    dir = root </> projectDir

    -- The workflow uses the path on the runner, where it does not exist.
    notRelative :: IO (Either [String] [FilePath])
    notRelative =
      pure $
        Left
          [ at $
              "the package location "
                ++ show t
                ++ " is not a relative path. The tool supports only packages in the repository."
          ]

    -- As in cabal, a path without a package is an error only if no path of
    -- the location has a package, so the glob */ can match a directory with
    -- documentation next to the packages. In optional-packages: it is never
    -- an error (checkIsFileGlobPackage in
    -- cabal-install/src/Distribution/Client/ProjectConfig.hs).
    collect :: [LocationMatch] -> Either [String] [FilePath]
    collect matches = case [e | MatchUnsupported e <- matches] of
      [] -> case [f | MatchCabalFile f <- matches] of
        []
          | required -> Left [e | MatchNoPackage e <- matches]
          | otherwise -> Right []
        files -> Right files
      errors -> Left errors

    -- Classify a match of the package location.
    classify :: FilePath -> IO LocationMatch
    classify path = do
      isDir <- doesDirectoryExist (dir </> path)
      if isDir
        then do
          -- cabal searches the directory with the glob *.cabal, which skips a
          -- hidden file, e.g. the lock file .#a.cabal of Emacs.
          cabalFiles <-
            filter (\f -> takeExtension f == ".cabal" && not ("." `L.isPrefixOf` f))
              <$> listDirectory (dir </> path)
          pure $ case cabalFiles of
            [f] -> MatchCabalFile (normalise $ path </> f)
            [] -> MatchNoPackage . at $ "the directory " ++ show path ++ " contains no .cabal file."
            _ ->
              MatchNoPackage . at $
                "the directory " ++ show path ++ " contains more than one .cabal file."
        else pure $ case () of
          _
            | ".tar.gz" `L.isSuffixOf` path ->
                MatchUnsupported . at $
                  "the package location "
                    ++ show path
                    ++ " is a tarball. The tool supports only local packages."
            | takeExtension path == ".cabal" -> MatchCabalFile (normalise path)
            | otherwise ->
                MatchNoPackage . at $
                  "the package location " ++ show path ++ " is not a directory or a .cabal file."

----------------------------------------
-- Packages

-- | Read a @.cabal@ file.
readPackage
  :: FilePath
  -- ^ The root of the repository.
  -> FilePath
  -- ^ The path relative to the root.
  -> FilePath
  -- ^ The path relative to the project directory.
  -> IO (Either [String] Package)
readPackage root path relative = do
  input <- BS.readFile (root </> path)
  case runCabalParser path (parseGenericPackageDescription input) of
    Left errors -> pure $ Left errors
    Right gpd -> packageFrom gpd <$> doctestArguments (flattenPackageDescription gpd)
  where
    packageFrom :: GenericPackageDescription -> [[String]] -> Either [String] Package
    packageFrom gpd args = case [r | (GHC, r) <- testedWith pd] of
      [] -> Left ["Package " ++ pkgName' ++ " has no GHC version in tested-with."]
      r : rs ->
        Right
          Package
            { name = pkgName'
            , directory = takeDirectory relative
            , ghcRange = foldl' unionVersionRanges r rs
            , hasTestSuite = not (null (condTestSuites gpd))
            , doctestArgs = args
            }
      where
        pd :: PackageDescription
        pd = packageDescription gpd

        pkgName' :: String
        pkgName' = unPackageName (pkgName (package pd))

    -- The arguments are the language, the extensions and the sources, as in
    -- haskell-ci. The description is flattened, so the fields of all
    -- conditional blocks count.
    doctestArguments :: PackageDescription -> IO [[String]]
    doctestArguments pd = fmap (L.nub . filter (not . null)) . forM (toList (library pd) ++ subLibraries pd) $ \lib -> do
      let bi = libBuildInfo lib
      -- The package directory can also contain other components, e.g. the
      -- tests, so it gives the files of the exposed modules instead.
      sources <- case map (normalise . Path.getSymbolicPath) $ hsSourceDirs bi of
        dirs
          | all (== ".") dirs -> mapM moduleFile (exposedModules lib)
          | otherwise -> fmap concat . forM dirs $ \case
              "." -> catMaybes <$> mapM findModuleFile (exposedModules lib)
              dir -> pure [dir]
      pure $
        if null sources
          then []
          else
            ["-X" ++ prettyShow l | Just l <- [defaultLanguage bi]]
              ++ ["-X" ++ prettyShow e | e <- defaultExtensions bi]
              ++ sources

    -- For a module name, GHC takes the compiled module from the GHC environment
    -- file, and doctest finds no examples. A file name works.
    moduleFile :: ModuleName.ModuleName -> IO FilePath
    moduleFile m = fromMaybe (prettyShow m) <$> findModuleFile m

    -- The file of a module in the package directory.
    findModuleFile :: ModuleName.ModuleName -> IO (Maybe FilePath)
    findModuleFile m =
      listToMaybe
        <$> filterM
          (doesFileExist . ((root </> takeDirectory path) </>))
          [ModuleName.toFilePath m <.> ext | ext <- ["hs", "lhs"]]

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
projectFrom exists dir packages byToken parts = do
  entries <- traverse (\p -> fromErrors $ entriesFromRange p.name p.ghcRange) packages
  let axis = L.sort (L.nub (concat entries))
  matrix <- dedupe (traverse matrixEntry axis)
  traverse_ (untested matrix) (zip packages entries)
  pure Project {packages = packages, matrix = matrix, imports = imports parts}
  where
    imports :: [Part] -> [Import]
    imports = concatMap $ \case
      Packages _ _ -> []
      ImportLine i -> [i]
      Conditional _ _ yes no -> imports yes ++ imports no

    matrixEntry :: GhcEntry -> Check MatrixEntry
    matrixEntry entry = do
      pkgs <- L.nubBy (\a b -> a.directory == b.directory) <$> included entry parts
      if null pkgs
        then
          failure $
            "There are no packages in "
              ++ projectDescription exists dir
              ++ " for GHC "
              ++ T.unpack (entryText entry)
              ++ "."
        else traverse_ (supports entry) pkgs
      pure (MatrixEntry entry pkgs)

    included :: GhcEntry -> [Part] -> Check [Package]
    included entry =
      fmap concat
        . traverse
          ( \case
              Packages _ es -> pure (concatMap (byToken . (.target)) es)
              ImportLine _ -> pure []
              Conditional pos c yes no -> do
                b <- evaluate entry pos c
                included entry (if b then yes else no)
          )

    supports :: GhcEntry -> Package -> Check ()
    supports entry p = case decide p.ghcRange entry of
      Included -> pure ()
      -- The package lists exact versions of a series that another package lists
      -- as a whole. A condition that includes the exact entries includes a part
      -- of the series entry too, so no block can help.
      Partial ->
        failure $
          "Package "
            ++ p.name
            ++ " lists only some versions of the GHC series "
            ++ T.unpack (entryText entry)
            ++ " in tested-with, but another package lists the whole series. A conditional block in cabal.project cannot separate the two. Write the series in the same form in all packages, e.g. ^>= "
            ++ T.unpack (entryText entry)
            ++ " or exact versions."
      Excluded ->
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

    -- A package that some jobs build must be in the project for each version
    -- of its tested-with field, or no job tests that version. A package that
    -- no job builds, e.g. one only for Windows, is out of scope.
    untested :: [MatrixEntry] -> (Package, [GhcEntry]) -> Check ()
    untested matrix (p, own)
      | not (any builds matrix) = pure ()
      | otherwise =
          sequenceA_
            [ failure $
                "Package "
                  ++ p.name
                  ++ " lists GHC "
                  ++ T.unpack (entryText e.ghc)
                  ++ " in tested-with, but "
                  ++ projectDescription exists dir
                  ++ " does not include the package for that GHC version, so no job tests it. Remove the version from tested-with, or change the conditional block in cabal.project."
            | e <- matrix
            , e.ghc `elem` own
            , not (builds e)
            ]
      where
        builds :: MatrixEntry -> Bool
        builds e = p.directory `elem` map (.directory) e.packages

    -- The same error for several matrix entries is shown once.
    dedupe :: Check a -> Check a
    dedupe c = either (fromErrors . Left . L.nub) pure (runCheck c)

    evaluate :: GhcEntry -> Position -> Condition ConfVar -> Check Bool
    evaluate entry pos = \case
      Var (Impl GHC r) ->
        fromEither $
          decideRange (location pos ++ "the condition impl(ghc " ++ prettyShow r ++ ")") r entry
      Var (Impl _ _) -> pure False
      Var (OS os) -> pure (os == Linux)
      Var (Arch arch) -> pure (arch == X86_64)
      Var (PackageFlag f) ->
        failure $
          location pos
            ++ "the condition flag("
            ++ unFlagName f
            ++ ") is not supported, because the tool does not know the value of the flag."
      Lit b -> pure b
      CNot c -> not <$> evaluate entry pos c
      COr a b -> absorb True (evaluate entry pos a) (evaluate entry pos b)
      CAnd a b -> absorb False (evaluate entry pos a) (evaluate entry pos b)

    -- If one side of || is true or one side of && is false, cabal ignores the
    -- other side, so an error in it does not count.
    absorb :: Bool -> Check Bool -> Check Bool -> Check Bool
    absorb z a b
      | Right z `elem` [runCheck a, runCheck b] = pure z
      | otherwise = (if z then (||) else (&&)) <$> a <*> b

    location :: Position -> String
    location pos = showPError (dir </> "cabal.project") (PError pos "")
