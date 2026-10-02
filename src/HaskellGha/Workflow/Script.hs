-- | The shell scripts of the workflow steps. A script that refers to a step
-- output stays with its step in "HaskellGha.Workflow", next to the step IDs.
module HaskellGha.Workflow.Script
  ( -- * Quoting
    shellQuote

    -- * Source tarballs
  , sourceDirName
  , unpackScript

    -- * Scripts
  , aptScript
  , configureScript
  , parallelScript
  , semaphoreScript
  , checkScript
  , doctestScript
  ) where

import Data.Char
import Data.List qualified as L
import Data.Text qualified as T
import Distribution.Version

import HaskellGha.Config
import HaskellGha.Project

-- | Quote a word for bash, if it needs quotes.
shellQuote :: T.Text -> T.Text
shellQuote t
  | not (T.null t) && T.all safe t = t
  | otherwise = "'" <> T.replace "'" "'\\''" t <> "'"
  where
    safe :: Char -> Bool
    safe c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("-_./=:+@%," :: String)

----------------------------------------
-- Source tarballs

-- | The directory in the temporary directory of the runner with the content of
-- the tarballs, at the same relative paths as in the project directory.
sourceDirName :: T.Text
sourceDirName = "haskell-gha"

-- | Unpack the tarballs of the packages. The step makes the tarballs of the
-- packages of the matrix entry, so a package that is not in the project has no
-- tarball. The pattern of a tarball allows only a version after the name,
-- because the tarball of a package foo-2d also starts with foo-.
unpackScript :: [Package] -> T.Text
unpackScript pkgs =
  T.unlines $
    [ "shopt -s extglob"
    , "cabal sdist all --output-directory=\"$RUNNER_TEMP\"/haskell-gha-sdist"
    , "mkdir " <> sourceDir
    , "for f in cabal.project cabal.project.freeze cabal.project.local; do"
    , "  if [ -f \"$f\" ]; then cp \"$f\" " <> sourceDir <> "; fi"
    , "done"
    ]
      ++ concat
        [ ["mkdir -p " <> dir | p.directory /= "."]
            ++ [ "tar -xzf \"$RUNNER_TEMP\"/haskell-gha-sdist/"
                   <> T.pack p.name
                   <> "-+([0-9.]).tar.gz --strip-components=1 -C "
                   <> dir
               ]
        | p <- pkgs
        , let dir =
                if p.directory == "."
                  then sourceDir
                  else sourceDir <> "/" <> shellQuote (T.pack p.directory)
        ]
  where
    sourceDir :: T.Text
    sourceDir = "\"$RUNNER_TEMP\"/" <> sourceDirName

----------------------------------------
-- Scripts

-- | Install Ubuntu packages. A job in a container runs as root, and the image
-- has no sudo. The runner images set DEBIAN_FRONTEND in /etc/environment, but
-- the containers do not, and a debconf question there waits for an answer on
-- stdin. sudo drops the variable from the environment of the step, so the
-- command line sets it.
aptScript
  :: Maybe Container
  -- ^ The container of the job.
  -> [T.Text]
  -- ^ The packages.
  -> T.Text
aptScript container packages =
  T.unlines
    [ sudo <> "apt-get update"
    , sudo
        <> "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "
        <> T.unwords (map shellQuote packages)
    ]
  where
    sudo :: T.Text
    sudo = maybe "sudo " (const "") container

-- | Write the settings of the configuration to @cabal.project.local@.
configureScript
  :: Config
  -> Bool
  -- ^ Whether doctest runs, so it needs the GHC environment files.
  -> [Package]
  -- ^ The packages that get the @ghc-options@ of the configuration.
  -> T.Text
configureScript config doctest pkgs =
  heredoc $
    concat
      [ ["jobs: " <> tshow config.jobs.value]
      , ["tests: True" | config.tests]
      , ["benchmarks: True" | config.benchmarks]
      , ["write-ghc-environment-files: always" | doctest]
      , concat
          [ "" : stanza p ("ghc-options: " <> config.ghcOptions.value)
          | not (T.null config.ghcOptions.value)
          , p <- pkgs
          ]
      , case T.lines (T.dropWhileEnd isSpace config.cabalProjectLocal.value) of
          [] -> []
          ls -> "" : ls
      ]

