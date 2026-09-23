-- | Checks that collect all their errors.
module HaskellGha.Check
  ( -- * Check
    Check
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
newtype Check a = Check (Either [String] a)
  deriving stock (Show)

instance Functor Check where
  fmap f (Check r) = Check (fmap f r)

instance Applicative Check where
  pure = Check . Right
  Check (Left e1) <*> Check (Left e2) = Check (Left (e1 ++ e2))
  Check (Left e) <*> _ = Check (Left e)
  Check (Right f) <*> Check r = Check (fmap f r)

-- | Get the errors or the result.
runCheck :: Check a -> Either [String] a
runCheck (Check r) = r

-- | A check with one error.
failure :: String -> Check a
failure e = Check (Left [e])

-- | Convert an 'Either' with one error.
fromEither :: Either String a -> Check a
fromEither = Check . either (Left . pure) Right

-- | Convert an 'Either' with a list of errors.
fromErrors :: Either [String] a -> Check a
fromErrors = Check

-- | Run the second check only if the first one succeeds.
andThen :: Check a -> (a -> Check b) -> Check b
andThen (Check r) f = either (Check . Left) f r
