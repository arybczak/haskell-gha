module ProjectTests (projectTests) where

import Control.Exception
import Data.List qualified as L
import Distribution.Version
import System.Directory
import System.FilePath
import Test.Tasty
import Test.Tasty.HUnit

import HaskellGha.Ghc
import HaskellGha.Project

projectTests :: TestTree
projectTests =
  testGroup
    "Project"
    [ testCase "a single package without cabal.project" test_single
    , testCase "a conditional block" test_conditional
    , testCase "elif and else" test_elifElse
    , testCase "import lines" test_imports
    , testCase "globs" test_globs
    , testCase "optional packages" test_optional
    , testCase "exact and series entries" test_exactAndSeries
    , testCase "an exact entry next to a series entry" test_exactNextToSeries
    , testCase "a missing conditional block" test_missingBlock
    , testCase "a condition that includes a part of a series" test_partialCondition
    , testCase "a flag condition" test_flagCondition
    , testCase "os and arch conditions" test_osArch
    , testCase "tested-with errors" test_testedWithErrors
    , testCase "no packages for a matrix entry" test_emptyEntry
    , testCase "package location errors" test_locationErrors
    , testCase "doctest sources in the package directory and a subdirectory" test_doctestRootAndSubdirectory
    ]

test_single :: Assertion
test_single = do
  project <- readOk [("example.cabal", cabal "example" "GHC == 9.6.7 || ^>= 9.10 || ^>= 9.12" True)]
  assertEqual "packages" ["example"] (map (.name) project.packages)
  assertEqual "directory" ["."] (map (.directory) project.packages)
  assertEqual "test suite" [True] (map (.hasTestSuite) project.packages)
  assertEqual "matrix" [(v [9, 6, 7], ["example"]), (s 9 10, ["example"]), (s 9 12, ["example"])] (matrixOf project)

test_conditional :: Assertion
test_conditional = do
  project <-
    readOk
      [ ("cabal.project", "packages: core\n\nif impl(ghc >= 9.8)\n  packages: new\n")
      , ("core/core.cabal", cabal "core" "GHC == 9.6.7 || ^>= 9.8 || ^>= 9.10" False)
      , ("new/new.cabal", cabal "new" "GHC ^>= 9.8 || ^>= 9.10" True)
      ]
  assertEqual "packages" ["core", "new"] (map (.name) project.packages)
  assertEqual
    "matrix"
    [ (v [9, 6, 7], ["core"])
    , (s 9 8, ["core", "new"])
    , (s 9 10, ["core", "new"])
    ]
    (matrixOf project)

test_elifElse :: Assertion
test_elifElse = do
  project <-
    readOk
      [ ("cabal.project", "if impl(ghc >= 9.12)\n  packages: c\nelif impl(ghc >= 9.8)\n  packages: b\nelse\n  packages: a\n")
      , ("a/a.cabal", cabal "a" "GHC == 9.6.7" False)
      , ("b/b.cabal", cabal "b" "GHC ^>= 9.10" False)
      , ("c/c.cabal", cabal "c" "GHC ^>= 9.12" False)
      ]
  assertEqual "matrix" [(v [9, 6, 7], ["a"]), (s 9 10, ["b"]), (s 9 12, ["c"])] (matrixOf project)

test_imports :: Assertion
test_imports = do
  project <-
    readOk
      [ ("cabal.project", "packages: a\nimport: base.project\n\nif impl(ghc >= 9.12)\n  import: new.project\n")
      , ("a/a.cabal", cabal "a" "GHC ^>= 9.10" False)
      ]
  assertEqual
    "imports"
    [ Import "PROJECT/cabal.project:2:1: " "base.project"
    , Import "PROJECT/cabal.project:5:3: " "new.project"
    ]
    project.imports

test_globs :: Assertion
test_globs = do
  project <-
    readOk
      [ ("cabal.project", "packages: pkgs/*/\n          other/*.cabal, {x,y}\n")
      , ("pkgs/a/a.cabal", cabal "a" "GHC ^>= 9.10" False)
      , ("pkgs/b/b.cabal", cabal "b" "GHC ^>= 9.10" False)
      , ("other/o.cabal", cabal "o" "GHC ^>= 9.10" False)
      , ("x/x.cabal", cabal "x" "GHC ^>= 9.10" False)
      , ("y/y.cabal", cabal "y" "GHC ^>= 9.10" False)
      ]
  assertEqual "packages" ["a", "b", "o", "x", "y"] (L.sort $ map (.name) project.packages)
  assertEqual "directories" ["other", "pkgs/a", "pkgs/b", "x", "y"] (L.sort $ map (.directory) project.packages)