-- | Make GHC compile the modules of the packages in parallel.
parallelScript
  :: Int
  -- ^ The number of parallel jobs.
  -> [Package]
  -> T.Text
parallelScript jobs pkgs =
  heredoc . L.intercalate [""] $
    [stanza p ("ghc-options: -j" <> tshow jobs) | p <- pkgs]

-- | Enable the GHC job semaphore, or parallel module builds if GHC and cabal
-- use different versions of the semaphore protocol. With different versions,
-- GHC compiles the modules one at a time. Only some minor versions of a series
-- use version 2, and a series entry gets its newest release when the job runs,
-- so the script asks GHC. A GHC without the Semaphore version entry in its info
-- uses version 1.
semaphoreScript
  :: Int
  -- ^ The number of parallel jobs.
  -> CabalVersion
  -> [Package]
  -> T.Text
semaphoreScript jobs cabalVersion pkgs =
  T.concat
    [ "if ghc --info | grep -F '(\"Semaphore version\",\"2\")' > /dev/null; then\n"
    , branch 2
    , "else\n"
    , branch 1
    , "fi\n"
    ]
  where
    branch :: Int -> T.Text
    branch ghcV
      | ghcV == cabalV =
          echo
            ( "GHC and cabal use version "
                <> tshow ghcV
                <> " of the semaphore protocol, so GHC uses the semaphore."
            )
            <> heredoc ["semaphore: True"]
      | otherwise =
          echo
            ( "GHC uses version "
                <> tshow ghcV
                <> " of the semaphore protocol and cabal version "
                <> tshow cabalV
                <> ", so GHC uses -j"
                <> tshow jobs
                <> "."
            )
            <> parallelScript jobs pkgs

    echo :: T.Text -> T.Text
    echo msg = "echo '" <> msg <> "'\n"

    -- cabal 3.18 and later use only version 2, older versions only version 1.
    cabalV :: Int
    cabalV = case cabalVersion of
      CabalLatest -> 2
      CabalVersion v
        | v >= mkVersion [3, 18] -> 2
        | otherwise -> 1

-- | Run cabal check for each package. cabal check works on the package in the
-- current directory, and its output does not name the package. The step runs
-- with bash -e, so a failed check must not end the script before the other
-- packages.
checkScript :: [Package] -> T.Text
checkScript pkgs =
  T.unlines $
    concat
      [
        [ "failed=0"
        , "check() {"
        , "  echo \"Checking the package $1\""
        , "  (cd \"$2\" && cabal check) || { echo \"::error::cabal check failed for the package $1\"; failed=1; }"
        , "}"
        ]
      , [ "check " <> shellQuote (T.pack p.name) <> " " <> shellQuote (T.pack p.directory)
        | p <- pkgs
        ]
      , ["exit \"$failed\""]
      ]

-- | Run doctest for the library and each sublibrary of a package.
doctestScript
  :: [T.Text]
  -- ^ Extra arguments for doctest.
  -> Package
  -> T.Text
doctestScript options p =
  T.unlines $
    ["cd " <> shellQuote (T.pack p.directory) | p.directory /= "."]
      ++ [ T.unwords ("\"$HOME\"/.local/bin/doctest" : map shellQuote (options ++ map T.pack args))
         | args <- p.doctestArgs
         ]

----------------------------------------
-- Helpers

-- | A package stanza of @cabal.project.local@ with one field.
stanza :: Package -> T.Text -> [T.Text]
stanza p line = ["package " <> T.pack p.name, "  " <> line]

-- | Add lines to @cabal.project.local@.
heredoc :: [T.Text] -> T.Text
heredoc ls = T.unlines $ ["cat >> cabal.project.local <<'EOF'"] ++ ls ++ ["EOF"]

tshow :: Int -> T.Text
tshow = T.pack . show
