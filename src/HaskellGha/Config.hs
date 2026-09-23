{-# LANGUAGE OverloadedStrings #-}

-- | The configuration file.
module HaskellGha.Config
  ( -- * Configuration
    Config (..)
  , CabalVersion (..)
  , Hooks (..)
  , Doctest (..)
  , Fourmolu (..)
  , Actions (..)
  , defaultConfig
  , defaultDoctest
  , defaultFourmolu

    -- * Matrix
  , matrixAxes
  , matrixGhcValues

    -- * Reading
  , readConfig
  , parseConfig
  ) where

import Control.Monad
import Data.ByteString.Lazy qualified as BL
import Data.Char
import Data.Foldable
import Data.Text qualified as T
import Distribution.Parsec
import Distribution.Version
import System.Directory

import HaskellGha.Check
import HaskellGha.Yaml

-- | The configuration.
data Config = Config
  { name :: Node
  -- ^ A scalar.
  , cabalVersion :: CabalVersion
  , runsOn :: Node
  -- ^ A scalar.
  , branches :: [Node]
  -- ^ Scalars.
  , matrix :: [Item (Key, Node)]
  -- ^ The extra axes, @include@ and @exclude@.
  , apt :: [T.Text]
  , services :: Maybe Node
  , hooks :: Hooks
  , ghcOptions :: T.Text
  , cabalProjectLocal :: T.Text
  -- ^ Extra text for @cabal.project.local@.
  , jobs :: Int
  , tests :: Bool
  , benchmarks :: Bool
  , doctest :: Maybe Doctest
  , check :: Bool
  , sdist :: Bool
  , haddock :: Bool
  , fourmolu :: Maybe Fourmolu
  , actions :: Actions
  }
  deriving stock (Eq, Show)

-- | The configuration of the fourmolu job.
data Fourmolu = Fourmolu
  { version :: Version
  , patterns :: [T.Text]
  -- ^ The files to check. An empty list gives the default of the action.
  }
  deriving stock (Eq, Show)

-- | The versions of the actions, i.e. the Git refs after the @\@@ in @uses@.
data Actions = Actions
  { checkout :: T.Text
  , setup :: T.Text
  , cache :: T.Text
  -- ^ For both @actions/cache/restore@ and @actions/cache/save@.
  , runFourmolu :: T.Text
  }
  deriving stock (Eq, Show)

-- | The cabal version for @haskell-actions/setup@.
data CabalVersion
  = CabalLatest
  | CabalVersion Version
  deriving stock (Eq, Show)

-- | The steps that the tool puts in the workflow.
data Hooks = Hooks
  { beforeBuild :: [Item Node]
  , afterBuild :: [Item Node]
  }
  deriving stock (Eq, Show)

-- | The configuration of doctest.
data Doctest = Doctest
  { ghc :: VersionRange
  , version :: Maybe VersionRange
  , skip :: [T.Text]
  , options :: [T.Text]
  }
  deriving stock (Eq, Show)

-- | The configuration if the file does not exist.
defaultConfig :: Config
defaultConfig =
  Config
    { name = plain "CI"
    , cabalVersion = CabalVersion (mkVersion [3, 16, 1, 0])
    , runsOn = plain "ubuntu-26.04"
    , branches = [plain "master", plain "main"]
    , matrix = []
    , apt = []
    , services = Nothing
    , hooks = Hooks [] []
    , ghcOptions = "-Werror"
    , cabalProjectLocal = ""
    , jobs = 4
    , tests = True
    , benchmarks = True
    , doctest = Nothing
    , check = True
    , sdist = True
    , haddock = True
    , fourmolu = Nothing
    , actions = Actions {checkout = "v7", setup = "v2", cache = "v6", runFourmolu = "v13"}
    }

-- | The fourmolu configuration of an empty @fourmolu@ field. Version 0.20
-- and later needs run-fourmolu v13 or later.
defaultFourmolu :: Fourmolu
defaultFourmolu =
  Fourmolu
    { version = mkVersion [0, 20, 1, 0]
    , patterns = []
    }

-- | The doctest configuration of an empty @doctest@ field.
defaultDoctest :: Doctest
defaultDoctest =
  Doctest
    { ghc = anyVersion
    , version = Nothing
    , skip = []
    , options = []
    }

----------------------------------------
-- Matrix

-- | The names of the extra axes.
matrixAxes :: Config -> [T.Text]
matrixAxes config =
  [ k.name
  | Item _ (k, _) <- config.matrix
  , k.name `notElem` ["include", "exclude"]
  ]

-- | The values of @ghc@ in @include@ and @exclude@.
matrixGhcValues :: Config -> [T.Text]
matrixGhcValues config =
  [ v
  | Item _ (k, Sequence entries _) <- config.matrix
  , k.name `elem` ["include", "exclude"]
  , Item _ (Mapping fields _) <- entries
  , Just (Scalar _ v) <- [lookupKey "ghc" fields]
  ]

----------------------------------------
-- Reading

-- | Read the configuration file. If the file does not exist, the result is
-- 'defaultConfig'.
readConfig :: FilePath -> IO (Either [String] Config)
readConfig file =
  doesFileExist file >>= \case
    False -> pure $ Right defaultConfig
    True -> parseConfig file <$> BL.readFile file

-- | Parse the configuration.
parseConfig
  :: FilePath
  -- ^ The file name for the error messages.
  -> BL.ByteString
  -> Either [String] Config
parseConfig file input = case parseYaml input of
  Left e -> Left [renderYamlError file e]
  Right Nothing -> Right defaultConfig
  Right (Just root) -> either (Left . map ((file ++ ": ") ++)) Right . runCheck $ configFromNode root

configFromNode :: Node -> Check Config
configFromNode = \case
  Mapping entries _ ->
    knownFields "" fields entries
      *> ( Config
             <$> field entries "name" defaultConfig.name scalar
             <*> field entries "cabal-version" defaultConfig.cabalVersion cabalVersionField
             <*> field entries "runs-on" defaultConfig.runsOn scalar
             <*> field entries "branches" defaultConfig.branches branchesField
             <*> field entries "matrix" defaultConfig.matrix matrixField
             <*> field entries "apt" defaultConfig.apt textList
             <*> field entries "services" defaultConfig.services (\p n -> Just <$> mappingNode p n)
             <*> field entries "hooks" defaultConfig.hooks hooksField
             <*> field entries "ghc-options" defaultConfig.ghcOptions text
             <*> field entries "cabal-project-local" defaultConfig.cabalProjectLocal projectText
             <*> field entries "jobs" defaultConfig.jobs positiveInt
             <*> field entries "tests" defaultConfig.tests bool
             <*> field entries "benchmarks" defaultConfig.benchmarks bool
             <*> doctestField entries
             <*> field entries "check" defaultConfig.check bool
             <*> field entries "sdist" defaultConfig.sdist bool
             <*> field entries "haddock" defaultConfig.haddock bool
             <*> fourmoluField entries
             <*> field entries "actions" defaultConfig.actions actionsField
         )
  _ -> failure "the configuration must be a mapping"
  where
    fields :: [T.Text]
    fields =
      ["name", "cabal-version", "runs-on", "branches", "matrix", "apt", "services", "hooks", "ghc-options", "cabal-project-local", "jobs", "tests", "benchmarks", "doctest", "check", "sdist", "haddock", "fourmolu", "actions"]

    fourmoluField :: [Item (Key, Node)] -> Check (Maybe Fourmolu)
    fourmoluField entries = case lookupKey "fourmolu" entries of
      Nothing -> pure Nothing
      Just n | isNull n -> pure $ Just defaultFourmolu
      Just (Mapping fs _) ->
        knownFields "fourmolu." ["version", "pattern"] fs
          *> ( fmap Just $
                 Fourmolu
                   <$> field' fs "fourmolu.version" "version" defaultFourmolu.version versionField
                   <*> field' fs "fourmolu.pattern" "pattern" defaultFourmolu.patterns textList
             )
      Just _ -> expected "fourmolu" "a mapping"

    versionField :: String -> Node -> Check Version
    versionField path n =
      text path n `andThen` \t -> case simpleParsec (T.unpack t) of
        Just v -> pure v
        Nothing -> expected path "a version, e.g. 0.20.1.0"

    actionsField :: String -> Node -> Check Actions
    actionsField path = \case
      Mapping as _ ->
        knownFields "actions." ["checkout", "setup", "cache", "run-fourmolu"] as
          *> ( Actions
                 <$> field' as "actions.checkout" "checkout" defaultConfig.actions.checkout ref
                 <*> field' as "actions.setup" "setup" defaultConfig.actions.setup ref
                 <*> field' as "actions.cache" "cache" defaultConfig.actions.cache ref
                 <*> field' as "actions.run-fourmolu" "run-fourmolu" defaultConfig.actions.runFourmolu ref
             )
      _ -> expected path "a mapping"

    ref :: String -> Node -> Check T.Text
    ref path n =
      text path n `andThen` \t ->
        if T.null t || T.any isSpace t
          then expected path "a Git ref, e.g. v7"
          else pure t

    -- The workflow writes the text with a heredoc that ends at the line EOF.
    projectText :: String -> Node -> Check T.Text
    projectText path n =
      text path n `andThen` \t ->
        if "EOF" `elem` T.lines t
          then failure $ "field " ++ show path ++ ": a line must not be EOF"
          else pure t

    hooksField :: String -> Node -> Check Hooks
    hooksField path = \case
      Mapping hs _ ->
        knownFields "hooks." ["before-build", "after-build"] hs
          *> ( Hooks
                 <$> field' hs "hooks.before-build" "before-build" [] steps
                 <*> field' hs "hooks.after-build" "after-build" [] steps
             )
      _ -> expected path "a mapping"

    doctestField :: [Item (Key, Node)] -> Check (Maybe Doctest)
    doctestField entries = case lookupKey "doctest" entries of
      Nothing -> pure Nothing
      Just n | isNull n -> pure $ Just defaultDoctest
      Just (Mapping ds _) ->
        knownFields "doctest." ["ghc", "version", "skip", "options"] ds
          *> ( fmap Just $
                 Doctest
                   <$> field' ds "doctest.ghc" "ghc" defaultDoctest.ghc versionRange
                   <*> field' ds "doctest.version" "version" defaultDoctest.version (\p n -> Just <$> versionRange p n)
                   <*> field' ds "doctest.skip" "skip" defaultDoctest.skip textList
                   <*> field' ds "doctest.options" "options" defaultDoctest.options textList
             )
      Just _ -> expected "doctest" "a mapping"

----------------------------------------
-- Fields

-- | Read a top-level field.
field :: [Item (Key, Node)] -> T.Text -> a -> (String -> Node -> Check a) -> Check a
field entries k = field' entries k k

-- | Read a field. A missing field or a null value gives the default.
field'
  :: [Item (Key, Node)]
  -> T.Text
  -- ^ The path of the field for the error messages.
  -> T.Text
  -- ^ The key.
  -> a
  -> (String -> Node -> Check a)
  -> Check a
field' entries path k def reader = case lookupKey k entries of
  Just n | not (isNull n) -> reader (T.unpack path) n
  _ -> pure def

knownFields :: T.Text -> [T.Text] -> [Item (Key, Node)] -> Check ()
knownFields prefix known entries =
  traverse_
    (\k -> failure $ "unknown field " ++ show (T.unpack $ prefix <> k))
    [k.name | Item _ (k, _) <- entries, k.name `notElem` known]

expected :: String -> String -> Check a
expected path what = failure $ "field " ++ show path ++ ": expected " ++ what

isNull :: Node -> Bool
isNull = \case
  Scalar Plain t -> t `elem` ["", "~", "null", "Null", "NULL"]
  _ -> False

scalar :: String -> Node -> Check Node
scalar path = \case
  n@(Scalar _ _) -> pure n
  _ -> expected path "a string"

text :: String -> Node -> Check T.Text
text path = \case
  Scalar _ t -> pure t
  _ -> expected path "a string"

textList :: String -> Node -> Check [T.Text]
textList path = \case
  Sequence items _ -> traverse (text path . (.value)) items
  _ -> expected path "a list of strings"

bool :: String -> Node -> Check Bool
bool path = \case
  Scalar Plain t
    | t `elem` ["true", "True", "TRUE"] -> pure True
    | t `elem` ["false", "False", "FALSE"] -> pure False
  _ -> expected path "true or false"

positiveInt :: String -> Node -> Check Int
positiveInt path = \case
  Scalar Plain t
    | not (T.null t)
    , T.all (`elem` ['0' .. '9']) t
    , n <- read @Int (T.unpack t)
    , n > 0 ->
        pure n
  _ -> expected path "a positive integer"

versionRange :: String -> Node -> Check VersionRange
versionRange path n =
  text path n `andThen` \t -> case simpleParsec (T.unpack t) of
    Just r -> pure r
    Nothing -> expected path "a version range"

cabalVersionField :: String -> Node -> Check CabalVersion
cabalVersionField path n =
  text path n `andThen` \case
    "latest" -> pure CabalLatest
    t -> case simpleParsec (T.unpack t) of
      Just v
        | take 2 (versionNumbers v) < [3, 12] ->
            failure $ "field " ++ show path ++ ": the GHC job semaphore needs cabal 3.12 or later"
        | otherwise -> pure $ CabalVersion v
      Nothing -> expected path "latest or a version"

branchesField :: String -> Node -> Check [Node]
branchesField path = \case
  Sequence [] _ -> failure $ "field " ++ show path ++ ": the list must not be empty"
  Sequence items _ -> traverse (scalar path . (.value)) items
  _ -> expected path "a list of branches"

mappingNode :: String -> Node -> Check Node
mappingNode path = \case
  n@(Mapping _ _) -> pure n
  _ -> expected path "a mapping"

steps :: String -> Node -> Check [Item Node]
steps path = \case
  Sequence items _ -> items <$ traverse_ (mappingNode (path ++ " item") . (.value)) items
  _ -> expected path "a list of steps"

matrixField :: String -> Node -> Check [Item (Key, Node)]
matrixField path = \case
  Mapping entries _ -> entries <$ traverse_ (entry [k.name | Item _ (k, _) <- entries, k.name `notElem` ["include", "exclude"]]) entries
  _ -> expected path "a mapping"
  where
    entry :: [T.Text] -> Item (Key, Node) -> Check ()
    entry axes (Item _ (k, v))
      | k.name == "ghc" = failure $ "field " ++ show path ++ ": the tool makes the ghc axis, so the matrix must not contain it"
      | k.name `elem` ["include", "exclude"] = case v of
          Sequence items _ -> traverse_ (combination axes (k.name == "exclude") (path ++ "." ++ T.unpack k.name) . (.value)) items
          _ -> expected (path ++ "." ++ T.unpack k.name) "a list of mappings"
      | otherwise = pure ()

    combination :: [T.Text] -> Bool -> String -> Node -> Check ()
    combination axes isExclude p = \case
      Mapping fields _ ->
        ghcValue p fields
          *> when isExclude (traverse_ (unknownAxis axes p) [k.name | Item _ (k, _) <- fields, k.name /= "ghc"])
      _ -> expected p "a list of mappings"

    ghcValue :: String -> [Item (Key, Node)] -> Check ()
    ghcValue p fields = case lookupKey "ghc" fields of
      Just (Scalar s _) | s `notElem` [SingleQuoted, DoubleQuoted] -> failure $ "field " ++ show p ++ ": a ghc value must be a quoted string, e.g. '9.10'"
      Just (Scalar _ _) -> pure ()
      Just _ -> failure $ "field " ++ show p ++ ": a ghc value must be a quoted string, e.g. '9.10'"
      Nothing -> pure ()

    unknownAxis :: [T.Text] -> String -> T.Text -> Check ()
    unknownAxis axes p name
      | name `elem` axes = pure ()
      | otherwise =
          failure $
            "field "
              ++ show p
              ++ ": the key "
              ++ T.unpack name
              ++ " is not an axis of the matrix. The axes are: "
              ++ T.unpack (T.intercalate ", " ("ghc" : axes))
