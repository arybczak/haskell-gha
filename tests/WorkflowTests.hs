module WorkflowTests (workflowTests) where

import Control.Monad
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Either
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Time.Clock.POSIX
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
    , testCase "a range that includes no matrix entry" test_unusedRange
    , testCase "an unknown package in doctest.skip" test_unknownSkip
    , testCase "the errors of independent checks are collected" test_independentChecks
    , testCase "the command line in the header" test_headerCommandLine
    , testCase "sdist with an import and a package outside the project" test_sdistOutside
    , testCase "an import outside the repository" test_importOutside
    , testCase "sdist with a package name that starts with another" test_sdistNamePrefix
    , testCase "a project directory outside the repository" test_projectDirOutside
    , testCase "a configuration file outside the repository" test_configOutside
    , testCase "an output file that GitHub does not read" test_outputPath
    , testCase "a control character or a line separator in a path option" test_controlCharacters
    , testCase "a named default configuration file" test_namedDefaultConfig
    , testCase "an hlint path outside the repository" test_hlintPathOutside
    , testCase "a hook step with the id of a step of the tool" test_hookStepId
    , testCase "the comments that the workflow keeps and drops" test_comments
    , testCase "the modes of the command line" test_modes
    , testCase "the generated workflows" test_findWorkflows
    , testCase "the commands write and check the workflow files" test_runCommand
    , testCase "symbolic links" test_symbolicLinks
    ]

test_comments :: Assertion
test_comments = do
  (config, source) <-
    either (assertFailure . unlines) pure . parseConfig "conf.yml" . BS8.pack $
      unlines
        [ "# The configuration."
        , ""
        , "# The permissions of the workflow."
        , "permissions: read-all # For the checkout."
        , "matrix:"
        , "  # The matrix."
        , ""
        , "  # The first axis."
        , "  os: [a, b]"
        , "  # The end of the matrix."
        , "tests: false"
        , "check: false"
        , "haddock: false"
        , ""
        , "# The jobs."
        , ""
        , "# The runner of the build."
        , "runs-on: ubuntu-24.04"
        , "fourmolu:"
        , "  enabled: true"
        , "hooks:"
        , "  # The steps after the build."
        , "  after-build:"
        , "    # The step."
        , "    - run: echo a"
        , "    # A section."
        , ""
        , "    # The second step."
        , "    - run: echo b"
        , "    # The last lines."
        , "  # The end of the hooks."
        ]
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
  node <-
    either (assertFailure . unlines) pure (workflow defaultOptions source config project)
  let rendered = T.lines $ renderWorkflow defaultOptions node
      assertLines preface ls = assertBool preface $ map T.pack ls `L.isInfixOf` rendered
  assertLines
    "top comment"
    ["# The permissions of the workflow.", "permissions: read-all # For the checkout."]
  assertBool "comment of the file" $ T.pack "# The configuration." `notElem` rendered
  assertBool "comment of a section" $ T.pack "    # The jobs." `notElem` rendered
  assertLines "matrix" ["      matrix:", "        # The matrix.", "", "        ghc:"]
  assertLines "first axis" ["        - '9.12'", "        # The first axis.", "        os:"]
  assertLines
    "end of the matrix"
    ["        - b", "        # The end of the matrix.", "    steps:"]
  assertLines "step" ["    # The step.", "    - run: echo a"]
  assertLines
    "second step"
    ["    - run: echo a", "", "    # The second step.", "    - run: echo b"]
  assertEqual
    "end of the steps"
    [T.pack "    - run: echo b"]
    (drop (length rendered - 1) rendered)
  assertBool "hook key" $ T.pack "    # The steps after the build." `notElem` rendered
  assertEqual
    "runs-on of the build job only"
    1
    (length (filter (== T.pack "    # The runner of the build.") rendered))

