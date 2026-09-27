{-# LANGUAGE OverloadedStrings #-}

module ConfigTests (configTests) where

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
    , testCase "a null value gives the default" test_null
    , testCase "cabal-version latest" test_latest
    , testCase "recursive submodules" test_recursiveSubmodules
    , testCase "a folded ghc-options value" test_foldedGhcOptions
    , testCase "errors" test_errors
    , testCase "all errors are collected" test_allErrors
    , testCase "errors give the line and the column" test_locations
    ]

test_missingFile :: Assertion
test_missingFile = do
  -- The directory has no default configuration file.
  optional <- readConfig "tests" DefaultConfigFile
  assertEqual "default" (Right defaultConfig) optional
  required <- readConfig "." (ConfigFile "tests/does-not-exist.yml")
  assertEqual "named" (Left ["The configuration file tests/does-not-exist.yml does not exist."]) required

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
  assertEqual "name" (plain "Tests") (normalize config.name)
  assertEqual "cabal-version" (CabalVersion $ mkVersion [3, 14, 2, 0]) config.cabalVersion
  assertEqual "runs-on" (plain "ubuntu-24.04") (normalize config.runsOn)
  assertEqual "timeout-minutes" 30 config.timeoutMinutes
  assertEqual "branches" [plain "master"] (map normalize config.branches)
  assertEqual "submodules" TopSubmodules config.submodules
  assertEqual "matrix axes" ["postgres"] (matrixAxes config)
  assertEqual "matrix ghc values" ["9.10"] (matrixGhcValues config)
  assertEqual "apt" ["libpq-dev"] config.apt
  assertBool "services" (isJust config.services)
  assertEqual "permissions" (plain "read-all") (normalize config.permissions)
  assertEqual "after-setup" 1 (length config.hooks.afterSetup.steps)
  assertEqual "after-build" 0 (length config.hooks.afterBuild.steps)
  assertEqual "ghc-options" "-Werror -Wno-unused" config.ghcOptions
  assertEqual "cabal-project-local" "package a\n  flags: +b\n" config.cabalProjectLocal
  assertEqual "jobs" 2 config.jobs
  assertEqual "tests" False config.tests
  assertEqual "benchmarks" False config.benchmarks
  assertEqual
    "doctest"
    Doctest
      { enabled = True
      , ghc = intersectVersionRanges (orLaterVersion $ mkVersion [9, 6]) (earlierVersion $ mkVersion [9, 14])
      , version = Just (orLaterVersion $ mkVersion [0, 24])
      , skip = ["some-package"]
      , options = ["--fast"]
      }
    config.doctest
  assertEqual "check" False config.check
  assertEqual "sdist" False config.sdist
  assertEqual "haddock" False config.haddock
  assertEqual "fourmolu" Fourmolu {enabled = True, version = mkVersion [0, 19, 0, 1], patterns = ["src/**/*.hs"]} config.fourmolu
  assertEqual "hlint" HLint {enabled = True, version = mkVersion [3, 10], failOn = "error", path = ["src"]} config.hlint
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
  assertEqual "hlint" defaultHLint {failOn = "error"} config.hlint

test_null :: Assertion
test_null = do
  config <- parseOk "jobs: ~\nhooks:\n"
  assertEqual "config" defaultConfig config

test_recursiveSubmodules :: Assertion
test_recursiveSubmodules = do
  config <- parseOk "submodules: recursive\n"
  assertEqual "submodules" RecursiveSubmodules config.submodules

test_foldedGhcOptions :: Assertion
test_foldedGhcOptions = do
  config <- parseOk "ghc-options: >\n  -Wall\n  -Werror\n"
  assertEqual "ghc-options" "-Wall -Werror" config.ghcOptions

test_latest :: Assertion
test_latest = do
  config <- parseOk "cabal-version: latest\n"
  assertEqual "cabal-version" CabalLatest config.cabalVersion

