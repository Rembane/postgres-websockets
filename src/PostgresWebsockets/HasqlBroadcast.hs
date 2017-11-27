{-| Uses Broadcast module adding database as a source producer.
    This module provides a function to produce a 'Multiplexer' from a Hasql 'Connection'.
    The producer issues a LISTEN command upon Open commands and UNLISTEN upon Close.
-}
module PostgresWebsockets.HasqlBroadcast
  ( newHasqlBroadcaster
  , newHasqlBroadcasterOrError
  -- re-export
  , acquire
  , relayMessages
  , relayMessagesForever
  ) where

import Protolude

import Hasql.Connection
import Data.Either.Combinators (mapBoth)
import Data.Function           (id)
import Control.Retry           (RetryStatus, retrying, capDelay, exponentialBackoff)

import PostgresWebsockets.Database
import PostgresWebsockets.Broadcast

{- | Returns a multiplexer from a connection URI, keeps trying to connect in case there is any error.
   This function also spawns a thread that keeps relaying the messages from the database to the multiplexer's listeners
-}
newHasqlBroadcaster :: ByteString -> IO Multiplexer
newHasqlBroadcaster = newHasqlBroadcasterForConnection . tryUntilConnected

{- | Returns a multiplexer from a connection URI or an error message on the left case
   This function also spawns a thread that keeps relaying the messages from the database to the multiplexer's listeners
-}
newHasqlBroadcasterOrError :: ByteString -> IO (Either ByteString Multiplexer)
newHasqlBroadcasterOrError =
  acquire >=> (sequence . mapBoth show (newHasqlBroadcasterForConnection . return))

tryUntilConnected :: ByteString -> IO Connection
tryUntilConnected =
  fmap (either (panic "Failure on connection retry") id) . retryConnection
  where
    retryConnection conStr = retrying retryPolicy shouldRetry (const $ acquire conStr)
    maxDelayInMicroseconds = 32000000
    firstDelayInMicroseconds = 1000000
    retryPolicy = capDelay maxDelayInMicroseconds $ exponentialBackoff firstDelayInMicroseconds
    shouldRetry :: RetryStatus -> Either ConnectionError Connection -> IO Bool
    shouldRetry _ con =
      case con of
        Left err -> do
          putErrLn $ "Error connecting notification listener to database: " <> show err
          return True
        _ -> return False

{- | Returns a multiplexer from an IO Connection, listen for different database notification channels using the connection produced.

   This function also spawns a thread that keeps relaying the messages from the database to the multiplexer's listeners

   To listen on channels *chat*

   @
   import Protolude
   import PostgresWebsockets.HasqlBroadcast
   import PostgresWebsockets.Broadcast
   import Hasql.Connection

   main = do
    conOrError <- H.acquire "postgres://localhost/test_database"
    let con = either (panic . show) id conOrError :: Connection
    multi <- newHasqlBroadcaster con

    onMessage multi "chat" (\ch ->
      forever $ fmap print (atomically $ readTChan ch)
   @

-}
newHasqlBroadcasterForConnection :: IO Connection -> IO Multiplexer
newHasqlBroadcasterForConnection getCon = do
  multi <- newMultiplexer openProducer closeProducer
  void $ relayMessagesForever multi
  return multi
  where
    closeProducer _ = putErrLn "Broadcaster is dead"
    openProducer cmds msgs = do
      con <- getCon
      waitForNotifications
        (\c m-> atomically $ writeTQueue msgs $ Message c m)
        con
      forever $ do
        cmd <- atomically $ readTQueue cmds
        case cmd of
          Open ch -> listen con $ toPgIdentifier ch
          Close ch -> unlisten con $ toPgIdentifier ch


putErrLn :: Text -> IO ()
putErrLn = hPutStrLn stderr
