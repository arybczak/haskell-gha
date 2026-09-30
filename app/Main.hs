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
  problems <-
    execParser (optionsParser (showVersion version)) >>= \case
      Generate opts -> run False opts
      Regenerate -> everyWorkflow False
      Check -> everyWorkflow True
  if null problems
    then pure ()
    else do
      hPutStr stderr (unlines problems)
      exitFailure
  where
    everyWorkflow :: Bool -> IO [String]
    everyWorkflow check =
      findWorkflows "." >>= \case
        Left errors -> pure errors
        Right workflows -> concat <$> traverse (run check) workflows

    run :: Bool -> Options -> IO [String]
    run check opts =
      generate "." opts >>= \case
        Left errors -> pure errors
        Right node -> do
          let rendered = T.encodeUtf8 $ renderWorkflow (showVersion version) opts node
          exists <- doesFileExist opts.output
          current <- if exists then Just <$> BS.readFile opts.output else pure Nothing
          let upToDate = current == Just rendered
          if check
            then pure ["The workflow " ++ opts.output ++ " is not up to date. To update it, run haskell-gha without --check." | not upToDate]
            else do
              -- A write of the same content changes the mtime. Then tools
              -- that trust the Git index, e.g. gitk, list the file as changed.
              unless upToDate $ do
                createDirectoryIfMissing True (takeDirectory opts.output)
                BS.writeFile opts.output rendered
              pure []
