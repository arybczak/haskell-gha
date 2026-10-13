module Main (main) where

import Test.Tasty

import HaskellGha.Test.Config
import HaskellGha.Test.Golden
import HaskellGha.Test.Project
import HaskellGha.Test.Workflow
import HaskellGha.Test.Yaml

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
