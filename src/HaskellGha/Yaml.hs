{-# LANGUAGE OverloadedStrings #-}

-- | An ordered YAML tree that keeps the key order, the scalar styles and the
-- comments of its input.
module HaskellGha.Yaml
  ( -- * Tree
    Node (..)
  , Item (..)
  , Key (..)
  , Comment (..)
  , Y.ScalarStyle (..)
  , Y.Chomp (..)
  , Y.IndentOfs (..)

    -- * Construction
  , plain
  , singleQuoted
  , literal
  , item
  , mapping
  , sequenceOf

    -- * Queries
  , lookupKey
  , stripComments

    -- * Parsing
  , YamlError (..)
  , renderYamlError
  , parseYaml

    -- * Rendering
  , renderYaml
  ) where

import Data.ByteString.Lazy qualified as BL
import Data.Foldable
import Data.Set qualified as S
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.YAML.Event qualified as Y

-- | A YAML node.
data Node
  = Scalar Y.ScalarStyle T.Text
  | -- | The items and the comments after the last item.
    Sequence [Item Node] [Comment]
  | -- | The entries and the comments after the last entry.
    Mapping [Item (Key, Node)] [Comment]
  deriving stock (Eq, Show)

-- | An entry of a mapping or an item of a sequence, with the comments before
-- it.
data Item a = Item
  { comments :: [Comment]
  , value :: a
  }
  deriving stock (Eq, Show)

-- | A mapping key.
data Key = Key
  { style :: Y.ScalarStyle
  , name :: T.Text
  }
  deriving stock (Eq, Show)

-- | A comment line.
data Comment
  = -- | The text after @#@.
    Comment T.Text
  | EmptyLine
  deriving stock (Eq, Show)

----------------------------------------
-- Construction

-- | A plain scalar.
plain :: T.Text -> Node
plain = Scalar Y.Plain

-- | A single-quoted scalar.
singleQuoted :: T.Text -> Node
singleQuoted = Scalar Y.SingleQuoted

-- | A literal block scalar with the default chomping.
literal :: T.Text -> Node
literal = Scalar (Y.Literal Y.Clip Y.IndentAuto)

-- | An item without comments.
item :: a -> Item a
item = Item []

-- | A mapping with plain keys and without comments.
mapping :: [(T.Text, Node)] -> Node
mapping entries = Mapping [item (Key Y.Plain k, v) | (k, v) <- entries] []

-- | A sequence without comments.
sequenceOf :: [Node] -> Node
sequenceOf nodes = Sequence (map item nodes) []

----------------------------------------
-- Queries

-- | Look up the value of a key in a mapping.
lookupKey :: T.Text -> [Item (Key, Node)] -> Maybe Node
lookupKey k = fmap (snd . (.value)) . find (\i -> (fst i.value).name == k)

-- | Remove all comments from a node.
stripComments :: Node -> Node
stripComments = \case
  Scalar s t -> Scalar s t
  Sequence items _ -> Sequence [item (stripComments i.value) | i <- items] []
  Mapping entries _ -> Mapping [item (k, stripComments v) | Item _ (k, v) <- entries] []

----------------------------------------
-- Parsing

-- | An error in the YAML input.
data YamlError = YamlError
  { line :: Int
  -- ^ 1-based.
  , column :: Int
  -- ^ 1-based.
  , message :: String
  }
  deriving stock (Eq, Show)

-- | Render an error for a file.
renderYamlError :: FilePath -> YamlError -> String
renderYamlError file e = file ++ ":" ++ show e.line ++ ":" ++ show e.column ++ ": " ++ e.message

-- | Parse a YAML document. An empty input gives 'Nothing'.
parseYaml :: BL.ByteString -> Either YamlError (Maybe Node)
parseYaml input = do
  events <- traverse (either syntaxError Right) (Y.parseEvents input)
  case events of
    Y.EvPos Y.StreamStart _ : rest -> stream rest
    _ -> Left $ YamlError 1 1 "invalid YAML stream"
  where
    syntaxError :: (Y.Pos, String) -> Either YamlError a
    syntaxError (pos, msg) = Left $ errorAt pos msg

    stream :: [Y.EvPos] -> Either YamlError (Maybe Node)
    stream evs0 = case takeComments evs0 of
      (_, Y.EvPos Y.StreamEnd _ : _) -> pure Nothing
      (cs0, Y.EvPos (Y.DocumentStart _) _ : evs1) -> do
        let (cs1, evs2) = takeComments evs1
        (root, carry, evs3) <- node (cs0 ++ cs1) evs2
        case dropComments evs3 of
          Y.EvPos (Y.DocumentEnd _) _ : evs4 -> case dropComments evs4 of
            Y.EvPos Y.StreamEnd _ : _ -> pure . Just $ appendComments (map snd carry) root
            ev : _ -> Left $ errorAt ev.ePos "the file must contain only one YAML document"
            [] -> unexpectedEnd
          ev : _ -> unexpected ev
          [] -> unexpectedEnd
      (_, ev : _) -> unexpected ev
      (_, []) -> unexpectedEnd

    -- Comments come with their columns. The second component of the result
    -- holds the comments that belong to the next item of the parent: the
    -- comments before a scalar, and the comments at the end of a mapping with a
    -- smaller column than its keys.
    node :: [(Int, Comment)] -> [Y.EvPos] -> Either YamlError (Node, [(Int, Comment)], [Y.EvPos])
    node cs = \case
      ev@(Y.EvPos (Y.Scalar anchor tag s t) _) : evs -> do
        checkProperties ev anchor tag
        pure (Scalar s t, cs, evs)
      ev@(Y.EvPos (Y.SequenceStart anchor tag _) _) : evs -> do
        checkProperties ev anchor tag
        (items, trailing, rest) <- sequenceItems cs evs
        pure (Sequence items (map snd trailing), [], rest)
      ev@(Y.EvPos (Y.MappingStart anchor tag _) _) : evs -> do
        checkProperties ev anchor tag
        (entries, trailing, rest) <- mappingEntries S.empty cs evs
        let (inside, outside) = case entries of
              (_, column) : _ -> break ((< column) . fst) trailing
              [] -> (trailing, [])
        pure (Mapping (map fst entries) (map snd inside), outside, rest)
      ev@(Y.EvPos (Y.Alias _) _) : _ -> Left $ errorAt ev.ePos "aliases are not supported"
      ev : _ -> unexpected ev
      [] -> unexpectedEnd

    sequenceItems :: [(Int, Comment)] -> [Y.EvPos] -> Either YamlError ([Item Node], [(Int, Comment)], [Y.EvPos])
    sequenceItems pending evs0 = case takeComments evs0 of
      (cs, Y.EvPos Y.SequenceEnd _ : evs) -> pure ([], pending ++ cs, evs)
      (cs, evs1) -> do
        (v, carry, evs2) <- node [] evs1
        (items, trailing, evs3) <- sequenceItems carry evs2
        pure (Item (map snd $ pending ++ cs) v : items, trailing, evs3)

    -- Each entry comes with the column of its key.
    mappingEntries
      :: S.Set T.Text
      -> [(Int, Comment)]
      -> [Y.EvPos]
      -> Either YamlError ([(Item (Key, Node), Int)], [(Int, Comment)], [Y.EvPos])
    mappingEntries seen pending evs0 = case takeComments evs0 of
      (cs, Y.EvPos Y.MappingEnd _ : evs) -> pure ([], pending ++ cs, evs)
      (cs, ev@(Y.EvPos (Y.Scalar anchor tag s k) pos) : evs1) -> do
        checkProperties ev anchor tag
        if k `S.member` seen
          then Left . errorAt pos $ "duplicate key " ++ show k
          else do
            let (keyComments, evs2) = takeComments evs1
            (v, carry, evs3) <- node keyComments evs2
            (entries, trailing, evs4) <- mappingEntries (S.insert k seen) carry evs3
            pure ((Item (map snd $ pending ++ cs) (Key s k, v), pos.posColumn) : entries, trailing, evs4)
      (_, ev : _) -> Left $ errorAt ev.ePos "a mapping key must be a scalar"
      (_, []) -> unexpectedEnd

    checkProperties :: Y.EvPos -> Maybe Y.Anchor -> Y.Tag -> Either YamlError ()
    checkProperties ev anchor tag
      | Just _ <- anchor = Left $ errorAt ev.ePos "anchors are not supported"
      | not (Y.isUntagged tag) = Left $ errorAt ev.ePos "tags are not supported"
      | otherwise = pure ()

    takeComments :: [Y.EvPos] -> ([(Int, Comment)], [Y.EvPos])
    takeComments = \case
      Y.EvPos (Y.Comment c) pos : evs ->
        let (cs, rest) = takeComments evs
        in ((pos.posColumn, Comment c) : cs, rest)
      evs -> ([], evs)

    dropComments :: [Y.EvPos] -> [Y.EvPos]
    dropComments = snd . takeComments

    appendComments :: [Comment] -> Node -> Node
    appendComments cs = \case
      Sequence items trailing -> Sequence items (trailing ++ cs)
      Mapping entries trailing -> Mapping entries (trailing ++ cs)
      n -> n

    unexpected :: Y.EvPos -> Either YamlError a
    unexpected ev = Left . errorAt ev.ePos $ "unexpected " ++ show ev.eEvent

    unexpectedEnd :: Either YamlError a
    unexpectedEnd = Left $ YamlError 1 1 "unexpected end of the YAML stream"

    errorAt :: Y.Pos -> String -> YamlError
    errorAt pos = YamlError pos.posLine (pos.posColumn + 1)

----------------------------------------
-- Rendering

-- | Render a node as a YAML document. The header lines become comments at the
-- start of the document.
renderYaml
  :: [T.Text]
  -- ^ The header lines.
  -> Node
  -> T.Text
renderYaml header root = T.unlines . map emptyLine . T.lines . TL.toStrict $ Y.writeEventsText events
  where
    (rootComments, root') = liftComments root

    events :: [Y.Event]
    events =
      [Y.StreamStart, Y.DocumentStart Y.NoDirEndMarker]
        ++ map (\h -> Y.Comment $ if T.null h then "" else " " <> h) header
        ++ map commentEvent rootComments
        ++ nodeEvents root'
        ++ [Y.DocumentEnd False, Y.StreamEnd]

    nodeEvents :: Node -> [Y.Event]
    nodeEvents = \case
      Scalar s t -> [Y.Scalar Nothing Y.untagged s t]
      Sequence items trailing ->
        [Y.SequenceStart Nothing Y.untagged Y.Block]
          ++ concat [map commentEvent i.comments ++ nodeEvents i.value | i <- items]
          ++ map commentEvent trailing
          ++ [Y.SequenceEnd]
      Mapping entries trailing ->
        [Y.MappingStart Nothing Y.untagged Y.Block]
          ++ concat
            [ map commentEvent i.comments ++ Y.Scalar Nothing Y.untagged k.style k.name : nodeEvents v
            | i@(Item _ (k, v)) <- entries
            ]
          ++ map commentEvent trailing
          ++ [Y.MappingEnd]

    commentEvent :: Comment -> Y.Event
    commentEvent = \case
      Comment c -> Y.Comment c
      EmptyLine -> Y.Comment emptyLineMarker

    emptyLine :: T.Text -> T.Text
    emptyLine l = if T.strip l == "#" <> emptyLineMarker then "" else l

    emptyLineMarker :: T.Text
    emptyLineMarker = "\x1F"

-- | The writer of HsYAML cannot write a comment before the first entry of a
-- collection. Move such comments before the entry that contains the collection.
-- The first component of the result goes before the node.
liftComments :: Node -> ([Comment], Node)
liftComments = \case
  Scalar s t -> ([], Scalar s t)
  Sequence items trailing -> case map liftItem items of
    Item cs v : rest -> (cs, Sequence (Item [] v : rest) trailing)
    [] -> (trailing, Sequence [] [])
  Mapping entries trailing -> case map liftEntry entries of
    Item cs e : rest -> (cs, Mapping (Item [] e : rest) trailing)
    [] -> (trailing, Mapping [] [])
  where
    liftItem :: Item Node -> Item Node
    liftItem (Item cs v) = let (lifted, v') = liftComments v in Item (cs ++ lifted) v'

    liftEntry :: Item (Key, Node) -> Item (Key, Node)
    liftEntry (Item cs (k, v)) = let (lifted, v') = liftComments v in Item (cs ++ lifted) (k, v')