test_hlintPathOutside :: Assertion
test_hlintPathOutside = do
  assertErrors
    "hlint:\n  enabled: true\n  path: [../x, /abs, a/../src]\n"
    [ "conf.yml:3:10: hlint.path[0]: the path ../x is not in the repository. Give a path relative to the project directory."
    , "conf.yml:3:16: hlint.path[1]: the path /abs is not in the repository. Give a path relative to the project directory."
    ]
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
  (config, source) <-
    either (assertFailure . unlines) pure . parseConfig "conf.yml" $
      BS8.pack "hlint:\n  enabled: true\n  path: [../x]\n"
  assertBool
    "in the repository"
    (isRight $ workflow defaultOptions {projectDir = "sub"} source config project)
  (off, offSource) <-
    either (assertFailure . unlines) pure . parseConfig "conf.yml" $
      BS8.pack "hlint:\n  path: [../x]\n"
  assertBool "not enabled" (isRight $ workflow defaultOptions offSource off project)

test_hookStepId :: Assertion
test_hookStepId = do
  assertErrors
    "hooks:\n  after-setup:\n  - id: cache\n    run: echo a\n  after-build:\n  - id: Setup\n    run: echo b\n"
    [ "conf.yml:3:9: hooks.after-setup[0].id: the build job already has a step with the id cache. Give the hook step another id."
    , "conf.yml:6:9: hooks.after-build[0].id: the build job already has a step with the id setup, and GitHub compares the ids without case. Give the hook step another id."
    ]
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
  (config, source) <-
    either (assertFailure . unlines) pure . parseConfig "conf.yml" $
      BS8.pack "hooks:\n  after-build:\n  - id: doctest\n    run: echo a\n"
  assertBool "without doctest" (isRight $ workflow defaultOptions source config project)

test_namedDefaultConfig :: Assertion
test_namedDefaultConfig = do
  let parse = parseOptions
  assertEqual "without --config" (Just DefaultConfigFile) ((.config) <$> parse [])
  assertEqual
    "with --config"
    (Just (ConfigFile defaultConfigPath))
    ((.config) <$> parse ["--config", defaultConfigPath])
  assertEqual
    "command line"
    (Just ["haskell-gha", "--generate", "--config", defaultConfigPath])
    (commandLine <$> parse ["--config", defaultConfigPath])

test_configOutside :: Assertion
test_configOutside = do
  let parse path = (.config) <$> parseOptions ["--config", path]
  assertEqual "sub" (Just (ConfigFile "a/../b.yml")) (parse "a/../b.yml")
  assertEqual "absolute" Nothing (parse "/tmp/conf.yml")
  assertEqual "parent" Nothing (parse "../conf.yml")

test_projectDirOutside :: Assertion
test_projectDirOutside = do
  let parse dir = parseOptions ["--project-dir", dir]
  assertEqual "sub" (Just "a/../b") ((.projectDir) <$> parse "a/../b")
  assertEqual "absolute" Nothing (parse "/tmp/project")
  assertEqual "parent" Nothing (parse "a/../../b")
  assertEqual "empty" Nothing (parse "")

test_outputPath :: Assertion
test_outputPath = do
  let parse name = (.output) <$> parseOptions ["--output", name]
  assertEqual "yml" (Just "a.yml") (parse "a.yml")
  assertEqual "yaml" (Just "a.yaml") (parse "a.yaml")
  assertEqual
    "path"
    (Just ".github/workflows/a.yml")
    (outputPath <$> parseOptions ["--output", "a.yml"])
  assertEqual "directory" Nothing (parse ".github/workflows/a.yml")
  assertEqual "current directory" Nothing (parse "./a.yml")
  assertEqual "absolute" Nothing (parse "/a.yml")
  assertEqual "extension" Nothing (parse "a.txt")

test_controlCharacters :: Assertion
test_controlCharacters =
  forM_ ["--config", "--project-dir", "--output"] $ \opt -> do
    assertEqual (opt ++ " with a line break") Nothing (parseOptions [opt, "a\nb"])
    assertEqual (opt ++ " with a tab") Nothing (parseOptions [opt, "a\tb"])
    assertEqual (opt ++ " with U+2028") Nothing (parseOptions [opt, "a\x2028\&b"])
    assertEqual (opt ++ " with U+2029") Nothing (parseOptions [opt, "a\x2029\&b"])

