module WorkflowTests (workflowTests) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Either
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Options.Applicative
import System.Directory
import System.FilePath
import System.IO.Temp
import Test.Tasty
import Test.Tasty.HUnit
import Yamlet

import HaskellGha.Config
import HaskellGha.Options
import HaskellGha.Project
import HaskellGha.Workflow

workflowTests :: TestTree
workflowTests =
  testGroup
    "Workflow"
    [ testCase "a ghc value of the matrix that is not in the axis" test_unknownGhcValue
    , testCase "the dependencies axis" test_dependenciesAxis
    , testCase "a doctest range that includes a part of a series" test_partialDoctestRange
    , testCase "a head-hackage range that includes a part of a series" test_partialHeadHackageRange
    , testCase "head-hackage with the oldest dependencies" test_oldestHeadHackage
    , testCase "an unknown package in doctest.skip" test_unknownSkip
    , testCase "the errors of independent checks are collected" test_independentChecks
    , testCase "the command line in the header" test_headerCommandLine
    , testCase "sdist with an import and a package outside the project" test_sdistOutside
    , testCase "an import outside the repository" test_importOutside
    , testCase "sdist with a package name that starts with another" test_sdistNamePrefix
    , testCase "a project directory outside the repository" test_projectDirOutside
    , testCase "a named default configuration file" test_namedDefaultConfig
    , testCase "an hlint path outside the repository" test_hlintPathOutside
    , testCase "the comments that the workflow keeps and drops" test_comments
    , testCase "the modes of the command line" test_modes
    , testCase "the generated workflows" test_findWorkflows
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
        , "# The runner of the build."
        , "runs-on: ubuntu-24.04"
        , "fourmolu:"
        , "  enabled: true"
        , "hooks:"
        , "  # The steps after the build."
        , "  after-build:"
        , "    # The step."
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
  assertLines "step" ["    # The step.", "    - run: echo a"]
  assertEqual "end of the steps" [T.pack "    - run: echo a"] (drop (length rendered - 1) rendered)
  assertBool "hook key" $ T.pack "    # The steps after the build." `notElem` rendered
  assertEqual "runs-on of the build job only" 1 (length (filter (== T.pack "    # The runner of the build.") rendered))

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
  let parse = parseOptions
  assertEqual "without --config" (Just DefaultConfigFile) ((.config) <$> parse [])
  assertEqual "with --config" (Just (ConfigFile defaultConfigPath)) ((.config) <$> parse ["--config", defaultConfigPath])
  assertEqual "command line" (Just ["haskell-gha", "--generate", "--config", defaultConfigPath]) (commandLine <$> parse ["--config", defaultConfigPath])

test_projectDirOutside :: Assertion
test_projectDirOutside = do
  let parse dir = parseOptions ["--project-dir", dir]
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

test_importOutside :: Assertion
test_importOutside = do
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
  let changed =
        project
          { imports =
              [ Import "cabal.project:1:1: " "../inside.project"
              , Import "cabal.project:2:1: " "../../outside.project"
              , Import "cabal.project:3:1: " "/etc/absolute.project"
              ]
          }
      opts = defaultOptions {projectDir = "sub"}
      outside =
        [ "cabal.project:2:1: the imported file ../../outside.project is not in the repository. Give a path relative to the project directory."
        , "cabal.project:3:1: the imported file /etc/absolute.project is not in the repository. Give a path relative to the project directory."
        ]
  assertEqual
    "sdist: true"
    ( Left $
        "cabal.project:1:1: the workflow builds the source tarballs in a copy of the project directory, and the copy does not contain the imported file ../inside.project. Set sdist: false in the configuration."
          : outside
    )
    (workflow opts (emptySource "conf.yml") defaultConfig changed)
  assertEqual "sdist: false" (Left outside) (workflow opts (emptySource "conf.yml") defaultConfig {sdist = False} changed)

test_headerCommandLine :: Assertion
test_headerCommandLine = do
  let opts = defaultOptions {projectDir = "my project", output = "it's.yml"}
      line = T.unpack <$> L.find (T.isInfixOf (T.pack "haskell-gha --")) (T.lines $ renderWorkflow "TEST" opts (mapping []))
  assertEqual "command line" (Just "#   haskell-gha --generate --project-dir 'my project' --output 'it'\\''s.yml'") line

test_unknownGhcValue :: Assertion
test_unknownGhcValue =
  assertErrors
    "matrix:\n  x: [a, b]\n  exclude:\n    - ghc: '9.8'\n      x: a\n"
    ["conf.yml:4:12: matrix.exclude[0].ghc: GHC 9.8 is not in the ghc axis, which contains only 9.6.7, 9.10, 9.12"]

test_dependenciesAxis :: Assertion
test_dependenciesAxis = do
  assertErrors
    "dependencies: both\nmatrix:\n  dependencies: [a, b]\n  exclude:\n    - dependencies: older\n"
    [ "conf.yml:3:3: matrix: the tool makes the dependencies axis for dependencies: both, so the matrix must not contain it"
    , "conf.yml:5:21: matrix.exclude[0].dependencies: dependencies older is not in the dependencies axis, which contains only newest, oldest"
    ]
  assertErrors
    "matrix:\n  exclude:\n    - dependencies: oldest\n"
    ["conf.yml:3:21: matrix.exclude[0].dependencies: the matrix has no dependencies axis. Set dependencies: both to add it."]
  assertValid "dependencies: both\nmatrix:\n  exclude:\n    - ghc: '9.10'\n      dependencies: oldest\n"
  assertValid "matrix:\n  dependencies: [a, b]\n  exclude:\n    - dependencies: a\n"
  where
    assertValid :: String -> Assertion
    assertValid input = do
      (config, source) <- either (assertFailure . unlines) pure . parseConfig "conf.yml" $ BS8.pack input
      project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
      either (assertFailure . unlines) (const (pure ())) (workflow defaultOptions source config project)

test_partialDoctestRange :: Assertion
test_partialDoctestRange =
  assertErrors
    "doctest:\n  enabled: true\n  ghc: '>=9.10.2'\n"
    ["conf.yml:3:8: doctest.ghc: the range >=9.10.2 includes only a part of the GHC versions of the matrix entry 9.10, so the result depends on the minor version that haskell-actions/setup selects. Change the range, or write exact versions in tested-with."]

test_partialHeadHackageRange :: Assertion
test_partialHeadHackageRange =
  assertErrors
    "head-hackage: '>=9.12.2'\n"
    ["conf.yml:1:15: head-hackage: the range >=9.12.2 includes only a part of the GHC versions of the matrix entry 9.12, so the result depends on the minor version that haskell-actions/setup selects. Change the range, or write exact versions in tested-with."]

test_oldestHeadHackage :: Assertion
test_oldestHeadHackage =
  assertErrors
    "dependencies: oldest\nhead-hackage: '>=9.12'\n"
    ["conf.yml:2:15: head-hackage: the range >=9.12 includes the matrix entries 9.12, but head.hackage allows newer versions of the libraries that come with GHC, so a job with dependencies: oldest cannot test the lower bounds. Change the range, or set dependencies to newest or both."]

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

test_modes :: Assertion
test_modes = do
  let parse = getParseResult . execParserPure defaultPrefs (optionsParser "TEST")
  assertEqual "no options" (Just Regenerate) (parse [])
  assertEqual "--check" (Just Check) (parse ["--check"])
  assertEqual "--generate" (Just (Generate defaultOptions)) (parse ["--generate"])
  assertEqual "--generate --check" Nothing (parse ["--generate", "--check"])
  assertEqual "--output without --generate" Nothing (parse ["--output", "a.yml"])

test_findWorkflows :: Assertion
test_findWorkflows =
  withSystemTempDirectory "haskell-gha-tests" $ \root -> do
    let dir = takeDirectory defaultOptions.output
        opts = defaultOptions {config = ConfigFile "it's.yml", projectDir = "my project", output = dir </> "a.yml"}
        write :: FilePath -> T.Text -> IO ()
        write name = BS.writeFile (root </> dir </> name) . T.encodeUtf8
    assertEqual "no directory" (Left ["No workflow in " ++ dir ++ " was generated by haskell-gha. To make one, run haskell-gha --generate."]) =<< findWorkflows root
    createDirectoryIfMissing True (root </> dir)
    write "a.yml" $ renderWorkflow "TEST" opts (mapping [])
    write "b.yml" (T.pack "name: other\n")
    assertEqual "generated workflow" (Right [opts]) =<< findWorkflows root
    write "c.yaml" $ renderWorkflow "TEST" opts {output = dir </> "d.yml"} (mapping [])
    assertEqual
      "other output"
      (Left [dir </> "c.yaml" ++ ": the command in the header writes the workflow to " ++ dir </> "d.yml" ++ ", not to this file"])
      =<< findWorkflows root
    let withCommand :: String -> IO ()
        withCommand line = write "c.yaml" . T.unlines . zipWith (\i l -> if i == 1 then T.pack ("#   " ++ line) else l) [0 :: Int ..] . T.lines $ renderWorkflow "TEST" opts (mapping [])
        firstLines :: Either [String] a -> Either [String] a
        firstLines = either (Left . map (takeWhile (/= '\n'))) Right
    withCommand "echo haskell-gha"
    assertEqual
      "other program"
      (Left [dir </> "c.yaml" ++ ": the command in the header is not valid: the command does not start with haskell-gha --generate"])
      =<< findWorkflows root
    withCommand "haskell-gha --generate --output .github/workflows/c.yaml --foo"
    assertEqual
      "unknown option"
      (Left [dir </> "c.yaml" ++ ": the command in the header is not valid: Invalid option `--foo'"])
      . firstLines
      =<< findWorkflows root

-- | The options of a command line for one workflow, after @--generate@.
parseOptions :: [String] -> Maybe Options
parseOptions args = case getParseResult $ execParserPure defaultPrefs (optionsParser "TEST") ("--generate" : args) of
  Just (Generate opts) -> Just opts
  _ -> Nothing
