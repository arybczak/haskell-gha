module YamlTests (yamlTests) where

import Data.Text qualified as T
import Test.Tasty
import Test.Tasty.HUnit
import Yamlet
import Yamlet.Syntax

import HaskellGha.Yaml
import Utils

yamlTests :: TestTree
yamlTests =
  testGroup
    "Yaml"
    [ testCase "styles and key order survive a round trip" test_styles
    , testCase "flow collections become block collections" test_flow
    , testCase "comments survive a round trip" test_comments
    , testCase "empty lines" test_emptyLines
    , testCase "the output parses to the same tree" test_reparse
    , testCase "a comment above the first key after the header" test_header
    , testCase "trailing empty lines of a block scalar" test_keep
    , testCase "a plain scalar that needs quotes" test_plainQuotes
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
  assertEqual
    "rendered"
    (T.unlines ["branches:", "- master", "- main", "ports:", "- '5432:5432'", "none: []"])
    (render node)

test_comments :: Assertion
test_comments =
  assertRoundTrip $
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

test_emptyLines :: Assertion
test_emptyLines = do
  let node =
        mapping
          [ "name" .= plain "CI"
          , "steps" .= sequenceNode [plain "a", plain "b"]
          , "more" .= sequenceNode [plain "c", plain "d"]
          ]
  assertEqual
    "rendered"
    ( T.unlines
        ["# header", "", "name: CI", "", "steps:", "- a", "", "- b", "", "more:", "- c", "- d"]
    )
    (renderDocument ["header"] separated node)
  where
    separated :: [T.Text] -> Bool
    separated = \case
      [] -> True
      ["steps"] -> True
      _ -> False

test_reparse :: Assertion
test_reparse = do
  let node =
        mapping
          [ "on"
              .= mapping
                [ "push" .= mapping ["branches" .= sequenceNode [plain "master"]]
                , "pull_request" .= plain ""
                ]
          , "run" .= literal "cabal build all\ncabal test all\n"
          , "ghc" .= sequenceNode [singleQuoted "9.10", singleQuoted "it's"]
          ]
  reparsed <- parse $ renderDocument ["header"] (const True) node
  assertEqual "reparsed tree" node (normalize reparsed)

test_header :: Assertion
test_header = do
  let node = mapping [(addBefore [Comment "the name"] (plain "name"), plain "CI")]
  assertEqual
    "rendered"
    (T.unlines ["# header", "", "# the name", "name: CI"])
    (renderDocument ["header"] (const False) node)

test_keep :: Assertion
test_keep = do
  let node = mapping ["run" .= literal "echo a\n\n", "next" .= plain "b"]
  reparsed <- parse $ renderDocument [] (const True) node
  assertEqual "reparsed tree" node (normalize reparsed)

test_plainQuotes :: Assertion
test_plainQuotes = do
  let texts =
        [ "my dir: x"
        , "dir #1"
        , "[x]"
        , "*x"
        , "&x"
        , "- x"
        , " x"
        , "x "
        , "x:"
        , "'x"
        , "a\tb"
        , ""
        , "~"
        , "null"
        , "true"
        , "False"
        , "1"
        , "1.0"
        , "0x1F"
        , ".inf"
        ]
      node = sequenceNode (map plain texts)
  reparsed <- parse $ render node
  assertEqual "texts" (sequenceNode [singleQuoted t | t <- texts]) (normalize reparsed)
  assertEqual
    "plain"
    [ scalarNode Plain t
    | t <-
        [ "sub/dir"
        , "-x"
        , "a:b"
        , "a#b"
        , "yes"
        , "1.0.0"
        , "9.10.3"
        , "${{ matrix.ghc }}"
        , "contains(fromJSON('[\"9.10\"]'), matrix.ghc)"
        ]
    ]
    ( map
        plain
        [ "sub/dir"
        , "-x"
        , "a:b"
        , "a#b"
        , "yes"
        , "1.0.0"
        , "9.10.3"
        , "${{ matrix.ghc }}"
        , "contains(fromJSON('[\"9.10\"]'), matrix.ghc)"
        ]
    )

----------------------------------------
-- Helpers

parse :: T.Text -> IO Node
parse input = case decodeText @(Maybe Node) input of
  Left errors -> assertFailure $ foldMap ((++ "\n") . prettyError "input") errors
  Right Nothing -> assertFailure "no document"
  Right (Just node) -> pure node

render :: Node -> T.Text
render = renderDocument [] (const False)

assertRoundTrip :: T.Text -> Assertion
assertRoundTrip input = do
  node <- parse input
  assertEqual "rendered" input (render node)
