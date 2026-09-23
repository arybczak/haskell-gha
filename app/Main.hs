module Main (main) where

import Data.ByteString qualified as BS
import Data.Text.Encoding qualified as T
import Data.Version
import Options.Applicative
import System.Directory
import System.Exit
import System.FilePath
import System.IO

import HaskellGha.Options
import HaskellGha.Workflow
import Paths_haskell_gha

main :: IO ()
main = do
  opts <- execParser (optionsParser (showVersion version))
  generate "." opts >>= \case
    Left errors -> do
      hPutStr stderr (unlines errors)
      exitFailure
    Right node -> do
      createDirectoryIfMissing True (takeDirectory opts.output)
      BS.writeFile opts.output . T.encodeUtf8 $ renderWorkflow (showVersion version) opts node
