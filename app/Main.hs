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
  -- The messages quote lines of the user's files, and the locale can be ASCII,
  -- e.g. in a container that sets no LANG.
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  problems <-
    runCommand "." =<< execParser (optionsParser (showVersion version))
  unless (null problems) $ do
    hPutStr stderr (unlines problems)
    exitFailure
