module Main (main) where

import Control.Monad
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
      let rendered = T.encodeUtf8 $ renderWorkflow (showVersion version) opts node
      if opts.check
        then
          doesFileExist opts.output >>= \case
            False -> failWith $ "The workflow " ++ opts.output ++ " does not exist."
            True -> do
              current <- BS.readFile opts.output
              when (current /= rendered) . failWith $ "The workflow " ++ opts.output ++ " is not up to date."
        else do
          createDirectoryIfMissing True (takeDirectory opts.output)
          BS.writeFile opts.output rendered
  where
    failWith :: String -> IO ()
    failWith message = do
      hPutStrLn stderr $ message ++ " To write it, run the same command without --check."
      exitFailure
