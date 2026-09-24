{-# LANGUAGE OverloadedStrings #-}

-- | An ordered YAML tree that keeps the key order and the scalar styles of its
-- input.
module HaskellGha.Yaml
  ( -- * Tree
    Node (..)
  , Item (..)
  , Key (..)
  , Y.ScalarStyle (..)
  , Y.Chomp (..)
  , Y.IndentOfs (..)

    -- * Construction
  , plain
  , nullValue
  , boolean
  , singleQuoted
  , literal
  , item
  , mapping
  , sequenceOf

    -- * Queries
  , isString
  , lookupKey

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
import Data.YAML qualified as YAML
import Data.YAML.Event qualified as Y
import Data.YAML.Schema qualified as YAML

-- | A YAML node.
data Node
  = Scalar Y.ScalarStyle T.Text
  | Sequence [Item Node]
  | Mapping [Item (Key, Node)]
  deriving stock (Eq, Show)

-- | An entry of a mapping or an item of a sequence.
data Item a = Item
  { emptyLine :: Bool
  -- ^ An empty line before the item. The writer of HsYAML cannot write it
  -- before the first item of a collection.
  , value :: a
  }
  deriving stock (Eq, Show)

-- | A mapping key.
data Key = Key
  { style :: Y.ScalarStyle
  , name :: T.Text
  }
  deriving stock (Eq, Show)

----------------------------------------
-- Construction

-- | A string as a plain scalar, or as a single-quoted scalar if the plain
-- scalar is not valid or is not a string. The writer of HsYAML writes a plain
-- scalar without a check.
plain :: T.Text -> Node
plain t
  | validPlain && isString Y.Plain t = Scalar Y.Plain t
  | otherwise = Scalar Y.SingleQuoted t
  where
    -- A subset of the valid plain scalars in block context.
    validPlain :: Bool
    validPlain =
      not (T.any (`elem` ("-?:,[]{}#&*!|>'\"%@` " :: String)) (T.take 1 t))
        && not (T.any (`elem` (": " :: String)) (T.takeEnd 1 t))
        && not (": " `T.isInfixOf` t || " #" `T.isInfixOf` t)
        && T.all (\c -> c >= ' ' && c /= '\DEL') t

-- | The null value, as an empty plain scalar.
nullValue :: Node
nullValue = Scalar Y.Plain ""

-- | A boolean.
boolean :: Bool -> Node
boolean b = Scalar Y.Plain (if b then "true" else "false")

-- | A single-quoted scalar.
singleQuoted :: T.Text -> Node
singleQuoted = Scalar Y.SingleQuoted

-- | A literal block scalar with the default chomping.
literal :: T.Text -> Node
literal = Scalar (Y.Literal Y.Clip Y.IndentAuto)

-- | An item without an empty line before it.
item :: a -> Item a
item = Item False

-- | A mapping with plain keys.
mapping :: [(T.Text, Node)] -> Node
mapping entries = Mapping [item (Key Y.Plain k, v) | (k, v) <- entries]

-- | A sequence.
sequenceOf :: [Node] -> Node
sequenceOf nodes = Sequence (map item nodes)

----------------------------------------
-- Queries

-- | Whether YAML reads a scalar as a string. GitHub reads a plain scalar with
-- the YAML 1.2 core schema, e.g. @1.0@ is a number.
isString :: Y.ScalarStyle -> T.Text -> Bool
isString style t = case YAML.schemaResolverScalar YAML.coreSchemaResolver Y.untagged style t of
  Right (YAML.SStr _) -> True
  _ -> False

-- | Look up the value of a key in a mapping.
lookupKey :: T.Text -> [Item (Key, Node)] -> Maybe Node
lookupKey k = fmap (snd . (.value)) . find (\i -> (fst i.value).name == k)

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

-- | Parse a YAML document. An empty input gives 'Nothing'. The tree does not
-- keep the comments.
parseYaml :: BL.ByteString -> Either YamlError (Maybe Node)
parseYaml input = do
  events <- traverse (either syntaxError Right) (Y.parseEvents input)
  case filter (not . isComment) events of
    Y.EvPos Y.StreamStart _ : rest -> stream rest
    _ -> Left $ YamlError 1 1 "invalid YAML stream"
  where
    syntaxError :: (Y.Pos, String) -> Either YamlError a
    syntaxError (pos, msg) = Left $ errorAt pos msg

    isComment :: Y.EvPos -> Bool
    isComment ev = case ev.eEvent of
      Y.Comment _ -> True
      _ -> False

    stream :: [Y.EvPos] -> Either YamlError (Maybe Node)
    stream = \case
      Y.EvPos Y.StreamEnd _ : _ -> pure Nothing
      Y.EvPos (Y.DocumentStart _) _ : evs1 -> do
        (root, evs2) <- node evs1
        case evs2 of
          Y.EvPos (Y.DocumentEnd _) _ : evs3 -> case evs3 of
            Y.EvPos Y.StreamEnd _ : _ -> pure (Just root)
            ev : _ -> Left $ errorAt ev.ePos "the file must contain only one YAML document"
            [] -> unexpectedEnd
          ev : _ -> unexpected ev
          [] -> unexpectedEnd
      ev : _ -> unexpected ev
      [] -> unexpectedEnd

    node :: [Y.EvPos] -> Either YamlError (Node, [Y.EvPos])
    node = \case
      ev@(Y.EvPos (Y.Scalar anchor tag s t) _) : evs -> do
        checkProperties ev anchor tag
        checkChomping ev s
        pure (Scalar s t, evs)
      ev@(Y.EvPos (Y.SequenceStart anchor tag _) _) : evs -> do
        checkProperties ev anchor tag
        (items, rest) <- sequenceItems evs
        pure (Sequence items, rest)
      ev@(Y.EvPos (Y.MappingStart anchor tag _) _) : evs -> do
        checkProperties ev anchor tag
        (entries, rest) <- mappingEntries S.empty evs
        pure (Mapping entries, rest)
      ev@(Y.EvPos (Y.Alias _) _) : _ -> Left $ errorAt ev.ePos "aliases are not supported"
      ev : _ -> unexpected ev
      [] -> unexpectedEnd

    sequenceItems :: [Y.EvPos] -> Either YamlError ([Item Node], [Y.EvPos])
    sequenceItems = \case
      Y.EvPos Y.SequenceEnd _ : evs -> pure ([], evs)
      evs1 -> do
        (v, evs2) <- node evs1
        (items, evs3) <- sequenceItems evs2
        pure (item v : items, evs3)

    mappingEntries :: S.Set T.Text -> [Y.EvPos] -> Either YamlError ([Item (Key, Node)], [Y.EvPos])
    mappingEntries seen = \case
      Y.EvPos Y.MappingEnd _ : evs -> pure ([], evs)
      ev@(Y.EvPos (Y.Scalar anchor tag s k) pos) : evs1 -> do
        checkProperties ev anchor tag
        if k `S.member` seen
          then Left . errorAt pos $ "duplicate key " ++ show k
          else do
            (v, evs2) <- node evs1
            (entries, evs3) <- mappingEntries (S.insert k seen) evs2
            pure (item (Key s k, v) : entries, evs3)
      ev : _ -> Left $ errorAt ev.ePos "a mapping key must be a scalar"
      [] -> unexpectedEnd

    checkProperties :: Y.EvPos -> Maybe Y.Anchor -> Y.Tag -> Either YamlError ()
    checkProperties ev anchor tag
      | Just _ <- anchor = Left $ errorAt ev.ePos "anchors are not supported"
      | not (Y.isUntagged tag) = Left $ errorAt ev.ePos "tags are not supported"
      | otherwise = pure ()

    -- The writer puts an empty line before the next item, and a block scalar
    -- with the keep indicator takes that line into its value.
    checkChomping :: Y.EvPos -> Y.ScalarStyle -> Either YamlError ()
    checkChomping ev = \case
      Y.Literal Y.Keep _ -> keep
      Y.Folded Y.Keep _ -> keep
      _ -> pure ()
      where
        keep :: Either YamlError ()
        keep = Left $ errorAt ev.ePos "the chomping indicator + is not supported. Remove the +, e.g. write | in place of |+"

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
renderYaml header root = T.unlines . map replaceMarker . T.lines . TL.toStrict $ Y.writeEventsText events
  where
    events :: [Y.Event]
    events =
      [Y.StreamStart, Y.DocumentStart Y.NoDirEndMarker]
        ++ map (\h -> Y.Comment $ if T.null h then "" else " " <> h) header
        ++ nodeEvents root
        ++ [Y.DocumentEnd False, Y.StreamEnd]

    nodeEvents :: Node -> [Y.Event]
    nodeEvents = \case
      Scalar s t -> [Y.Scalar Nothing Y.untagged s t]
      Sequence items ->
        [Y.SequenceStart Nothing Y.untagged Y.Block]
          ++ concat [emptyLineEvent i ++ nodeEvents i.value | i <- items]
          ++ [Y.SequenceEnd]
      Mapping entries ->
        [Y.MappingStart Nothing Y.untagged Y.Block]
          ++ concat
            [ emptyLineEvent i ++ Y.Scalar Nothing Y.untagged k.style k.name : nodeEvents v
            | i@(Item _ (k, v)) <- entries
            ]
          ++ [Y.MappingEnd]

    -- The writer has no event for an empty line, so a comment with a marker
    -- stands for it.
    emptyLineEvent :: Item a -> [Y.Event]
    emptyLineEvent i = [Y.Comment emptyLineMarker | i.emptyLine]

    replaceMarker :: T.Text -> T.Text
    replaceMarker l = if T.strip l == "#" <> emptyLineMarker then "" else l

    emptyLineMarker :: T.Text
    emptyLineMarker = "\x1F"
