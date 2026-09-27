{-# LANGUAGE OverloadedStrings #-}

module ConfigTests (configTests) where

import Data.List.NonEmpty qualified as NE
import Data.Maybe
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Distribution.Version
import Test.Tasty
import Test.Tasty.HUnit

import HaskellGha.Config
import HaskellGha.Yaml

configTests :: TestTree
configTests =
  testGroup
    "Config"
    [ testCase "a missing file" test_missingFile
    , testCase "an empty file gives the defaults" test_emptyFile
    , testCase "the example configuration" test_example
    , testCase "a section without enabled stays off" test_sectionWithoutEnabled
    , testCase "cabal-version latest" test_latest
    , testCase "recursive submodules" test_recursiveSubmodules
    , testCase "a folded ghc-options value" test_foldedGhcOptions
    , testCase "errors" test_errors
    , testCase "all errors are collected" test_allErrors
    , testCase "errors give the line and the column" test_locations
    , testCase "an alias in a hook" test_alias
    ]

test_missingFile :: Assertion
test_missingFile = do
  -- The directory has no default configuration file.
  optional <- readConfig "tests" DefaultConfigFile
  assertEqual "default" (Right defaultConfig) (fst <$> optional)
  required <- readConfig "." (ConfigFile "tests/does-not-exist.yml")
  assertEqual "named" (Left ["The configuration file tests/does-not-exist.yml does not exist."]) (fst <$> required)

test_emptyFile :: Assertion
test_emptyFile = assertEqual "config" (Right defaultConfig) (parse "# only a comment\n")

test_example :: Assertion
test_example = do
  config <-
    parseOk $
      T.unlines
        [ "name: Tests"
        , "cabal-version: 3.14.2.0"
        , "runs-on: ubuntu-24.04"
        , "timeout-minutes: 30"
        , "branches: [master]"
        , "submodules: true"
        , "matrix:"
        , "  postgres: ['15', '18']"
        , "  exclude:"
        , "    - ghc: '9.10'"
        , "      postgres: '15'"
        , "apt: [libpq-dev]"
        , "services:"
        , "  postgres:"
        , "    image: postgres:${{ matrix.postgres }}"
        , "permissions: read-all"
        , "hooks:"
        , "  after-setup:"
        , "    - name: Show the Postgres version"
        , "      run: psql --version"
        , "  after-build: []"
        , "ghc-options: -Werror -Wno-unused"
        , "cabal-project-local: |"
        , "  package a"
        , "    flags: +b"
        , "jobs: 2"
        , "tests: false"
        , "benchmarks: False"
        , "dependencies: both"
        , "doctest:"
        , "  enabled: true"
        , "  ghc: '>=9.6 && <9.14'"
        , "  version: '>=0.24'"
        , "  skip: [some-package]"
        , "  options: [--fast]"
        , "check: false"
        , "sdist: false"
        , "haddock: false"
        , "fourmolu:"
        , "  enabled: true"
        , "  version: 0.19.0.1"
        , "  pattern: ['src/**/*.hs']"
        , "hlint:"
        , "  enabled: true"
        , "  fail-on: error"
        , "  path: [src]"
        , "actions:"
        , "  checkout: v8"
        , "  cache: runs-on/cache@v4"
        , "  setup: 0123abc"
        , "  run-fourmolu: v12"
        , "  hlint-run: v2"
        ]
  assertEqual "name" "Tests" config.name.value
  assertEqual "cabal-version" (CabalVersion $ mkVersion [3, 14, 2, 0]) config.cabalVersion
  assertEqual "runs-on" "ubuntu-24.04" config.runsOn.value
  assertEqual "timeout-minutes" 30 config.timeoutMinutes.value
  assertEqual "branches" ["master"] (map (.value) (NE.toList config.branches.value))
  assertEqual "submodules" TopSubmodules config.submodules
  assertEqual "matrix axes" ["postgres"] (matrixAxes config)
  assertEqual "matrix ghc values" ["9.10"] (map (.value) (matrixValues ["include", "exclude"] "ghc" config))
  assertEqual "apt" ["libpq-dev"] config.apt
  assertBool "services" (isJust config.services)
  assertEqual "permissions" (plain "read-all") (normalize config.permissions.value.value)
  assertEqual "after-setup" 1 (length config.hooks.value.afterSetup.value)
  assertEqual "after-build" 0 (length config.hooks.value.afterBuild.value)
  assertEqual "ghc-options" "-Werror -Wno-unused" config.ghcOptions.value
  assertEqual "cabal-project-local" "package a\n  flags: +b\n" config.cabalProjectLocal.value
  assertEqual "jobs" 2 config.jobs.value
  assertEqual "tests" False config.tests
  assertEqual "benchmarks" False config.benchmarks
  assertEqual "dependencies" DependenciesBoth config.dependencies
  assertEqual "doctest enabled" True config.doctest.enabled
  assertEqual "doctest ghc" (intersectVersionRanges (orLaterVersion $ mkVersion [9, 6]) (earlierVersion $ mkVersion [9, 14])) config.doctest.ghc.value
  assertEqual "doctest version" (Just (orLaterVersion $ mkVersion [0, 24])) config.doctest.version
  assertEqual "doctest skip" ["some-package"] (map (.value) config.doctest.skip)
  assertEqual "doctest options" ["--fast"] config.doctest.options
  assertEqual "check" False config.check
  assertEqual "sdist" False config.sdist
  assertEqual "haddock" False config.haddock
  assertEqual "fourmolu" Fourmolu {enabled = True, version = mkVersion [0, 19, 0, 1], patterns = [Pattern "src/**/*.hs"]} config.fourmolu
  assertEqual "hlint enabled" True config.hlint.enabled
  assertEqual "hlint version" (mkVersion [3, 10]) config.hlint.version
  assertEqual "hlint fail-on" FailError config.hlint.failOn
  assertEqual "hlint path" [HLintPath "src"] (map (.value) config.hlint.path)
  assertEqual
    "actions"
    ( Actions
        { checkout = ActionRef Nothing "v8"
        , setup = ActionRef Nothing "0123abc"
        , cache = ActionRef (Just "runs-on/cache") "v4"
        , runFourmolu = ActionRef Nothing "v12"
        , hlintSetup = defaultConfig.actions.hlintSetup
        , hlintRun = ActionRef Nothing "v2"
        }
    )
    config.actions

test_sectionWithoutEnabled :: Assertion
test_sectionWithoutEnabled = do
  config <- parseOk "hlint:\n  fail-on: error\n"
  assertEqual "hlint" defaultHLint {failOn = FailError} config.hlint

test_recursiveSubmodules :: Assertion
test_recursiveSubmodules = do
  config <- parseOk "submodules: recursive\n"
  assertEqual "submodules" RecursiveSubmodules config.submodules

test_foldedGhcOptions :: Assertion
test_foldedGhcOptions = do
  config <- parseOk "ghc-options: >\n  -Wall\n  -Werror\n"
  assertEqual "ghc-options" "-Wall -Werror" config.ghcOptions.value

test_latest :: Assertion
test_latest = do
  config <- parseOk "cabal-version: latest\n"
  assertEqual "cabal-version" CabalLatest config.cabalVersion

test_errors :: Assertion
test_errors = do
  assertError "not a mapping" "expected a mapping, but got a list" "- a\n"
  assertError "unknown key" "unknown key \"job\", did you mean \"jobs\"?" "job: 4\n"
  assertError "unknown hooks key" "hooks: unknown key \"before-build\", expected one of: after-setup, after-build" "hooks:\n  before-build: []\n"
  assertError "unknown doctest key" "doctest: unknown key \"flags\", expected one of: enabled, ghc, version, skip, options" "doctest:\n  flags: []\n"
  assertError "duplicate key" "duplicate key \"jobs\"" "jobs: 1\njobs: 2\n"
  assertError "two documents" "expected a single document, but got a second one" "jobs: 1\n---\njobs: 2\n"
  assertError "jobs" "jobs: expected a positive integer" "jobs: 0\n"
  assertError "jobs type" "jobs: expected a positive integer" "jobs: four\n"
  assertError "jobs null" "jobs: expected a positive integer" "jobs: ~\n"
  assertError "timeout-minutes" "timeout-minutes: expected a positive integer" "timeout-minutes: 0\n"
  assertError "tests" "tests: expected a boolean, but got a string" "tests: 'true'\n"
  assertError "branches" "branches: expected a non-empty list" "branches: []\n"
  assertError "dependencies" "dependencies: unknown value \"old\", expected one of: newest, oldest, both" "dependencies: old\n"
  assertError "submodules" "submodules: expected true, false or recursive" "submodules: 'yes'\n"
  assertError "runs-on" "runs-on: expected a string, but got a list" "runs-on: [self-hosted, linux]\n"
  assertError "old cabal" "cabal-version: the tool supports only cabal 3.12 and later" "cabal-version: '3.10'\n"
  assertError "unquoted number" "hlint.version: expected a string, but got a floating-point number, quote the value, e.g. '3.10'" "hlint:\n  version: 3.10\n"
  assertError "unquoted boolean" "apt[0]: expected a string, but got a boolean, quote the value, e.g. 'true'" "apt: [true]\n"
  assertError "old cabal full" "cabal-version: the tool supports only cabal 3.12 and later" "cabal-version: 3.10.3.0\n"
  assertError "cabal version" "cabal-version: expected latest or a version" "cabal-version: newest\n"
  assertError "ghc axis" "matrix: the tool makes the ghc axis, so the matrix must not contain it" "matrix:\n  ghc: ['9.10']\n"
  assertError "axis name" "matrix: the axis name \"os x\" is not valid in a GitHub expression. A name must start with a letter or _, and contain only letters, digits, _ and -, e.g. os-version" "matrix:\n  os x: ['a']\n"
  assertError "axis name start" "matrix: the axis name \"1os\" is not valid in a GitHub expression. A name must start with a letter or _, and contain only letters, digits, _ and -, e.g. os-version" "matrix:\n  1os: ['a']\n"
  assertError "unquoted ghc" "matrix.include[0].ghc: a ghc value must be a quoted string, e.g. '9.10'" "matrix:\n  include:\n    - ghc: 9.10\n"
  assertError "exclude" "matrix.exclude: expected a list of mappings, but got a string" "matrix:\n  exclude: '9.10'\n"
  assertError "include item" "matrix.include[0]: expected a mapping, but got a string" "matrix:\n  include:\n    - '9.10'\n"
  assertError "exclude key" "matrix.exclude[0]: version is not an axis of the matrix. The axes are: ghc, postgres" "matrix:\n  postgres: ['15', '18']\n  exclude:\n    - ghc: '9.10'\n      version: '15'\n"
  assertError "services" "services: expected a mapping, but got a list" "services: [postgres]\n"
  assertError "permissions" "permissions: expected a mapping, read-all or write-all" "permissions: [contents]\n"
  assertError "permissions scalar" "permissions: expected a mapping, read-all or write-all" "permissions: read\n"
  assertError "hooks null" "hooks: expected a mapping, but got null" "hooks:\n"
  assertError "step" "hooks.after-setup[0]: expected a mapping, but got a string" "hooks:\n  after-setup:\n    - make\n"
  assertError "doctest null" "doctest: expected a mapping, but got null" "doctest:\n"
  assertError "doctest range" "doctest.ghc: expected a version range" "doctest:\n  ghc: nine\n"
  assertError "apt" "apt: expected a list, but got a string" "apt: libpq-dev\n"
  assertError "cabal-project-local" "cabal-project-local: a line must not be EOF" "cabal-project-local: |\n  tests: True\n  EOF\n"
  assertError "unknown action" "actions: unknown key \"run-ormolu\", did you mean \"run-fourmolu\"?" "actions:\n  run-ormolu: v17\n"
  assertError "fourmolu version" "fourmolu.version: expected a version, e.g. 0.20.1.0" "fourmolu:\n  version: latest\n"
  assertError "hlint path" "hlint.path[1]: a path must not contain a control character, e.g. a tab or a line break" "hlint:\n  path: [src, \"a\\tb\"]\n"
  assertError "hlint fail-on" "hlint.fail-on: unknown value \"warnings\", did you mean \"warning\"?" "hlint:\n  fail-on: warnings\n"
  assertError "unknown fourmolu key" "fourmolu: unknown key \"extra-args\", expected one of: enabled, version, pattern" "fourmolu:\n  extra-args: [-q]\n"
  assertError "action ref" actionError "actions:\n  setup: 'v 2'\n"
  assertError "action without owner" actionError "actions:\n  setup: setup@v2\n"
  assertError "action with a path" actionError "actions:\n  setup: a/b/c@v2\n"
  assertError "action without ref" actionError "actions:\n  setup: a/b@\n"
  assertError "action with two refs" actionError "actions:\n  setup: a/b@v1@v2\n"
  assertError "ghc-options lines" "ghc-options: the value must be one line" "ghc-options: |\n  -Wall\n  -Werror\n"
  assertError "fourmolu pattern space" "fourmolu.pattern[0]: a pattern must be one line without spaces at the start or the end" "fourmolu:\n  pattern: [' src/**/*.hs']\n"
  assertError "fourmolu pattern lines" "fourmolu.pattern[0]: a pattern must be one line without spaces at the start or the end" "fourmolu:\n  pattern: [\"a.hs\\nb.hs\"]\n"
  assertError "cabal-project-local type" "cabal-project-local: expected a string, but got a list" "cabal-project-local: [tests]\n"
  where
    assertError :: String -> String -> T.Text -> Assertion
    assertError preface expected input =
      assertEqual preface (Left [expected]) (either (Left . map dropLocation) Right . firstLines $ parse input)

    -- The file name has no space, so the location ends at the first space.
    dropLocation :: String -> String
    dropLocation = drop 1 . dropWhile (/= ' ')

    actionError :: String
    actionError = "actions.setup: expected a Git ref, e.g. v7, or a repository with a Git ref, e.g. runs-on/cache@v4"

test_locations :: Assertion
test_locations = do
  assertEqual
    "excerpt"
    (Left ["conf.yml:2:12: hlint.version: expected a string, but got a floating-point number, quote the value, e.g. '3.10'\n  |\n2 |   version: 3.10\n  |            ^"])
    (parse "hlint:\n  version: 3.10\n")
  assertEqual "root" (Left ["conf.yml:1:1: expected a mapping, but got a list"]) (firstLines $ parse "- a\n")
  assertEqual "nested key" (Left ["conf.yml:2:3: hooks: unknown key \"before-build\", expected one of: after-setup, after-build"]) (firstLines $ parse "hooks:\n  before-build: []\n")
  assertEqual "list item" (Left ["conf.yml:1:13: apt[2]: expected a string, but got a boolean, quote the value, e.g. 'true'"]) (firstLines $ parse "apt: [a, b, true]\n")
  assertEqual
    "matrix key"
    (Left ["conf.yml:4:7: matrix.exclude[0]: version is not an axis of the matrix. The axes are: ghc, postgres"])
    (firstLines $ parse "matrix:\n  postgres: ['15']\n  exclude:\n    - version: '15'\n")

test_allErrors :: Assertion
test_allErrors = do
  assertEqual
    "fields"
    (Left ["conf.yml:1:1: unknown key \"job\", did you mean \"jobs\"?", "conf.yml:2:8: tests: expected a boolean, but got an integer", "conf.yml:3:7: jobs: expected a positive integer"])
    (firstLines $ parse "job: 1\ntests: 1\njobs: -1\n")
  assertEqual
    "matrix"
    ( Left
        [ "conf.yml:2:3: matrix: the axis name \"os x\" is not valid in a GitHub expression. A name must start with a letter or _, and contain only letters, digits, _ and -, e.g. os-version"
        , "conf.yml:3:3: matrix: the tool makes the ghc axis, so the matrix must not contain it"
        , "conf.yml:5:12: matrix.include[0].ghc: a ghc value must be a quoted string, e.g. '9.10'"
        , "conf.yml:8:7: matrix.exclude[0]: version is not an axis of the matrix. The axes are: ghc, os x"
        ]
    )
    (firstLines $ parse "matrix:\n  os x: [a]\n  ghc: ['9.10']\n  include:\n    - ghc: 9.10\n  exclude:\n    - ghc: '9.10'\n      version: '15'\n")

test_alias :: Assertion
test_alias = do
  config <- parseOk "hooks:\n  after-setup:\n    - &step {run: a}\n  after-build:\n    - *step\n"
  assertEqual "after-build" (contents config.hooks.value.afterSetup.value) (contents config.hooks.value.afterBuild.value)
  where
    -- The copy of an alias has no anchor.
    contents :: [MappingNode] -> [Content]
    contents = map (\s -> (normalize s.value).content)

----------------------------------------
-- Helpers

-- | The first line of each error, without the excerpt of the input.
firstLines :: Either [String] a -> Either [String] a
firstLines = either (Left . map (takeWhile (/= '\n'))) Right

parse :: T.Text -> Either [String] Config
parse = fmap fst . parseConfig "conf.yml" . T.encodeUtf8

parseOk :: T.Text -> IO Config
parseOk input = case parse input of
  Left errors -> assertFailure $ unlines errors
  Right config -> pure config
