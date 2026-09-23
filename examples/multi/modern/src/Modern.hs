module Modern (Point (..), norm1) where

-- | A point.
data Point = Point {x :: Int, y :: Int}

-- | The Manhattan norm of a point.
--
-- >>> norm1 (Point 3 (-4))
-- 7
norm1 :: Point -> Int
norm1 p = abs p.x + abs p.y
