{-# LANGUAGE OverloadedStrings #-}

-- | The entries of the @ghc@ axis of the matrix.
module HaskellGha.Ghc
  ( -- * Entries
    GhcEntry (..)
  , entryRange
  , entryText
  , entriesFromRange

    -- * Decisions
  , Decision (..)
  , decide
  , decideRange
  ) where

import Data.Either
import Data.Text qualified as T
import Distribution.Pretty
import Distribution.Types.VersionInterval
import Distribution.Version

-- | An entry of the @ghc@ axis.
data GhcEntry
  = -- | An exact version, e.g. @9.10.3@.
    GhcExact Version
  | -- | A major series, e.g. @9.10@. The action selects its newest release.
    GhcSeries Int Int
  deriving stock (Eq, Show)

-- | Sort by the lowest version of the entry.
instance Ord GhcEntry where
  compare a b = compare (key a) (key b)
    where
      key :: GhcEntry -> (Version, Bool)
      key = \case
        GhcSeries x y -> (mkVersion [x, y], False)
        GhcExact v -> (v, True)

-- | The versions that the action can select for the entry.
entryRange :: GhcEntry -> VersionRange
entryRange = \case
  GhcExact v -> thisVersion v
  GhcSeries x y -> majorBoundVersion (mkVersion [x, y])

-- | The value of the entry in the matrix.
entryText :: GhcEntry -> T.Text
entryText = \case
  GhcExact v -> T.pack (prettyShow v)
  GhcSeries x y -> T.pack (show x ++ "." ++ show y)

-- | Split the GHC range of a package into entries.
entriesFromRange
  :: String
  -- ^ The name of the package for the error messages.
  -> VersionRange
  -> Either [String] [GhcEntry]
entriesFromRange package range = case partitionEithers . map entry $ asVersionIntervals range of
  ([], entries) -> Right entries
  (bad, _) -> Left bad
  where
    entry :: VersionInterval -> Either String GhcEntry
    entry i@(VersionInterval lower upper) = case (lower, upper) of
      (LowerBound v InclusiveBound, UpperBound w InclusiveBound)
        | v == w ->
            -- haskell-actions/setup selects the newest release of the
            -- series for such a version, e.g. 9.10.3 for 9.10.
            if length (versionNumbers v) < 3
              then Left (shortVersion v)
              else Right (GhcExact v)
      (LowerBound v InclusiveBound, UpperBound w ExclusiveBound)
        | [x, y] <- versionNumbers v
        , versionNumbers w == [x, y + 1] ->
            Right (GhcSeries x y)
      (_, NoUpperBound) -> Left (openRange (fromInterval i))
      _ -> Left (partialSeries (fromInterval i))

    openRange :: VersionRange -> String
    openRange r =
      "Package "
        ++ package
        ++ " lists the GHC range "
        ++ prettyShow r
        ++ " in tested-with. The matrix needs a finite list of versions. Write an exact version, e.g. == 9.10.3, or a major series, e.g. ^>= 9.10."

    partialSeries :: VersionRange -> String
    partialSeries r =
      "Package "
        ++ package
        ++ " lists the GHC range "
        ++ prettyShow r
        ++ " in tested-with. A range must be a whole major series with two version parts, e.g. ^>= 9.10 or == 9.10.*. Write the series, or an exact version, e.g. == 9.10.3."

    shortVersion :: Version -> String
    shortVersion v =
      "Package "
        ++ package
        ++ " lists GHC == "
        ++ prettyShow v
        ++ " in tested-with. No GHC release has this version. Write an exact version with three parts, e.g. == 9.10.3, or a major series, e.g. ^>= 9.10."

    fromInterval :: VersionInterval -> VersionRange
    fromInterval (VersionInterval (LowerBound v lb) upper) =
      let lowerRange = case lb of
            InclusiveBound -> orLaterVersion v
            ExclusiveBound -> laterVersion v
      in case upper of
           NoUpperBound -> lowerRange
           UpperBound w ub ->
             intersectVersionRanges lowerRange $ case ub of
               InclusiveBound -> orEarlierVersion w
               ExclusiveBound -> earlierVersion w

-- | The result of a range for a matrix entry.
data Decision
  = -- | The range includes all versions of the entry.
    Included
  | -- | The range includes no version of the entry.
    Excluded
  | -- | The range includes only a part of the entry.
    Partial
  deriving stock (Eq, Show)

-- | Decide a range for a matrix entry.
decide :: VersionRange -> GhcEntry -> Decision
decide range entry
  | null common = Excluded
  | common == asVersionIntervals (entryRange entry) = Included
  | otherwise = Partial
  where
    common :: [VersionInterval]
    common = asVersionIntervals (intersectVersionRanges range (entryRange entry))

-- | Decide a range for a matrix entry. A partial result is an error.
decideRange
  :: String
  -- ^ A description of the range for the error message.
  -> VersionRange
  -> GhcEntry
  -> Either String Bool
decideRange description range entry = case decide range entry of
  Included -> Right True
  Excluded -> Right False
  Partial ->
    Left $
      description
        ++ " includes only a part of the GHC versions of the matrix entry "
        ++ T.unpack (entryText entry)
        ++ ", so the result depends on the minor version that haskell-actions/setup selects. Change the range, or write exact versions in tested-with."
