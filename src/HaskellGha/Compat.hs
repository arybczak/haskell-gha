{-# LANGUAGE CPP #-}

-- | Functions whose Cabal or Cabal-syntax API differs between versions.
module HaskellGha.Compat
  ( -- * Parsing
    runCabalParser
  , parseCondition

    -- * Globs
  , matchPackageGlob
  ) where

import Data.Foldable
import Distribution.Fields
import Distribution.Fields.ConfVar
import Distribution.Parsec
import Distribution.Simple.Glob
import Distribution.Types.Condition
import Distribution.Types.ConfVar
#if !MIN_VERSION_Cabal(3,18,0)
import Distribution.Simple.Glob.Internal
import System.FilePath
#endif

#if MIN_VERSION_Cabal(3,18,0)
-- | Match a glob of @packages:@ in a directory, as cabal does.
matchPackageGlob :: FilePath -> Glob -> IO [FilePath]
matchPackageGlob = matchGlob
#else
-- | Match a glob of @packages:@ in a directory, as cabal does. Before Cabal
-- 3.18, a wildcard such as @.*@ also matches the entries @.@ and @..@ of a
-- directory, so a match can lead out of the directory.
matchPackageGlob :: FilePath -> Glob -> IO [FilePath]
matchPackageGlob root glob = filter (not . dotEntry) <$> matchGlob root glob
  where
    -- matchGlob starts the match after the leading literal components, so
    -- only a later component can come from a wildcard.
    dotEntry :: FilePath -> Bool
    dotEntry = any (`elem` [".", ".."]) . drop (literalPrefix glob) . splitDirectories

    literalPrefix :: Glob -> Int
    literalPrefix = \case
      GlobDir [Literal _] rest -> 1 + literalPrefix rest
      _ -> 0
#endif

#if MIN_VERSION_Cabal_syntax(3,18,0)
-- | Run a parser of Cabal-syntax. The result has the rendered errors.
runCabalParser
  :: FilePath
  -- ^ The file name for the error messages.
  -> ParseResult src a
  -> Either [String] a
runCabalParser file p = case snd (runParseResult p) of
  Right a -> Right a
  Left (_, errors) -> Left [showPError file e | PErrorWithSource _ e <- toList errors]

-- | Parse the condition of an @if@ or @elif@ section.
parseCondition :: FilePath -> Position -> [SectionArg Position] -> Either [String] (Condition ConfVar)
parseCondition file pos = runCabalParser file . parseConditionConfVar pos
#else
-- | Run a parser of Cabal-syntax. The result has the rendered errors.
runCabalParser
  :: FilePath
  -- ^ The file name for the error messages.
  -> ParseResult a
  -> Either [String] a
runCabalParser file p = case snd (runParseResult p) of
  Right a -> Right a
  Left (_, errors) -> Left [showPError file e | e <- toList errors]

-- | Parse the condition of an @if@ or @elif@ section.
parseCondition :: FilePath -> Position -> [SectionArg Position] -> Either [String] (Condition ConfVar)
parseCondition file _ = runCabalParser file . parseConditionConfVar
#endif
