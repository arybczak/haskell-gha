-- The lists of the workflow join their parts with concat, also if there are
-- only two parts.
{- HLINT ignore "Use ++" -}

-- | The generated workflow.
module HaskellGha.Workflow
  ( -- * Workflow
    workflow
  ) where

import Data.Functor
import Data.List qualified as L
import Data.Maybe
import Data.Text qualified as T
import Distribution.Pretty
import Distribution.Version
import System.FilePath
import Yamlet
import Yamlet.Syntax

import HaskellGha.Check
import HaskellGha.Command.Options
import HaskellGha.Config
import HaskellGha.Project
import HaskellGha.Project.Ghc
import HaskellGha.Workflow.Script
import HaskellGha.Workflow.Validate
import HaskellGha.Yaml

-- | Make the workflow.
workflow :: Options -> ConfigSource -> Config -> Project -> Either [String] Node
workflow opts source config project =
  runCheck $ validateWorkflow opts source config project stepIds $> root
  where
    stepIds :: [T.Text]
    stepIds = [i.value | s <- setupSteps ++ buildSteps ++ testSteps, Just i <- [stringField "id" s]]

    entries :: [GhcEntry]
    entries = map (.ghc) project.matrix

    root :: Node
    root =
      mapping
        [ "name" .= copied config.name
        , -- GitHub reads a plain on as a string, so the key needs no quotes,
          -- although YAML 1.1 reads it as a boolean.
          (plain "on", triggers)
        , "permissions" .= copied config.permissions
        , -- A new run cancels the older run of the same ref, also on a branch
          -- of the push trigger. The newer run tests the newer code and saves
          -- the cache that the older run did not save. The workflow_ref has
          -- the path of the workflow file and the ref, so two workflows with
          -- the same name do not share the group.
          "concurrency"
            .= mapping
              [ "group" .= plain "${{ github.workflow_ref }}"
              , "cancel-in-progress" .= True
              ]
        , "defaults"
            .= mapping
              [ "run"
                  .= mappingConcat
                    [ ["shell" .= plain "bash"]
                    , workingDirectory
                    ]
              ]
        , -- The short jobs come first, so the long build job does not hide
          -- them.
          "jobs"
            .= mappingConcat
              [ ["fourmolu" .= fourmoluJob config.fourmolu | config.fourmolu.enabled]
              , ["hlint" .= hlintJob config.hlint | config.hlint.enabled]
              , ["build" .= job]
              ]
        ]

    mappingConcat :: [[(Node, Node)]] -> Node
    mappingConcat = mapping . concat

    copied :: Commented a -> Commented a
    copied c = Commented c.value c.comments {before = directlyAbove c.comments.before}

    -- A comment above an empty line describes the layout of the configuration,
    -- e.g. a section of it, and the workflow has its own layout.
    directlyAbove :: [Line] -> [Line]
    directlyAbove = reverse . takeWhile (/= EmptyLine) . reverse

    triggers :: Node
    triggers =
      mapping
        [ "push" .= mapping ["branches" .= copied config.branches]
        , "pull_request" .= nullValue
        , "merge_group" .= nullValue
        , "workflow_dispatch" .= nullValue
        ]

    workingDirectory :: [(Node, Node)]
    workingDirectory = ["working-directory" .= plain (T.pack projectDir) | projectDir /= "."]

    projectDir :: FilePath
    projectDir = dropTrailingPathSeparator (normalise opts.projectDir)

    job :: Node
    job =
      mappingConcat
        [
          [ "name" .= jobName
          , runsOn (Just config.runsOn)
          ]
        , ["container" .= plain c.image | Just c <- [config.container]]
        , [timeout]
        , ["services" .= copied s | Just s <- [config.services]]
        ,
          [ "strategy"
              .= mapping
                [ "fail-fast" .= False
                , "matrix" .= copied (Commented matrix config.matrix.comments)
                ]
          ]
        , ["steps" .= steps]
        ]

    -- A job without its own runs-on gets the value of the top-level key, but
    -- the comments of that key stay with the build job.
    runsOn :: Maybe (Commented RunsOn) -> (Node, Node)
    runsOn = \case
      Just r -> "runs-on" .= copied r
      Nothing -> "runs-on" .= config.runsOn.value

    timeout :: (Node, Node)
    timeout = "timeout-minutes" .= config.timeoutMinutes.value

    -- The job needs no GHC, so it runs once, next to the build jobs.
    fourmoluJob :: Fourmolu -> Node
    fourmoluJob f =
      mapping
        [ "name" .= plain "Fourmolu"
        , runsOn f.runsOn.value
        , timeout
        , "steps"
            .= sequenceNode
              [ checkoutStep NoSubmodules
              , mapping
                  [ uses "haskell-actions/run-fourmolu" "" config.actions.runFourmolu
                  , "with"
                      .= mappingConcat
                        [ ["version" .= singleQuoted (T.pack (prettyShow f.version))]
                        , ["pattern" .= literal (T.unlines (map (.value) f.patterns)) | not (null f.patterns)]
                        , -- The run defaults do not apply to an action.
                          workingDirectory
                        ]
                  ]
              ]
        ]

    hlintJob :: HLint -> Node
    hlintJob h =
      mapping
        [ "name" .= plain "HLint"
        , runsOn h.runsOn.value
        , timeout
        , "steps"
            .= sequenceNode
              [ checkoutStep NoSubmodules
              , mapping
                  [ uses "haskell-actions/hlint-setup" "" config.actions.hlintSetup
                  , "with" .= mapping ["version" .= singleQuoted (T.pack (prettyShow h.version))]
                  ]
              , mapping
                  [ uses "haskell-actions/hlint-run" "" config.actions.hlintRun
                  , "with"
                      .= mappingConcat
                        [ ["path" .= p | Just p <- [hlintPath h]]
                        , ["fail-on" .= h.failOn]
                        ]
                  ]
              ]
        ]

    -- The action runs in the root of the repository and takes one path, or a
    -- JSON array of paths. Without a path, it checks the root.
    hlintPath :: HLint -> Maybe Node
    hlintPath h = case paths of
      ["."] -> Nothing
      [p] -> Just (singleQuoted (T.pack p))
      ps -> Just (singleQuoted ("[" <> T.intercalate ", " (map (jsonString . T.pack) ps) <> "]"))
      where
        paths :: [FilePath]
        paths
          | null h.path = [projectDir]
          | otherwise =
              [ dropTrailingPathSeparator (normalise (projectDir </> T.unpack p.value.value))
              | p <- h.path
              ]

        jsonString :: T.Text -> T.Text
        jsonString t =
          "\""
            <> T.concatMap (\c -> if c `elem` ['"', '\\'] then T.pack ['\\', c] else T.singleton c) t
            <> "\""

    -- The fourmolu and HLint jobs do not fetch the submodules, because the
    -- files of a submodule are not the code of the project.
    checkoutStep :: Submodules -> Node
    checkoutStep submodules =
      mapping $
        uses "actions/checkout" "" config.actions.checkout : case submodules of
          NoSubmodules -> []
          TopSubmodules -> ["with" .= mapping ["submodules" .= True]]
          RecursiveSubmodules -> ["with" .= mapping ["submodules" .= plain "recursive"]]

    -- The default repository, and the path of the action in the repository,
    -- e.g. /restore.
    uses :: T.Text -> T.Text -> ActionRef -> (Node, Node)
    uses repo path a = "uses" .= plain (fromMaybe repo a.repository <> path <> "@" <> a.ref)

    jobName :: Node
    jobName = case parts of
      [p] -> plain p
      ps -> singleQuoted (T.intercalate ", " ps)
      where
        -- The values newest and oldest are clear without the axis name.
        parts :: [T.Text]
        parts =
          concat
            [ ["GHC ${{ matrix.ghc }}"]
            , ["${{ matrix.dependencies }}" | bothDependencies]
            , [a <> " ${{ matrix." <> a <> " }}" | a <- map (.value) config.matrix.value.axes]
            ]

    bothDependencies :: Bool
    bothDependencies = config.dependencies == DependenciesBoth

    -- The comments below matrix: and above an empty line describe the whole
    -- matrix, so they stay above the ghc axis. The comments after the matrix
    -- are in its entry, so the entry writes them after the new matrix.
    matrix :: Node
    matrix =
      addBefore (dropWhile (== EmptyLine) config.matrix.value.leading) $
        mappingConcat
          [ ["ghc" .= sequenceNode (map (singleQuoted . entryText) entries)]
          , ["dependencies" .= sequenceNode [plain "newest", plain "oldest"] | bothDependencies]
          , config.matrix.value.entries
          ]

    -- The after-setup hooks come before the tarballs and the build plan, so a
    -- hook can install a library that the build plan needs, and the tarballs
    -- can contain a file that a hook makes.
    steps :: Node
    steps =
      sequenceNode $
        concat
          [ setupSteps
          , map hookStep config.hooks.afterSetup
          , buildSteps
          , map hookStep config.hooks.afterBuild
          , testSteps
          ]
      where
        hookStep :: MappingNode -> Node
        hookStep s = mapBefore directlyAbove s.value

    setupSteps :: [Node]
    setupSteps =
      concat
        [ [checkoutStep config.submodules]
        , [ runStep "Install the system packages" Nothing (aptScript config.container config.apt)
          | not (null config.apt)
          ]
        , [ runStep
              "Install the gold linker"
              (Just goldEntries)
              (aptScript config.container ["binutils-gold"])
          | not (null goldEntries)
          ]
        , [setupStep]
        , [versionsStep]
        ]

    buildSteps :: [Node]
    buildSteps =
      concat
        [ [ runStep "Unpack the source tarballs" (Just group) (unpackScript pkgs)
          | config.sdist
          , (group, pkgs) <- packageGroups project.matrix
          ]
        , -- A package stanza also applies to a package from Hackage, so a job
          -- gets the stanzas only of its own local packages.
          [ sourceStep
              "Configure the project"
              (Just group)
              (configureScript config (not (null doctestEntries)) pkgs)
          | (group, pkgs) <- packageGroups project.matrix
          ]
        , oldestStep
        , [ sourceStep
              "Enable parallel module builds for the local packages"
              (Just group)
              (parallelScript config.jobs.value pkgs)
          | (group, pkgs) <- packageGroups [e | e <- project.matrix, not (hasSemaphore e.ghc)]
          ]
        , [ sourceStep
              "Enable the GHC job semaphore or parallel module builds"
              (Just group)
              (semaphoreScript config.jobs.value config.cabalVersion pkgs)
          | (group, pkgs) <- packageGroups [e | e <- project.matrix, hasSemaphore e.ghc]
          ]
        , [planStep]
        , [cacheRestore]
        , [sourceStep "Build the dependencies" Nothing "cabal build all --only-dependencies\n"]
        , [cacheSave]
        , concat [doctestSteps config.doctest | not (null doctestEntries)]
        , [sourceStep "Build" Nothing "cabal build all\n"]
        ]

    testSteps :: [Node]
    testSteps =
      concat
        [ [ sourceStep
              "Run the tests"
              (Just testEntries)
              "cabal test all --test-show-details=direct\n"
          | config.tests
          , not (null testEntries)
          ]
        , [ sourceStep
              ("Run doctest for " <> T.pack p.name)
              (Just es)
              (doctestScript config.doctest.options p)
          | p <- project.packages
          , T.pack p.name `notElem` map (.value) config.doctest.skip
          , not (null p.doctestArgs)
          , let es =
                  [ e.ghc
                  | e <- project.matrix
                  , e.ghc `elem` doctestEntries
                  , p.directory `elem` map (.directory) e.packages
                  ]
          , not (null es)
          ]
        , [ sourceStep "Check the packages" (Just group) (checkScript pkgs)
          | config.check
          , (group, pkgs) <- packageGroups project.matrix
          ]
        , -- With --haddock-all, each component of a package writes the same
          -- documentation tarball, and parallel components then fail on its
          -- file lock.
          [ sourceStep
              "Build the documentation"
              Nothing
              "cabal haddock all --disable-documentation --haddock-for-hackage\n"
          | config.haddock
          ]
        ]

    -- The entries in the range of doctest.ghc. The workflow installs doctest
    -- for such an entry also if no package runs it there, e.g. if doctest.skip
    -- names all packages. Only an unusual configuration does that, so the tool
    -- accepts the extra steps.
    doctestEntries :: [GhcEntry]
    doctestEntries
      | config.doctest.enabled =
          [e | e <- entries, decide config.doctest.ghc.value e == Included]
      | otherwise = []

    -- The key of the main cache does not depend on the doctest version, so
    -- doctest has its own cache with only the binary.
    doctestSteps :: Doctest -> [Node]
    doctestSteps d =
      [ step
          False
          "Find the doctest version"
          (("id" .= plain "doctest") : doctestIf [])
          findDoctest
      , mappingConcat
          [
            [ uses "actions/cache" "/restore" config.actions.cache
            , "id" .= plain "doctest-cache"
            ]
          , doctestIf []
          ,
            [ "with"
                .= mapping
                  [ "path" .= plain "~/.local/bin/doctest"
                  , "key" .= plain cacheKey
                  ]
            ]
          ]
      , step False "Install doctest" (doctestIf [cacheMiss]) installDoctest
      , -- A separate save step keeps the binary also if a later step fails.
        mappingConcat
          [ [uses "actions/cache" "/save" config.actions.cache]
          , doctestIf [cacheMiss]
          ,
            [ "with"
                .= mapping
                  [ "path" .= plain "~/.local/bin/doctest"
                  , "key" .= plain "${{ steps.doctest-cache.outputs.cache-primary-key }}"
                  ]
            ]
          ]
      ]
      where
        cacheMiss :: T.Text
        cacheMiss = "steps.doctest-cache.outputs.cache-hit != 'true'"

        cacheKey :: T.Text
        cacheKey =
          T.intercalate
            "-"
            [ "${{ runner.os }}"
            , "${{ runner.arch }}"
            , "${{ steps.versions.outputs.image }}"
            , "doctest"
            , "${{ steps.doctest.outputs.version }}"
            , "ghc"
            , "${{ steps.setup.outputs.ghc-version }}"
            ]

        installDoctest :: T.Text
        installDoctest =
          T.unwords
            [ "cabal install doctest"
            , "--ignore-project"
            , "--install-method=copy"
            , "--installdir=\"$HOME/.local/bin\""
            , "--overwrite-policy=always"
            , "--constraint='doctest ==${{ steps.doctest.outputs.version }}'"
            ]
            <> "\n"

        doctestIf :: [T.Text] -> [(Node, Node)]
        doctestIf = ifField (Just doctestEntries)

        -- A store that already contains doctest gives a plan without it, so the
        -- dry run uses an empty store.
        findDoctest :: T.Text
        findDoctest =
          T.unlines
            [ "version=$(cabal --store-dir=\"$RUNNER_TEMP\"/doctest-store install doctest --ignore-project --dry-run"
                <> maybe
                  ""
                  (\r -> " --constraint=" <> shellQuote ("doctest " <> T.pack (prettyShow r)))
                  d.version.value
                <> " | sed -n 's/^ - doctest-\\([0-9.]*\\) (exe:doctest).*/\\1/p')"
            , "if [ -z \"$version\" ]; then"
            , "  echo 'The dry run of cabal install shows no doctest version.' >&2"
            , "  exit 1"
            , "fi"
            , "echo \"version=$version\" >> \"$GITHUB_OUTPUT\""
            ]

    -- A step with a script. The script runs for the given matrix entries, or
    -- for all of them.
    runStep :: T.Text -> Maybe [GhcEntry] -> T.Text -> Node
    runStep name only = step False name (ifField only [])

    -- A step that runs in the content of the tarballs, if sdist is true.
    sourceStep :: T.Text -> Maybe [GhcEntry] -> T.Text -> Node
    sourceStep name only = step config.sdist name (ifField only [])

    -- A step with a script and the fields between its name and its working
    -- directory, e.g. its id.
    step :: Bool -> T.Text -> [(Node, Node)] -> T.Text -> Node
    step inSource name fields script =
      mappingConcat
        [ ["name" .= plain name]
        , fields
        , ["working-directory" .= plain ("${{ runner.temp }}/" <> sourceDirName) | inSource]
        , ["run" .= literal script]
        ]

    -- The if field of a step that runs for the given matrix entries, or for
    -- all of them, and only if each extra condition holds.
    ifField :: Maybe [GhcEntry] -> [T.Text] -> [(Node, Node)]
    ifField only extra = case [condition es | Just es <- [only], es /= entries] ++ extra of
      [] -> []
      cs -> ["if" .= plain (T.intercalate " && " cs)]

    -- hashFiles only reads files in the workspace, and the content of the
    -- tarballs is outside it. Thus the step gives the hash of the plan to the
    -- cache key as an output.
    planStep :: Node
    planStep =
      step config.sdist "Make the build plan" ["id" .= plain "plan"] $
        T.unlines
          [ "cabal build all --dry-run"
          , "echo \"hash=$(sha256sum dist-newstyle/cache/plan.json | cut -d ' ' -f 1)\" >> \"$GITHUB_OUTPUT\""
          ]

    condition :: [GhcEntry] -> T.Text
    condition es =
      "contains(fromJSON('["
        <> T.intercalate "," ["\"" <> entryText e <> "\"" | e <- es]
        <> "]'), matrix.ghc)"

    setupStep :: Node
    setupStep =
      mapping
        [ uses "haskell-actions/setup" "" config.actions.setup
        , "id" .= plain "setup"
        , "with"
            .= mapping
              [ "ghc-version" .= plain "${{ matrix.ghc }}"
              , "cabal-version" .= singleQuoted cabalVersion
              ]
        ]

    cabalVersion :: T.Text
    cabalVersion = case config.cabalVersion of
      CabalLatest -> "latest"
      CabalVersion v -> T.pack (prettyShow v)

    -- An expression cannot read the environment variable ImageOS of the runner,
    -- so the step gives it to the cache key as an output. In a container, the
    -- variable is empty, and the image of the container takes its place.
    versionsStep :: Node
    versionsStep =
      mapping
        [ "name" .= plain "Show the versions"
        , "id" .= plain "versions"
        , "run"
            .= literal
              ( T.unlines
                  [ "ghc --version"
                  , "cabal --version"
                  , "echo \"GHC ${{ steps.setup.outputs.ghc-version }}, cabal ${{ steps.setup.outputs.cabal-version }}, image "
                      <> summaryImage
                      <> "\" >> \"$GITHUB_STEP_SUMMARY\""
                  , "echo \"image=" <> keyImage <> "\" >> \"$GITHUB_OUTPUT\""
                  ]
              )
        ]
      where
        summaryImage, keyImage :: T.Text
        (summaryImage, keyImage) = case config.container of
          Nothing -> ("$ImageOS $ImageVersion", "$ImageOS")
          Just c -> (c.image, c.image)

    -- Each later cabal command reads cabal.project.local, so all of them use
    -- the plan with the oldest versions.
    oldestStep :: [Node]
    oldestStep = case config.dependencies of
      DependenciesNewest -> []
      DependenciesOldest -> [preferOldest []]
      DependenciesBoth -> [preferOldest ["matrix.dependencies == 'oldest'"]]
      where
        preferOldest :: [T.Text] -> Node
        preferOldest extra =
          step
            config.sdist
            "Prefer the oldest dependencies"
            (ifField Nothing extra)
            "echo 'prefer-oldest: True' >> cabal.project.local\n"

    -- The matrix entries, grouped by their packages.
    packageGroups :: [MatrixEntry] -> [([GhcEntry], [Package])]
    packageGroups es =
      [ ([e.ghc | e <- es, names e.packages == names pkgs], pkgs)
      | pkgs <- L.nubBy (\a b -> names a == names b) (map (.packages) es)
      ]
      where
        names :: [Package] -> [String]
        names = map (.name)

    -- The semaphore needs GHC 9.8. A matrix entry is an exact version or a
    -- major series, so the range decides each entry completely.
    hasSemaphore :: GhcEntry -> Bool
    hasSemaphore e = decide (orLaterVersion (mkVersion [9, 8])) e == Included

    -- The hsc2hs of GHC 9.4 and older links with gold also if the runner has
    -- no gold, and Ubuntu 25.10 and later do not install gold by default.
    goldEntries :: [GhcEntry]
    goldEntries = [e | e <- entries, decide (earlierVersion (mkVersion [9, 5])) e == Included]

    testEntries :: [GhcEntry]
    testEntries = [e.ghc | e <- project.matrix, any (.hasTestSuite) e.packages]

    cacheRestore :: Node
    cacheRestore =
      mapping
        [ uses "actions/cache" "/restore" config.actions.cache
        , "id" .= plain "cache"
        , "with"
            .= mapping
              [ "path" .= plain "${{ steps.setup.outputs.cabal-store }}"
              , "key" .= plain (cachePrefix <> "${{ steps.plan.outputs.hash }}")
              , "restore-keys" .= plain cachePrefix
              ]
        ]

    -- A store from another image can link against system libraries that this
    -- image does not have. The prefix is also the restore key, so a job
    -- restores only a store of its own workflow with its own kind of
    -- dependencies. A store of another workflow would be saved again with the
    -- dependencies of both.
    cachePrefix :: T.Text
    cachePrefix =
      T.pack opts.output <> "-${{ runner.os }}-${{ runner.arch }}-${{ steps.versions.outputs.image }}-ghc-${{ steps.setup.outputs.ghc-version }}-" <> case config.dependencies of
        DependenciesNewest -> "newest-"
        DependenciesOldest -> "oldest-"
        DependenciesBoth -> "${{ matrix.dependencies }}-"

    cacheSave :: Node
    cacheSave =
      mapping
        [ uses "actions/cache" "/save" config.actions.cache
        , "if" .= plain "steps.cache.outputs.cache-hit != 'true'"
        , "with"
            .= mapping
              [ "path" .= plain "${{ steps.setup.outputs.cabal-store }}"
              , "key" .= plain "${{ steps.cache.outputs.cache-primary-key }}"
              ]
        ]
