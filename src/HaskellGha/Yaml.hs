{-# LANGUAGE OverloadedStrings #-}

-- | The YAML tree of yamlet, with helpers to build and render it.
module HaskellGha.Yaml
  ( -- * Tree
    Node (..)
  , Content (..)
  , ScalarStyle (..)
  , Comments (..)
  , Line (..)
  , noComments
  , Offset
  , Y.Commented (..)

    -- * Construction
  , plain
  , nullValue
  , singleQuoted
  , literal
  , scalarNode
  , Y.mapping
  , sequenceNode
  , addBefore
  , addAfter
  , Y.ToYaml (..)
  , (Y..=)

    -- * Queries
  , normalize

    -- * Rendering
  , renderDocument
  ) where

import Data.Text qualified as T
import Yamlet qualified as Y
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

-- | Put lines after the last entry of a collection.
addAfter :: [Line] -> Node -> Node
addAfter ls n = Node n.offset n.endOffset n.props (Comments c.before c.inline (c.after ++ ls)) n.content
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
  Sequence _ xs -> Sequence Block (map normalize xs)
  Mapping _ kvs -> Mapping Block [(normalize k, normalize v) | (k, v) <- kvs]
  c -> c

----------------------------------------
-- Rendering

-- | Render a node as a YAML document in the block style.
renderDocument
  :: [T.Text]
  -- ^ The header lines. They become comments at the start of the document.
  -> ([T.Text] -> Bool)
  -- ^ The collections with an empty line between their entries, by the keys
  -- on the path to them.
  -> Node
  -> T.Text
renderDocument header separated root =
  renderSyntax
    RenderOptions {forceBlock = True}
    [Document Nothing False False (Comments (map Comment header) Nothing []) (separate [] (apart root))]
  where
    -- An empty line keeps a comment above the first key apart from the
    -- header.
    apart :: Node -> Node
    apart n = case n.content of
      Mapping style ((k, v) : rest)
        | not (null header)
        , Comment _ : _ <- k.comments.before ->
            Node n.offset n.endOffset n.props n.comments (Mapping style ((addBefore [EmptyLine] k, v) : rest))
      _ -> n

    separate :: [T.Text] -> Node -> Node
    separate path n = case n.content of
      Mapping style entries -> withContent (Mapping style (zipWith entry [0 ..] entries))
      Sequence style items | separated path -> withContent (Sequence style (zipWith spaced [0 ..] items))
      _ -> n
      where
        withContent :: Content -> Node
        withContent = Node n.offset n.endOffset n.props n.comments

        entry :: Int -> (Node, Node) -> (Node, Node)
        entry i (k, v) =
          ( spaced i k
          , case k.content of
              Scalar _ name -> separate (path ++ [name]) v
              _ -> v
          )

        -- An entry that already has an empty line above it, e.g. from the
        -- comments after a hook, gets no second one.
        spaced :: Int -> Node -> Node
        spaced i x
          | i > 0 && separated path && EmptyLine `notElem` x.comments.before = addBefore [EmptyLine] x
          | otherwise = x