test_sdistNamePrefix :: Assertion
test_sdistNamePrefix = do
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
  p <- case project.packages of
    [p] -> pure p
    ps -> assertFailure ("packages: " ++ show ps)
  let pkgs = [p {directory = "a"}, p {name = "example-2d", directory = "b"}]
      changed = project {packages = pkgs, matrix = [MatrixEntry e.ghc pkgs | e <- project.matrix]}
  node <-
    either
      (assertFailure . unlines)
      pure
      (workflow defaultOptions (emptySource "conf.yml") defaultConfig changed)
  assertEqual
    "tar lines"
    [ "tar -xzf \"$RUNNER_TEMP\"/haskell-gha-sdist/example-+([0-9.]).tar.gz --strip-components=1 -C \"$RUNNER_TEMP\"/haskell-gha/a"
    , "tar -xzf \"$RUNNER_TEMP\"/haskell-gha-sdist/example-2d-+([0-9.]).tar.gz --strip-components=1 -C \"$RUNNER_TEMP\"/haskell-gha/b"
    ]
    [ T.unpack (T.strip l)
    | l <- T.lines (renderWorkflow defaultOptions node)
    , T.pack "tar -xzf" `T.isInfixOf` l
    ]

test_sdistOutside :: Assertion
test_sdistOutside = do
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
  p <- case project.packages of
    [p] -> pure p
    ps -> assertFailure ("packages: " ++ show ps)
  let changed =
        project
          { packages = [p {directory = "../lib"}, p {name = "inner", directory = "a/../b"}]
          , imports =
              [ Import
                  { location = "cabal.project:1:1: "
                  , target = "local.project"
                  }
              , Import
                  { location = "cabal.project:2:1: "
                  , target = "https://example.com/remote.project"
                  }
              ]
          }
  assertEqual
    "errors"
    ( Left
        [ "cabal.project:1:1: the workflow builds the source tarballs in a copy of the project directory, and the copy does not contain the imported file local.project. Set sdist: false in the configuration."
        , "Package example is in ../lib, outside the project directory, but the workflow builds the source tarballs in a copy of the project directory. Set sdist: false in the configuration."
        ]
    )
    (workflow defaultOptions (emptySource "conf.yml") defaultConfig changed)
  assertBool
    "sdist: false"
    ( isRight $
        workflow defaultOptions (emptySource "conf.yml") defaultConfig {sdist = False} changed
    )

