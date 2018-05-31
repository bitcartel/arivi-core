{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Arivi.AppM (module Arivi.AppM) where

import           Arivi.Crypto.Utils.Keys.Signature
import           Arivi.Crypto.Utils.PublicKey.Utils
import           Arivi.Env
import           Arivi.Logging
import           Arivi.Network.Connection           (Connection (..),
                                                     ConnectionId)
import           Arivi.Network.Datagram             (createUDPSocket)
import           Arivi.Network.Instance
import           Arivi.Network.StreamServer
import           Arivi.Network.Types                (Event (..), Payload (..))
import qualified Arivi.Network.Types                as ANT
import           Control.Concurrent                 (threadDelay)
import           Control.Concurrent.Async
import           Control.Concurrent.STM             (atomically, newTChan,
                                                     readTChan, writeTChan)
import           Control.Concurrent.STM.TQueue
import           Control.Monad                      (forever)
import           Control.Monad.Logger
import           Control.Monad.Reader
import           Data.ByteString.Lazy
import           Data.HashTable.IO                  as MutableHashMap (new)
import           Network.Socket

type AppM = ReaderT AriviEnv (LoggingT IO)

instance HasEnv AppM where
  getEnv = ask

instance HasAriviNetworkInstance AppM where
  getAriviNetworkInstance = ariviNetworkInstance <$> getEnv

instance HasSecretKey AppM where
  getSecretKey = cryptoEnvSercretKey . ariviCryptoEnv <$> getEnv

instance HasLogging AppM where
  getLoggerChan = loggerChan <$> getEnv

instance HasUDPSocket AppM where
  getUDPSocket = udpSocket <$> getEnv

runAppM :: AriviEnv -> AppM a -> LoggingT IO a
runAppM = flip runReaderT




sender sk rk = do
  tq <- newTQueueIO :: IO LogChan
  -- sock <- createUDPSocket "127.0.0.1" (envPort mkAriviEnv)
  mutableConnectionHashMap <- MutableHashMap.new
                                    :: IO (HashTable ConnectionId Connection)
  env' <- mkAriviEnv
  let env = env' { ariviCryptoEnv = CryptoEnv sk
                 , loggerChan = tq
                 -- , udpSocket = sock
                 , udpConnectionHashMap = mutableConnectionHashMap
                 }
  runStdoutLoggingT $ runAppM env (do
                                       let ha = "127.0.0.1"
                                       cid <- openConnection ha 8080 ANT.TCP (generateNodeId rk) ANT.INITIATOR

                                       liftIO $ print ha
                                       liftIO $ print cid

                                   )

receiver sk = do
  print (generateNodeId sk)
  tq <- newTQueueIO :: IO LogChan
  -- sock <- createUDPSocket "127.0.0.1" (envPort mkAriviEnv)
  mutableConnectionHashMap <- MutableHashMap.new
                                    :: IO (HashTable ConnectionId Connection)
  env' <- mkAriviEnv
  let env = env' { ariviCryptoEnv = CryptoEnv sk
                 , loggerChan = tq
                 -- , udpSocket = sock
                 , udpConnectionHashMap = mutableConnectionHashMap
                 }
  runStdoutLoggingT $ runAppM env (do
                                       runTCPserver (show (envPort env))
                                  )

main = do
  (sender_sk, _) <- generateKeyPair
  (recv_sk, _) <- generateKeyPair
  receiver recv_sk
  sender sender_sk recv_sk
