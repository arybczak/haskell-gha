module GoldenTests (goldenTests) where

import Control.Monad
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Options.Applicative
import System.Directory
import System.Environment
import System.FilePath
import Test.Tasty
import Test.Tasty.HUnit

import HaskellGha.Options
import HaskellGha.Workflow
import HaskellGha.Yaml

-- | A test for each directory in @tests/golden@. The test runs the tool in
-- the directory, with the arguments from the file @args@. If the directory
-- contains @haskell-gha.conf.yml@, the test uses it as the configuration.
goldenTests :: IO TestTree
goldenTests = do
  fixtures <- L.sort <$> listDirectory goldenDir
  pure . testGroup "Golden" $ [testCase fixture (golden fixture) | fixture <- fixtures]

goldenDir :: FilePath
goldenDir = "tests" </> "golden"

golden :: FilePath -> Assertion
golden fixture = do
  let dir = goldenDir </> fixture
  args <- readArgs (dir </> "args")
  hasConfig <- doesFileExist (dir </> "haskell-gha.conf.yml")
  let args' = if hasConfig && "--config" `notElem` args then args ++ ["--config", "haskell-gha.conf.yml"] else args
  opts <- case execParserPure defaultPrefs optionsParser args' of
    Success opts -> pure opts
    _ -> assertFailure $ "invalid arguments: " ++ unwords args'
  result <- withCurrentDirectory dir (generate opts)
  node <- either (assertFailure . unlines) pure result
  let actual = renderWorkflow "TEST" opts node
      expectedFile = dir </> "expected.yml"
  accept <- (== Just "1") <$> lookupEnv "HASKELL_GHA_ACCEPT"
  when accept $ BS.writeFile expectedFile (T.encodeUtf8 actual)
  expected <- T.decodeUtf8 <$> BS.readFile expectedFile
  assertEqual "workflow" (dropHeader expected) (dropHeader actual)
  case parseYaml (BL.fromStrict $ T.encodeUtf8 actual) of
    Right (Just reparsed) -> assertEqual "reparsed workflow" (stripComments node) (stripComments reparsed)
    Right Nothing -> assertFailure "the workflow is empty"
    Left e -> assertFailure $ renderYamlError expectedFile e
  where
    readArgs :: FilePath -> IO [String]
    readArgs path =
      doesFileExist path >>= \case
        True -> words <$> readFile path
        False -> pure []

    dropHeader :: T.Text -> T.Text
    dropHeader = T.unlines . dropWhile ((== Just '#') . fmap fst . T.uncons) . T.lines
