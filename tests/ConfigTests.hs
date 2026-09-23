{-# LANGUAGE OverloadedStrings #-}

module ConfigTests (configTests) where

import Data.ByteString.Lazy qualified as BL
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
    , testCase "an empty doctest field enables doctest" test_emptyDoctest
    , testCase "a null value gives the default" test_null
    , testCase "cabal-version latest" test_latest
    , testCase "recursive submodules" test_recursiveSubmodules
    , testCase "a folded ghc-options value" test_foldedGhcOptions
    , testCase "errors" test_errors
    , testCase "all errors are collected" test_allErrors
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
        , "  before-build:"
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
        , "  ghc: '>=9.6 && <9.14'"
        , "  version: '>=0.24'"
        , "  skip: [some-package]"
        , "  options: [--fast]"
        , "check: false"
        , "sdist: false"
        , "haddock: false"
        , "fourmolu:"
        , "  version: 0.19.0.1"
        , "  pattern: ['src/**/*.hs']"
        , "hlint:"
        , "  fail-on: error"
        , "  path: [src]"
        , "actions:"
        , "  checkout: v8"
        , "  cache: 0123abc"
        , "  run-fourmolu: v12"
        , "  hlint-run: v2"
        ]
  assertEqual "name" (plain "Tests") config.name
  assertEqual "cabal-version" (CabalVersion $ mkVersion [3, 14, 2, 0]) config.cabalVersion
  assertEqual "runs-on" (plain "ubuntu-24.04") config.runsOn
  assertEqual "branches" [plain "master"] config.branches
  assertEqual "submodules" TopSubmodules config.submodules
  assertEqual "matrix axes" ["postgres"] (matrixAxes config)
  assertEqual "matrix ghc values" ["9.10"] (matrixGhcValues config)
  assertEqual "apt" ["libpq-dev"] config.apt
  assertBool "services" (isJust config.services)
  assertEqual "permissions" (plain "read-all") config.permissions
  assertEqual "before-build" 1 (length config.hooks.beforeBuild)
  assertEqual "after-build" 0 (length config.hooks.afterBuild)
  assertEqual "ghc-options" "-Werror -Wno-unused" config.ghcOptions
  assertEqual "cabal-project-local" "package a\n  flags: +b\n" config.cabalProjectLocal
  assertEqual "jobs" 2 config.jobs
  assertEqual "tests" False config.tests
  assertEqual "benchmarks" False config.benchmarks
  assertEqual
    "doctest"
    ( Just
        Doctest
          { ghc = intersectVersionRanges (orLaterVersion $ mkVersion [9, 6]) (earlierVersion $ mkVersion [9, 14])
          , version = Just (orLaterVersion $ mkVersion [0, 24])
          , skip = ["some-package"]
          , options = ["--fast"]
          }
    )
    config.doctest
  assertEqual "check" False config.check
  assertEqual "sdist" False config.sdist
  assertEqual "haddock" False config.haddock
  assertEqual "fourmolu" (Just Fourmolu {version = mkVersion [0, 19, 0, 1], patterns = ["src/**/*.hs"]}) config.fourmolu
  assertEqual "hlint" (Just HLint {version = mkVersion [3, 10], failOn = "error", path = ["src"]}) config.hlint
  assertEqual
    "actions"
    (Actions {checkout = "v8", setup = "v2", cache = "0123abc", runFourmolu = "v12", hlintSetup = defaultConfig.actions.hlintSetup, hlintRun = "v2"})
    config.actions