test_optional :: Assertion
test_optional = do
  project <-
    readOk
      [ ("cabal.project", "packages: a\noptional-packages: vendor/*/\n")
      , ("a/a.cabal", cabal "a" "GHC ^>= 9.10" False)
      ]
  assertEqual "packages" ["a"] (map (.name) project.packages)

test_exactAndSeries :: Assertion
test_exactAndSeries = do
  project <- readOk [("a.cabal", cabal "a" "GHC == { 9.6.7 } || ^>= 9.10 || == 9.12.2" False)]
  assertEqual "axis" [v [9, 6, 7], s 9 10, v [9, 12, 2]] (map fst $ matrixOf project)

test_exactNextToSeries :: Assertion
test_exactNextToSeries = do
  errors <-
    readErrors
      [ ("cabal.project", "packages: a b\n")
      , ("a/a.cabal", cabal "a" "GHC == 9.10.3" False)
      , ("b/b.cabal", cabal "b" "GHC ^>= 9.10" False)
      ]
  assertEqual
    "errors"
    [ "Package a lists only some versions of the GHC series 9.10 in tested-with, but another package lists the whole series. A conditional block in cabal.project cannot separate the two. Write the series in the same form in all packages, e.g. ^>= 9.10 or exact versions."
    ]
    errors

test_missingBlock :: Assertion
test_missingBlock = do
  errors <-
    readErrors
      [ ("cabal.project", "packages: core servant-client\n")
      , ("core/core.cabal", cabal "core" "GHC == 9.6.7 || ^>= 9.10 || ^>= 9.12" False)
      , ("servant-client/servant-client.cabal", cabal "servant-client" "GHC ^>= 9.10 || ^>= 9.12" False)
      ]
  assertEqual "errors" [missingBlock "servant-client" "9.6.7" "^>=9.10 || ^>=9.12" "servant-client"] errors

test_partialCondition :: Assertion
test_partialCondition = do
  errors <-
    readErrors
      [ ("cabal.project", "packages: a\nif impl(ghc >= 9.10.2)\n  packages: b\n")
      , ("a/a.cabal", cabal "a" "GHC ^>= 9.10" False)
      , ("b/b.cabal", cabal "b" "GHC ^>= 9.10" False)
      ]
  case errors of
    [e] -> assertBool e ("the condition impl(ghc >=9.10.2) includes only a part of the GHC versions of the matrix entry 9.10" `L.isInfixOf` e)
    _ -> assertFailure (unlines errors)

test_flagCondition :: Assertion
test_flagCondition = do
  errors <-
    readErrors
      [ ("cabal.project", "packages: a\nif flag(dev)\n  packages: b\n")
      , ("a/a.cabal", cabal "a" "GHC ^>= 9.10" False)
      , ("b/b.cabal", cabal "b" "GHC ^>= 9.10" False)
      ]
  case errors of
    [e] -> assertBool e ("the condition flag(dev) is not supported" `L.isInfixOf` e)
    _ -> assertFailure (unlines errors)

test_osArch :: Assertion
test_osArch = do
  project <-
    readOk
      [ ("cabal.project", "packages: a\nif os(linux) && arch(x86_64)\n  packages: b\nif os(windows) || impl(ghcjs)\n  packages: c\n")
      , ("a/a.cabal", cabal "a" "GHC ^>= 9.10" False)
      , ("b/b.cabal", cabal "b" "GHC ^>= 9.10" False)
      , ("c/c.cabal", cabal "c" "GHC ^>= 9.10" False)
      ]
  assertEqual "matrix" [(s 9 10, ["a", "b"])] (matrixOf project)

test_testedWithErrors :: Assertion
test_testedWithErrors = do
  openRange <- readErrors [("a.cabal", cabal "a" "GHC >= 9.10" False)]
  assertEqual
    "open range"
    ["Package a lists the GHC range >=9.10 in tested-with. The matrix needs a finite list of versions. Write an exact version, e.g. == 9.10.3, or a major series, e.g. ^>= 9.10."]
    openRange
  minorRange <- readErrors [("a.cabal", cabal "a" "GHC ^>= 9.10.2" False)]
  assertEqual
    "minor range"
    ["Package a lists the GHC range >=9.10.2 && <9.11 in tested-with. A range must be a whole major series with two version parts, e.g. ^>= 9.10 or == 9.10.*. Write the series, or an exact version, e.g. == 9.10.3."]
    minorRange
  shortVersion <- readErrors [("a.cabal", cabal "a" "GHC == 9.10" False)]
  assertEqual
    "short version"
    ["Package a lists GHC == 9.10 in tested-with. No GHC release has this version. Write an exact version with three parts, e.g. == 9.10.3, or a major series, e.g. ^>= 9.10."]
    shortVersion
  noGhc <- readErrors [("a.cabal", cabal "a" "GHCJS == 8.10.7" False)]
  assertEqual "no GHC" ["Package a has no GHC version in tested-with."] noGhc

