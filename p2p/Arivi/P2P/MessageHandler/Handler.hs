{-# LANGUAGE ScopedTypeVariables #-}

module Arivi.P2P.MessageHandler.Handler
    ( sendRequest
    , sendRequestforKademlia
    , newIncomingConnection
    , cleanConnection
    ) where

import qualified Data.ByteString as B (ByteString)
import Data.ByteString.Char8 as Char8 (pack, unpack)
import qualified Data.ByteString.Lazy as Lazy (ByteString, fromStrict, toStrict)
import Data.HashMap.Strict as HM
import Data.List.Split (splitOn)

import Data.Maybe
import qualified Data.UUID as UUID (toString)
import Data.UUID.V4 (nextRandom)

import Control.Concurrent (forkIO)
import qualified Control.Concurrent.Async as Async (async, race)
import qualified Control.Concurrent.Async.Lifted as LAsync (async)
import Control.Concurrent.Lifted (fork, threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Concurrent.STM.TQueue ()
import Control.Concurrent.STM.TVar ()
import Control.Exception (throw)

import qualified Control.Exception.Lifted as Exception (SomeException, try)
import Control.Monad (forever, unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans

import Codec.Serialise (deserialise, serialise)

import Arivi.Network (openConnection)
import Arivi.P2P.MessageHandler.HandlerTypes
import Arivi.P2P.P2PEnv
import Arivi.Utils.Exception
import Network.Socket (PortNumber)

-- | used by RPC and PubSub to send outgoing requests. This is a blocing call which returns the reply
sendRequest ::
       (HasP2PEnv m) => NodeId -> MessageType -> P2PPayload -> m P2PPayload
sendRequest node mType p2pPayload = do
    nodeIdMapTVar <- getNodeIdPeerMapTVarP2PEnv
    newuuid <- liftIO getUUID
    mvar <- liftIO newEmptyMVar
    (connHandle, newFlag) <- getConnHandleFromNodeID node nodeIdMapTVar mType
    nodeIdMap <- liftIO $ readTVarIO nodeIdMapTVar
    let peerDetailsTVar = fromJust (HM.lookup node nodeIdMap)
    peerDetails <- liftIO $ readTVarIO peerDetailsTVar
    let uuidMapTVar = tvarUUIDMap peerDetails
    case newFlag of
        True -> do
            messageTypeMap <- getMessageTypeMapP2PEnv
            LAsync.async
                (readRequestThread connHandle uuidMapTVar messageTypeMap)
    liftIO $
        atomically
            (do uuidMap <- readTVar uuidMapTVar
                let newUUIDMAP = HM.insert newuuid mvar uuidMap
                writeTVar uuidMapTVar newUUIDMAP)
    let p2pMessage = generateP2PMessage mType p2pPayload newuuid
    res <- Exception.try $ send connHandle (serialise p2pMessage)
    case res of
        Left (e :: Exception.SomeException) -> do
            liftIO $ atomically (deleteUUID newuuid uuidMapTVar)
            throw e
        Right _ -> do
            winner <-
                liftIO $
                Async.race
                    (threadDelay 30000000) -- system.timeout
                    (takeMVar mvar :: IO P2PMessage)
            case winner of
                Left _ -> do
                    liftIO $ atomically (deleteUUID newuuid uuidMapTVar)
                    throw HandlerSendMessageTimeout
                Right (p2pReturnMessage :: P2PMessage) -> do
                    liftIO $ atomically (deleteUUID newuuid uuidMapTVar)
                    let returnMessage = payload p2pReturnMessage
                    return returnMessage

sendRequestforKademlia ::
       (HasP2PEnv m)
    => NodeId
    -> MessageType
    -> P2PPayload
    -> PortNumber
    -> IP
    -> m P2PPayload
sendRequestforKademlia node mType p2pPayload port ip = do
    nodeIdMapTVar <- getNodeIdPeerMapTVarP2PEnv
    nodeIdMap <- liftIO $ readTVarIO nodeIdMapTVar
    let maybePeer = HM.lookup node nodeIdMap
    if isNothing maybePeer -- concurrency issues might arise here need to check
        then do
            res <- openConnection ip port UDP node
            case res of
                Left e -> throw e
                Right connHandle -> do
                    liftIO $
                        addPeerFromConnection node UDP connHandle nodeIdMapTVar
                    newNodeIdMap <- liftIO $ readTVarIO nodeIdMapTVar
                    let peer = fromJust (HM.lookup node nodeIdMap)
                    peerDetails <- liftIO $ readTVarIO peer
                    let uuidMapTVar = tvarUUIDMap peerDetails
                    messageTypeMap <- getMessageTypeMapP2PEnv
                    readRequestThread connHandle uuidMapTVar messageTypeMap
                    sendRequest node mType p2pPayload
        else sendRequest node mType p2pPayload

readRequestThread ::
       (HasP2PEnv m)
    => ConnectionHandle
    -> TVar UUIDMap
    -> MessageTypeMap m
    -> m ()
readRequestThread connHandle uuidMapTVar messageTypeMap = do
    eitherByteMessage <- Exception.try $ recv connHandle
    case eitherByteMessage of
        Left (_ :: Exception.SomeException) -> return ()
        Right byteMessage -> do
            LAsync.async
                (processIncomingMessage
                     connHandle
                     uuidMapTVar
                     messageTypeMap
                     byteMessage)
            readRequestThread connHandle uuidMapTVar messageTypeMap

-- newConnectionHandler :: NodeId -> ConnectionHandle -> TransportType ->
newIncomingConnection ::
       (HasP2PEnv m) => NodeId -> ConnectionHandle -> TransportType -> m ()
newIncomingConnection nodeId connHandle transportType = do
    nodeIdMapTVar <- getNodeIdPeerMapTVarP2PEnv
    messageTypeMap <- getMessageTypeMapP2PEnv
    liftIO $ addPeerFromConnection nodeId transportType connHandle nodeIdMapTVar
    nodeIdMap <- liftIO $ readTVarIO nodeIdMapTVar
    peerDetails <- liftIO $ readTVarIO (fromJust (HM.lookup nodeId nodeIdMap))
    let uuidMapTVar = tvarUUIDMap peerDetails
    LAsync.async (readRequestThread connHandle uuidMapTVar messageTypeMap)
    return ()

cleanConnection ::
       (HasP2PEnv m) => NodeId -> ConnectionHandle -> TransportType -> m ()
cleanConnection nodeId connHandle transportType = do
    nodeIdMapTVar <- getNodeIdPeerMapTVarP2PEnv
    nodeIdMap <- liftIO $ readTVarIO nodeIdMapTVar
    let peerDetailsTVar = fromJust (HM.lookup nodeId nodeIdMap)
    liftIO $
        atomically
            (do peerDetails <- readTVar peerDetailsTVar
                let newPeerDetails =
                        case transportType of
                            UDP ->
                                case datagramHandle peerDetails of
                                    Connected _ ->
                                        peerDetails
                                            {datagramHandle = NotConnected}
                                    _ -> peerDetails
                            TCP ->
                                case streamHandle peerDetails of
                                    Connected _ ->
                                        peerDetails
                                            {streamHandle = NotConnected}
                                    _ -> peerDetails
                writeTVar peerDetailsTVar newPeerDetails)
    liftIO $ cleanPeer nodeId nodeIdMapTVar
    return ()

processIncomingMessage ::
       (HasP2PEnv m)
    => ConnectionHandle
    -> TVar UUIDMap
    -> MessageTypeMap m
    -> Lazy.ByteString
    -> m ()
processIncomingMessage connHandle uuidMapTVar messageTypeMap byteMessage = do
    let networkMessage = deserialise byteMessage :: P2PMessage
    uuidMap <- liftIO $ atomically (readTVar uuidMapTVar)
    let temp = HM.lookup (uuid networkMessage) uuidMap
    if isNothing temp
        then do
            response <-
                fromJust
                    (HM.lookup (messageType networkMessage) messageTypeMap)
                    (payload networkMessage)
            let p2pResponse =
                    generateP2PMessage
                        (messageType networkMessage)
                        response
                        (uuid networkMessage)
            res <- Exception.try $ send connHandle (serialise p2pResponse)
            case res of
                Left (e :: Exception.SomeException) -> return ()
                Right _ -> return ()
        else do
            let mVar = fromJust temp
            liftIO $ putMVar mVar networkMessage
            return ()

{-Support Functions===========================================================-}
-- | atomically checks for existing handle which is returned if it exists or else its status is changed to pending. then a new connection is established and it is stored as well as returned.
--
cleanPeer :: NodeId -> TVar NodeIdPeerMap -> IO ()
cleanPeer nodeId nodeIdMapTVar =
    atomically
        (do nodeIdMap <- readTVar nodeIdMapTVar
            let maybePeer = HM.lookup nodeId nodeIdMap
            when (isJust maybePeer) $ do
                let peerDetailsTVar = fromJust maybePeer
                peerDetails <- readTVar peerDetailsTVar
                case peerDetails of
                    PeerDetails node Nothing Nothing Nothing Nothing NotConnected NotConnected _ -> do
                        let newnodeIdMap = HM.delete nodeId nodeIdMap
                        writeTVar nodeIdMapTVar newnodeIdMap)

getConnectionHandle ::
       (HasP2PEnv m)
    => TVar PeerDetails
    -> TransportType
    -> m (ConnectionHandle, Bool)
getConnectionHandle peerDetailsTVar transportType = do
    peerDetails <- liftIO $ readTVarIO peerDetailsTVar
    let connMaybe =
            if transportType == TCP
                then streamHandle peerDetails
                else datagramHandle peerDetails
    case connMaybe of
        NotConnected -> do
            check <-
                liftIO $
                atomically
                    (changeConnectionStatus peerDetailsTVar transportType)
            if check
                then do
                    res <-
                        openConnection
                            (fromJust (ip peerDetails))
                            (if transportType == TCP
                                 then fromJust (tcpPort peerDetails)
                                 else fromJust (udpPort peerDetails))
                            transportType
                            (nodeId peerDetails)
                    case res of
                        Left e -> throw e
                        Right connHandle -> do
                            liftIO $
                                atomically
                                    (do oldPeerDetails <-
                                            readTVar peerDetailsTVar
                                        let newPeerDetails =
                                                if transportType == TCP
                                                    then oldPeerDetails
                                                             { streamHandle =
                                                                   Connected
                                                                       { connId =
                                                                             connHandle
                                                                       }
                                                             }
                                                    else oldPeerDetails
                                                             { datagramHandle =
                                                                   Connected
                                                                       { connId =
                                                                             connHandle
                                                                       }
                                                             }
                                        writeTVar peerDetailsTVar newPeerDetails)
                            return (connHandle, True)
                else getConnectionHandle peerDetailsTVar transportType
        Pending -> do
            liftIO $ threadDelay 3000 --should depend on avg time to open connection
            getConnectionHandle peerDetailsTVar transportType
        Connected connHandle -> return (connHandle, False)

-- | if connhandle is NotConnected then change it to Pending. Should be done atomically
changeConnectionStatus :: TVar PeerDetails -> TransportType -> STM Bool
changeConnectionStatus peerDetailsTVar transportType = do
    peerDetails <- readTVar peerDetailsTVar
    let connCheck =
            if transportType == TCP
                then streamHandle peerDetails
                else datagramHandle peerDetails
    if connCheck == NotConnected
        then do
            let newPeerDetails =
                    if transportType == TCP
                        then peerDetails {streamHandle = Pending}
                        else peerDetails {datagramHandle = Pending}
            writeTVar peerDetailsTVar newPeerDetails
            return True
        else return False

-- | delete an uuid entry from the map
deleteUUID :: P2PUUID -> TVar UUIDMap -> STM ()
deleteUUID uuid uuidMapTVar = do
    a <- readTVar uuidMapTVar
    let b = HM.delete uuid a
    writeTVar uuidMapTVar b

-- | get connection handle for the specific nodeID and mesaage type from the hashmap
getConnHandleFromNodeID ::
       (HasP2PEnv m)
    => NodeId
    -> TVar NodeIdPeerMap
    -> MessageType
    -> m (ConnectionHandle, Bool)
getConnHandleFromNodeID node nodeIdMapTVar mType = do
    nodeIdMap <- liftIO $ readTVarIO nodeIdMapTVar
    let peerDetailsTVar = fromJust (HM.lookup node nodeIdMap)
    getConnectionHandle
        peerDetailsTVar
        (if mType == RPC
             then TCP
             else UDP)

-- | wraps the payload with message type { Kademlia | RPC | PubSub} and UUID
generateP2PMessage :: MessageType -> P2PPayload -> P2PUUID -> P2PMessage
generateP2PMessage mType message uuid1 =
    P2PMessage {uuid = uuid1, messageType = mType, payload = message}

getUUID :: IO P2PUUID
getUUID = UUID.toString <$> nextRandom

-- | function for adding peer from a particular connectionhandle
addPeerFromConnection ::
       NodeId
    -> TransportType
    -> ConnectionHandle
    -> TVar NodeIdPeerMap
    -> IO ()
addPeerFromConnection node transportType connHandle nodeIdPeerMapTVar = do
    uuidMapTVar <- newTVarIO HM.empty
    atomically
        (do nodeIdPeerMap <- readTVar nodeIdPeerMapTVar
            let mapEntry = HM.lookup node nodeIdPeerMap
            peerDetails <-
                maybe
                    (do let newDetails =
                                PeerDetails
                                    { nodeId = node
                                    , rep = Nothing
                                    , ip = Nothing
                                    , udpPort = Nothing
                                    , tcpPort = Nothing
                                    , streamHandle = NotConnected
                                    , datagramHandle = NotConnected
                                    , tvarUUIDMap = uuidMapTVar
                                    }
                        peerTVar <- newTVar newDetails
                        readTVar peerTVar)
                    readTVar
                    mapEntry
            let newPeerDetails =
                    if transportType == TCP
                        then peerDetails
                                 { streamHandle =
                                       Connected {connId = connHandle}
                                 }
                        else peerDetails
                                 { datagramHandle =
                                       Connected {connId = connHandle}
                                 }
            newPeerTvar <- newTVar newPeerDetails
            let newHashMap = HM.insert node newPeerTvar nodeIdPeerMap
            writeTVar nodeIdPeerMapTVar newHashMap)
{-Dummy Functions========================================================-}
-- selfNodeId :: NodeId
-- selfNodeId = pack "12334556"
-- getNewConnection :: IO (NodeId, ConnectionHandle, TransportType)
-- getNewConnection = return (pack "DSGNO", pack "892sadasd346384", UDP)
-- openConnection :: NodeId -> IP -> PortNumber -> TransportType -> IO ConnectionHandle
-- openConnection nodeId ip port transportType = return (pack "892sadasd346384")
-- sendMessage :: ConnectionHandle -> Char8.ByteString -> IO ()
-- sendMessage connectionId byteString = return ()
-- readMessage :: ConnectionHandle -> IO ByteString
-- readMessage connId =
--     Lazy.toStrict .
--     serialise . generateP2PMessage Kademlia (pack "892sadasd346384") <$>
--     getUUID
