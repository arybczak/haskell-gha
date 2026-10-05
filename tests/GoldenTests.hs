module GoldenTests (goldenTests) where

import Control.Monad
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Text.Encoding qualified as T
import Options.Applicative
import System.Directory
import System.Environment
import System.FilePath
import Test.Tasty
import Test.Tasty.HUnit
import Yamlet

import HaskellGha.Command
import HaskellGha.Command.Header
import HaskellGha.Command.Options
import Utils

-- | A test for each directory in @tests/golden@. The test runs the tool in the
-- directory, with the arguments from the file @args@. If the directory contains
-- @haskell-gha.conf.yml@, the test uses it as the configuration.
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
  let args' =
        if hasConfig && "--config" `notElem` args
          then args ++ ["--config", "haskell-gha.conf.yml"]
          else args
  opts <- case execParserPure defaultPrefs (optionsParser "TEST") ("--generate" : args') of
    Success (Generate opts) -> pure opts
    _ -> assertFailure $ "invalid arguments: " ++ unwords args'
  result <- generate dir opts
  node <- either (assertFailure . unlines) pure result
  let actual = renderWorkflow opts node
      expectedFile = dir </> "expected.yml"
  accept <- (== Just "1") <$> lookupEnv "HASKELL_GHA_ACCEPT"
  when accept $ BS.writeFile expectedFile (T.encodeUtf8 actual)
  expected <- T.decodeUtf8 <$> BS.readFile expectedFile
  assertEqual "workflow" expected actual
  case decodeText @(Maybe Node) actual of
    Right (Just reparsed) -> assertEqual "reparsed workflow" (normalize node) (normalize reparsed)
    Right Nothing -> assertFailure "the workflow is empty"
    Left errors -> assertFailure $ foldMap ((++ "\n") . prettyError expectedFile) errors
  where
    readArgs :: FilePath -> IO [String]
    readArgs path =
      doesFileExist path >>= \case
        True -> words <$> readFile path
        False -> pure []
