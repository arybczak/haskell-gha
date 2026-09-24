{-# LANGUAGE OverloadedStrings #-}

module YamlTests (yamlTests) where

import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Test.Tasty
import Test.Tasty.HUnit

import HaskellGha.Yaml

yamlTests :: TestTree
yamlTests =
  testGroup
    "Yaml"
    [ testCase "styles and key order survive a round trip" test_styles
    , testCase "flow collections become block collections" test_flow
    , testCase "the parser drops the comments" test_comments
    , testCase "empty lines" test_emptyLines
    , testCase "the output parses to the same tree" test_reparse
    , testCase "a plain scalar that needs quotes" test_plainQuotes
    , testCase "an empty input has no document" test_empty
    , testCase "errors" test_errors
    ]

test_styles :: Assertion
test_styles =
  assertRoundTrip $
    T.unlines
      [ "zeta: plain"
      , "alpha: 'single: quoted'"
      , "beta: \"double\""
      , "run: |"
      , "  echo a"
      , "  echo b"
      , "strip: |-"
      , "  no newline"
      , "version: '9.10'"
      , "number: 9.10"
      , "empty:"
      , "steps:"
      , "- uses: actions/checkout@v7"
      , "  with:"
      , "    key: ${{ runner.os }}-ghc"
      ]

test_flow :: Assertion
test_flow = do
  node <- parse "branches: [master, main]\nports: ['5432:5432']\nnone: []\n"
  assertEqual "rendered" (T.unlines ["branches:", "- master", "- main", "ports:", "- '5432:5432'", "none: []"]) (renderYaml [] node)

test_comments :: Assertion
test_comments = do
  node <-
    parse $
      T.unlines
        [ "# before a key"
        , "services:"
        , "  # first entry"
        , "  postgres:"
        , "    image: postgres # end of line"
        , "hooks:"
        , "- run: a"
        , "# between items"
        , "- run: b"
        , "# at the end"
        ]
  assertEqual
    "rendered"
    (T.unlines ["services:", "  postgres:", "    image: postgres", "hooks:", "- run: a", "- run: b"])
    (renderYaml [] node)

test_emptyLines :: Assertion
test_emptyLines = do
  let node =
        Mapping
          [ item (Key Plain "name", plain "CI")
          , Item True (Key Plain "steps", Sequence [item (plain "a"), Item True (plain "b")])
          ]
  assertEqual
    "rendered"
    (T.unlines ["# header", "name: CI", "", "steps:", "- a", "", "- b"])
    (renderYaml ["header"] node)

test_reparse :: Assertion
test_reparse = do
  let node =
        mapping
          [ ("on", mapping [("push", mapping [("branches", sequenceOf [plain "master"])]), ("pull_request", plain "")])
          , ("run", literal "cabal build all\ncabal test all\n")
          , ("ghc", sequenceOf [singleQuoted "9.10", singleQuoted "it's"])
          ]
  reparsed <- parse $ renderYaml ["header"] node
  assertEqual "reparsed tree" node reparsed

test_plainQuotes :: Assertion
test_plainQuotes = do
  let texts = ["my dir: x", "dir #1", "[x]", "*x", "&x", "-x", " x", "x ", "x:", "'x", "a\tb", "", "~", "null", "true", "False", "1", "1.0", "0x1F", ".inf"]
      node = sequenceOf (map plain texts)
  reparsed <- parse $ renderYaml [] node
  assertEqual "texts" (Sequence [item (Scalar SingleQuoted t) | t <- texts]) reparsed
  assertEqual
    "plain"
    [Scalar Plain t | t <- ["sub/dir", "a:b", "a#b", "yes", "1.0.0", "9.10.3", "${{ matrix.ghc }}", "contains(fromJSON('[\"9.10\"]'), matrix.ghc)"]]
    (map plain ["sub/dir", "a:b", "a#b", "yes", "1.0.0", "9.10.3", "${{ matrix.ghc }}", "contains(fromJSON('[\"9.10\"]'), matrix.ghc)"])

test_empty :: Assertion
test_empty = do
  assertEqual "empty" (Right Nothing) (parseYaml "")
  assertEqual "only a comment" (Right Nothing) (parseYaml "# nothing\n")

test_errors :: Assertion
test_errors = do
  assertError "anchor" "anchors are not supported" "a: &x 1\n"
  assertError "alias" "aliases are not supported" "b: *x\n"
  assertError "tag" "tags are not supported" "a: !!str 1\n"
  assertError "literal keep" keepMessage "run: |+\n  echo a\n\nnext: 1\n"
  assertError "folded keep" keepMessage "run: >+\n  echo a\n"
  assertError "duplicate key" "duplicate key \"a\"" "a: 1\nb: 2\na: 3\n"
  assertError "two documents" "the file must contain only one YAML document" "a: 1\n---\nb: 2\n"
  assertError "complex key" "a mapping key must be a scalar" "? [a]\n: 1\n"
  case parseYaml "a: [1\n" of
    Left _ -> pure ()
    Right _ -> assertFailure "a syntax error must fail"
  where
    keepMessage :: String
    keepMessage = "the chomping indicator + is not supported. Remove the +, e.g. write | in place of |+"

    assertError :: String -> String -> BL.ByteString -> Assertion
    assertError preface expected input = case parseYaml input of
      Left e -> assertEqual preface expected e.message
      Right _ -> assertFailure $ preface ++ ": no error"

----------------------------------------
-- Helpers

parse :: T.Text -> IO Node
parse input = case parseYaml (BL.fromStrict $ T.encodeUtf8 input) of
  Left e -> assertFailure $ renderYamlError "input" e
  Right Nothing -> assertFailure "no document"
  Right (Just node) -> pure node

assertRoundTrip :: T.Text -> Assertion
assertRoundTrip input = do
  node <- parse input
  assertEqual "rendered" input (renderYaml [] node)
