{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

-- | The command line options.
module HaskellGha.Options
  ( -- * Options
    Options (..)
  , defaultOptions
  , optionsParser
  , commandLine
  ) where

import Options.Applicative

-- | The command line options.
data Options = Options
  { config :: FilePath
  , projectDir :: FilePath
  , output :: FilePath
  }
  deriving stock (Eq, Show)

-- | The options without arguments.
defaultOptions :: Options
defaultOptions =
  Options
    { config = ".github/haskell-gha.conf.yml"
    , projectDir = "."
    , output = ".github/workflows/haskell-gha.yml"
    }

-- | The parser of the options.
optionsParser :: ParserInfo Options
optionsParser =
  info
    (options <**> helper)
    (fullDesc <> progDesc "Write a GitHub Actions workflow that builds and tests a cabal project on each GHC version from tested-with.")
  where
    options :: Parser Options
    options = do
      config <- strOption (long "config" <> metavar "FILE" <> value defaultOptions.config <> showDefault <> help "The configuration file")
      projectDir <- strOption (long "project-dir" <> metavar "DIR" <> value defaultOptions.projectDir <> showDefault <> help "The directory that contains cabal.project or the package")
      output <- strOption (long "output" <> metavar "FILE" <> value defaultOptions.output <> showDefault <> help "The workflow file")
      pure Options {..}

-- | The command line that gives the options. It contains only the options that
-- are not defaults.
commandLine :: Options -> [String]
commandLine opts =
  "haskell-gha"
    : concat
      [ [name, v]
      | (name, v, def) <-
          [ ("--project-dir", opts.projectDir, defaultOptions.projectDir)
          , ("--config", opts.config, defaultOptions.config)
          , ("--output", opts.output, defaultOptions.output)
          ]
      , v /= def
      ]
