-- |
-- Module      : Arivi.Kademlia.RefreshKbucket
-- Copyright   : (c) Xoken Labs
-- License     : -
--
-- Maintainer  : Ankit Singh {ankitsiam@gmail.com}
-- Stability   : experimental
-- Portability : portable
--
-- This module provides functionality to refresh k-bucket after a fixed
-- time, this is necessary because in P2P Networks nodes go offline
-- all the time that's why it is essential to make sure that active
-- peers are prioritised, this module do that by issuing the PING request
-- to the k-bucket entries and shuffle the list based on the response
--
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}

module Arivi.P2P.Kademlia.RefreshKbucket
    ( refreshKbucket
    ) where

import           Arivi.P2P.Kademlia.Types
import           Arivi.P2P.MessageHandler.Handler
import qualified Arivi.P2P.MessageHandler.HandlerTypes as HT
import           Arivi.P2P.P2PEnv                      (HasP2PEnv,
                                                        getAriviTVarP2PEnv)
import           Arivi.P2P.Types
import           Arivi.Utils.Logging
import           Codec.Serialise                       (DeserialiseFailure,
                                                        deserialiseOrFail,
                                                        serialise)
import           Control.Concurrent.Async.Lifted
import           Control.Concurrent.STM.TVar           (readTVar)
import           Control.Exception
import qualified Control.Exception.Lifted              as Exception (SomeException,
                                                                     try)
import           Control.Monad                         ()
import           Control.Monad.IO.Class                (MonadIO, liftIO)
import           Control.Monad.Logger                  (logDebug)
import           Control.Monad.STM
import qualified Data.List                             as L
import qualified Data.Text                             as T

-- | Helper function to combine to lists
combineList :: [[a]] -> [[a]] -> [[a]]
combineList [] [] = []
combineList l1 l2 =
    [L.head l1 ++ L.head l2, L.head (L.tail l1) ++ L.head (L.tail l2)]

-- | creates a new list by combining two lists
addToNewList :: [Bool] -> [Peer] -> [[Peer]]
addToNewList _ [] = [[], []]
addToNewList bl pl
    | L.null bl = [[], []]
    | length bl == 1 =
        if L.head bl
            then combineList [[L.head pl], []] (addToNewList [] [])
            else combineList [[], [L.head pl]] (addToNewList [] [])
    | otherwise =
        if L.head bl
            then combineList
                     [[L.head pl], []]
                     (addToNewList (L.tail bl) (L.tail pl))
            else combineList
                     [[], [L.head pl]]
                     (addToNewList (L.tail bl) (L.tail pl))

-- | Issues a ping command and waits for the response and if the response is
--   is valid returns True else False
issuePing ::
       forall m. (HasP2PEnv m, HasLogging m, MonadIO m)
    => Peer
    -> m Bool
issuePing rpeer = do
    p2pInstanceTVar <- getAriviTVarP2PEnv
    p2pInstance <- liftIO $ atomically $ readTVar p2pInstanceTVar
    let lnid = selfNodeId p2pInstance
        luport = selfUDPPort p2pInstance
        lip = selfIP p2pInstance
        ltport = selfTCPPort p2pInstance
        rnid = fst $ getPeer rpeer
        rnep = snd $ getPeer rpeer
        ruport = Arivi.P2P.Kademlia.Types.udpPort rnep
        rip = nodeIp rnep
        ping_msg = packPing lnid lip luport ltport
    $(logDebug) $
        T.pack ("Issueing ping request to : " ++ show rip ++ ":" ++ show ruport)
    resp <-
        Exception.try $
        sendRequestforKademlia rnid HT.Kademlia (serialise ping_msg) ruport rip
    $(logDebug) $
        T.pack ("Response for ping from : " ++ show rip ++ ":" ++ show ruport)
    case resp of
        Left (e :: Exception.SomeException) -> do
            $(logDebug) (T.pack (displayException e))
            return False
        Right resp' -> do
            let resp'' =
                    deserialiseOrFail resp' :: Either DeserialiseFailure PayLoad
            case resp'' of
                Left e -> do
                    $(logDebug) $
                        T.append
                            (T.pack "Deserilization failure while pong: ")
                            (T.pack (displayException e))
                    return False
                Right rl -> do
                    let msg = message rl
                        msgb = messageBody msg
                    case msgb of
                        PONG _ _ -> return True
                        _        -> return False

-- | creates a new list from an existing one by issuing a ping command
refreshKbucket ::
       (HasP2PEnv m, HasLogging m, MonadIO m) => Peer -> [Peer] -> m [Peer]
refreshKbucket peerR pl = do
    sb <- getKb
    let pl2 =
            if peerR `elem` pl
                then L.deleteBy
                         (\p1 p2 -> fst (getPeer p1) == fst (getPeer p2))
                         peerR
                         pl
                else pl
    if L.length pl2 > pingThreshold sb
        then do
            let sl = L.splitAt (kademliaSoftBound sb) pl2
            $(logDebug) $
                T.append
                    (T.pack "Issueing ping to refresh kbucket no of req sent :")
                    (T.pack (show (fst sl)))
            resp <- mapConcurrently issuePing (fst sl)
            $(logDebug) $
                T.append (T.pack "Pong response recieved ") (T.pack (show resp))
            let temp = addToNewList resp (fst sl)
                newpl = L.head temp ++ [peerR] ++ L.head (L.tail temp) ++ snd sl
            return newpl
        else return (pl2 ++ [peerR])
-- runKademliaAction :: forall m. (HasP2PEnv m, HasLogging m, MonadIO m,a) =>
--                         (a -> m a)
--                         -> [a]
--                         -> m()
-- runKademliaAction fn il = do
--     sb <-  getKademliaSoftBound
--     let ls = L.splitAt sb il
--     temp <- mapConcurrenlty fn (fst ls)
--     temp ++ runAlphaConcurrenlty fn (snd ls)
