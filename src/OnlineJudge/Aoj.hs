{-# LANGUAGE FlexibleContexts, OverloadedStrings #-}
module OnlineJudge.Aoj where

import Control.Concurrent
import Control.Monad (liftM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Resource (MonadResource())

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import Data.List (sortBy)

import qualified Network.HTTP.Conduit as H
import qualified Network.HTTP.Types as HT
import Network.HTTP.Types.Status (ok200)

import qualified Text.XML.Light as XML

import Config hiding (user, pass)
import qualified Config as C

import ModelTypes
import Utils

courseList :: [String]
courseList = ["ITP1_1",  "ITP1_2",  "ITP1_3",  "ITP1_4",  "ITP1_5",  "ITP1_6",  "ITP1_7",  "ITP1_8",  "ITP1_9",  "ITP1_10",
              "ALDS1_1", "ALDS1_2", "ALDS1_3", "ALDS1_4", "ALDS1_5", "ALDS1_6", "ALDS1_7", "ALDS1_8", "ALDS1_9", "ALDS1_10", "ALDS1_11", "ALDS1_12",
              "DSL_1",   "DSL_2",
              "GRL_1",   "GRL_2",   "GRL_3",   "GRL_4",   "GRL_5",   "GRL_6",   "GRL_7",
              "CGL_1",   "CGL_2",   "CGL_3",   "CGL_4",   "CGL_5",
              "DPL_1",   "DPL_2",
              "NTL_1"]

endpoint :: String
endpoint = "http://judge.u-aizu.ac.jp/onlinejudge/servlet/Submit"

endpointCourse :: String
endpointCourse = "http://judge.u-aizu.ac.jp/onlinejudge/webservice/submit"

mkRequest :: HT.Method
             -> String
             -> HT.SimpleQuery
             -> IO H.Request
mkRequest m url query = do
  req <- H.parseUrl url
  return $ req { H.method = m
               , H.queryString = HT.renderSimpleQuery False query }

mkQuery :: ByteString -> ByteString -> ByteString -> ByteString -> ByteString
           -> [(ByteString, ByteString)]
mkQuery user pass pid lang src =
  [("userID"    , user),
   ("password"  , pass),
   ("language"  , lang),
   ("problemNO" , pid),
   ("sourceCode", src)]

mkQueryCourse :: ByteString -> ByteString -> ByteString -> ByteString -> ByteString
           -> [(ByteString, ByteString)]
mkQueryCourse user pass pid lang src =
  ("lessonID", lessonId) : mkQuery user pass pid' lang src
  where pid' = BC.drop (BC.length pid - 1) pid
        lessonId = BC.take (BC.length pid - 2) pid

api :: MonadResource m
       => HT.Method
       -> String
       -> HT.SimpleQuery
       -> H.Manager
       -> m (H.Response (C.ResumableSource m ByteString))
api m url query mgr = do
  req <- liftIO $ mkRequest m url query
  H.http req mgr

submitAux :: MonadResource m
          => ByteString -- user id
          -> ByteString -- password
          -> ByteString -- problem id
          -> ByteString -- language
          -> ByteString -- code
          -> H.Manager
          -> m (H.Response (C.ResumableSource m ByteString))
submitAux user pass pid lang src = case BC.count '_' pid of
  2 -> api "POST" endpointCourse (mkQueryCourse user pass pid lang src)
  _ -> api "POST" endpoint (mkQuery user pass pid lang src)

submit :: AojConf -> String -> String -> String -> IO Bool
submit conf pid lang code = H.withManager $ \mgr -> do
  res <- submitAux (BC.pack (C.user conf)) (BC.pack (C.pass conf)) (BC.pack pid)
         (BC.pack lang) (BC.pack code) mgr
  return (ok200 == H.responseStatus res)

mkStatusQuery :: String -> String -> HT.SimpleQuery
mkStatusQuery userId' pid =
  ("problem_id", BC.pack pid) : mkStatusQueryN userId'
mkStatusQueryC :: String -> String -> HT.SimpleQuery
mkStatusQueryC userId' pid =
  ("lesson_id", BC.pack pid) : mkStatusQueryN userId'
mkStatusQueryN :: String -> HT.SimpleQuery
mkStatusQueryN userId'=
  [("user_id", BC.pack userId'),
   ("limit", "10")]

status :: MonadResource m
          => String -- User ID
          -> Maybe String -- Problem ID
          -> H.Manager
          -> m (H.Response (C.ResumableSource m ByteString))
status userId' problemId' = case problemId' of
  Just pid -> if length (filter (=='_') pid) == 1
                then api "GET" lessonStatus (mkStatusQueryC userId' pid)
                else api "GET" statusLog (mkStatusQuery userId' pid)
  Nothing  -> api "GET" statusLog (mkStatusQueryN userId')
  where statusLog = "http://judge.u-aizu.ac.jp/onlinejudge/webservice/status_log"
        lessonStatus = "http://judge.u-aizu.ac.jp/onlinejudge/webservice/lesson_submission_log"

fetchStatusXmlCourse :: String -> String -> IO ByteString
fetchStatusXmlCourse userId' cName = H.withManager $ \mgr -> do
  res <- status userId' (Just cName) mgr
  xmls <- H.responseBody res C.$$+- CL.consume
  return $ BC.concat xmls

fetchStatusXml :: String -> IO ByteString
fetchStatusXml userId' = H.withManager $ \mgr -> do
  res <- status userId' Nothing mgr
  xmls <- H.responseBody res C.$$+- CL.consume
  return $ BC.concat xmls

-- parse status xml
getText :: XML.Element -> String -> String
getText parent childName =
  case XML.findChild (XML.unqual childName) parent of
    Nothing -> ""
    Just child ->
      let [XML.Text content] = XML.elContent child in
       XML.cdData content

data AojStatus = AojStatus {
  runId :: Int,
  userId :: String,
  problemId :: String,
  submissionDate :: Integer,
  judgeStatus :: JudgeStatus,
  language :: String,
  cpuTime :: Int,
  memory :: Int,
  codeSize :: Int
  } deriving (Show, Read, Eq)

instance Ord AojStatus where
  compare x y = compare (submissionDate x) (submissionDate y)

parseXML :: ByteString -> Maybe XML.Element
parseXML = XML.parseXMLDoc . filter (/= '\n') . BC.unpack

statusCodeToJudgeStatus :: String -> JudgeStatus
statusCodeToJudgeStatus code = case code of
  "0" -> CompileError
  "1" -> WrongAnswer
  "2" -> TimeLimitExceeded
  "3" -> MemoryLimitExceeded
  "4" -> Accepted
  "6" -> OutputLimitExceeded
  "7" -> RuntimeError
  "8" -> PresentationError
  _ -> SubmissionError

getStatuses :: XML.Element -> [AojStatus]
getStatuses xml = map f $ XML.findChildren (XML.unqual "status") xml
  where f st = AojStatus {
          runId = read $ getText st "run_id",
          userId = getText st "user_id",
          problemId = if length (getText st "problem_id") == 1
                        then getText st "lesson_id" ++ "_" ++ getText st "problem_id"
                        else getText st "problem_id",
          submissionDate = read $ getText st "submission_date",
          judgeStatus = case length $ getText st "problem_id" of
                          1 -> statusCodeToJudgeStatus $ getText st "status_code"
                          _ -> read $ getText st "status",
          language = getText st "language",
          cpuTime = read $ getText st "cputime",
          memory = read $ getText st "memory",
          codeSize = read $ getText st "code_size" }

fetchByRunId :: AojConf -> Int -> IO (Maybe (JudgeStatus, String, String))
fetchByRunId conf rid = loop (0 :: Int)
  where
    loop n = whenDef Nothing (n < 60) $ do
      threadDelay (1000 * 1000) -- wait 1sec
      xml' <- liftM parseXML $ fetchStatusXml (C.user conf)
      xmlc'' <- mapM (liftM parseXML . fetchStatusXmlCourse (C.user conf)) courseList
      let xmlc' = sequence xmlc''
      case (xml', xmlc') of
        (Nothing, _) -> loop (n+1)
        (_, Nothing) -> loop (n+1)
        (Just xml, Just xmlc) -> do
          let st = filter (\st' -> runId st' == rid) $ concatMap getStatuses (xml:xmlc)
          if null st || (judgeStatus (head st) == Pending)
            then loop (n+1)
            else return $ f (head st)
    f st = Just (judgeStatus st, show $ cpuTime st, show $ memory st)

getLatestRunId :: AojConf -> IO Int
getLatestRunId conf = do
  xml' <- liftM parseXML $ fetchStatusXml (C.user conf)
  xmlc'' <- mapM (liftM parseXML . fetchStatusXmlCourse (C.user conf)) courseList
  let xmlc' = sequence xmlc''
  case (xml', xmlc') of
   (Nothing, _) -> error "Failed to fetch status log."
   (_, Nothing) -> error "Failed to fetch status log."
   (Just xml, Just xmlc) -> do
     let sts = sortBy (flip compare) $ concatMap getStatuses (xml:xmlc)
     return . runId $ head sts
