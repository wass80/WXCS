{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Submit (
  SubmitQueue,
  initializeSubmitQueue,
  crawler
  ) where

import Control.Concurrent
import Control.Concurrent.STM.TQueue
import Control.Monad.Logger (logDebug, runStderrLoggingT)
import Control.Monad.Reader
import Control.Monad.STM (atomically)

import Database.Persist.Sql ((==.), (||.), entityVal)

import System.Process

import Model
import ModelTypes
import qualified OnlineJudge as OJ
import Types
import Utils
import HashColor

type SubmitQueue = TQueue Submit

-- Initialize the SubmitQueue.
-- Collect all submits whose state is 'Pending' or 'Running' and push them into
-- the submit queue.
initializeSubmitQueue :: SubmitQueue -> DatabaseT ()
initializeSubmitQueue q = do
  pendingSubmits <- findAllSubmits filt
  lift $ mapM_ (\s -> atomically $ writeTQueue q $ entityVal s) pendingSubmits
    where filt = [SubmitJudge ==. Pending] ||. [SubmitJudge ==. Running]

getAndUpdateWithRunId :: Submit -> Int -> DatabaseT ()
getAndUpdateWithRunId submit rid = do
  (_, conf) <- ask
  res <- liftIO $ OJ.fetchByRunId conf (submitJudgeType submit) rid
  case res of
    Nothing -> updateSubmit $ submit { submitJudge = SubmissionError }
    Just (judge, time, mem) -> do
      runStderrLoggingT $ $(logDebug) "Get the result."
      liftIO $ callCommand (if judge == Accepted then "./hue.sh 1 " else "./hue.sh 0 ") ++ color
      updateSubmit $ submit { submitJudge = judge, submitTime = time, submitMemory = mem }
        where
          color = hueColor . userId submit

getResultAndUpdate :: Submit -> Int -> DatabaseT ()
getResultAndUpdate submit latestRunId = loop (0 :: Int)
  where
    loop n =
      if n < 100
      then do
        (pool, conf) <- ask
        runId <- liftIO $ OJ.getLatestRunId conf (submitJudgeType submit)
        if runId /= latestRunId
          then do
          runStderrLoggingT $ $(logDebug) "Get the run-id."
          liftIO $ forkIO_ $ (`runReaderT` (pool, conf))
            $ getAndUpdateWithRunId submit runId
          else liftIO (threadDelay (1000 * 1000)) >> loop (n + 1)
      else
        updateSubmit $ submit { submitJudge = SubmissionError }

submitAndUpdate :: Submit -> DatabaseT ()
submitAndUpdate s = do
  (_, conf) <- ask
  lastRunId <- liftIO $ OJ.getLatestRunId conf (submitJudgeType s)
  updateSubmit $ s { submitJudge = Running }
  success <- liftIO $ OJ.submit conf (submitJudgeType s) (submitProblemId s)
             (submitLang s) (submitCode s)
  if success
    then do
    runStderrLoggingT $ $(logDebug) "Submit code to onlinejudge."
    getResultAndUpdate s lastRunId
    else updateSubmit $ s { submitJudge = SubmissionError }

crawler :: SubmitQueue -> DatabaseT ()
crawler queue = do
  submit <- lift $ atomically $ readTQueue queue
  runStderrLoggingT $ $(logDebug) "Take a submission from queue."
  submitAndUpdate submit
  crawler queue
