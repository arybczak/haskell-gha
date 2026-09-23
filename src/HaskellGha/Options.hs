{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

-- | The command line options.
module HaskellGha.Options
  ( -- * Options
    Options (..)
  , defaultOptions
  , optionsParser
  , commandLine

    -- * Paths
  , leadsAbove
  ) where

import Options.Applicative
import System.FilePath

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
optionsParser
  :: String
  -- ^ The version of the tool.
  -> ParserInfo Options
optionsParser version =
  info
    (options <**> versionOption <**> helper)
    (fullDesc <> progDesc "Write a GitHub Actions workflow that builds and tests a cabal project on each GHC version from tested-with.")
  where
    options :: Parser Options
    options = do
      config <- strOption (long "config" <> metavar "FILE" <> value defaultOptions.config <> showDefault <> help "The configuration file")
      projectDir <- option projectDirReader (long "project-dir" <> metavar "DIR" <> value defaultOptions.projectDir <> showDefault <> help "The directory that contains cabal.project or the package")
      output <- strOption (long "output" <> metavar "FILE" <> value defaultOptions.output <> showDefault <> help "The workflow file")
      pure Options {..}

    -- The workflow uses the directory on the runner, so it must be in the
    -- repository.
    projectDirReader :: ReadM FilePath
    projectDirReader = eitherReader $ \dir ->
      if isAbsolute dir || leadsAbove dir
        then Left $ "The project directory " ++ show dir ++ " is not in the repository. Give a path relative to the root of the repository."
        else Right dir

    versionOption :: Parser (a -> a)
    versionOption = infoOption ("haskell-gha " ++ version) (long "version" <> short 'v' <> help "Show the version")

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
