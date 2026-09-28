{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

-- | The command line options.
module HaskellGha.Options
  ( -- * Options
    Command (..)
  , Options (..)
  , defaultOptions
  , optionsParser
  , commandLine
  , parseCommandLine

    -- * Paths
  , leadsAbove
  ) where

import Options.Applicative
import System.FilePath

import HaskellGha.Config

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
  }
  deriving stock (Eq, Show)

-- | The options without arguments.
defaultOptions :: Options
defaultOptions =
  Options
    { config = DefaultConfigFile
    , projectDir = "."
    , output = ".github/workflows/haskell-gha.yml"
    }

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
              ++ takeDirectory defaultOptions.output
              ++ " that the tool generated again, with the command in its header."
          )
    )
  where
    generate :: Parser Command
    generate = flag' () (long "generate" <> help "Make one workflow with the options below") *> (Generate <$> options)

    check :: Parser Command
    check = flag Regenerate Check (long "check" <> help "Do not write the workflow files. Exit with code 1 if one is not up to date.")

    versionOption :: Parser (a -> a)
    versionOption = infoOption ("haskell-gha " ++ version) (long "version" <> short 'v' <> help "Show the version")

-- | The parser of the options of one workflow.
options :: Parser Options
options = do
  config <- option (ConfigFile <$> str) (long "config" <> metavar "FILE" <> value DefaultConfigFile <> showDefaultWith (const defaultConfigPath) <> help "The configuration file")
  projectDir <- option projectDirReader (long "project-dir" <> metavar "DIR" <> value defaultOptions.projectDir <> showDefault <> help "The directory that contains cabal.project or the package")
  output <- strOption (long "output" <> metavar "FILE" <> value defaultOptions.output <> showDefault <> help "The workflow file")
  pure Options {..}
  where
    -- The workflow uses the directory on the runner, so it must be in the
    -- repository.
    projectDirReader :: ReadM FilePath
    projectDirReader = eitherReader $ \case
      "" -> Left "The project directory is empty. For the root of the repository, give \".\"."
      dir
        | isAbsolute dir || leadsAbove dir -> Left $ "The project directory " ++ show dir ++ " is not in the repository. Give a path relative to the root of the repository."
        | otherwise -> Right dir

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

-- | Whether the @..@ components of a relative path lead above its start, e.g.
-- @a/../../b@.
leadsAbove :: FilePath -> Bool
leadsAbove = any (< 0) . scanl (+) 0 . map depth . splitDirectories
  where
    depth :: FilePath -> Int
    depth = \case
      ".." -> -1
      "." -> 0
      _ -> 1
