{-# LANGUAGE ApplicativeDo #-}

-- | The command line options.
module HaskellGha.Options
  ( -- * Options
    Command (..)
  , Options (..)
  , defaultOptions
  , outputPath
  , optionsParser
  , commandLine
  , parseCommandLine

    -- * Paths
  , workflowDirectory
  , workflowExtensions
  ) where

import Data.Char
import Data.List qualified as L
import Options.Applicative
import System.FilePath

import HaskellGha.Config
import HaskellGha.Path

-- | What the tool does.
data Command
  = -- | Make one workflow, with @--generate@.
    Generate Options
  | -- | Make each workflow that the tool generated again, with the command in
    -- its header.
    Regenerate
  | -- | Make sure that each generated workflow is up to date, with
    -- @--check@.
    Check
  deriving stock (Eq, Show)

-- | The options of one workflow.
data Options = Options
  { config :: ConfigFile
  , projectDir :: FilePath
  , output :: FilePath
  -- ^ The name of the workflow file in 'workflowDirectory'.
  }
  deriving stock (Eq, Show)

-- | The options without arguments.
defaultOptions :: Options
defaultOptions =
  Options
    { config = DefaultConfigFile
    , projectDir = "."
    , output = "haskell-gha.yml"
    }

-- | The path of the workflow file, relative to the root of the repository.
outputPath :: Options -> FilePath
outputPath opts = workflowDirectory </> opts.output

-- | The directory of the workflow files. GitHub reads only the files directly
-- in it.
workflowDirectory :: FilePath
workflowDirectory = ".github/workflows"

-- | The extensions of the files that GitHub reads as workflows.
workflowExtensions :: [String]
workflowExtensions = [".yml", ".yaml"]

-- | The parser of the command line.
optionsParser
  :: String
  -- ^ The version of the tool.
  -> ParserInfo Command
optionsParser version =
  info
    ((generate <|> check) <**> versionOption <**> helper)
    ( fullDesc
        <> progDesc
          ( "Write a GitHub Actions workflow that builds and tests a cabal project on each GHC version from tested-with. Without --generate, make each workflow in "
              ++ workflowDirectory
              ++ " that the tool generated again, with the command in its header."
          )
    )
  where
    generate :: Parser Command
    generate =
      flag' () (long "generate" <> help "Make one workflow with the options below")
        *> (Generate <$> options)

    check :: Parser Command
    check =
      flag
        Regenerate
        Check
        ( long "check"
            <> help "Do not write the workflow files. Exit with code 1 if one is not up to date."
        )

    versionOption :: Parser (a -> a)
    versionOption =
      infoOption
        ("haskell-gha " ++ version)
        (long "version" <> short 'v' <> help "Show the version")

-- | The parser of the options of one workflow.
options :: Parser Options
options = do
  config <-
    option
      configReader
      ( long "config"
          <> metavar "FILE"
          <> value DefaultConfigFile
          <> showDefaultWith (const defaultConfigPath)
          <> help "The configuration file"
      )
  projectDir <-
    option
      projectDirReader
      ( long "project-dir"
          <> metavar "DIR"
          <> value defaultOptions.projectDir
          <> showDefault
          <> help "The directory that contains cabal.project or the package"
      )
  output <-
    option
      outputReader
      ( long "output"
          <> metavar "NAME"
          <> value defaultOptions.output
          <> showDefault
          <> help ("The name of the workflow file in " ++ workflowDirectory)
      )
  pure Options {..}
  where
    -- A run without --generate reads the file from the header, also in
    -- another checkout of the repository, e.g. with --check in CI.
    configReader :: ReadM ConfigFile
    configReader = ConfigFile <$> (pathReader >>= inRepository "The configuration file")

    -- The workflow uses the directory on the runner, so it must be in the
    -- repository.
    projectDirReader :: ReadM FilePath
    projectDirReader = pathReader >>= inRepository "The project directory"

    inRepository :: String -> FilePath -> ReadM FilePath
    inRepository what path
      | leadsOut path =
          readerError $
            what
              ++ " "
              ++ show path
              ++ " is not in the repository. Give a path relative to the root of the repository."
      | otherwise = pure path

    -- GitHub reads only these files, and a run without --generate finds only
    -- them.
    outputReader :: ReadM FilePath
    outputReader =
      pathReader >>= \case
        name
          | any isPathSeparator name ->
              readerError $
                "The workflow file name "
                  ++ show name
                  ++ " contains a directory. GitHub reads only the files directly in "
                  ++ workflowDirectory
                  ++ ", so give only the name of the file, e.g. ci.yml."
          | ',' `elem` name ->
              readerError $
                "The workflow file name "
                  ++ show name
                  ++ " contains a comma. The name is a part of the cache keys, and actions/cache does not accept a comma in a key."
          | takeExtension name `notElem` workflowExtensions ->
              readerError $
                "The workflow file name "
                  ++ show name
                  ++ " does not end with "
                  ++ L.intercalate " or " workflowExtensions
                  ++ ". GitHub reads only such files."
          | otherwise -> pure name

    -- The header of the workflow has the command line on one comment line,
    -- and a line break ends the comment. YAML does not allow most other
    -- control characters. YAML 1.1, which GitHub reads, also breaks a line at
    -- U+2028 and U+2029, so the renderer splits the comment there.
    pathReader :: ReadM FilePath
    pathReader =
      str >>= \path -> case () of
        _
          | null path -> readerError "The path is empty."
          | any isControl path ->
              readerError $
                "The path "
                  ++ show path
                  ++ " contains a control character, e.g. a tab or a line break."
          | any (`elem` ['\x2028', '\x2029']) path ->
              readerError $
                "The path "
                  ++ show path
                  ++ " contains U+2028 or U+2029, which YAML reads as a line break."
          | otherwise -> pure path

-- | The command line that gives the options. It contains @--config@ if the user
-- gave it, and each other option that is not a default.
commandLine :: Options -> [String]
commandLine opts =
  "haskell-gha"
    : "--generate"
    : concat
      ( [["--project-dir", opts.projectDir] | opts.projectDir /= defaultOptions.projectDir]
          ++ [["--config", path] | ConfigFile path <- [opts.config]]
          ++ [["--output", opts.output] | opts.output /= defaultOptions.output]
      )

-- | The options of a command line from 'commandLine'.
parseCommandLine :: [String] -> Either String Options
parseCommandLine = \case
  "haskell-gha" : "--generate" : args ->
    case execParserPure defaultPrefs (info options mempty) args of
      Success opts -> Right opts
      Failure failure -> Left . fst $ renderFailure failure "haskell-gha --generate"
      CompletionInvoked _ -> Left "the command asks for a shell completion"
  _ -> Left "the command does not start with haskell-gha --generate"
