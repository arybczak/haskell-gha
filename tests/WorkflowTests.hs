module WorkflowTests (workflowTests) where

import Data.ByteString.Lazy.Char8 qualified as BL8
import Test.Tasty
import Test.Tasty.HUnit

import HaskellGha.Config
import HaskellGha.Options
import HaskellGha.Project
import HaskellGha.Workflow

workflowTests :: TestTree
workflowTests =
  testGroup
    "Workflow"
    [ testCase "a ghc value of the matrix that is not in the axis" test_unknownGhcValue
    ]

test_unknownGhcValue :: Assertion
test_unknownGhcValue = do
  config <- either (assertFailure . unlines) pure . parseConfig "conf.yml" $ BL8.pack "matrix:\n  x: [a, b]\n  exclude:\n    - ghc: '9.8'\n      x: a\n"
  project <- readProject "tests/golden/single" >>= either (assertFailure . unlines) pure
  assertEqual
    "errors"
    (Left ["The matrix of the configuration refers to GHC 9.8, but the ghc axis contains only 9.6.7, 9.10, 9.12."])
    (workflow defaultOptions config project)