test_emptyEntry :: Assertion
test_emptyEntry = do
  errors <-
    readErrors
      [ ("cabal.project", "if impl(ghc >= 9.10)\n  packages: a\n")
      , ("a/a.cabal", cabal "a" "GHC == 9.6.7 || ^>= 9.10" False)
      ]
  case errors of
    [e] -> assertBool e ("cabal.project for GHC 9.6.7." `L.isSuffixOf` e)
    _ -> assertFailure (unlines errors)

test_locationErrors :: Assertion
test_locationErrors = do
  errors <-
    readErrors
      [ ("cabal.project", "packages: missing/ nothing/*.cabal https://example.com/a.tar.gz two /opt/pkg ~/pkgs/*/\n")
      , ("two/a.cabal", cabal "a" "GHC ^>= 9.10" False)
      , ("two/b.cabal", cabal "b" "GHC ^>= 9.10" False)
      ]
  assertEqual
    "errors"
    [ "The package location \"missing/\" matches no files."
    , "The package location \"nothing/*.cabal\" matches no files."
    , "The package location \"https://example.com/a.tar.gz\" is a URL. The tool supports only local packages."
    , "The directory \"two\" contains more than one .cabal file."
    , "The package location \"/opt/pkg\" is not a relative path. The tool supports only packages in the repository."
    , "The package location \"~/pkgs/*/\" is not a relative path. The tool supports only packages in the repository."
    ]
    errors
  noPackages <- readErrors [("README", "")]
  assertEqual "no packages" 1 (length noPackages)

test_doctestRootAndSubdirectory :: Assertion
test_doctestRootAndSubdirectory = do
  project <-
    readOk
      [
        ( "a.cabal"
        , unlines
            [ "cabal-version: 3.0"
            , "name: a"
            , "version: 0"
            , "tested-with: GHC ^>= 9.10"
            , "library"
            , "  hs-source-dirs: . src"
            , "  exposed-modules: Root Inner"
            ]
        )
      , ("Root.hs", "")
      , ("src/Inner.hs", "")
      , ("test/Main.hs", "")
      ]
  assertEqual "doctest arguments" [[["Root.hs", "src"]]] (map (.doctestArgs) project.packages)

----------------------------------------
-- Helpers

v :: [Int] -> GhcEntry
v = GhcExact . mkVersion

s :: Int -> Int -> GhcEntry
s = GhcSeries

matrixOf :: Project -> [(GhcEntry, [String])]
matrixOf project = [(e.ghc, map (.name) e.packages) | e <- project.matrix]

missingBlock :: String -> String -> String -> FilePath -> String
missingBlock package version range dir =
  unlines
    [ "Package "
        ++ package
        ++ " does not list GHC "
        ++ version
        ++ " in tested-with, but "
        ++ "PROJECT/cabal.project"
        ++ " includes it for that GHC version. Move the package to a conditional block in cabal.project, e.g.:"
    , ""
    , "if impl(ghc " ++ range ++ ")"
    , "  packages: " ++ dir
    ]

-- | The contents of a @.cabal@ file.
cabal :: String -> String -> Bool -> String
cabal name testedWith testSuite =
  unlines $
    [ "cabal-version: 3.0"
    , "name: " ++ name
    , "version: 0"
    , "tested-with: " ++ testedWith
    , "library"
    , "  exposed-modules: M"
    ]
      ++ if testSuite then ["test-suite test", "  type: exitcode-stdio-1.0", "  main-is: Main.hs"] else []

-- | Write the files of a project to a temporary directory and read it.
readProjectFiles :: [(FilePath, String)] -> IO (Either [String] Project)
readProjectFiles files = do
  tmp <- getTemporaryDirectory
  let dir = tmp </> "haskell-gha-tests" </> "PROJECT"
  bracket_ (createDirectoryIfMissing True dir) (removeDirectoryRecursive (takeDirectory dir)) $ do
    withCurrentDirectory (takeDirectory dir) $ do
      forM_' files $ \(path, contents) -> do
        createDirectoryIfMissing True (takeDirectory ("PROJECT" </> path))
        writeFile ("PROJECT" </> path) contents
      readProject "PROJECT"
  where
    forM_' :: [a] -> (a -> IO ()) -> IO ()
    forM_' xs f = mapM_ f xs

readOk :: [(FilePath, String)] -> IO Project
readOk files =
  readProjectFiles files >>= \case
    Left errors -> assertFailure (unlines errors)
    Right project -> pure project

readErrors :: [(FilePath, String)] -> IO [String]
readErrors files =
  readProjectFiles files >>= \case
    Left errors -> pure errors
    Right _ -> assertFailure "no errors"
