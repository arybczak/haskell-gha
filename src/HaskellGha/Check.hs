-- | Checks that collect all their errors.
module HaskellGha.Check
  ( -- * Check
    Validation
  , Check
  , runCheck
  , failure
  , fromEither
  , fromErrors
  , andThen
  ) where

-- | A computation that collects all errors of its independent parts.
--
-- The type has no 'Monad' instance. '>>=' cannot collect the errors of its
-- second part after the first part fails, so 'Control.Monad.ap' would differ
-- from '<*>' and break the law @(<*>) = ap@. 'andThen' is '>>=' under a name
-- that shows the difference. The missing instance also protects the parsers
-- that use @ApplicativeDo@: a statement that uses the result of an earlier one
-- is a compile error, and not a silent loss of errors.
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

-- | Run the second check only if the first one succeeds.
andThen :: Validation e a -> (a -> Validation e b) -> Validation e b
andThen (Validation r) f = either (Validation . Left) f r
