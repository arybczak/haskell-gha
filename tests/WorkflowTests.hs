module WorkflowTests (workflowTests) where

import Data.ByteString.Char8 qualified as BS8
import Data.Either
import Data.List qualified as L
import Data.Text qualified as T
import Options.Applicative
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
    , testCase "the errors of independent checks are collected" test_independentChecks
    , testCase "the command line in the header" test_headerCommandLine
    , testCase "sdist with an import and a package outside the project" test_sdistOutside
    , testCase "sdist with a package name that starts with another" test_sdistNamePrefix
    , testCase "a project directory outside the repository" test_projectDirOutside
    , testCase "a named default configuration file" test_namedDefaultConfig
    , testCase "an hlint path outside the repository" test_hlintPathOutside
    , testCase "comments at the start of the file and after the last step" test_comments
    ]

test_comments :: Assertion
test_comments = do
  (config, source) <-
    either (assertFailure . unlines) pure . parseConfig "conf.yml" . BS8.pack $
      unlines
        [ "# The permissions of the workflow."
        , "permissions: read-all # For the checkout."
        , "matrix:"
        , "  # The first axis."
        , ""
        , "  os: [a, b]"
        , "  # The end of the matrix."
        , "tests: false"
        , "check: false"
        , "haddock: false"
        , "hooks:"
        , "  after-build:"
        , "    - run: echo a"
        , "    # The last lines."
        , "  # The end of the hooks."
        ]
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
  node <- either (assertFailure . unlines) pure (workflow defaultOptions source config project)
  let rendered = T.lines $ renderWorkflow "TEST" defaultOptions node
      assertLines preface ls = assertBool preface $ map T.pack ls `L.isInfixOf` rendered
  assertLines "top comment" ["# The permissions of the workflow.", "permissions: read-all # For the checkout."]
  assertLines "first axis" ["        - '9.12'", "        # The first axis.", "        os:"]
  assertLines "end of the matrix" ["        - b", "        # The end of the matrix.", "    steps:"]
  -- The renderer indents a list with lines after it, so that the lines belong
  -- to the list and not to its last step.
  assertEqual
    "end of the steps"
    (map T.pack ["      - run: echo a", "      # The last lines.", "      # The end of the hooks."])
    (drop (length rendered - 3) rendered)

test_hlintPathOutside :: Assertion
test_hlintPathOutside = do
  assertErrors
    "hlint:\n  enabled: true\n  path: [../x, /abs, a/../src]\n"
    [ "conf.yml:3:10: hlint.path[0]: the path ../x is not in the repository. Give a path relative to the project directory."
    , "conf.yml:3:16: hlint.path[1]: the path /abs is not in the repository. Give a path relative to the project directory."
    ]
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
  (config, source) <- either (assertFailure . unlines) pure . parseConfig "conf.yml" $ BS8.pack "hlint:\n  enabled: true\n  path: [../x]\n"
  assertBool "in the repository" (isRight $ workflow defaultOptions {projectDir = "sub"} source config project)
  (off, offSource) <- either (assertFailure . unlines) pure . parseConfig "conf.yml" $ BS8.pack "hlint:\n  path: [../x]\n"
  assertBool "not enabled" (isRight $ workflow defaultOptions offSource off project)

test_namedDefaultConfig :: Assertion
test_namedDefaultConfig = do
  let parse args = getParseResult $ execParserPure defaultPrefs (optionsParser "TEST") args
  assertEqual "without --config" (Just DefaultConfigFile) ((.config) <$> parse [])
  assertEqual "with --config" (Just (ConfigFile defaultConfigPath)) ((.config) <$> parse ["--config", defaultConfigPath])
  assertEqual "command line" (Just ["haskell-gha", "--config", defaultConfigPath]) (commandLine <$> parse ["--config", defaultConfigPath])

test_projectDirOutside :: Assertion
test_projectDirOutside = do
  let parse dir = getParseResult $ execParserPure defaultPrefs (optionsParser "TEST") ["--project-dir", dir]
  assertEqual "sub" (Just "a/../b") ((.projectDir) <$> parse "a/../b")
  assertEqual "absolute" Nothing (parse "/tmp/project")
  assertEqual "parent" Nothing (parse "a/../../b")
  assertEqual "empty" Nothing (parse "")

