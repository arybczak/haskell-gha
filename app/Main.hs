module Main (main) where

import Control.Monad
import Data.Version
import Options.Applicative
import System.Exit
import System.IO

import HaskellGha.Command
import HaskellGha.Command.Options
import Paths_haskell_gha

main :: IO ()
main = do
  problems <-
    runCommand "." =<< execParser (optionsParser (showVersion version))
  unless (null problems) $ do
    hPutStr stderr (unlines problems)
    exitFailure