test_importOutside :: Assertion
test_importOutside = do
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
  let changed =
        project
          { imports =
              [ Import
                  { location = "cabal.project:1:1: "
                  , target = "../inside.project"
                  }
              , Import
                  { location = "cabal.project:2:1: "
                  , target = "../../outside.project"
                  }
              , Import
                  { location = "cabal.project:3:1: "
                  , target = "/etc/absolute.project"
                  }
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
  assertEqual
    "sdist: false"
    (Left outside)
    (workflow opts (emptySource "conf.yml") defaultConfig {sdist = False} changed)

test_headerCommandLine :: Assertion
test_headerCommandLine = do
  let opts = defaultOptions {projectDir = "my project", output = "it's.yml"}
      line =
        T.unpack
          <$> L.find
            (T.isInfixOf (T.pack "haskell-gha --"))
            (T.lines $ renderWorkflow opts (mapping []))
  assertEqual
    "command line"
    (Just "#   haskell-gha --generate --project-dir 'my project' --output 'it'\\''s.yml'")
    line

test_unknownGhcValue :: Assertion
test_unknownGhcValue =
  assertErrors
    "matrix:\n  x: [a, b]\n  exclude:\n    - ghc: '9.8'\n      x: a\n"
    [ "conf.yml:4:12: matrix.exclude[0].ghc: GHC 9.8 is not in the ghc axis, which contains only 9.6.7, 9.10, 9.12"
    ]

test_dependenciesAxis :: Assertion
test_dependenciesAxis = do
  assertErrors
    "dependencies: both\nmatrix:\n  dependencies: [a, b]\n  exclude:\n    - dependencies: older\n"
    [ "conf.yml:3:3: matrix: the tool makes the dependencies axis for dependencies: both, so the matrix must not contain it"
    , "conf.yml:5:21: matrix.exclude[0].dependencies: dependencies older is not in the dependencies axis, which contains only newest, oldest"
    ]
  assertErrors
    "matrix:\n  exclude:\n    - dependencies: oldest\n"
    [ "conf.yml:3:21: matrix.exclude[0].dependencies: the matrix has no dependencies axis. Set dependencies: both to add it."
    ]
  assertValid
    "dependencies: both\nmatrix:\n  exclude:\n    - ghc: '9.10'\n      dependencies: oldest\n"
  assertValid "matrix:\n  dependencies: [a, b]\n  exclude:\n    - dependencies: a\n"
  where
    assertValid :: String -> Assertion
    assertValid input = do
      (config, source) <-
        either (assertFailure . unlines) pure . parseConfig "conf.yml" $ BS8.pack input
      project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
      either
        (assertFailure . unlines)
        (const (pure ()))
        (workflow defaultOptions source config project)

test_partialDoctestRange :: Assertion
test_partialDoctestRange =
  assertErrors
    "doctest:\n  enabled: true\n  ghc: '>=9.10.2'\n"
    [ "conf.yml:3:8: doctest.ghc: the range >=9.10.2 includes only a part of the GHC versions of the matrix entry 9.10, so the result depends on the minor version that haskell-actions/setup selects. Change the range, or write exact versions in tested-with."
    ]

test_unusedRange :: Assertion
test_unusedRange =
  assertErrors
    "doctest:\n  enabled: true\n  ghc: '>=9.14'\n"
    [ "conf.yml:3:8: doctest.ghc: the range >=9.14 includes no GHC version of the matrix, which contains only 9.6.7, 9.10, 9.12"
    ]

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
  (config, source) <-
    either (assertFailure . unlines) pure . parseConfig "conf.yml" $ BS8.pack input
  project <- readProject "." "tests/golden/single" >>= either (assertFailure . unlines) pure
  assertEqual
    "errors"
    (Left expected)
    ( either
        (Left . map (takeWhile (/= '\n')))
        Right
        (workflow defaultOptions source config project)
    )

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
    let dir = workflowDirectory
        opts =
          defaultOptions
            { config = ConfigFile "it's.yml"
            , projectDir = "my project"
            , output = "a.yml"
            }
        write :: FilePath -> T.Text -> IO ()
        write name = BS.writeFile (root </> dir </> name) . T.encodeUtf8
    assertEqual
      "no directory"
      ( Left
          [ "No workflow in "
              ++ dir
              ++ " was generated by haskell-gha. To make one, run haskell-gha --generate."
          ]
      )
      =<< findWorkflows root
    createDirectoryIfMissing True (root </> dir)
    write "a.yml" $ renderWorkflow opts (mapping [])
    write "b.yml" (T.pack "name: other\n")
    createDirectory (root </> dir </> "directory.yml")
    createFileLink (root </> dir </> "missing") (root </> dir </> "dangling.yml")
    assertEqual "generated workflow" (Right [opts]) =<< findWorkflows root
    write "c.yaml" $ renderWorkflow opts {output = "d.yml"} (mapping [])
    assertEqual
      "other output"
      ( Left
          [ dir
              </> "c.yaml"
              ++ ": the command in the header writes the workflow to "
              ++ dir
              </> "d.yml"
              ++ ", not to this file"
          ]
      )
      =<< findWorkflows root
    let withCommand :: String -> IO ()
        withCommand line =
          write "c.yaml"
            . T.unlines
            . zipWith (\i l -> if i == 1 then T.pack ("#   " ++ line) else l) [0 :: Int ..]
            . T.lines
            $ renderWorkflow opts (mapping [])
        firstLines :: Either [String] a -> Either [String] a
        firstLines = either (Left . map (takeWhile (/= '\n'))) Right
    withCommand "echo haskell-gha"
    assertEqual
      "other program"
      ( Left
          [ dir
              </> "c.yaml"
              ++ ": the command in the header is not valid: the command does not start with haskell-gha --generate"
          ]
      )
      =<< findWorkflows root
    withCommand "haskell-gha --generate --output c.yaml --foo"
    assertEqual
      "unknown option"
      ( Left
          [dir </> "c.yaml" ++ ": the command in the header is not valid: Invalid option `--foo'"]
      )
      . firstLines
      =<< findWorkflows root

test_symbolicLinks :: Assertion
test_symbolicLinks =
  withSystemTempDirectory "haskell-gha-tests" $ \tmp -> do
    let root = tmp </> "repo"
        outside = tmp </> "outside"
        writePackage :: FilePath -> IO ()
        writePackage dir = do
          createDirectoryIfMissing True dir
          writeFile (dir </> "a.cabal") . unlines $
            [ "cabal-version: 3.0"
            , "name: a"
            , "version: 0"
            , "tested-with: GHC ^>= 9.10"
            , "library"
            ]
        -- Without the excerpts of the configuration.
        errors :: Options -> IO (Either [String] ())
        errors = fmap (either (Left . map (takeWhile (/= '\n'))) (const (Right ()))) . generate root
        throughLink :: String -> String
        throughLink start = start ++ " leads out of the repository through a symbolic link."
    writePackage (root </> "real")
    writePackage (outside </> "project")
    writeFile (outside </> "conf.yml") ""
    writeFile (outside </> "cabal.project") "packages: .\n"
    writeFile (root </> "real" </> "conf.yml") ""
    createFileLink "../outside/conf.yml" (root </> "out.yml")
    createDirectoryLink "../outside/project" (root </> "out")
    createDirectoryLink ".." (root </> "up")
    createFileLink (outside </> "conf.yml") (root </> "absolute.yml")
    createFileLink "loop.yml" (root </> "loop.yml")
    createFileLink "real/conf.yml" (root </> "in.yml")
    createDirectoryLink "real" (root </> "in")

    assertEqual "links in the repository" (Right ())
      =<< errors defaultOptions {config = ConfigFile "in.yml", projectDir = "in"}
    assertEqual
      "links out of the repository"
      ( Left
          [ throughLink "The configuration file out.yml"
          , throughLink "The project directory out"
          ]
      )
      =<< errors defaultOptions {config = ConfigFile "out.yml", projectDir = "out"}
    assertEqual
      "a link to the parent directory"
      (Left [throughLink "The project directory up"])
      =<< errors defaultOptions {projectDir = "up"}
    assertEqual
      "an absolute target"
      ( Left
          [ "The configuration file absolute.yml goes through the symbolic link absolute.yml with an absolute target, but the repository is at another place on the runner. Give the link a relative target."
          ]
      )
      =<< errors defaultOptions {config = ConfigFile "absolute.yml", projectDir = "real"}
    assertEqual
      "a loop"
      ( Left
          [ "The configuration file loop.yml goes through more than 40 symbolic links, and Linux on the runner follows no more."
          ]
      )
      =<< errors defaultOptions {config = ConfigFile "loop.yml", projectDir = "real"}

    createDirectory (root </> "linked")
    createFileLink "../../outside/cabal.project" (root </> "linked" </> "cabal.project")
    assertEqual
      "the project file"
      (Left [throughLink "The project file linked/cabal.project"])
      =<< errors defaultOptions {projectDir = "linked"}

    createDirectory (root </> "proj")
    writeFile (root </> "proj" </> "cabal.project") "packages: pkg\nimport: ../out.yml\n"
    createDirectoryLink "../../outside/project" (root </> "proj" </> "pkg")
    assertEqual
      "a package file"
      (Left [throughLink "The package file proj/pkg/a.cabal"])
      =<< errors defaultOptions {projectDir = "proj"}

    removeDirectoryLink (root </> "proj" </> "pkg")
    createDirectoryLink "../real" (root </> "proj" </> "pkg")
    writeFile
      (root </> "proj" </> "conf.yml")
      "sdist: false\nhlint:\n  enabled: true\n  path: [../out]\n"
    assertEqual
      "the paths on the runner"
      ( Left
          [ throughLink "proj/conf.yml:4:10: hlint.path[0]: the path ../out"
          , throughLink "proj/cabal.project:2:1: the imported file ../out.yml"
          ]
      )
      =<< errors defaultOptions {config = ConfigFile "proj/conf.yml", projectDir = "proj"}

    createDirectoryIfMissing True (root </> workflowDirectory)
    createFileLink "../../../outside/new.yml" (root </> outputPath defaultOptions)
    assertEqual
      "a broken link at the output"
      [throughLink ("The workflow " ++ outputPath defaultOptions)]
      =<< runCommand root (Generate defaultOptions {projectDir = "real"})
    assertBool "no file outside" . not =<< doesPathExist (outside </> "new.yml")

test_runCommand :: Assertion
test_runCommand =
  withSystemTempDirectory "haskell-gha-tests" $ \root -> do
    let writePackage :: IO ()
        writePackage =
          writeFile (root </> "a.cabal") . unlines $
            [ "cabal-version: 3.0"
            , "name: a"
            , "version: 0"
            , "tested-with: GHC ^>= 9.10"
            , "library"
            ]
    writePackage
    let run :: Command -> IO [String]
        run = runCommand root
        output :: FilePath
        output = root </> outputPath defaultOptions
        old = posixSecondsToUTCTime 0
        notUpToDate =
          [ "The workflow "
              ++ outputPath defaultOptions
              ++ " is not up to date. To update it, run haskell-gha without --check."
          ]
    assertEqual "first --generate" [] =<< run (Generate defaultOptions)
    assertBool "workflow written" =<< doesFileExist output
    assertEqual "--check after --generate" [] =<< run Check
    setModificationTime output old
    assertEqual "second --generate" [] =<< run (Generate defaultOptions)
    assertEqual "regenerate" [] =<< run Regenerate
    assertEqual "mtime of an unchanged workflow" old =<< getModificationTime output
    appendFile output "# An edit.\n"
    assertEqual "--check after an edit" notUpToDate =<< run Check
    assertEqual "regenerate after an edit" [] =<< run Regenerate
    assertEqual "--check after regenerate" [] =<< run Check
    removeFile (root </> "a.cabal")
    let noPackages = "There are no packages in the implicit project of \".\"."
    assertEqual "error" [noPackages] =<< run (Generate defaultOptions)
    let named = [outputPath defaultOptions ++ ": " ++ noPackages]
    assertEqual "error of regenerate" named =<< run Regenerate
    assertEqual "error of --check" named =<< run Check
    writePackage
    let ci = root </> workflowDirectory </> "ci.yml"
        ciOptions = defaultOptions {output = "ci.yml"}
    writeFile ci "name: CI\n"
    assertEqual
      "--generate over a workflow that the tool did not generate"
      [ "The workflow "
          ++ outputPath ciOptions
          ++ " was not generated by haskell-gha, so the tool does not replace it. Delete the file first, or give another name with --output."
      ]
      =<< run (Generate ciOptions)
    assertEqual "the workflow that the tool did not generate" "name: CI\n" =<< readFile ci
    let dirOptions = defaultOptions {output = "dir.yml"}
    createDirectory (root </> outputPath dirOptions)
    assertEqual
      "--generate over a directory"
      [ "The workflow "
          ++ outputPath dirOptions
          ++ " is a directory, so the tool does not replace it. Delete the directory first, or give another name with --output."
      ]
      =<< run (Generate dirOptions)
    assertEqual "regenerate next to a directory" [] =<< run Regenerate

-- | The options of a command line for one workflow, after @--generate@.
parseOptions :: [String] -> Maybe Options
parseOptions args = case getParseResult $ execParserPure defaultPrefs (optionsParser "TEST") ("--generate" : args) of
  Just (Generate opts) -> Just opts
  _ -> Nothing
