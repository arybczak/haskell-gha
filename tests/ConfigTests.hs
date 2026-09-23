{-# LANGUAGE OverloadedStrings #-}

module ConfigTests (configTests) where

import Data.ByteString.Lazy qualified as BL
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
    [ testCase "a missing file gives the defaults" test_missingFile
    , testCase "an empty file gives the defaults" test_emptyFile
    , testCase "the example configuration" test_example
    , testCase "an empty doctest field enables doctest" test_emptyDoctest
    , testCase "a null value gives the default" test_null
    , testCase "cabal-version latest" test_latest
    , testCase "errors" test_errors
    , testCase "all errors are collected" test_allErrors
    ]

test_missingFile :: Assertion
test_missingFile = do
  result <- readConfig "tests/does-not-exist.yml"
  assertEqual "config" (Right defaultConfig) result

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
        , "matrix:"
        , "  postgres: ['15', '18']"
        , "  exclude:"
        , "    - ghc: '9.10'"
        , "      postgres: '15'"
        , "apt: [libpq-dev]"
        , "services:"
        , "  postgres:"
        , "    image: postgres:${{ matrix.postgres }}"
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
        , "actions:"
        , "  checkout: v8"
        , "  cache: 0123abc"
        ]
  assertEqual "name" (plain "Tests") config.name
  assertEqual "cabal-version" (CabalVersion $ mkVersion [3, 14, 2, 0]) config.cabalVersion
  assertEqual "runs-on" (plain "ubuntu-24.04") config.runsOn
  assertEqual "branches" [plain "master"] config.branches
  assertEqual "matrix axes" ["postgres"] (matrixAxes config)
  assertEqual "matrix ghc values" ["9.10"] (matrixGhcValues config)
  assertEqual "apt" ["libpq-dev"] config.apt
  assertBool "services" (config.services /= Nothing)
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
  assertEqual "actions" (Actions {checkout = "v8", setup = "v2", cache = "0123abc"}) config.actions

test_emptyDoctest :: Assertion
test_emptyDoctest = do
  config <- parseOk "doctest:\n"
  assertEqual "doctest" (Just defaultDoctest) config.doctest

test_null :: Assertion
test_null = do
  config <- parseOk "jobs: ~\nhooks:\n"
  assertEqual "config" defaultConfig config

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
  assertError "runs-on" "field \"runs-on\": expected a string" "runs-on: [self-hosted, linux]\n"
  assertError "old cabal" "field \"cabal-version\": the GHC job semaphore needs cabal 3.12 or later" "cabal-version: 3.10\n"
  assertError "old cabal full" "field \"cabal-version\": the GHC job semaphore needs cabal 3.12 or later" "cabal-version: 3.10.3.0\n"
  assertError "cabal version" "field \"cabal-version\": expected latest or a version" "cabal-version: newest\n"
  assertError "ghc axis" "field \"matrix\": the tool makes the ghc axis, so the matrix must not contain it" "matrix:\n  ghc: ['9.10']\n"
  assertError "unquoted ghc" "field \"matrix.include\": a ghc value must be a quoted string, e.g. '9.10'" "matrix:\n  include:\n    - ghc: 9.10\n"
  assertError "exclude" "field \"matrix.exclude\": expected a list of mappings" "matrix:\n  exclude: '9.10'\n"
  assertError "exclude key" "field \"matrix.exclude\": the key version is not an axis of the matrix. The axes are: ghc, postgres" "matrix:\n  postgres: ['15', '18']\n  exclude:\n    - ghc: '9.10'\n      version: '15'\n"
  assertError "services" "field \"services\": expected a mapping" "services: [postgres]\n"
  assertError "step" "field \"hooks.before-build item\": expected a mapping" "hooks:\n  before-build:\n    - make\n"
  assertError "doctest range" "field \"doctest.ghc\": expected a version range" "doctest:\n  ghc: nine\n"
  assertError "apt" "field \"apt\": expected a list of strings" "apt: libpq-dev\n"
  assertError "cabal-project-local" "field \"cabal-project-local\": a line must not be EOF" "cabal-project-local: |\n  tests: True\n  EOF\n"
  assertError "unknown action" "unknown field \"actions.run-fourmolu\"" "actions:\n  run-fourmolu: v13\n"
  assertError "action ref" "field \"actions.setup\": expected a Git ref, e.g. v7" "actions:\n  setup: 'v 2'\n"
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
