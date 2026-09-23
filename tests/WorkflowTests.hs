module WorkflowTests (workflowTests) where

import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Either
import Data.List qualified as L
import Data.Text qualified as T
import Test.Tasty
import Test.Tasty.HUnit

import HaskellGha.Config
import HaskellGha.Options
import HaskellGha.Project
import HaskellGha.Workflow
import HaskellGha.Yaml

workflowTests :: TestTree
workflowTests =
  testGroup
    "Workflow"
    [ testCase "a ghc value of the matrix that is not in the axis" test_unknownGhcValue
    , testCase "a doctest range that includes a part of a series" test_partialDoctestRange
    , testCase "an unknown package in doctest.skip" test_unknownSkip
    , testCase "the command line in the header" test_headerCommandLine
    , testCase "sdist with an import and a package outside the project" test_sdistOutside
    ]

test_sdistOutside :: Assertion
test_sdistOutside = do
  project <- readProject "tests/golden/single" >>= either (assertFailure . unlines) pure
  p <- case project.packages of
    [p] -> pure p
    ps -> assertFailure ("packages: " ++ show ps)
  let changed =
        project
          { packages = [p {directory = "../lib"}, p {name = "inner", directory = "a/../b"}]
          , imports = [Import "cabal.project:1:1: " "local.project", Import "cabal.project:2:1: " "https://example.com/remote.project"]
          }
  assertEqual
    "errors"
    ( Left
        [ "cabal.project:1:1: the workflow builds the source tarballs in a copy of the project directory, and the copy does not contain the imported file local.project. Set sdist: false in the configuration."
        , "Package example is in ../lib, outside the project directory, but the workflow builds the source tarballs in a copy of the project directory. Set sdist: false in the configuration."
        ]
    )
    (workflow defaultOptions defaultConfig changed)
  assertBool "sdist: false" (isRight $ workflow defaultOptions defaultConfig {sdist = False} changed)

test_headerCommandLine :: Assertion
test_headerCommandLine = do
  let opts = defaultOptions {projectDir = "my project", output = "it's.yml"}
      header = T.unpack <$> L.find (T.isInfixOf (T.pack "haskell-gha --")) (T.lines $ renderWorkflow "TEST" opts (Mapping [] []))
  assertEqual "command line" (Just "#   haskell-gha --project-dir 'my project' --output 'it'\\''s.yml'") header

test_unknownGhcValue :: Assertion
test_unknownGhcValue =
  assertErrors
    "matrix:\n  x: [a, b]\n  exclude:\n    - ghc: '9.8'\n      x: a\n"
    ["The matrix of the configuration refers to GHC 9.8, but the ghc axis contains only 9.6.7, 9.10, 9.12."]

test_partialDoctestRange :: Assertion
test_partialDoctestRange =
  assertErrors
    "doctest:\n  ghc: '>=9.10.2'\n"
    ["The range >=9.10.2 of the field doctest.ghc includes only a part of the GHC versions of the matrix entry 9.10, so the result depends on the minor version that haskell-actions/setup selects. Change the range, or write exact versions in tested-with."]

test_unknownSkip :: Assertion
test_unknownSkip =
  assertErrors
    "doctest:\n  skip: [other]\n"
    ["The field doctest.skip names the package other, but the project has no such local package."]

-- | The errors for a configuration and the project of the golden test @single@.
assertErrors :: String -> [String] -> Assertion
assertErrors input expected = do
  config <- either (assertFailure . unlines) pure . parseConfig "conf.yml" $ BL8.pack input
  project <- readProject "tests/golden/single" >>= either (assertFailure . unlines) pure
  assertEqual "errors" (Left expected) (workflow defaultOptions config project)
