module Main (main) where

import Test.Tasty

import ConfigTests
import ProjectTests
import YamlTests

main :: IO ()
main =
  defaultMain $
    testGroup
      "haskell-gha"
      [ yamlTests
      , configTests
      , projectTests
      ]
