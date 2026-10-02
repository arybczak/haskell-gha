-- | The rules for the paths that the tool reads or writes, and for the paths
-- that the workflow uses on the runner. The runner has only the repository,
-- at another place than the local checkout.
module HaskellGha.Path
  ( -- * Rules
    leadsOut
  , linkProblem
  , linkErrors

    -- * Text
  , leadsAbove
  ) where

import Control.Exception
import Data.Foldable
import System.Directory
import System.FilePath

import HaskellGha.Check

-- | Whether a path, relative to the root of the repository, leads out of it by
-- its text: it is absolute, or its @..@ components lead above the root.
leadsOut :: FilePath -> Bool
leadsOut path = isAbsolute path || leadsAbove path

-- | Whether the @..@ components of a relative path lead above its start, e.g.
-- @a/../../b@.
leadsAbove :: FilePath -> Bool
leadsAbove = any (< 0) . scanl (+) 0 . map depth . splitDirectories
  where
    depth :: FilePath -> Int
    depth = \case
      ".." -> -1
      "." -> 0
      _ -> 1

-- | Why a path, relative to the root of the repository, does not work on the
-- runner, if it does not. The path follows each symbolic link, also a broken
-- one, and a @..@ after a link leaves the target of the link, as in the
-- system. A component that does not exist is not a link, so the path can name
-- a file that the tool or the workflow makes.
linkProblem
  :: FilePath
  -- ^ The root of the repository.
  -> FilePath
  -> IO (Maybe String)
linkProblem root path
  | isAbsolute path = pure (Just "leads out of the repository")
  | otherwise = go 0 [] (splitDirectories path)
  where
    -- The arguments are the number of links so far, and the components of the
    -- directory so far, in reverse order.
    go :: Int -> [FilePath] -> [FilePath] -> IO (Maybe String)
    go links dir = \case
      [] -> pure Nothing
      "." : rest -> go links dir rest
      ".." : rest -> case dir of
        _ : up -> go links up rest
        []
          | links == 0 -> pure (Just "leads out of the repository")
          | otherwise -> pure (Just "leads out of the repository through a symbolic link")
      c : rest -> do
        let here = joinPath (reverse (c : dir))
        try @IOException (getSymbolicLinkTarget (root </> here)) >>= \case
          -- Also a path that does not exist.
          Left _ -> go links (c : dir) rest
          Right target
            | links == maxLinks ->
                pure . Just $
                  "goes through more than "
                    ++ show maxLinks
                    ++ " symbolic links, and Linux on the runner follows no more"
            | isAbsolute target ->
                pure . Just $
                  "goes through the symbolic link "
                    ++ here
                    ++ " with an absolute target, but the repository is at another place on the runner. Give the link a relative target"
            | otherwise -> go (links + 1) dir (splitDirectories target ++ rest)

    -- MAXSYMLINKS in include/linux/namei.h, the limit of the links in one path
    -- on the runner.
    maxLinks :: Int
    maxLinks = 40

-- | An error for each path that 'linkProblem' rejects. The paths are relative to
-- the root of the repository, and each comes with the start of its message,
-- e.g. @The project directory a@.
linkErrors
  :: FilePath
  -- ^ The root of the repository.
  -> [(String, FilePath)]
  -> IO (Either [String] ())
linkErrors root =
  fmap (runCheck . traverse_ (traverse_ failure))
    . mapM (\(start, path) -> fmap (\r -> start ++ " " ++ r ++ ".") <$> linkProblem root path)
