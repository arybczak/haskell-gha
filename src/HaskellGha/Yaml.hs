{-# LANGUAGE OverloadedStrings #-}

-- | The YAML tree of yamlet, with helpers to build, parse and render it.
module HaskellGha.Yaml
  ( -- * Tree
    Node (..)
  , Content (..)
  , ScalarStyle (..)
  , Comments (..)
  , Line (..)
  , noComments
  , Offset

    -- * Construction
  , plain
  , nullValue
  , boolean
  , singleQuoted
  , literal
  , scalarNode
  , mapping
  , mappingNode
  , sequenceNode
  , addBefore
  , addAfter
  , commentKeys

    -- * Queries
  , isString
  , describeNode
  , keyName
  , lookupEntry
  , lookupKey
  , normalize

    -- * Parsing
  , Error (..)
  , Location (..)
  , errorAt
  , prettyError
  , decodeInput
  , parseYaml

    -- * Rendering
  , renderYaml
  ) where

import Control.Monad
import Data.Foldable
import Data.Set qualified as S
import Data.Text qualified as T
import Yamlet.Decode hiding (failAt, lookupKey, parseYaml)
import Yamlet.Error
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

-- | A boolean.
boolean :: Bool -> Node
boolean b = plainNode (if b then "true" else "false")

-- | A single-quoted scalar.
singleQuoted :: T.Text -> Node
singleQuoted = scalarNode SingleQuoted

-- | A literal block scalar.
literal :: T.Text -> Node
literal = scalarNode Literal

-- | A mapping with plain keys.
mapping :: [(T.Text, Node)] -> Node
mapping entries = mappingNode [(plainNode k, v) | (k, v) <- entries]

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

-- | Give the keys of a mapping the comments from the list.
commentKeys :: [(T.Text, Comments)] -> Node -> Node
commentKeys cs n = case n.content of
  Mapping style entries -> Node n.offset n.endOffset n.props n.comments (Mapping style (map entry entries))
  _ -> n
  where
    entry :: (Node, Node) -> (Node, Node)
    entry (k, v) = case keyName k >>= (`lookup` cs) of
      Just c -> (Node k.offset k.endOffset k.props c k.content, v)
      Nothing -> (k, v)

----------------------------------------
-- Queries

-- | Whether YAML reads a scalar as a string. GitHub reads a plain scalar with
-- the YAML 1.2 core schema, e.g. @1.0@ is a number.
isString :: ScalarStyle -> T.Text -> Bool
isString style t = style /= Plain || isPlainString t

-- | The text of a scalar key.
keyName :: Node -> Maybe T.Text
keyName n = case n.content of
  Scalar _ t -> Just t
  _ -> Nothing

-- | Look up the entry of a key in a mapping.
lookupEntry :: T.Text -> [(Node, Node)] -> Maybe (Node, Node)
lookupEntry k entries = asum [Just e | e@(key, _) <- entries, keyName key == Just k]

-- | Look up the value of a key in a mapping.
lookupKey :: T.Text -> [(Node, Node)] -> Maybe Node
lookupKey k = fmap snd . lookupEntry k

-- | Remove the positions and the comments, and give every collection the
-- block style, as the renderer writes it. A parsed node then compares equal
-- to a built one.
normalize :: Node -> Node
normalize n = Node noOffset noOffset n.props noComments $ case n.content of
  Sequence _ xs -> Sequence Block (map normalize xs)
  Mapping _ kvs -> Mapping Block [(normalize k, normalize v) | (k, v) <- kvs]
  c -> c

----------------------------------------
-- Parsing

-- | Parse a YAML document. An empty input gives 'Nothing'. The comments at
-- the end of the document are lost. An anchor, an alias, a tag, a duplicate
-- key and a key that is not a scalar are errors.
--
-- The offsets of the nodes refer to the input, so 'errorAt' with the same
-- input gives the line and the column of a node.
parseYaml :: T.Text -> Either Error (Maybe Node)
parseYaml input =
  parseDocumentsText input >>= \case
    [] -> pure Nothing
    [doc] -> Just (copyNode doc.root) <$ check input doc.root
    _ : doc : _ -> Left $ errorAt input doc.root.offset "the file must contain only one YAML document"

check :: T.Text -> Node -> Either Error ()
check input = node
  where
    node :: Node -> Either Error ()
    node n =
      checkProps n *> case n.content of
        Scalar {} -> pure ()
        Sequence _ items -> traverse_ node items
        Mapping _ entries -> mappingEntries S.empty entries
        Alias _ -> failAt n "aliases are not supported"

    mappingEntries :: S.Set T.Text -> [(Node, Node)] -> Either Error ()
    mappingEntries seen = \case
      [] -> pure ()
      (k, v) : rest -> case k.content of
        Scalar _ name -> do
          checkProps k
          when (name `S.member` seen) . failAt k $ "duplicate key " ++ show name
          node v
          mappingEntries (S.insert name seen) rest
        _ -> failAt k "a mapping key must be a scalar"

    checkProps :: Node -> Either Error ()
    checkProps n
      | Just _ <- n.props.anchor = failAt n "anchors are not supported"
      | n.props.tag /= NoTag = failAt n "tags are not supported"
      | otherwise = pure ()

    failAt :: Node -> String -> Either Error a
    failAt n = Left . errorAt input n.offset

----------------------------------------
-- Rendering

-- | Render a node as a YAML document in the block style.
renderYaml
  :: [T.Text]
  -- ^ The header lines. They become comments at the start of the document.
  -> ([T.Text] -> Bool)
  -- ^ The collections with an empty line between their entries, by the keys
  -- on the path to them.
  -> Node
  -> T.Text
renderYaml header separated root =
  renderSyntax
    RenderOptions {forceBlock = True}
    [Document Nothing False False (Comments (map Comment header) Nothing []) (separate [] root)]
  where
    separate :: [T.Text] -> Node -> Node
    separate path n = case n.content of
      Mapping style entries -> withContent (Mapping style (zipWith entry [0 ..] entries))
      Sequence style items | separated path -> withContent (Sequence style (zipWith spaced [0 ..] items))
      _ -> n
      where
        withContent :: Content -> Node
        withContent = Node n.offset n.endOffset n.props n.comments

        entry :: Int -> (Node, Node) -> (Node, Node)
        entry i (k, v) = (spaced i k, maybe v (\name -> separate (path ++ [name]) v) (keyName k))

        -- An entry that already has an empty line above it, e.g. from the
        -- comments after a hook, gets no second one.
        spaced :: Int -> Node -> Node
        spaced i x
          | i > 0 && separated path && EmptyLine `notElem` x.comments.before = addBefore [EmptyLine] x
          | otherwise = x
