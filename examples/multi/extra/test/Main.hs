module Main (main) where

import Control.Monad
import System.Exit

import Extra

main :: IO ()
main = unless (quadruple 3 == 12) exitFailure
