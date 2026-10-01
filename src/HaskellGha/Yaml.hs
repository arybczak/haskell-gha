-- | Helpers to build and render the YAML tree of yamlet.
module HaskellGha.Yaml
  ( -- * Construction
    plain
  , nullValue
  , singleQuoted
  , literal
  , addBefore

    -- * Queries
  , normalize

    -- * Rendering
  , renderDocument
  ) where

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
addBefore ls n = Node n.offset n.endOffset n.props (Comments (ls ++ c.before) c.inline c.after) n.content
  where
    c :: Comments
    c = n.comments

----------------------------------------
-- Queries

-- | Remove the positions and the comments, and give every collection the
-- block style, as the renderer writes it. A parsed node then compares equal
-- to a built one.
normalize :: Node -> Node
normalize n = Node noOffset noOffset n.props noComments $ case n.content of
  SequenceContent _ xs -> SequenceContent Block (map normalize xs)
  MappingContent _ kvs -> MappingContent Block [(normalize k, normalize v) | (k, v) <- kvs]
  c -> c

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
    -- On the document, the header would get a --- marker below it.
    [Document Nothing False False noComments (addBefore (map Comment header) (separate [] root))]
  where
    separate :: [T.Text] -> Node -> Node
    separate path n = case n.content of
      MappingContent style entries -> withContent (MappingContent style (zipWith entry [0 ..] entries))
      SequenceContent style items | separated path -> withContent (SequenceContent style (zipWith spaced [0 ..] items))
      _ -> n
      where
        withContent :: Content -> Node
        withContent = Node n.offset n.endOffset n.props n.comments

        entry :: Int -> (Node, Node) -> (Node, Node)
        entry i (k, v) =
          ( spaced i k
          , case k.content of
              ScalarContent _ name -> separate (path ++ [name]) v
              _ -> v
          )

        -- An entry that already has an empty line above it, e.g. a hook step
        -- after an empty line in the configuration, gets no second one.
        spaced :: Int -> Node -> Node
        spaced i x
          | i > 0 && separated path && EmptyLine `notElem` x.comments.before = addBefore [EmptyLine] x
          | otherwise = x
