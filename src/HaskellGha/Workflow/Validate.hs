-- | The checks of the configuration against the project, before the tool makes
-- the workflow.
module HaskellGha.Workflow.Validate
  ( -- * Validation
    validateWorkflow
  ) where

import Control.Monad
import Data.Foldable
import Data.List qualified as L
import Data.Text qualified as T
import Distribution.Pretty
import Distribution.Version
import System.FilePath
import Yamlet

import HaskellGha.Check
import HaskellGha.Config
import HaskellGha.Ghc
import HaskellGha.Options
import HaskellGha.Project

-- | Check that the workflow can be made from the configuration and the project.
validateWorkflow :: Options -> ConfigSource -> Config -> Project -> Check ()
validateWorkflow opts source config project = do
  traverse_
    checkGhcValue
    (combinationValues "ghc" (config.matrix.value.include ++ config.matrix.value.exclude))
  checkDependencies
  when config.doctest.enabled $ do
    checkRange config.doctest.ghc
    traverse_ checkSkip config.doctest.skip
  traverse_ checkImport project.imports
  when config.sdist $
    traverse_ checkInside project.packages
  when config.hlint.enabled $
    traverse_ checkHLintPath config.hlint.path
  where
    entries :: [GhcEntry]
    entries = map (.ghc) project.matrix

    -- An error at a value of the configuration, with its position.
    failureAt :: Offset -> String -> Check ()
    failureAt off msg = traverse_ failure (sourceErrors source [(off, msg)])

    -- The action gets the path on the runner, where only the repository
    -- exists.
    checkHLintPath :: Located HLintPath -> Check ()
    checkHLintPath p
      | isAbsolute path || leadsAbove (opts.projectDir </> path) =
          failureAt p.offset $
            "the path "
              ++ path
              ++ " is not in the repository. Give a path relative to the project directory."
      | otherwise = pure ()
      where
        path :: FilePath
        path = T.unpack p.value.value

    -- cabal fetches an import from a URL. It reads a local file on the runner,
    -- where only the repository exists, and the copy of the source tarballs
    -- does not contain it.
    checkImport :: Import -> Check ()
    checkImport i
      | "://" `L.isInfixOf` i.target = pure ()
      | isAbsolute i.target || leadsAbove (opts.projectDir </> i.target) =
          failure $
            i.location
              ++ "the imported file "
              ++ i.target
              ++ " is not in the repository. Give a path relative to the project directory."
      | config.sdist =
          failure $
            i.location
              ++ "the workflow builds the source tarballs in a copy of the project directory, and the copy does not contain the imported file "
              ++ i.target
              ++ ". Set sdist: false in the configuration."
      | otherwise = pure ()

    -- The unpack step keeps the path of each package relative to the project
    -- directory, so a path with .. leads out of the copy.
    checkInside :: Package -> Check ()
    checkInside p
      | leadsAbove p.directory =
          failure $
            "Package "
              ++ p.name
              ++ " is in "
              ++ p.directory
              ++ ", outside the project directory, but the workflow builds the source tarballs in a copy of the project directory. Set sdist: false in the configuration."
      | otherwise = pure ()

    -- A range that includes no matrix entry turns its feature off without
    -- any sign in the workflow, e.g. ==10.0 for the series 10.0.
    checkRange :: Located VersionRange -> Check ()
    checkRange r = do
      traverse_
        (either (failureAt r.offset) (const (pure ())) . decideRange name r.value)
        entries
      when (all (\e -> decide r.value e == Excluded) entries)
        $ failureAt r.offset
        $ name
          ++ " includes no GHC version of the matrix, which contains only "
          ++ L.intercalate ", " (map (T.unpack . entryText) entries)
      where
        name :: String
        name = "the range " ++ prettyShow r.value

    checkSkip :: Located T.Text -> Check ()
    checkSkip p
      | T.unpack p.value `elem` map (.name) project.packages = pure ()
      | otherwise = failureAt p.offset $ "the project has no local package " ++ T.unpack p.value

    -- The tool makes the dependencies axis only for both. Otherwise the name
    -- is free for an axis of the user.
    checkDependencies :: Check ()
    checkDependencies
      | config.dependencies == DependenciesBoth = do
          traverse_ ownAxis [a.offset | a <- config.matrix.value.axes, a.value == "dependencies"]
          traverse_
            value
            ( combinationValues
                "dependencies"
                (config.matrix.value.include ++ config.matrix.value.exclude)
            )
      | "dependencies" `elem` map (.value) config.matrix.value.axes = pure ()
      | otherwise =
          traverse_ noAxis (combinationValues "dependencies" config.matrix.value.exclude)
      where
        ownAxis :: Offset -> Check ()
        ownAxis off =
          failureAt
            off
            "the tool makes the dependencies axis for dependencies: both, so the matrix must not contain it"

        value :: Located T.Text -> Check ()
        value v
          | v.value `elem` ["newest", "oldest"] = pure ()
          | otherwise =
              failureAt v.offset $
                "dependencies "
                  ++ T.unpack v.value
                  ++ " is not in the dependencies axis, which contains only newest, oldest"

        noAxis :: Located T.Text -> Check ()
        noAxis v =
          failureAt
            v.offset
            "the matrix has no dependencies axis. Set dependencies: both to add it."

    checkGhcValue :: Located T.Text -> Check ()
    checkGhcValue v
      | v.value `elem` map entryText entries = pure ()
      | otherwise =
          failureAt v.offset $
            "GHC "
              ++ T.unpack v.value
              ++ " is not in the ghc axis, which contains only "
              ++ L.intercalate ", " (map (T.unpack . entryText) entries)