test_sdistNamePrefix :: Assertion
test_sdistNamePrefix = do
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
  p <- case project.packages of
    [p] -> pure p
    ps -> assertFailure ("packages: " ++ show ps)
  let pkgs = [p {directory = "a"}, p {name = "example-2d", directory = "b"}]
      changed = project {packages = pkgs, matrix = [MatrixEntry e.ghc pkgs | e <- project.matrix]}
  node <- either (assertFailure . unlines) pure (workflow defaultOptions (emptySource "conf.yml") defaultConfig changed)
  assertEqual
    "tar lines"
    [ "tar -xzf \"$RUNNER_TEMP\"/haskell-gha-sdist/example-+([0-9.]).tar.gz --strip-components=1 -C \"$RUNNER_TEMP\"/haskell-gha/a"
    , "tar -xzf \"$RUNNER_TEMP\"/haskell-gha-sdist/example-2d-+([0-9.]).tar.gz --strip-components=1 -C \"$RUNNER_TEMP\"/haskell-gha/b"
    ]
    [T.unpack (T.strip l) | l <- T.lines (renderWorkflow "TEST" defaultOptions node), T.pack "tar -xzf" `T.isInfixOf` l]

test_sdistOutside :: Assertion
test_sdistOutside = do
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
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
    (workflow defaultOptions (emptySource "conf.yml") defaultConfig changed)
  assertBool "sdist: false" (isRight $ workflow defaultOptions (emptySource "conf.yml") defaultConfig {sdist = False} changed)

test_headerCommandLine :: Assertion
test_headerCommandLine = do
  let opts = defaultOptions {projectDir = "my project", output = "it's.yml"}
      line = T.unpack <$> L.find (T.isInfixOf (T.pack "haskell-gha --")) (T.lines $ renderWorkflow "TEST" opts (mapping []))
  assertEqual "command line" (Just "#   haskell-gha --project-dir 'my project' --output 'it'\\''s.yml'") line

test_unknownGhcValue :: Assertion
test_unknownGhcValue =
  assertErrors
    "matrix:\n  x: [a, b]\n  exclude:\n    - ghc: '9.8'\n      x: a\n"
    ["conf.yml:4:12: matrix.exclude[0].ghc: GHC 9.8 is not in the ghc axis, which contains only 9.6.7, 9.10, 9.12"]

test_partialDoctestRange :: Assertion
test_partialDoctestRange =
  assertErrors
    "doctest:\n  enabled: true\n  ghc: '>=9.10.2'\n"
    ["conf.yml:3:8: doctest.ghc: the range >=9.10.2 includes only a part of the GHC versions of the matrix entry 9.10, so the result depends on the minor version that haskell-actions/setup selects. Change the range, or write exact versions in tested-with."]

test_independentChecks :: Assertion
test_independentChecks =
  assertErrors
    "doctest:\n  enabled: true\n  skip: [other]\nhlint:\n  enabled: true\n  path: [../x]\n"
    [ "conf.yml:3:10: doctest.skip[0]: the project has no local package other"
    , "conf.yml:6:10: hlint.path[0]: the path ../x is not in the repository. Give a path relative to the project directory."
    ]

test_unknownSkip :: Assertion
test_unknownSkip =
  assertErrors
    "doctest:\n  enabled: true\n  skip: [other]\n"
    ["conf.yml:3:10: doctest.skip[0]: the project has no local package other"]

-- | The first lines of the errors for a configuration and the project of the
-- golden test @single@. The other lines show the line of the configuration.
assertErrors :: String -> [String] -> Assertion
assertErrors input expected = do
  (config, source) <- either (assertFailure . unlines) pure . parseConfig "conf.yml" $ BS8.pack input
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
  assertEqual "errors" (Left expected) (either (Left . map (takeWhile (/= '\n'))) Right (workflow defaultOptions source config project))
