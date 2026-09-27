{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | The configuration file.
module HaskellGha.Config
  ( -- * Configuration
    Config (..)
  , CabalVersion (..)
  , Submodules (..)
  , KeyComments (..)
  , Hooks (..)
  , Hook (..)
  , Doctest (..)
  , Fourmolu (..)
  , HLint (..)
  , Actions (..)
  , ActionRef (..)
  , defaultConfig
  , defaultDoctest
  , defaultFourmolu
  , defaultHLint

    -- * Matrix
  , matrixEntries
  , matrixAxes
  , matrixGhcValues

    -- * Reading
  , ConfigFile (..)
  , defaultConfigPath
  , readConfig
  , parseConfig
  ) where

import Control.Monad
import Data.ByteString qualified as BS
import Data.Char
import Data.Foldable
import Data.List qualified as L
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
  , matrix :: Node
  -- ^ A mapping with the extra axes, @include@ and @exclude@.
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
  , keyComments :: KeyComments
  }
  deriving stock (Eq, Show)

-- | The comments above the keys that the workflow copies with their values.
-- The comments inside a value stay in the value.
data KeyComments = KeyComments
  { matrix :: Comments
  , services :: Comments
  , permissions :: Comments
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
  deriving stock (Eq, Show)

-- | The version of an action in @uses@.
data ActionRef = ActionRef
  { repository :: Maybe T.Text
  -- ^ A repository in place of the default one, e.g. a fork.
  , ref :: T.Text
  -- ^ The Git ref after the @\@@.
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
  { afterSetup :: Hook
  , afterBuild :: Hook
  }
  deriving stock (Eq, Show)

-- | The steps of a hook. The comments above the hook list are in the first
-- step.
data Hook = Hook
  { steps :: [Node]
  , trailing :: [Line]
  -- ^ The comment lines after the last step.
  }
  deriving stock (Eq, Show)

-- | A hook without steps.
noHook :: Hook
noHook = Hook [] []

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
    , matrix = mapping []
    , apt = []
    , services = Nothing
    , permissions = mapping [("contents", plain "read")]
    , hooks = Hooks noHook noHook
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
          { checkout = ActionRef Nothing "v7"
          , setup = ActionRef Nothing "v2"
          , cache = ActionRef Nothing "v6"
          , runFourmolu = ActionRef Nothing "v13"
          , -- The commits "Upgrade to node24". Each release still needs
            -- Node.js 20.
            hlintSetup = ActionRef Nothing "c04631035af0a6787c85e33b3ea0128b8568b590"
          , hlintRun = ActionRef Nothing "d009541bdae0b8492992416e665bb6df8a3b5cde"
          }
    , keyComments = KeyComments noComments noComments noComments
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

-- | The entries of the @matrix@ mapping.
matrixEntries :: Config -> [(Node, Node)]
matrixEntries config = case config.matrix.content of
  Mapping _ entries -> entries
  _ -> []

-- | The names of the extra axes.
matrixAxes :: Config -> [T.Text]
matrixAxes config =
  [ k
  | (Node {content = Scalar _ k}, _) <- matrixEntries config
  , k `notElem` ["include", "exclude"]
  ]

-- | The values of @ghc@ in @include@ and @exclude@.
matrixGhcValues :: Config -> [T.Text]
matrixGhcValues config =
  [ v
  | (Node {content = Scalar _ k}, Node {content = Sequence _ entries}) <- matrixEntries config
  , k `elem` ["include", "exclude"]
  , Node {content = Mapping _ fields} <- entries
  , Just Node {content = Scalar _ v} <- [lookupKey "ghc" fields]
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
    True -> parseConfig file <$> BS.readFile (root </> file)
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
  -> BS.ByteString
  -> Either [String] Config
parseConfig file bytes = case decodeInput bytes of
  Left e -> Left [prettyError file e]
  Right input -> case parseYaml input of
    Left e -> Left [prettyError file e]
    Right Nothing -> Right defaultConfig
    Right (Just root) -> case runCheck (configFromNode root) of
      Left errors -> Left [prettyError file (errorAt input off msg) | (off, msg) <- L.sortOn fst errors]
      Right config -> Right config

-- | A check of the configuration. Each error has the position of the node
-- that caused it.
type ConfigCheck = Validation (Offset, String)

configFromNode :: Node -> ConfigCheck Config
configFromNode root = case root.content of
  Mapping _ entries -> runFields "" configFields (topComment entries)
  _ -> failAt root "the configuration must be a mapping"
  where
    -- A comment at the top of the file belongs to the root. It goes to the
    -- workflow only with a first key that the workflow copies.
    topComment :: [(Node, Node)] -> [(Node, Node)]
    topComment = \case
      (k, v) : rest
        | keyName k `elem` map Just ["matrix", "services", "permissions", "hooks"] ->
            (addBefore root.comments.before k, v) : rest
      entries -> entries

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
      services <- field "services" defaultConfig.services (\p n -> Just <$> mappingValue p n)
      permissions <- field "permissions" defaultConfig.permissions permissionsField
      hooks <- fieldWithKey "hooks" defaultConfig.hooks hooksField
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
      keyComments <- KeyComments <$> keyComment "matrix" <*> keyComment "services" <*> keyComment "permissions"
      pure Config {..}

    -- The workflow makes the same key, so the comment at the end of its line
    -- stays there.
    keyComment :: T.Text -> Fields Comments
    keyComment k = Fields [] $ \_ entries ->
      pure $ case lookupEntry k entries of
        Just (key, _) -> Comments (filter (/= EmptyLine) key.comments.before) key.comments.inline []
        Nothing -> noComments

    -- The comments above the hooks go before the first step, and the
    -- comments after the last hook list go after the last step.
    hooksField :: String -> Node -> Node -> ConfigCheck Hooks
    hooksField path key n = place <$> mappingOf hooksFields path n
      where
        place :: Hooks -> Hooks
        place (Hooks setup build)
          | null setup.steps = Hooks setup (end (leadHook ls build))
          | null build.steps = Hooks (end (leadHook ls setup)) build
          | otherwise = Hooks (leadHook ls setup) (end build)

        ls :: [Line]
        ls = commentLines key.comments ++ commentLines n.comments

        end :: Hook -> Hook
        end h = Hook h.steps (h.trailing ++ filter (/= EmptyLine) n.comments.after)

    hookField :: String -> Node -> Node -> ConfigCheck Hook
    hookField path key n =
      (\items -> leadHook (commentLines key.comments ++ commentLines n.comments) (Hook items (filter (/= EmptyLine) n.comments.after)))
        <$> steps path n

    hlintFields :: Fields HLint
    hlintFields = do
      version <- field "version" defaultHLint.version versionField
      failOn <- field "fail-on" defaultHLint.failOn failOnField
      path <- field "path" defaultHLint.path textList
      pure HLint {..}

    failOnField :: String -> Node -> ConfigCheck T.Text
    failOnField path n =
      text path n `andThen` \t ->
        if t `elem` levels
          then pure t
          else expected path n ("one of " ++ T.unpack (T.intercalate ", " levels))
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
    patternList :: String -> Node -> ConfigCheck [T.Text]
    patternList path n =
      textList path n `andThen` \ps ->
        if all valid ps
          then pure ps
          else failAt n $ "key " ++ show path ++ ": a pattern must be one line without spaces at the start or the end"
      where
        valid :: T.Text -> Bool
        valid p = not (T.null p) && T.strip p == p && not (T.any (`elem` ['\n', '\r']) p)

    versionField :: String -> Node -> ConfigCheck Version
    versionField path n =
      text path n `andThen` \t -> case simpleParsec (T.unpack t) of
        Just v -> pure v
        Nothing -> expected path n "a version, e.g. 0.20.1.0"

    actionsFields :: Fields Actions
    actionsFields = do
      checkout <- field "checkout" defaultConfig.actions.checkout actionRef
      setup <- field "setup" defaultConfig.actions.setup actionRef
      cache <- field "cache" defaultConfig.actions.cache actionRef
      runFourmolu <- field "run-fourmolu" defaultConfig.actions.runFourmolu actionRef
      hlintSetup <- field "hlint-setup" defaultConfig.actions.hlintSetup actionRef
      hlintRun <- field "hlint-run" defaultConfig.actions.hlintRun actionRef
      pure Actions {..}

    actionRef :: String -> Node -> ConfigCheck ActionRef
    actionRef path n =
      text path n `andThen` \t -> case T.splitOn "@" t of
        [r] | word r -> pure $ ActionRef Nothing r
        [repo, r]
          | [owner, name] <- T.splitOn "/" repo
          , all word [owner, name, r] ->
              pure $ ActionRef (Just repo) r
        _ -> expected path n "a Git ref, e.g. v7, or a repository with a Git ref, e.g. runs-on/cache@v4"
      where
        word :: T.Text -> Bool
        word w = not (T.null w) && not (T.any isSpace w)

    -- The workflow writes the text with a heredoc that ends at the line EOF.
    projectText :: String -> Node -> ConfigCheck T.Text
    projectText path n =
      text path n `andThen` \t ->
        if "EOF" `elem` T.lines t
          then failAt n $ "key " ++ show path ++ ": a line must not be EOF"
          else pure t

    -- The workflow writes the text as one field of a package stanza.
    oneLine :: String -> Node -> ConfigCheck T.Text
    oneLine path n =
      text path n `andThen` \t ->
        if T.any (`elem` ['\n', '\r']) (T.dropWhileEnd isSpace t)
          then failAt n $ "key " ++ show path ++ ": the value must be one line"
          else pure (T.strip t)

    hooksFields :: Fields Hooks
    hooksFields = do
      afterSetup <- fieldWithKey "after-setup" noHook hookField
      afterBuild <- fieldWithKey "after-build" noHook hookField
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
    positiveInt :: String -> Node -> ConfigCheck Int
    positiveInt path n = case n.content of
      Scalar Plain t
        | not (T.null t)
        , T.all (`elem` ['0' .. '9']) t
        , i <- read @Int (T.unpack t)
        , i > 0 ->
            pure i
      _ -> expected path n "a positive integer"

    cabalVersionField :: String -> Node -> ConfigCheck CabalVersion
    cabalVersionField path n =
      text path n `andThen` \case
        "latest" -> pure CabalLatest
        t -> case simpleParsec (T.unpack t) of
          Just v
            | take 2 (versionNumbers v) < [3, 12] ->
                failAt n $ "key " ++ show path ++ ": the tool supports only cabal 3.12 and later"
            | otherwise -> pure $ CabalVersion v
          Nothing -> expected path n "latest or a version"

    branchesField :: String -> Node -> ConfigCheck [Node]
    branchesField path n = case n.content of
      Sequence _ [] -> failAt n $ "key " ++ show path ++ ": the list must not be empty"
      Sequence _ items -> traverse (scalar path) items
      _ -> mismatch path n "a list of branches"

    submodulesField :: String -> Node -> ConfigCheck Submodules
    submodulesField path n = case (n.content, boolValue n) of
      (Scalar _ "recursive", _) -> pure RecursiveSubmodules
      (_, Just True) -> pure TopSubmodules
      (_, Just False) -> pure NoSubmodules
      _ -> expected path n "true, false or recursive"

    permissionsField :: String -> Node -> ConfigCheck Node
    permissionsField path n = case n.content of
      Mapping {} -> pure n
      Scalar _ t | t `elem` ["read-all", "write-all"] -> pure n
      _ -> expected path n "a mapping, read-all or write-all"

    steps :: String -> Node -> ConfigCheck [Node]
    steps path n = case n.content of
      Sequence _ items -> items <$ traverse_ (mappingValue (path ++ " item")) items
      _ -> mismatch path n "a list of steps"

    matrixField :: String -> Node -> ConfigCheck Node
    matrixField path n = case n.content of
      Mapping _ entries -> n <$ traverse_ (entry [k | (Node {content = Scalar _ k}, _) <- entries, k `notElem` ["include", "exclude"]]) entries
      _ -> mismatch path n "a mapping"
      where
        entry :: [T.Text] -> (Node, Node) -> ConfigCheck ()
        entry axes (key@Node {content = Scalar _ k}, v)
          | k == "ghc" = failAt key $ "key " ++ show path ++ ": the tool makes the ghc axis, so the matrix must not contain it"
          | k `elem` ["include", "exclude"] = case v.content of
              Sequence _ items -> traverse_ (combination axes (k == "exclude") (path ++ "." ++ T.unpack k)) items
              _ -> mismatch (path ++ "." ++ T.unpack k) v "a list of mappings"
          | not (identifier k) =
              failAt key $
                "key "
                  ++ show path
                  ++ ": the axis name "
                  ++ show (T.unpack k)
                  ++ " is not valid in a GitHub expression. A name must start with a letter or _, and contain only letters, digits, _ and -, e.g. os-version"
          | otherwise = pure ()
        -- The parser accepts only scalar keys.
        entry _ _ = pure ()

        -- The job name refers to each axis as matrix.<name>.
        identifier :: T.Text -> Bool
        identifier t = case T.uncons t of
          Just (c, rest) -> (isAsciiAlpha c || c == '_') && T.all (\x -> isAsciiAlpha x || isDigit x || x `elem` ['_', '-']) rest
          Nothing -> False
          where
            isAsciiAlpha :: Char -> Bool
            isAsciiAlpha x = isAsciiLower x || isAsciiUpper x

        combination :: [T.Text] -> Bool -> String -> Node -> ConfigCheck ()
        combination axes isExclude p item = case item.content of
          Mapping _ fields ->
            ghcValue p fields
              *> when isExclude (traverse_ (unknownAxis axes p) [(key, k) | (key@Node {content = Scalar _ k}, _) <- fields, k /= "ghc"])
          _ -> mismatch (p ++ " item") item "a mapping"

        ghcValue :: String -> [(Node, Node)] -> ConfigCheck ()
        ghcValue p fields = case lookupKey "ghc" fields of
          Just Node {content = Scalar s _} | s `elem` [SingleQuoted, DoubleQuoted] -> pure ()
          Just value -> failAt value $ "key " ++ show p ++ ": a ghc value must be a quoted string, e.g. '9.10'"
          Nothing -> pure ()

        unknownAxis :: [T.Text] -> String -> (Node, T.Text) -> ConfigCheck ()
        unknownAxis axes p (key, name)
          | name `elem` axes = pure ()
          | otherwise =
              failAt key $
                "key "
                  ++ show p
                  ++ ": "
                  ++ T.unpack name
                  ++ " is not an axis of the matrix. The axes are: "
                  ++ T.unpack (T.intercalate ", " ("ghc" : axes))

----------------------------------------
-- Fields

-- | A reader of the fields of a mapping. It knows the keys that it reads, so
-- each other key of the mapping is an error.
data Fields a = Fields [T.Text] (T.Text -> [(Node, Node)] -> ConfigCheck a)

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
  -> [(Node, Node)]
  -> ConfigCheck a
runFields prefix (Fields known reader) entries =
  traverse_
    (\(key, k) -> failAt key $ "unknown key " ++ show (T.unpack $ prefix <> k) ++ knownKeys)
    [(key, k) | (key@Node {content = Scalar _ k}, _) <- entries, k `notElem` known]
    *> reader prefix entries
  where
    -- The top level has too many keys for a list in one message.
    knownKeys :: String
    knownKeys
      | T.null prefix = ""
      | otherwise = ", expected one of: " ++ L.intercalate ", " (map T.unpack known)

-- | Read a field. A missing field or a null value gives the default.
field :: T.Text -> a -> (String -> Node -> ConfigCheck a) -> Fields a
field k def reader = fieldWithKey k def (\path _ n -> reader path n)

-- | Read a field with a reader that also gets the key node.
fieldWithKey :: T.Text -> a -> (String -> Node -> Node -> ConfigCheck a) -> Fields a
fieldWithKey k def reader = Fields [k] $ \prefix entries -> case lookupEntry k entries of
  Just (key, n) | not (isNull n) -> reader (T.unpack $ prefix <> k) key n
  _ -> pure def

-- | The comments above a node and at the end of its first line, as lines.
-- The empty lines are left out, because the workflow has its own layout.
commentLines :: Comments -> [Line]
commentLines c = filter (/= EmptyLine) c.before ++ [Comment t | Just t <- [c.inline]]

-- | Put lines before the first step of a hook.
leadHook :: [Line] -> Hook -> Hook
leadHook ls h = case h.steps of
  x : xs -> Hook (addBefore ls x : xs) h.trailing
  [] -> h

-- | Read an optional field with a mapping. A missing field gives 'Nothing',
-- and a null value gives the default.
section :: T.Text -> a -> Fields a -> Fields (Maybe a)
section k def fields = Fields [k] $ \prefix entries -> case lookupKey k entries of
  Nothing -> pure Nothing
  Just n
    | isNull n -> pure $ Just def
    | otherwise -> Just <$> mappingOf fields (T.unpack $ prefix <> k) n

-- | Read a mapping with the given fields.
mappingOf :: Fields a -> String -> Node -> ConfigCheck a
mappingOf fields path n = case n.content of
  Mapping _ entries -> runFields (T.pack path <> ".") fields entries
  _ -> mismatch path n "a mapping"

expected :: String -> Node -> String -> ConfigCheck a
expected path n what = failAt n $ "key " ++ show path ++ ": expected " ++ what

-- | An error for a value of the wrong kind. The message names the kind that
-- the value has.
mismatch :: String -> Node -> String -> ConfigCheck a
mismatch path n what = expected path n (what ++ ", but got " ++ describeNode n)

failAt :: Node -> String -> ConfigCheck a
failAt n msg = failure (n.offset, msg)

isNull :: Node -> Bool
isNull n = case n.content of
  Scalar Plain t -> t `elem` ["", "~", "null", "Null", "NULL"]
  _ -> False

scalar :: String -> Node -> ConfigCheck Node
scalar path n = case n.content of
  Scalar {} -> pure n
  _ -> mismatch path n "a string"

-- The workflow needs quotes for a value that YAML does not read as a string,
-- so the configuration needs them too.
text :: String -> Node -> ConfigCheck T.Text
text path n = case n.content of
  Scalar s t
    | isString s t -> pure t
    | otherwise -> expected path n ("a string, but got " ++ describeNode n ++ ". Quote the value, e.g. '" ++ T.unpack t ++ "'")
  _ -> mismatch path n "a string"

textList :: String -> Node -> ConfigCheck [T.Text]
textList path n = case n.content of
  Sequence _ items -> traverse (text path) items
  _ -> mismatch path n "a list of strings"

bool :: String -> Node -> ConfigCheck Bool
bool path n = maybe (mismatch path n "true or false") pure (boolValue n)

boolValue :: Node -> Maybe Bool
boolValue n = case n.content of
  Scalar Plain t
    | t `elem` ["true", "True", "TRUE"] -> Just True
    | t `elem` ["false", "False", "FALSE"] -> Just False
  _ -> Nothing

versionRange :: String -> Node -> ConfigCheck VersionRange
versionRange path n =
  text path n `andThen` \t -> case simpleParsec (T.unpack t) of
    Just r -> pure r
    Nothing -> expected path n "a version range"

mappingValue :: String -> Node -> ConfigCheck Node
mappingValue path n = case n.content of
  Mapping {} -> pure n
  _ -> mismatch path n "a mapping"
