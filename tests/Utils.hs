module Utils (normalize) where

import Yamlet.Syntax

-- | Remove the positions and the comments, and give every collection the
-- block style, as the renderer writes it. A parsed node then compares equal
-- to a built one.
normalize :: Node -> Node
normalize n = Node noOffset noOffset n.props noComments $ case n.content of
  SequenceContent _ xs -> SequenceContent Block (map normalize xs)
  MappingContent _ kvs -> MappingContent Block [(normalize k, normalize v) | (k, v) <- kvs]
  c -> c