test_emptyDoctest :: Assertion
test_emptyDoctest = do
  config <- parseOk "doctest:\n"
  assertEqual "doctest" (Just defaultDoctest) config.doctest

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
  assertError "unknown field" "unknown field \"job\"" "job: 4\n"
  assertError "unknown hooks field" "unknown field \"hooks.before-test\"" "hooks:\n  before-test: []\n"
  assertError "unknown doctest field" "unknown field \"doctest.flags\"" "doctest:\n  flags: []\n"
  assertError "jobs" "field \"jobs\": expected a positive integer" "jobs: 0\n"
  assertError "jobs type" "field \"jobs\": expected a positive integer" "jobs: four\n"
  assertError "tests" "field \"tests\": expected true or false" "tests: 'true'\n"
  assertError "branches" "field \"branches\": the list must not be empty" "branches: []\n"
  assertError "submodules" "field \"submodules\": expected true, false or recursive" "submodules: 'yes'\n"
  assertError "runs-on" "field \"runs-on\": expected a string" "runs-on: [self-hosted, linux]\n"
  assertError "old cabal" "field \"cabal-version\": the GHC job semaphore needs cabal 3.12 or later" "cabal-version: '3.10'\n"
  assertError "unquoted number" "field \"hlint.version\": expected a string. Quote the value, e.g. '3.10'" "hlint:\n  version: 3.10\n"
  assertError "unquoted boolean" "field \"apt\": expected a string. Quote the value, e.g. 'true'" "apt: [true]\n"
  assertError "old cabal full" "field \"cabal-version\": the GHC job semaphore needs cabal 3.12 or later" "cabal-version: 3.10.3.0\n"
  assertError "cabal version" "field \"cabal-version\": expected latest or a version" "cabal-version: newest\n"
  assertError "ghc axis" "field \"matrix\": the tool makes the ghc axis, so the matrix must not contain it" "matrix:\n  ghc: ['9.10']\n"
  assertError "unquoted ghc" "field \"matrix.include\": a ghc value must be a quoted string, e.g. '9.10'" "matrix:\n  include:\n    - ghc: 9.10\n"
  assertError "exclude" "field \"matrix.exclude\": expected a list of mappings" "matrix:\n  exclude: '9.10'\n"
  assertError "exclude key" "field \"matrix.exclude\": the key version is not an axis of the matrix. The axes are: ghc, postgres" "matrix:\n  postgres: ['15', '18']\n  exclude:\n    - ghc: '9.10'\n      version: '15'\n"
  assertError "services" "field \"services\": expected a mapping" "services: [postgres]\n"
  assertError "permissions" "field \"permissions\": expected a mapping, read-all or write-all" "permissions: [contents]\n"
  assertError "permissions scalar" "field \"permissions\": expected a mapping, read-all or write-all" "permissions: read\n"
  assertError "step" "field \"hooks.before-build item\": expected a mapping" "hooks:\n  before-build:\n    - make\n"
  assertError "doctest range" "field \"doctest.ghc\": expected a version range" "doctest:\n  ghc: nine\n"
  assertError "apt" "field \"apt\": expected a list of strings" "apt: libpq-dev\n"
  assertError "cabal-project-local" "field \"cabal-project-local\": a line must not be EOF" "cabal-project-local: |\n  tests: True\n  EOF\n"
  assertError "unknown action" "unknown field \"actions.run-ormolu\"" "actions:\n  run-ormolu: v17\n"
  assertError "fourmolu version" "field \"fourmolu.version\": expected a version, e.g. 0.20.1.0" "fourmolu:\n  version: latest\n"
  assertError "hlint fail-on" "field \"hlint.fail-on\": expected one of never, status, warning, suggestion, error" "hlint:\n  fail-on: warnings\n"
  assertError "unknown fourmolu field" "unknown field \"fourmolu.extra-args\"" "fourmolu:\n  extra-args: [-q]\n"
  assertError "action ref" "field \"actions.setup\": expected a Git ref, e.g. v7" "actions:\n  setup: 'v 2'\n"
  assertError "ghc-options lines" "field \"ghc-options\": the value must be one line" "ghc-options: |\n  -Wall\n  -Werror\n"
  assertError "fourmolu pattern space" "field \"fourmolu.pattern\": a pattern must be one line without spaces at the start or the end" "fourmolu:\n  pattern: [' src/**/*.hs']\n"
  assertError "fourmolu pattern lines" "field \"fourmolu.pattern\": a pattern must be one line without spaces at the start or the end" "fourmolu:\n  pattern: [\"a.hs\\nb.hs\"]\n"
  assertError "cabal-project-local type" "field \"cabal-project-local\": expected a string" "cabal-project-local: [tests]\n"
  where
    assertError :: String -> String -> T.Text -> Assertion
    assertError preface expected input =
      assertEqual preface (Left ["conf.yml: " ++ expected]) (parse input)

test_allErrors :: Assertion
test_allErrors =
  assertEqual
    "errors"
    (Left ["conf.yml: unknown field \"job\"", "conf.yml: field \"jobs\": expected a positive integer", "conf.yml: field \"tests\": expected true or false"])
    (parse "job: 1\ntests: 1\njobs: -1\n")

----------------------------------------
-- Helpers

parse :: T.Text -> Either [String] Config
parse = parseConfig "conf.yml" . BL.fromStrict . T.encodeUtf8

parseOk :: T.Text -> IO Config
parseOk input = case parse input of
  Left errors -> assertFailure $ unlines errors
  Right config -> pure config
