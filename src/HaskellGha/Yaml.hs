-- | Helpers to build and render the YAML tree of yamlet.
module HaskellGha.Yaml
  ( -- * Construction
    plain
  , nullValue
  , singleQuoted
  , literal
  , addBefore
  , mapBefore

    -- * Inspection
  , stringField

    -- * Rendering
  , renderDocument
  ) where

import Data.Maybe
import Data.Text qualified as T
import Yamlet
import Yamlet.Schema
import Yamlet.Syntax

----------------------------------------
-- Construction

-- | A string as a plain scalar, or as a single-quoted scalar if the plain
-- scalar does not read back as the same string.
plain :: T.Text -> Node
plain t = scalarNode (if isPlainSafe t then Plain else SingleQuoted) t

-- | The null value, as an empty plain scalar.
nullValue :: Node
nullValue = plainNode ""

-- | A single-quoted scalar.
singleQuoted :: T.Text -> Node
singleQuoted = scalarNode SingleQuoted

-- | A literal block scalar.
literal :: T.Text -> Node
literal = scalarNode Literal

-- | Put lines above a node, in front of the lines that it already has.
addBefore :: [Line] -> Node -> Node
addBefore ls = mapBefore (ls ++)

-- | Change the lines above a node.
mapBefore :: ([Line] -> [Line]) -> Node -> Node
mapBefore f n =
  -- A record update of comments is ambiguous, because another record of
  -- yamlet has a field with this name.
  Node
    { offset = n.offset
    , endOffset = n.endOffset
    , props = n.props
    , comments = n.comments {before = f n.comments.before}
    , content = n.content
    }

----------------------------------------
-- Inspection

-- | The scalar value of a key of a mapping, with its position.
stringField :: T.Text -> Node -> Maybe (Located T.Text)
stringField key n = case n.content of
  MappingContent _ entries ->
    listToMaybe
      [ Located t v.offset
      | (Node {content = ScalarContent _ k}, v@Node {content = ScalarContent _ t}) <- entries
      , k == key
      ]
  _ -> Nothing

----------------------------------------
-- Rendering

-- | Render a node as a YAML document in the block style.
renderDocument
  :: [T.Text]
  -- ^ The header lines. They become comments at the start of the document,
  -- with an empty line below them.
  -> ([T.Text] -> Bool)
  -- ^ The collections with an empty line between their entries, by the keys
  -- on the path to them.
  -> Node
  -> T.Text
renderDocument header separated root =
  renderSyntax
    RenderOptions {forceBlock = True}
    -- The header goes on the root node, because on the document it would
    -- need a --- marker below it.
    [ Document
        { version = Nothing
        , explicitStart = False
        , explicitEnd = False
        , docComments = noComments
        , root = addBefore (map Comment header) (separate [] root)
        }
    ]
  where
    separate :: [T.Text] -> Node -> Node
    separate path n = case n.content of
      MappingContent style entries -> n {content = MappingContent style (zipWith entry [0 ..] entries)}
      SequenceContent style items
        | separated path -> n {content = SequenceContent style (zipWith spaced [0 ..] items)}
      _ -> n
      where
        entry :: Int -> (Node, Node) -> (Node, Node)
        entry i (k, v) =
          ( spaced i k
          , case k.content of
              ScalarContent _ name -> separate (path ++ [name]) v
              _ -> v
          )

        spaced :: Int -> Node -> Node
        spaced i x
          | i > 0 && separated path = addBefore [EmptyLine] x
          | otherwise = x
