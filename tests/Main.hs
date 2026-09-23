module Main (main) where

import Test.Tasty

import ConfigTests
import GoldenTests
import ProjectTests
import WorkflowTests
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
      , workflowTests
      , golden
      ]
