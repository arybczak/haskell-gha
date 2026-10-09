{-# OPTIONS_GHC -Wno-orphans #-}

-- | The configuration file.
module HaskellGha.Config
  ( -- * Configuration
    Config (..)
  , CabalVersion (..)
  , Container (..)
  , Submodules (..)
  , Dependencies (..)
  , Hooks (..)
  , Doctest (..)
  , Fourmolu (..)
  , HLint (..)
  , FailOn (..)
  , Actions (..)
  , ActionRef (..)
  , defaultConfig
  , defaultHLint

    -- * Values
  , Optional (..)
  , Positive (..)
  , MappingNode (..)
  , Permissions (..)
  , RunsOn (..)
  , Matrix (..)
  , GhcOptions (..)
  , ProjectText (..)
  , Pattern (..)
  , HLintPath (..)

    -- * Matrix
  , combinationValues

    -- * Reading
  , ConfigFile (..)
  , ConfigSource (..)
  , emptySource
  , sourceErrors
  , defaultConfigPath
  , configPath
  , readConfig
  , parseConfig
  ) where

import Control.Monad
import Data.Bifunctor
import Data.ByteString qualified as BS
import Data.Char
import Data.Foldable
import Data.Functor
import Data.List.NonEmpty qualified as NE
import Data.Maybe
import Data.Text qualified as T
import Distribution.Parsec
import Distribution.Version
import System.Directory hiding (Permissions)
import System.FilePath
import Yamlet
import Yamlet.Syntax

import HaskellGha.Yaml

-- | The configuration.
data Config = Config
  { name :: Commented T.Text
  , cabalVersion :: CabalVersion
  , runsOn :: Commented RunsOn
  , container :: Maybe Container
  , timeoutMinutes :: Positive
  , branches :: Commented (NE.NonEmpty (Commented T.Text))
  , submodules :: Submodules
  , matrix :: Commented Matrix
  , apt :: [T.Text]
  , services :: Maybe (Commented MappingNode)
  , permissions :: Commented Permissions
  , hooks :: Hooks
  , ghcOptions :: GhcOptions
  , cabalProjectLocal :: ProjectText
  , jobs :: Positive
  , tests :: Bool
  , benchmarks :: Bool
  , dependencies :: Dependencies
  , doctest :: Doctest
  , check :: Bool
  , sdist :: Bool
  , haddock :: Bool
  , fourmolu :: Fourmolu
  , hlint :: HLint
  , actions :: Actions
  }
  deriving stock (Eq, Show, Generic)
  deriving (FromYaml) via GenericYaml Config

instance GenericYamlOptions Config where
  yamlOptions = options
  yamlDefault = Just defaultConfig

-- | The configuration of the HLint job.
data HLint = HLint
  { enabled :: Bool
  , version :: Version
  , failOn :: FailOn
  , path :: [Located HLintPath]
  -- ^ Relative to the project directory. An empty list gives the project
  -- directory.
  , runsOn :: Optional (Commented RunsOn)
  -- ^ 'Nothing' gives the @runs-on@ of the build jobs.
  }
  deriving stock (Eq, Show, Generic)
  deriving (FromYaml) via GenericYaml HLint

instance GenericYamlOptions HLint where
  yamlOptions = options
  yamlDefault = Just defaultHLint

-- | The lowest hint level that fails the HLint job.
data FailOn
  = FailNever
  | FailStatus
  | FailWarning
  | FailSuggestion
  | FailError
  deriving stock (Eq, Show, Generic)
  deriving (FromYaml, ToYaml) via GenericYaml FailOn

instance GenericYamlOptions FailOn where
  yamlOptions = defaultYamlOptions {constructorTagModifier = map toLower . drop (length @[] "Fail")}

-- | The configuration of the fourmolu job.
data Fourmolu = Fourmolu
  { enabled :: Bool
  , version :: Version
  , patterns :: [Pattern]
  -- ^ The files to check. An empty list gives the default of the action.
  , runsOn :: Optional (Commented RunsOn)
  -- ^ 'Nothing' gives the @runs-on@ of the build jobs.
  }
  deriving stock (Eq, Show, Generic)
  deriving (FromYaml) via GenericYaml Fourmolu

instance GenericYamlOptions Fourmolu where
  yamlOptions =
    options
      { fieldLabelModifier = \case
          "patterns" -> "pattern"
          f -> kebabCase f
      }
  yamlDefault = Just defaultFourmolu

-- | The versions of the actions.
data Actions = Actions
  { checkout :: ActionRef
  , setup :: ActionRef
  , cache :: ActionRef
  -- ^ For both @actions/cache/restore@ and @actions/cache/save@.
  , runFourmolu :: ActionRef
  , hlintSetup :: ActionRef
  , hlintRun :: ActionRef
  }
  deriving stock (Eq, Show, Generic)
  deriving (FromYaml) via GenericYaml Actions

instance GenericYamlOptions Actions where
  yamlOptions = options
  yamlDefault = Just defaultConfig.actions

-- | The version of an action in @uses@.
data ActionRef = ActionRef
  { repository :: Maybe T.Text
  -- ^ A repository in place of the default one, e.g. a fork.
  , ref :: T.Text
  -- ^ The Git ref after the @\@@.
  }
  deriving stock (Eq, Show)

-- | A Git ref, e.g. @v7@, or a repository with a Git ref, e.g.
-- @runs-on/cache\@v4@.
instance FromYaml ActionRef where
  parseYaml = withText $ \t -> case T.splitOn "@" t of
    [r] | word r -> pure ActionRef {repository = Nothing, ref = r}
    [repo, r]
      | [owner, name] <- T.splitOn "/" repo
      , all word [owner, name, r] ->
          pure ActionRef {repository = Just repo, ref = r}
    _ ->
      fail "expected a Git ref, e.g. v7, or a repository with a Git ref, e.g. runs-on/cache@v4"
    where
      word :: T.Text -> Bool
      word w = not (T.null w) && not (T.any isSpace w)

-- | The cabal version for @haskell-actions/setup@.
data CabalVersion
  = CabalLatest
  | CabalVersion Version
  deriving stock (Eq, Show)

instance FromYaml CabalVersion where
  parseYaml = withText $ \case
    "latest" -> pure CabalLatest
    t -> case simpleParsec (T.unpack t) of
      Just v
        | take 2 (versionNumbers v) < [3, 12] ->
            fail "the tool supports only cabal 3.12 and later"
        | otherwise -> pure $ CabalVersion v
      Nothing -> fail "expected latest or a version"

-- | The image of the job container of the build jobs, e.g.
-- @buildpack-deps:26.04@.
newtype Container = Container {image :: T.Text}
  deriving stock (Eq, Show)

instance FromYaml Container where
  parseYaml = oneOf [(i, Container i) | v <- versions, let i = "buildpack-deps:" <> v]
    where
      -- The Ubuntu versions of the buildpack-deps images of the LTS releases,
      -- from the file library/buildpack-deps of docker-library/official-images
      -- on 2026-09-27. An interim release has support for only 9 months, so the
      -- list leaves it out. The tool accepts only the images that it knows,
      -- because another image can lack a package that the workflow needs, e.g.
      -- git or xz-utils.
      versions :: [T.Text]
      versions = ["22.04", "24.04", "26.04"]

-- | The versions of the dependencies that the build jobs use.
data Dependencies
  = DependenciesNewest
  | -- | The oldest versions that the bounds allow.
    DependenciesOldest
  | -- | A job for each of the two, as the values of a matrix axis.
    DependenciesBoth
  deriving stock (Eq, Show, Generic)
  deriving (FromYaml) via GenericYaml Dependencies

instance GenericYamlOptions Dependencies where
  yamlOptions =
    defaultYamlOptions
      { constructorTagModifier = map toLower . drop (length @[] "Dependencies")
      }

-- | The Git submodules that the build jobs fetch.
data Submodules
  = NoSubmodules
  | -- | The submodules of the repository, without their own submodules.
    TopSubmodules
  | RecursiveSubmodules
  deriving stock (Eq, Show)

instance FromYaml Submodules where
  parseYaml n = case view n of
    StringView "recursive" -> pure RecursiveSubmodules
    BoolView True -> pure TopSubmodules
    BoolView False -> pure NoSubmodules
    _ -> failAt n "expected true, false or recursive"

-- | The steps that the tool puts in the workflow.
data Hooks = Hooks
  { afterSetup :: [MappingNode]
  , afterBuild :: [MappingNode]
  }
  deriving stock (Eq, Show, Generic)
  deriving (FromYaml) via GenericYaml Hooks

instance GenericYamlOptions Hooks where
  yamlOptions = options
  yamlDefault = Just defaultConfig.hooks

-- | The configuration of doctest.
data Doctest = Doctest
  { enabled :: Bool
  , ghc :: Located VersionRange
  , version :: Optional VersionRange
  , skip :: [Located T.Text]
  , options :: [T.Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving (FromYaml) via GenericYaml Doctest

instance GenericYamlOptions Doctest where
  yamlOptions = options
  yamlDefault = Just defaultDoctest

-- | The options of the records of the configuration.
options :: YamlOptions
options = defaultYamlOptions {fieldLabelModifier = kebabCase}

-- | The configuration if the file does not exist.
defaultConfig :: Config
defaultConfig =
  Config
    { name = bare "CI"
    , cabalVersion = CabalVersion (mkVersion [3, 16, 1, 0])
    , runsOn = bare (RunsOn (plain "ubuntu-26.04"))
    , container = Nothing
    , -- Without a limit, GitHub stops a job only after six hours. A build
      -- usually takes way less than an hour, so 60 leaves room for a build
      -- without a cache.
      timeoutMinutes = Positive 60
    , branches = bare (bare "master" NE.:| [bare "main"])
    , submodules = NoSubmodules
    , matrix =
        bare
          Matrix
            { leading = []
            , entries = []
            , axes = []
            , include = []
            , exclude = []
            }
    , apt = []
    , services = Nothing
    , permissions = bare (Permissions (mapping ["contents" .= plain "read"]))
    , hooks = Hooks {afterSetup = [], afterBuild = []}
    , ghcOptions = GhcOptions "-Werror"
    , cabalProjectLocal = ProjectText ""
    , -- The standard Linux runners of GitHub have 4 CPUs.
      jobs = Positive 4
    , tests = True
    , benchmarks = True
    , dependencies = DependenciesNewest
    , doctest = defaultDoctest
    , check = True
    , sdist = True
    , haddock = True
    , fourmolu = defaultFourmolu
    , hlint = defaultHLint
    , actions =
        Actions
          { checkout = ActionRef {repository = Nothing, ref = "v7"}
          , setup = ActionRef {repository = Nothing, ref = "v2"}
          , cache = ActionRef {repository = Nothing, ref = "v6"}
          , runFourmolu = ActionRef {repository = Nothing, ref = "v13"}
          , -- The commits "Upgrade to node24". Each release still needs
            -- Node.js 20.
            hlintSetup =
              ActionRef
                { repository = Nothing
                , ref = "c04631035af0a6787c85e33b3ea0128b8568b590"
                }
          , hlintRun =
              ActionRef
                { repository = Nothing
                , ref = "d009541bdae0b8492992416e665bb6df8a3b5cde"
                }
          }
    }
  where
    bare :: a -> Commented a
    bare a = Commented a noComments

-- | The HLint configuration without an @hlint@ field.
defaultHLint :: HLint
defaultHLint =
  HLint
    { enabled = False
    , version = mkVersion [3, 10]
    , failOn = FailSuggestion
    , path = []
    , runsOn = Optional Nothing
    }

-- | The fourmolu configuration without a @fourmolu@ field. Version 0.20 and
-- later needs run-fourmolu v13 or later.
defaultFourmolu :: Fourmolu
defaultFourmolu =
  Fourmolu
    { enabled = False
    , version = mkVersion [0, 21, 0, 0]
    , patterns = []
    , runsOn = Optional Nothing
    }

-- | The doctest configuration without a @doctest@ field.
defaultDoctest :: Doctest
defaultDoctest =
  Doctest
    { enabled = False
    , ghc = Located anyVersion noOffset
    , version = Optional Nothing
    , skip = []
    , options = []
    }

----------------------------------------
-- Values

-- | A version, e.g. @0.21.0.0@. It must be a string, because YAML reads e.g.
-- @3.10@ as the number 3.1.
instance FromYaml Version where
  parseYaml = withText $ \t -> maybe (fail "expected a version, e.g. 0.21.0.0") pure (simpleParsec (T.unpack t))

-- | A version range, e.g. @>=9.6 && <9.14@.
instance FromYaml VersionRange where
  parseYaml = withText $ \t -> maybe (fail "expected a version range") pure (simpleParsec (T.unpack t))

-- | A value that only a missing key leaves out. Unlike for 'Maybe', null is an
-- error.
newtype Optional a = Optional {value :: Maybe a}
  deriving newtype (Eq, Show)

instance FromYaml a => FromYaml (Optional a) where
  parseYaml n = Optional . Just <$> parseYaml n
  parseYamlField k n = Optional . Just <$> parseYamlField k n

-- | A positive integer.
newtype Positive = Positive {value :: Int}
  deriving newtype (Eq, Show)

instance FromYaml Positive where
  parseYaml n = case view n of
    IntView i
      | i > 0
      , i <= toInteger (maxBound @Int) ->
          pure $ Positive (fromInteger i)
    _ -> failAt n "expected a positive integer"

-- | A mapping that the workflow copies, e.g. a step of a hook.
newtype MappingNode = MappingNode {value :: Node}
  deriving newtype (Eq, Show, ToYaml)

instance FromYaml MappingNode where
  parseYaml n = case n.content of
    MappingContent {} -> MappingNode <$> parseYaml n
    _ -> typeMismatch "a mapping" n

-- | The permissions of the workflow: a mapping, @read-all@ or @write-all@.
newtype Permissions = Permissions {value :: Node}
  deriving newtype (Eq, Show, ToYaml)

instance FromYaml Permissions where
  parseYaml n = case view n of
    MappingView _ -> Permissions <$> parseYaml n
    StringView t | t `elem` ["read-all", "write-all"] -> Permissions <$> parseYaml n
    _ -> failAt n "expected a mapping, read-all or write-all"

-- | The runner of a job: a label, a list of labels or a mapping, e.g. with
-- @group@ and @labels@.
newtype RunsOn = RunsOn {value :: Node}
  deriving newtype (Eq, Show, ToYaml)

instance FromYaml RunsOn where
  parseYaml n = case view n of
    StringView _ -> RunsOn <$> parseYaml n
    SequenceView _ -> parseYaml @[T.Text] n *> (RunsOn <$> parseYaml n)
    MappingView _ -> RunsOn <$> parseYaml n
    _ -> failAt n "expected a runner label, a list of labels or a mapping"

-- | The @ghc-options@ of the local packages. The workflow writes them as one
-- field of a package stanza, so they must be one line.
newtype GhcOptions = GhcOptions {value :: T.Text}
  deriving newtype (Eq, Show)

instance FromYaml GhcOptions where
  parseYaml = withText $ \t ->
    if T.any (`elem` ['\n', '\r']) (T.dropWhileEnd isSpace t)
      then fail "the value must be one line"
      else pure $ GhcOptions (T.strip t)

-- | Extra text for @cabal.project.local@. The workflow writes the text with a
-- heredoc that ends at the line EOF.
newtype ProjectText = ProjectText {value :: T.Text}
  deriving newtype (Eq, Show)

instance FromYaml ProjectText where
  parseYaml = withText $ \t ->
    if "EOF" `elem` T.lines t
      then fail "a line must not be EOF"
      else pure $ ProjectText t

-- | A pattern of the files that fourmolu checks. The workflow gives the
-- patterns to the action as a literal block with one pattern on each line. The
-- YAML writer breaks the block if its first line starts with a space.
newtype Pattern = Pattern {value :: T.Text}
  deriving newtype (Eq, Show)

instance FromYaml Pattern where
  parseYaml = withText $ \p ->
    if not (T.null p) && T.strip p == p && not (T.any (`elem` ['\n', '\r']) p)
      then pure $ Pattern p
      else fail "a pattern must be one line without spaces at the start or the end"

-- | A path that the HLint job checks. The workflow gives the paths to the
-- action in a JSON array, and a JSON string cannot contain a raw control
-- character.
newtype HLintPath = HLintPath {value :: T.Text}
  deriving newtype (Eq, Show)

instance FromYaml HLintPath where
  parseYaml = withText $ \p -> case () of
    _
      | T.null p -> fail "a path must not be empty"
      | T.any isControl p ->
          fail "a path must not contain a control character, e.g. a tab or a line break"
      | otherwise -> pure $ HLintPath p

----------------------------------------
-- Matrix

-- | The extra axes of the matrix, with @include@ and @exclude@.
data Matrix = Matrix
  { leading :: [Line]
  -- ^ The comments below @matrix:@ and above an empty line before its first
  -- entry. The parser gives the comments below the empty line to that entry.
  , entries :: [(Node, Node)]
  , axes :: [Located T.Text]
  -- ^ The names of the extra axes.
  , include :: [[(T.Text, Located T.Text)]]
  -- ^ The keys of each entry with their string values.
  , exclude :: [[(T.Text, Located T.Text)]]
  -- ^ The keys of each entry with their string values.
  }
  deriving stock (Eq, Show)

-- | The values of a key in the entries of @include@ or @exclude@, e.g. of
-- @ghc@.
combinationValues :: T.Text -> [[(T.Text, Located T.Text)]] -> [Located T.Text]
combinationValues key cs = [v | c <- cs, Just v <- [lookup key c]]

instance FromYaml Matrix where
  parseYaml n = case m.content of
    MappingContent _ es ->
      traverse_ (entry (map (.value) (axes es))) es
        $> Matrix
          { leading = m.comments.before
          , entries = es
          , axes = axes es
          , include = combinations "include" es
          , exclude = combinations "exclude" es
          }
    _ -> typeMismatch "a mapping" n
    where
      -- A copy of every text, so the configuration does not keep the input file
      -- in memory.
      m :: Node
      m = copyNode n

      axes :: [(Node, Node)] -> [Located T.Text]
      axes es =
        [ Located k key.offset
        | (key@Node {content = ScalarContent _ k}, _) <- es
        , k `notElem` ["ghc", "include", "exclude"]
        ]

      combinations :: T.Text -> [(Node, Node)] -> [[(T.Text, Located T.Text)]]
      combinations list es =
        [ [ (f, Located t v.offset)
          | (Node {content = ScalarContent _ f}, v@Node {content = ScalarContent _ t}) <- fields
          ]
        | (Node {content = ScalarContent _ k}, Node {content = SequenceContent _ items}) <- es
        , k == list
        , Node {content = MappingContent _ fields} <- items
        ]

      entry :: [T.Text] -> (Node, Node) -> Parser ()
      entry as = \case
        (key@Node {content = ScalarContent _ k}, v)
          | k == "ghc" ->
              failAt key "the tool makes the ghc axis, so the matrix must not contain it"
          | k `elem` ["include", "exclude"] -> case v.content of
              SequenceContent _ items -> traverse_ (combination as (k == "exclude")) items
              _ -> typeMismatch "a list of mappings" v
          | not (identifier k) ->
              failAt key $
                "the axis name "
                  ++ show (T.unpack k)
                  ++ " is not valid in a GitHub expression. A name must start with a letter or _, and contain only letters, digits, _ and -, e.g. os-version"
          | otherwise -> pure ()
        (key, _) -> failAt key "an axis name must be a string"

      -- The job name refers to each axis as matrix.<name>.
      identifier :: T.Text -> Bool
      identifier t = case T.uncons t of
        Just (c, rest) ->
          (isAsciiAlpha c || c == '_')
            && T.all (\x -> isAsciiAlpha x || isDigit x || x `elem` ['_', '-']) rest
        Nothing -> False
        where
          isAsciiAlpha :: Char -> Bool
          isAsciiAlpha x = isAsciiLower x || isAsciiUpper x

      combination :: [T.Text] -> Bool -> Node -> Parser ()
      combination as isExclude item = case item.content of
        MappingContent _ fields ->
          ghcValue fields
            -- Whether dependencies is a valid key depends on the dependencies
            -- setting, so the checks of the workflow decide it.
            *> when
              isExclude
              ( traverse_
                  (unknownAxis as)
                  [ (key, k)
                  | (key@Node {content = ScalarContent _ k}, _) <- fields
                  , k `notElem` ["ghc", "dependencies"]
                  ]
              )
        _ -> typeMismatch "a mapping" item

      ghcValue :: [(Node, Node)] -> Parser ()
      ghcValue fields = case [v | (Node {content = ScalarContent _ "ghc"}, v) <- fields] of
        Node {content = ScalarContent s _} : _ | s `elem` [SingleQuoted, DoubleQuoted] -> pure ()
        v : _ -> failAt v "a ghc value must be a quoted string, e.g. '9.10'"
        [] -> pure ()

      unknownAxis :: [T.Text] -> (Node, T.Text) -> Parser ()
      unknownAxis as (key, axis)
        | axis `elem` as = pure ()
        | otherwise =
            failAt key $
              T.unpack axis
                ++ " is not an axis of the matrix. The axes are: "
                ++ T.unpack (T.intercalate ", " ("ghc" : as))

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
defaultConfigPath = ".github/haskell-gha.conf.yaml"

-- | The configuration file, for the errors of the checks after the decode.
data ConfigSource = ConfigSource
  { file :: FilePath
  , input :: T.Text
  , document :: Document
  }

-- | The source of a configuration without a file, e.g. of 'defaultConfig'.
emptySource :: FilePath -> ConfigSource
emptySource file =
  ConfigSource
    { file = file
    , input = ""
    , document = document nullValue
    }

-- | The errors at the offsets of values of the configuration, e.g. of 'Located'
-- values.
sourceErrors :: ConfigSource -> [(Offset, String)] -> [String]
sourceErrors source = map (prettyError source.file) . documentErrors source.input source.document

-- | Read the configuration file. If the default file does not exist, the result
-- is 'defaultConfig'.
readConfig
  :: FilePath
  -- ^ The root of the repository.
  -> ConfigFile
  -> IO (Either [String] (Config, ConfigSource))
readConfig root configFile =
  doesFileExist (root </> file) >>= \case
    True -> parseConfig file <$> BS.readFile (root </> file)
    False ->
      -- The entry of the name in its directory does not show a path such as
      -- . or a/, so the directory needs its own check.
      ((||) <$> doesDirectoryExist (root </> file) <*> hasEntry) <&> \case
        -- Also for the default file, because the defaults would hide the broken
        -- file.
        True ->
          Left
            ["The configuration file " ++ file ++ " is a directory or a broken symbolic link."]
        False -> case configFile of
          DefaultConfigFile -> Right (defaultConfig, emptySource file)
          ConfigFile _ -> Left ["The configuration file " ++ file ++ " does not exist."]
  where
    -- Whether the directory of the file has an entry with its name. Unlike
    -- doesPathExist, this is also true for a broken symbolic link.
    hasEntry :: IO Bool
    hasEntry =
      doesDirectoryExist parent >>= \case
        True -> elem (takeFileName file) <$> listDirectory parent
        False -> pure False
      where
        parent :: FilePath
        parent = takeDirectory (root </> file)

    file :: FilePath
    file = configPath configFile

-- | The path of the configuration file, relative to the root of the repository.
configPath :: ConfigFile -> FilePath
configPath = \case
  DefaultConfigFile -> defaultConfigPath
  ConfigFile path -> path

-- | Parse the configuration. An empty file gives 'defaultConfig'.
parseConfig
  :: FilePath
  -- ^ The file name for the error messages.
  -> BS.ByteString
  -> Either [String] (Config, ConfigSource)
parseConfig file bytes = first (map (prettyError file)) $ do
  input <- first pure (decodeInput bytes)
  (config, doc) <- first NE.toList (decodeWithDocument input)
  pure
    ( fromMaybe defaultConfig config
    , ConfigSource {file = file, input = input, document = doc}
    )
