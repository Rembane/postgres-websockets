module HasqlBroadcastSpec (spec) where

import Protolude

import           Data.Function                        (id)

import Test.Hspec

import PostgresWebsockets.Broadcast
import PostgresWebsockets.HasqlBroadcast
import PostgresWebsockets.Database

spec :: Spec
spec = describe "newHasqlBroadcaster" $ do
    let newConnection connStr =
            either (panic . show) id
            <$> acquire connStr

    it "relay messages sent to the appropriate database channel" $ do
      multi <- either (panic .show) id <$> newHasqlBroadcasterOrError "postgres://localhost/postgres_ws_test"
      msg <- liftIO newEmptyMVar
      onMessage multi "test" $ putMVar msg

      con <- newConnection "postgres://localhost/postgres_ws_test"
      void $ notify con (toPgIdentifier "postgres-websockets") "{\"channel\": \"test\", \"payload\": \"hello there\"}"

      readMVar msg `shouldReturn` (Message "test" "hello there")
