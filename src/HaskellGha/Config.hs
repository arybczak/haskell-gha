{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | The configuration file.
module HaskellGha.Config
  ( -- * Configuration
    Config (..)
  , CabalVersion (..)
  , Submodules (..)
  , Hooks (..)
  , Doctest (..)
  , Fourmolu (..)
  , HLint (..)
  , Actions (..)
  , defaultConfig
  , defaultDoctest
  , defaultFourmolu
  , defaultHLint

    -- * Matrix
  , matrixAxes
  , matrixGhcValues

    -- * Reading
  , ConfigFile (..)
  , defaultConfigPath
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
import System.FilePath

import HaskellGha.Check
import HaskellGha.Yaml

-- | The configuration.
data Config = Config
  { name :: Node
  -- ^ A scalar.
  , cabalVersion :: CabalVersion
  , runsOn :: Node
  -- ^ A scalar.
  , timeoutMinutes :: Int
  , branches :: [Node]
  -- ^ Scalars.
  , submodules :: Submodules
  , matrix :: [Item (Key, Node)]
  -- ^ The extra axes, @include@ and @exclude@.
  , apt :: [T.Text]
  , services :: Maybe Node
  , permissions :: Node
  -- ^ A mapping, @read-all@ or @write-all@.
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
  , hlint :: Maybe HLint
  , actions :: Actions
  }
  deriving stock (Eq, Show)

-- | The configuration of the HLint job.
data HLint = HLint
  { version :: Version
  , failOn :: T.Text
  , path :: [T.Text]
  -- ^ Relative to the project directory. An empty list gives the project
  -- directory.
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
  , hlintSetup :: T.Text
  , hlintRun :: T.Text
  }
  deriving stock (Eq, Show)

-- | The cabal version for @haskell-actions/setup@.
data CabalVersion
  = CabalLatest
  | CabalVersion Version
  deriving stock (Eq, Show)

-- | The Git submodules that the build jobs fetch.
data Submodules
  = NoSubmodules
  | -- | The submodules of the repository, without their own submodules.
    TopSubmodules
  | RecursiveSubmodules
  deriving stock (Eq, Show)

-- | The steps that the tool puts in the workflow.
data Hooks = Hooks
  { afterSetup :: [Item Node]
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
    , timeoutMinutes = 60
    , branches = [plain "master", plain "main"]
    , submodules = NoSubmodules
    , matrix = []
    , apt = []
    , services = Nothing
    , permissions = mapping [("contents", plain "read")]
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
    , hlint = Nothing
    , actions =
        Actions
          { checkout = "v7"
          , setup = "v2"
          , cache = "v6"
          , runFourmolu = "v13"
          , -- The commits "Upgrade to node24". Each release still needs
            -- Node.js 20.
            hlintSetup = "c04631035af0a6787c85e33b3ea0128b8568b590"
          , hlintRun = "d009541bdae0b8492992416e665bb6df8a3b5cde"
          }
    }

-- | The HLint configuration of an empty @hlint@ field.
defaultHLint :: HLint
defaultHLint =
  HLint
    { version = mkVersion [3, 10]
    , failOn = "suggestion"
    , path = []
    }

-- | The fourmolu configuration of an empty @fourmolu@ field. Version 0.20 and
-- later needs run-fourmolu v13 or later.
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
  | Item _ (k, Sequence entries) <- config.matrix
  , k.name `elem` ["include", "exclude"]
  , Item _ (Mapping fields) <- entries
  , Just (Scalar _ v) <- [lookupKey "ghc" fields]
  ]

----------------------------------------
-- Reading

-- | The location of the configuration file.
data ConfigFile
  = -- | The default file. It can be missing.
    DefaultConfigFile
  | -- | A file that the user names. It must exist, because a typo in its name
    -- would silently give the defaults.
    ConfigFile FilePath
  deriving stock (Eq, Show)

-- | The path of the default configuration file.
defaultConfigPath :: FilePath
defaultConfigPath = ".github/haskell-gha.conf.yml"

-- | Read the configuration file. If the default file does not exist, the
-- result is 'defaultConfig'.
readConfig
  :: FilePath
  -- ^ The root of the repository.
  -> ConfigFile
  -> IO (Either [String] Config)
readConfig root configFile =
  doesFileExist (root </> file) >>= \case
    True -> parseConfig file <$> BL.readFile (root </> file)
    False -> pure $ case configFile of
      DefaultConfigFile -> Right defaultConfig
      ConfigFile _ -> Left ["The configuration file " ++ file ++ " does not exist."]
  where
    file :: FilePath
    file = case configFile of
      DefaultConfigFile -> defaultConfigPath
      ConfigFile path -> path

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
  Mapping entries -> runFields "" configFields entries
  _ -> failure "the configuration must be a mapping"
  where
    configFields :: Fields Config
    configFields = do
      name <- field "name" defaultConfig.name scalar
      cabalVersion <- field "cabal-version" defaultConfig.cabalVersion cabalVersionField
      runsOn <- field "runs-on" defaultConfig.runsOn scalar
      timeoutMinutes <- field "timeout-minutes" defaultConfig.timeoutMinutes positiveInt
      branches <- field "branches" defaultConfig.branches branchesField
      submodules <- field "submodules" defaultConfig.submodules submodulesField
      matrix <- field "matrix" defaultConfig.matrix matrixField
      apt <- field "apt" defaultConfig.apt textList
      services <- field "services" defaultConfig.services (\p n -> Just <$> mappingNode p n)
      permissions <- field "permissions" defaultConfig.permissions permissionsField
      hooks <- field "hooks" defaultConfig.hooks (mappingOf hooksFields)
      ghcOptions <- field "ghc-options" defaultConfig.ghcOptions oneLine
      cabalProjectLocal <- field "cabal-project-local" defaultConfig.cabalProjectLocal projectText
      jobs <- field "jobs" defaultConfig.jobs positiveInt
      tests <- field "tests" defaultConfig.tests bool
      benchmarks <- field "benchmarks" defaultConfig.benchmarks bool
      doctest <- section "doctest" defaultDoctest doctestFields
      check <- field "check" defaultConfig.check bool
      sdist <- field "sdist" defaultConfig.sdist bool
      haddock <- field "haddock" defaultConfig.haddock bool
      fourmolu <- section "fourmolu" defaultFourmolu fourmoluFields
      hlint <- section "hlint" defaultHLint hlintFields
      actions <- field "actions" defaultConfig.actions (mappingOf actionsFields)
      pure Config {..}

    hlintFields :: Fields HLint
    hlintFields = do
      version <- field "version" defaultHLint.version versionField
      failOn <- field "fail-on" defaultHLint.failOn failOnField
      path <- field "path" defaultHLint.path textList
      pure HLint {..}

    failOnField :: String -> Node -> Check T.Text
    failOnField path n =
      text path n `andThen` \t ->
        if t `elem` levels
          then pure t
          else expected path ("one of " ++ T.unpack (T.intercalate ", " levels))
      where
        levels :: [T.Text]
        levels = ["never", "status", "warning", "suggestion", "error"]

    fourmoluFields :: Fields Fourmolu
    fourmoluFields = do
      version <- field "version" defaultFourmolu.version versionField
      patterns <- field "pattern" defaultFourmolu.patterns patternList
      pure Fourmolu {..}

    -- The workflow gives the patterns to the action as a literal block with
    -- one pattern on each line. The YAML writer breaks the block if its first
    -- line starts with a space.
    patternList :: String -> Node -> Check [T.Text]
    patternList path n =
      textList path n `andThen` \ps ->
        if all valid ps
          then pure ps
          else failure $ "field " ++ show path ++ ": a pattern must be one line without spaces at the start or the end"
      where
        valid :: T.Text -> Bool
        valid p = not (T.null p) && T.strip p == p && not (T.any (`elem` ['\n', '\r']) p)

    versionField :: String -> Node -> Check Version
    versionField path n =
      text path n `andThen` \t -> case simpleParsec (T.unpack t) of
        Just v -> pure v
        Nothing -> expected path "a version, e.g. 0.20.1.0"

    actionsFields :: Fields Actions
    actionsFields = do
      checkout <- field "checkout" defaultConfig.actions.checkout ref
      setup <- field "setup" defaultConfig.actions.setup ref
      cache <- field "cache" defaultConfig.actions.cache ref
      runFourmolu <- field "run-fourmolu" defaultConfig.actions.runFourmolu ref
      hlintSetup <- field "hlint-setup" defaultConfig.actions.hlintSetup ref
      hlintRun <- field "hlint-run" defaultConfig.actions.hlintRun ref
      pure Actions {..}

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

    -- The workflow writes the text as one field of a package stanza.
    oneLine :: String -> Node -> Check T.Text
    oneLine path n =
      text path n `andThen` \t ->
        if T.any (`elem` ['\n', '\r']) (T.dropWhileEnd isSpace t)
          then failure $ "field " ++ show path ++ ": the value must be one line"
          else pure (T.strip t)

    hooksFields :: Fields Hooks
    hooksFields = do
      afterSetup <- field "after-setup" [] steps
      afterBuild <- field "after-build" [] steps
      pure Hooks {..}

    doctestFields :: Fields Doctest
    doctestFields = do
      ghc <- field "ghc" defaultDoctest.ghc versionRange
      version <- field "version" defaultDoctest.version (\p n -> Just <$> versionRange p n)
      skip <- field "skip" defaultDoctest.skip textList
      options <- field "options" defaultDoctest.options textList
      pure Doctest {..}

    -- A number beyond the range of Int wraps around. No real job count is
    -- that large, so the reader does not check for it.
    positiveInt :: String -> Node -> Check Int
    positiveInt path = \case
      Scalar Plain t
        | not (T.null t)
        , T.all (`elem` ['0' .. '9']) t
        , n <- read @Int (T.unpack t)
        , n > 0 ->
            pure n
      _ -> expected path "a positive integer"

    cabalVersionField :: String -> Node -> Check CabalVersion
    cabalVersionField path n =
      text path n `andThen` \case
        "latest" -> pure CabalLatest
        t -> case simpleParsec (T.unpack t) of
          Just v
            | take 2 (versionNumbers v) < [3, 12] ->
                failure $ "field " ++ show path ++ ": the tool supports only cabal 3.12 and later"
            | otherwise -> pure $ CabalVersion v
          Nothing -> expected path "latest or a version"

    branchesField :: String -> Node -> Check [Node]
    branchesField path = \case
      Sequence [] -> failure $ "field " ++ show path ++ ": the list must not be empty"
      Sequence items -> traverse (scalar path . (.value)) items
      _ -> expected path "a list of branches"

    submodulesField :: String -> Node -> Check Submodules
    submodulesField path n = case (n, boolValue n) of
      (Scalar _ "recursive", _) -> pure RecursiveSubmodules
      (_, Just True) -> pure TopSubmodules
      (_, Just False) -> pure NoSubmodules
      _ -> expected path "true, false or recursive"

    permissionsField :: String -> Node -> Check Node
    permissionsField path = \case
      n@(Mapping _) -> pure n
      n@(Scalar _ t) | t `elem` ["read-all", "write-all"] -> pure n
      _ -> expected path "a mapping, read-all or write-all"

    steps :: String -> Node -> Check [Item Node]
    steps path = \case
      Sequence items -> items <$ traverse_ (mappingNode (path ++ " item") . (.value)) items
      _ -> expected path "a list of steps"

    matrixField :: String -> Node -> Check [Item (Key, Node)]
    matrixField path = \case
      Mapping entries -> entries <$ traverse_ (entry [k.name | Item _ (k, _) <- entries, k.name `notElem` ["include", "exclude"]]) entries
      _ -> expected path "a mapping"
      where
        entry :: [T.Text] -> Item (Key, Node) -> Check ()
        entry axes (Item _ (k, v))
          | k.name == "ghc" = failure $ "field " ++ show path ++ ": the tool makes the ghc axis, so the matrix must not contain it"
          | k.name `elem` ["include", "exclude"] = case v of
              Sequence items -> traverse_ (combination axes (k.name == "exclude") (path ++ "." ++ T.unpack k.name) . (.value)) items
              _ -> expected (path ++ "." ++ T.unpack k.name) "a list of mappings"
          | not (identifier k.name) =
              failure $
                "field "
                  ++ show path
                  ++ ": the axis name "
                  ++ show (T.unpack k.name)
                  ++ " is not valid in a GitHub expression. A name must start with a letter or _, and contain only letters, digits, _ and -, e.g. os-version"
          | otherwise = pure ()

        -- The job name refers to each axis as matrix.<name>.
        identifier :: T.Text -> Bool
        identifier t = case T.uncons t of
          Just (c, rest) -> (isAsciiAlpha c || c == '_') && T.all (\x -> isAsciiAlpha x || isDigit x || x `elem` ['_', '-']) rest
          Nothing -> False
          where
            isAsciiAlpha :: Char -> Bool
            isAsciiAlpha x = isAsciiLower x || isAsciiUpper x

        combination :: [T.Text] -> Bool -> String -> Node -> Check ()
        combination axes isExclude p = \case
          Mapping fields ->
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

----------------------------------------
-- Fields

-- | A reader of the fields of a mapping. It knows the keys that it reads, so
-- each other key of the mapping is an error.
data Fields a = Fields [T.Text] (T.Text -> [Item (Key, Node)] -> Check a)

instance Functor Fields where
  fmap f (Fields keys reader) = Fields keys (\prefix entries -> f <$> reader prefix entries)

instance Applicative Fields where
  pure a = Fields [] (\_ _ -> pure a)
  Fields keys1 reader1 <*> Fields keys2 reader2 =
    Fields (keys1 ++ keys2) (\prefix entries -> reader1 prefix entries <*> reader2 prefix entries)

-- | Read the entries of a mapping.
runFields
  :: T.Text
  -- ^ The prefix of the field paths for the error messages, e.g. @hlint.@.
  -> Fields a
  -> [Item (Key, Node)]
  -> Check a
runFields prefix (Fields known reader) entries =
  traverse_
    (\k -> failure $ "unknown field " ++ show (T.unpack $ prefix <> k))
    [k.name | Item _ (k, _) <- entries, k.name `notElem` known]
    *> reader prefix entries

-- | Read a field. A missing field or a null value gives the default.
field :: T.Text -> a -> (String -> Node -> Check a) -> Fields a
field k def reader = Fields [k] $ \prefix entries -> case lookupKey k entries of
  Just n | not (isNull n) -> reader (T.unpack $ prefix <> k) n
  _ -> pure def

-- | Read an optional field with a mapping. A missing field gives 'Nothing',
-- and a null value gives the default.
section :: T.Text -> a -> Fields a -> Fields (Maybe a)
section k def fields = Fields [k] $ \prefix entries -> case lookupKey k entries of
  Nothing -> pure Nothing
  Just n
    | isNull n -> pure $ Just def
    | otherwise -> Just <$> mappingOf fields (T.unpack $ prefix <> k) n

-- | Read a mapping with the given fields.
mappingOf :: Fields a -> String -> Node -> Check a
mappingOf fields path = \case
  Mapping entries -> runFields (T.pack path <> ".") fields entries
  _ -> expected path "a mapping"

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

-- The workflow needs quotes for a value that YAML does not read as a string,
-- so the configuration needs them too.
text :: String -> Node -> Check T.Text
text path = \case
  Scalar s t
    | isString s t -> pure t
    | otherwise -> expected path ("a string. Quote the value, e.g. '" ++ T.unpack t ++ "'")
  _ -> expected path "a string"

textList :: String -> Node -> Check [T.Text]
textList path = \case
  Sequence items -> traverse (text path . (.value)) items
  _ -> expected path "a list of strings"

bool :: String -> Node -> Check Bool
bool path n = maybe (expected path "true or false") pure (boolValue n)

boolValue :: Node -> Maybe Bool
boolValue = \case
  Scalar Plain t
    | t `elem` ["true", "True", "TRUE"] -> Just True
    | t `elem` ["false", "False", "FALSE"] -> Just False
  _ -> Nothing

versionRange :: String -> Node -> Check VersionRange
versionRange path n =
  text path n `andThen` \t -> case simpleParsec (T.unpack t) of
    Just r -> pure r
    Nothing -> expected path "a version range"

mappingNode :: String -> Node -> Check Node
mappingNode path = \case
  n@(Mapping _) -> pure n
  _ -> expected path "a mapping"
