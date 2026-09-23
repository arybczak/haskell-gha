module Main (main) where

import Test.Tasty

import ConfigTests
import GoldenTests
import ProjectTests
import YamlTests

main :: IO ()
main = do
  golden <- goldenTests
  defaultMain $
    testGroup
      "haskell-gha"
      [ yamlTests
      , configTests
      , projectTests
      , golden
      ]