test_errors :: Assertion
test_errors = do
  assertError "not a mapping" "the configuration must be a mapping" "- a\n"
  assertError "unknown key" "unknown key \"job\"" "job: 4\n"
  assertError "unknown hooks key" "unknown key \"hooks.before-build\", expected one of: after-setup, after-build" "hooks:\n  before-build: []\n"
  assertError "unknown doctest key" "unknown key \"doctest.flags\", expected one of: enabled, ghc, version, skip, options" "doctest:\n  flags: []\n"
  assertError "jobs" "key \"jobs\": expected a positive integer" "jobs: 0\n"
  assertError "jobs type" "key \"jobs\": expected a positive integer" "jobs: four\n"
  assertError "timeout-minutes" "key \"timeout-minutes\": expected a positive integer" "timeout-minutes: 0\n"
  assertError "tests" "key \"tests\": expected true or false, but got a string" "tests: 'true'\n"
  assertError "branches" "key \"branches\": the list must not be empty" "branches: []\n"
  assertError "submodules" "key \"submodules\": expected true, false or recursive" "submodules: 'yes'\n"
  assertError "runs-on" "key \"runs-on\": expected a string, but got a list" "runs-on: [self-hosted, linux]\n"
  assertError "old cabal" "key \"cabal-version\": the tool supports only cabal 3.12 and later" "cabal-version: '3.10'\n"
  assertError "unquoted number" "key \"hlint.version\": expected a string, but got a floating-point number. Quote the value, e.g. '3.10'" "hlint:\n  version: 3.10\n"
  assertError "unquoted boolean" "key \"apt\": expected a string, but got a boolean. Quote the value, e.g. 'true'" "apt: [true]\n"
  assertError "old cabal full" "key \"cabal-version\": the tool supports only cabal 3.12 and later" "cabal-version: 3.10.3.0\n"
  assertError "cabal version" "key \"cabal-version\": expected latest or a version" "cabal-version: newest\n"
  assertError "ghc axis" "key \"matrix\": the tool makes the ghc axis, so the matrix must not contain it" "matrix:\n  ghc: ['9.10']\n"
  assertError "axis name" "key \"matrix\": the axis name \"os x\" is not valid in a GitHub expression. A name must start with a letter or _, and contain only letters, digits, _ and -, e.g. os-version" "matrix:\n  os x: ['a']\n"
  assertError "axis name start" "key \"matrix\": the axis name \"1os\" is not valid in a GitHub expression. A name must start with a letter or _, and contain only letters, digits, _ and -, e.g. os-version" "matrix:\n  1os: ['a']\n"
  assertError "unquoted ghc" "key \"matrix.include\": a ghc value must be a quoted string, e.g. '9.10'" "matrix:\n  include:\n    - ghc: 9.10\n"
  assertError "exclude" "key \"matrix.exclude\": expected a list of mappings, but got a string" "matrix:\n  exclude: '9.10'\n"
  assertError "include item" "key \"matrix.include item\": expected a mapping, but got a string" "matrix:\n  include:\n    - '9.10'\n"
  assertError "exclude key" "key \"matrix.exclude\": version is not an axis of the matrix. The axes are: ghc, postgres" "matrix:\n  postgres: ['15', '18']\n  exclude:\n    - ghc: '9.10'\n      version: '15'\n"
  assertError "services" "key \"services\": expected a mapping, but got a list" "services: [postgres]\n"
  assertError "permissions" "key \"permissions\": expected a mapping, read-all or write-all" "permissions: [contents]\n"
  assertError "permissions scalar" "key \"permissions\": expected a mapping, read-all or write-all" "permissions: read\n"
  assertError "step" "key \"hooks.after-setup item\": expected a mapping, but got a string" "hooks:\n  after-setup:\n    - make\n"
  assertError "doctest range" "key \"doctest.ghc\": expected a version range" "doctest:\n  ghc: nine\n"
  assertError "apt" "key \"apt\": expected a list of strings, but got a string" "apt: libpq-dev\n"
  assertError "cabal-project-local" "key \"cabal-project-local\": a line must not be EOF" "cabal-project-local: |\n  tests: True\n  EOF\n"
  assertError "unknown action" "unknown key \"actions.run-ormolu\", expected one of: checkout, setup, cache, run-fourmolu, hlint-setup, hlint-run" "actions:\n  run-ormolu: v17\n"
  assertError "fourmolu version" "key \"fourmolu.version\": expected a version, e.g. 0.20.1.0" "fourmolu:\n  version: latest\n"
  assertError "hlint fail-on" "key \"hlint.fail-on\": expected one of never, status, warning, suggestion, error" "hlint:\n  fail-on: warnings\n"
  assertError "unknown fourmolu key" "unknown key \"fourmolu.extra-args\", expected one of: enabled, version, pattern" "fourmolu:\n  extra-args: [-q]\n"
  assertError "action ref" actionError "actions:\n  setup: 'v 2'\n"
  assertError "action without owner" actionError "actions:\n  setup: setup@v2\n"
  assertError "action with a path" actionError "actions:\n  setup: a/b/c@v2\n"
  assertError "action without ref" actionError "actions:\n  setup: a/b@\n"
  assertError "action with two refs" actionError "actions:\n  setup: a/b@v1@v2\n"
  assertError "ghc-options lines" "key \"ghc-options\": the value must be one line" "ghc-options: |\n  -Wall\n  -Werror\n"
  assertError "fourmolu pattern space" "key \"fourmolu.pattern\": a pattern must be one line without spaces at the start or the end" "fourmolu:\n  pattern: [' src/**/*.hs']\n"
  assertError "fourmolu pattern lines" "key \"fourmolu.pattern\": a pattern must be one line without spaces at the start or the end" "fourmolu:\n  pattern: [\"a.hs\\nb.hs\"]\n"
  assertError "cabal-project-local type" "key \"cabal-project-local\": expected a string, but got a list" "cabal-project-local: [tests]\n"
  where
    assertError :: String -> String -> T.Text -> Assertion
    assertError preface expected input =
      assertEqual preface (Left [expected]) (either (Left . map dropLocation) Right . firstLines $ parse input)

    -- The file name has no space, so the location ends at the first space.
    dropLocation :: String -> String
    dropLocation = drop 1 . dropWhile (/= ' ')

    actionError :: String
    actionError = "key \"actions.setup\": expected a Git ref, e.g. v7, or a repository with a Git ref, e.g. runs-on/cache@v4"

