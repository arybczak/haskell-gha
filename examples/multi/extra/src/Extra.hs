module Extra (quadruple) where

import Core

-- | Quadruple a number.
--
-- >>> quadruple 3
-- 12
quadruple :: Int -> Int
quadruple = double . double
