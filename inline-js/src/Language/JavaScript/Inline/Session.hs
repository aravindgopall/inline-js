{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

module Language.JavaScript.Inline.Session
  ( JSSessionOpts(..)
  , defJSSessionOpts
  , JSSession
  , startJSSession
  , killJSSession
  , withJSSession
  , sendMsg
  , recvMsg
  , sendRecv
  ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Coerce
import Data.Function
import Data.Functor
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Text.Lazy.IO as LText
import qualified Language.JavaScript.Inline.JSON as JSON
import Language.JavaScript.Inline.Message
import Language.JavaScript.Inline.MessageCounter
import qualified Paths_inline_js
import System.Environment.Blank
import System.FilePath
import System.IO
import System.Process

data JSSessionOpts = JSSessionOpts
  { nodePath :: FilePath
  , nodeExtraArgs :: [String]
  , nodePwd :: Maybe FilePath
  , nodeExtraEnv :: [(String, String)]
  , nodeStdErrCopyBack :: Bool
  } deriving (Show)

defJSSessionOpts :: JSSessionOpts
defJSSessionOpts =
  JSSessionOpts
    { nodePath = "node"
    , nodeExtraArgs = []
    , nodePwd = Nothing
    , nodeExtraEnv = []
    , nodeStdErrCopyBack = False
    }

data JSSession = JSSession
  { nodeStdIn, nodeStdOut :: Handle
  , nodeStdErr :: Maybe Handle
  , nodeProc :: ProcessHandle
  , msgCounter :: MsgCounter
  , sendQueue :: TQueue (MsgId, SendMsg)
  , recvMap :: TVar (IntMap.IntMap RecvMsg)
  , sendWorker, recvWorker :: ThreadId
  }

startJSSession :: JSSessionOpts -> IO JSSession
startJSSession JSSessionOpts {..} = do
  _datadir <- Paths_inline_js.getDataDir
  _env <- getEnvironment
  (Just _stdin, Just _stdout, _m_stderr, _h) <-
    createProcess
      (proc nodePath (nodeExtraArgs <> [_datadir </> "jsbits" </> "server.js"]))
        { cwd = nodePwd
        , env = Just (nodeExtraEnv <> _env)
        , std_in = CreatePipe
        , std_out = CreatePipe
        , std_err =
            if nodeStdErrCopyBack
              then Inherit
              else CreatePipe
        }
  hSetBinaryMode _stdout True
  hSetBuffering _stdin LineBuffering
  hSetEncoding _stdin utf8
  hSetNewlineMode _stdin noNewlineTranslation
  Right (0, Result {isError = False, result = JSON.Null}) <-
    unsafeRecvMsg _stdout
  _msg_counter <- newMsgCounter
  _send_queue <- newTQueueIO
  _sender <-
    forkIO $
    fix $ \w -> do
      (_msg_id, _msg) <- atomically $ readTQueue _send_queue
      r <- unsafeSendMsg _stdin _msg_id _msg
      case r of
        Left _ -> pure ()
        Right _ -> w
  _recv_map <- newTVarIO IntMap.empty
  _recver <-
    forkIO $
    fix $ \w -> do
      r <- unsafeRecvMsg _stdout
      case r of
        Left _ -> pure ()
        Right (_msg_id, _msg) -> do
          atomically $
            modifyTVar' _recv_map $ IntMap.insert (coerce _msg_id) _msg
          w
  pure
    JSSession
      { nodeStdIn = _stdin
      , nodeStdOut = _stdout
      , nodeStdErr = _m_stderr
      , nodeProc = _h
      , msgCounter = _msg_counter
      , sendQueue = _send_queue
      , recvMap = _recv_map
      , sendWorker = _sender
      , recvWorker = _recver
      }

killJSSession :: JSSession -> IO ()
killJSSession JSSession {..} = do
  terminateProcess nodeProc
  killThread sendWorker
  killThread recvWorker

withJSSession :: JSSessionOpts -> (JSSession -> IO r) -> IO r
withJSSession opts = bracket (startJSSession opts) killJSSession

unsafeSendMsg :: Handle -> MsgId -> SendMsg -> IO (Either String ())
unsafeSendMsg _node_stdin msg_id msg = do
  r <-
    try $
    LText.hPutStrLn _node_stdin $ JSON.encodeLazyText (encodeSendMsg msg_id msg)
  pure $
    case r of
      Left err ->
        Left $
        "Language.JavaScript.Inline.JSON.unsafeSendMsg: writing to stdin of node process failed with " <>
        show (err :: SomeException)
      Right _ -> Right ()

unsafeRecvMsg :: Handle -> IO (Either String (MsgId, RecvMsg))
unsafeRecvMsg _node_stdout = do
  r <- try $ BS.hGetLine _node_stdout
  pure $
    case r of
      Left err ->
        Left $
        "Language.JavaScript.Inline.JSON.unsafeRecvMsg: reading stdout of node process failed with " <>
        show (err :: SomeException)
      Right l ->
        case JSON.decode $ LBS.fromStrict l of
          Left err ->
            Left $
            "Language.JavaScript.Inline.JSON.unsafeRecvMsg: parsing Value failed with " <>
            err
          Right v ->
            case decodeRecvMsg v of
              Left err ->
                Left $
                "Language.JavaScript.Inline.JSON.unsafeRecvMsg: parsing RecvMsg failed with " <>
                err
              Right msg -> Right msg

sendMsg :: JSSession -> SendMsg -> IO MsgId
sendMsg JSSession {..} msg = do
  _msg_id <- newMsgId msgCounter
  atomically $ writeTQueue sendQueue (_msg_id, msg)
  pure _msg_id

recvMsg :: JSSession -> MsgId -> IO RecvMsg
recvMsg JSSession {..} msg_id =
  atomically $ do
    _recv_map_prev <- readTVar recvMap
    case IntMap.updateLookupWithKey
           (\_ _ -> Nothing)
           (coerce msg_id)
           _recv_map_prev of
      (Just _msg, _recv_map) -> writeTVar recvMap _recv_map $> _msg
      _ -> retry

sendRecv :: JSSession -> SendMsg -> IO RecvMsg
sendRecv s = recvMsg s <=< sendMsg s