test_allErrors :: Assertion
test_allErrors =
  assertEqual
    "errors"
    (Left ["conf.yml:1:1: unknown key \"job\"", "conf.yml:2:8: key \"tests\": expected true or false, but got an integer", "conf.yml:3:7: key \"jobs\": expected a positive integer"])
    (firstLines $ parse "job: 1\ntests: 1\njobs: -1\n")

test_locations :: Assertion
test_locations = do
  assertEqual
    "excerpt"
    (Left ["conf.yml:2:12: key \"hlint.version\": expected a string, but got a floating-point number. Quote the value, e.g. '3.10'\n  |\n2 |   version: 3.10\n  |            ^"])
    (parse "hlint:\n  version: 3.10\n")
  assertEqual "root" (Left ["conf.yml:1:1: the configuration must be a mapping"]) (firstLines $ parse "- a\n")
  assertEqual "nested key" (Left ["conf.yml:2:3: unknown key \"hooks.before-build\", expected one of: after-setup, after-build"]) (firstLines $ parse "hooks:\n  before-build: []\n")
  assertEqual "list item" (Left ["conf.yml:1:13: key \"apt\": expected a string, but got a boolean. Quote the value, e.g. 'true'"]) (firstLines $ parse "apt: [a, b, true]\n")
  assertEqual
    "matrix key"
    (Left ["conf.yml:4:7: key \"matrix.exclude\": version is not an axis of the matrix. The axes are: ghc, postgres"])
    (firstLines $ parse "matrix:\n  postgres: ['15']\n  exclude:\n    - version: '15'\n")

----------------------------------------
-- Helpers

-- | The first line of each error, without the excerpt of the input.
firstLines :: Either [String] a -> Either [String] a
firstLines = either (Left . map (takeWhile (/= '\n'))) Right

parse :: T.Text -> Either [String] Config
parse = parseConfig "conf.yml" . T.encodeUtf8

parseOk :: T.Text -> IO Config
parseOk input = case parse input of
  Left errors -> assertFailure $ unlines errors
  Right config -> pure config
