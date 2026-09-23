{-# LANGUAGE CPP #-}

-- | Functions whose Cabal-syntax API differs between versions.
module HaskellGha.Compat
  ( -- * Parsing
    runCabalParser
  , parseCondition
  ) where

import Data.Foldable
import Distribution.Fields
import Distribution.Fields.ConfVar
import Distribution.Parsec
import Distribution.Types.Condition
import Distribution.Types.ConfVar

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
