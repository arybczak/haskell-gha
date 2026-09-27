-- | Checks that collect all their errors.
module HaskellGha.Check
  ( -- * Check
    Validation
  , Check
  , runCheck
  , failure
  , fromEither
  , fromErrors
  ) where

-- | A computation that collects all errors of its independent parts. In a
-- @do@ block, a bind runs the rest only if its check succeeds, and a
-- statement without a bind collects its errors with the errors of the rest.
newtype Validation e a = Validation (Either [e] a)
  deriving stock (Show)

-- | A check with error messages.
type Check = Validation String

instance Functor (Validation e) where
  fmap f (Validation r) = Validation (fmap f r)

instance Applicative (Validation e) where
  pure = Validation . Right
  Validation (Left e1) <*> Validation (Left e2) = Validation (Left (e1 ++ e2))
  Validation (Left e) <*> _ = Validation (Left e)
  Validation (Right f) <*> Validation r = Validation (fmap f r)

-- '>>=' cannot collect the errors of its second part after the first part
-- fails, but '<*>' and '>>' collect them. Thus the instance breaks the laws
-- @(<*>) = ap@ and @m >> k = m >>= \_ -> k@.
instance Monad (Validation e) where
  Validation r >>= f = either (Validation . Left) f r
  (>>) = (*>)

-- | Get the errors or the result.
runCheck :: Validation e a -> Either [e] a
runCheck (Validation r) = r

-- | A check with one error.
failure :: e -> Validation e a
failure e = Validation (Left [e])

-- | Convert an 'Either' with one error.
fromEither :: Either e a -> Validation e a
fromEither = Validation . either (Left . pure) Right

-- | Convert an 'Either' with a list of errors.
fromErrors :: Either [e] a -> Validation e a
fromErrors = Validation
