-- |
-- Module      : Arivi.Kademlia.Instance
-- Copyright   : (c) Xoken Labs
-- License     : -
--
-- Maintainer  : Ankit Singh {ankitsiam@gmail.com}
-- Stability   : experimental
-- Portability : portable
--
-- This module provides access to Kbucket which is responsible for storing
-- peers, and other helper functions to work with kbucket.
--

{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Arivi.P2P.Kademlia.Kbucket
  (
    Kbucket (..),
    Peer (..),
    createKbucket,
    getDefaultNodeId,
    getPeerList,
    getPeerListByKIndex,
    ifPeerExist,
    addToKBucket,
    removePeer,
    getKClosestPeers
  ) where

import qualified Arivi.P2P.Kademlia.Types       as T
import qualified Arivi.P2P.Kademlia.Utils       as U
import           Arivi.P2P.Kademlia.XorDistance
import           Arivi.Utils.Exception
import           Control.Monad
import qualified Data.HashTable.IO              as H
import qualified Data.List                      as L
import           Data.Maybe
-- | Peer information encapsulated in a single structure
newtype Peer = Peer {
                        getPeer :: (T.NodeId,T.NodeEndPoint)
                      }
                      deriving (Show)

instance Eq Peer where
  Peer (x,_) == Peer (a,_) = a == x

-- | K-bucket to store peers
newtype Kbucket k v = Kbucket {
                        getKbucket :: H.CuckooHashTable k v
                      }
                      deriving (Show)

-- | Creates a new K-bucket which is a mutable hash table, and inserts the local
-- node with position 0 i.e kb index is zero since the distance of a node
-- from it's own address is zero. This will help insert the new peers into
-- kbucket with respect to the local peer

createKbucket :: Peer
              -> IO (Kbucket Int [Peer])
createKbucket localPeer = do
  m <- H.new
  H.insert m 0 [localPeer]
  return (Kbucket m)

-- | Gets default peer relative to which all the peers are stores in Kbucket
--   hash table based on XorDistance
getDefaultNodeId :: Kbucket Int [Peer] -> IO (Either AriviException T.NodeId)
getDefaultNodeId kbucket = do
  let kb = getKbucket kbucket
  lp <- H.lookup kb 0
  let localPeer = fromMaybe [] lp
  if null localPeer
    then return $ Left KademliaDefaultPeerDoesNotExists
    else return $ Right $ fst $ getPeer $ head localPeer

-- | Gives a peerList of which a peer is part of in kbucket hashtable for any
-- given peer with respect to the default peer or local peer for which
-- the kbucket is created. If peer doesn't exist it returns an empty list
getPeerList :: Peer
            -> Kbucket Int [Peer]
            -> IO (Either AriviException [Peer])
getPeerList peerR kbucket = do
  lp <- getDefaultNodeId kbucket
  case lp of
    Right localPeer ->  do
                            let peer       = fst $ getPeer peerR
                                kbDistance = getKbIndex localPeer peer
                            pl <- H.lookup (getKbucket kbucket) kbDistance
                            let peerList = fromMaybe [] pl
                            return $ Right peerList

    Left _          -> return $ Left KademliaDefaultPeerDoesNotExists

-- -- | gets Peer by Kbucket-Index (kb-index) Index
getPeerListByKIndex :: Int
                    -> Kbucket Int [Peer]
                    -> IO (Either AriviException [Peer])
getPeerListByKIndex kbi kbucket = do
  peerl <- H.lookup (getKbucket kbucket) kbi
  let pl = fromMaybe [] peerl
  case pl of
    [] -> return $ Left KademliaKbIndexDoesNotExist
    _  -> return $ Right pl

-- -- checks if a peer already exists
ifPeerExist :: Peer
            -> Kbucket Int [Peer]
            -> IO (Either AriviException Bool)
ifPeerExist peer kbucket = do
  peerList <- getPeerList peer kbucket
  case peerList of
    Right pl  -> if peer `elem` pl
                  then return (Right True)
                  else return (Right False)
    Left  _   -> return (Left KademliaKbIndexDoesNotExist)

-- |Adds a given peer to kbucket hash table by calculating the appropriate
-- kbindex based on the XOR Distance.
addToKBucket :: Peer
             -> Kbucket Int [Peer]
             -> IO ()
addToKBucket peerR kbucket = do
  lp <- getDefaultNodeId kbucket
  case lp of
    Right localPeer -> do
      peerList <- getPeerList peerR kbucket
      case peerList of
        Right pl -> do
          let kb = getKbucket kbucket
          let peer       = fst $ getPeer peerR
              kbDistance = getKbIndex localPeer peer
          if peerR `elem` pl
            then H.insert kb kbDistance (pl ++ [peerR])
            else H.insert kb kbDistance [peerR]
        Left _ -> return ()
    Left _ -> return ()

-- | Removes a given peer from kbucket
removePeer :: Peer
           -> Kbucket Int [Peer]
           -> IO ()
removePeer peerR kbucket = do
  lp <- getDefaultNodeId kbucket
  case lp of
    Right localPeer -> do
      peerList <- getPeerList peerR kbucket
      case peerList of
        Right pl -> do
          let kb = getKbucket kbucket
              peer       = fst $ getPeer peerR
              kbDistance = getKbIndex localPeer peer
          if peerR `elem` pl
            then H.insert kb kbDistance (L.delete peerR pl)
            else H.insert kb kbDistance [peerR]
        Left _ -> return ()
    Left _ -> return ()

-- Gives a peer list given a list of keys
getPeerListFromKeyList :: Int
                       -> [Int]
                       -> Kbucket Int [Peer]
                       -> IO [Peer]
getPeerListFromKeyList _ [] _           = return []
getPeerListFromKeyList 0 _ _            = return []
getPeerListFromKeyList k (x:xs) kbucket = do
  pl <- H.lookup (getKbucket kbucket) x
  let peerList = fromMaybe [] pl
      ple      = fst $ L.splitAt k peerList
  if L.length peerList >= k then return ple else do
      temp <- getPeerListFromKeyList (k- L.length ple) xs kbucket
      return $ ple ++ temp

-- | Gets k-closest peers to a given peeer if k-peer exist in kbukcet being
--   queried else returns all availaible peers.
getKClosestPeers :: Peer
                 -> Int
                 -> Kbucket Int [Peer]
                 -> IO (Either AriviException [Peer])
getKClosestPeers peerR k kbucket = do
  kvList <- H.toList (getKbucket kbucket)
  lp <- getDefaultNodeId kbucket
  case lp of
    Right localPeer -> do
      let peer = fst $ getPeer peerR
          kbi  = getKbIndex localPeer peer
          keys = L.sort $ fmap fst kvList
      peerl <- getPeerListFromKeyList k keys kbucket
      return (Right peerl)
    Left x  -> return (Left x)


getKRandomPeers :: Peer
                -> Int
                -> Kbucket Int [Peer]
                -> IO [Peer]
getKRandomPeers peerR k kbucket = do
  keyl <- U.randomList k
  getPeerListFromKeyList k keyl kbucket