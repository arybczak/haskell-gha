module Main (main) where

import Control.Monad
import Data.Version
import Options.Applicative
import System.Exit
import System.IO

import HaskellGha.Options
import HaskellGha.Workflow
import Paths_haskell_gha

main :: IO ()
main = do
  problems <-
    runCommand "." (showVersion version) =<< execParser (optionsParser (showVersion version))
  unless (null problems) $ do
    hPutStr stderr (unlines problems)
    exitFailure
