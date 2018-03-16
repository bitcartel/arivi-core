{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE MagicHash #-}

module Kademlia.Node
  ( runUDPServerForever,
    messageHandler,
    loadDefaultPeers,
    networkClient,
    addToKbChan,
    -- refreshKbucket
  ) where

import           Control.Concurrent        (forkIO, newChan, newEmptyMVar,
                                            putMVar, readChan, takeMVar,
                                            threadDelay, writeChan,isEmptyChan,Chan,ThreadId)
import           Control.Monad             (forever)
import qualified Data.ByteString.Char8     as C
import           Network.Socket            hiding (recv)
import qualified Network.Socket.ByteString as N (recv, recvFrom, sendAll,
                                                 sendAllTo, sendTo)
import           Control.Concurrent.Async
import           System.Environment
import           System.Random             (randomRIO)
import qualified Data.Map.Strict           as Map 
import           Data.Maybe 
import           System.Random
import           Data.Word 
import           Kademlia.Utils              
import qualified Kademlia.Types as T 

import           Codec.Serialise
import           Codec.Serialise.Encoding
import           Codec.Serialise.Decoding
import           Codec.Serialise.Class
import           Data.Time.Clock.POSIX 
import           Data.Time.Clock   
import           Crypto.PubKey.Ed25519
import qualified Data.ByteString.Lazy as LBS 

import Crypto.Util 
import GHC.Integer.Logarithms
import GHC.Exts
import Data.ByteString.Base16 as H 
import Data.ByteArray 
import Control.Concurrent.STM.TChan
import Control.Monad.STM 
import Control.Monad 

import Crypto.Utils.Keys.Signature 
import qualified Kademlia.Query as Q 


extractDistance :: T.NodeId 
                -> (T.NodeId,T.NodeEndPoint) 
                -> ((T.NodeId,T.NodeEndPoint),Int) 

extractDistance localNodeId x  = (((fst x),(snd x)),kbi)   
    where temp = (fst x)     :: PublicKey 
          nid  = localNodeId :: PublicKey 
          dis  = Data.ByteArray.xor temp nid :: C.ByteString 
          kbi  = I# (integerLog2# (bs2i dis)) 

-- Process all the incoming messages to server and write the response to outboundChan 
-- whenever a findNode message is recieved it write that peer to peerChan  
messageHandler :: T.NodeId  
               -> SecretKey
               -> TChan (SockAddr,Socket)
               -> TChan (T.PayLoad,SockAddr,SockAddr,Socket) 
               -> TChan (T.PayLoad,SockAddr,Socket) 
               -> TChan ((T.NodeId,T.NodeEndPoint),Int) 
               -> TChan (Map.Map Int [(T.NodeId,T.NodeEndPoint)])
               -> Int            
               -> Int                           
               -> IO ThreadId                   

messageHandler nodeId sk servChan inboundChan outboundChan peerChan kbChan k workerId = forkIO $ forever $ do
    msg <- atomically $ readTChan inboundChan
    let incMsg = extractFirst2 msg
        socka  = extractThird2 msg 
    -- handles the case when message type is MSG01 i.e PING 

    case (T.messageType (T.message (incMsg)))  of 
        (T.MSG01) -> do   
            let payl = T.packPong nodeId sk socka (1)     
            atomically $ writeTChan outboundChan (payl,extractSecond2 msg,extractFourth msg)
       
        -- handles the case when message type is MSG02 i.e PONG
        (T.MSG02) -> do 
            let payl = T.packPing nodeId sk socka (1) 
            atomically $ writeTChan outboundChan (payl,extractSecond2 msg,extractFourth msg)

        -- handles the case when message type is MSG03 i.e FIND_NODE
        -- Adds peer issuing FIND_NODE to it's appropriate k-bucket 
        (T.MSG03) -> do
            let nId     = T.nodeId (T.messageBody(T.message (incMsg)))
                nIdPk   = nId :: PublicKey 
                dis     = ((Data.ByteArray.xor nId nodeId) :: C.ByteString)
                kbi     = I# (integerLog2# (bs2i dis))
                nep     = T.fromEndPoint (T.messageBody(T.message (incMsg)))
            atomically $ writeTChan peerChan ((nId,nep),kbi)

            -- Queries k-buckets and send k-closest buckets 
            let localSock   = extractThird2 msg 
                remoteSock  = extractSecond2 msg  
                localSocket = extractFourth msg 
            threadDelay 1000
            Q.queryKBucket nodeId nId k kbChan outboundChan localSock remoteSock localSocket sk 
        
        -- handles the case when message type is MSG04 i.e FN_RESP
        (T.MSG04) -> do   
            let nId     = T.nodeId (T.messageBody(T.message (incMsg)))
                nep     = T.fromEndPoint (T.messageBody(T.message (incMsg)))
                plist   = T.peerList (T.messageBody(T.message (incMsg)))
                nIdPk   = nId :: PublicKey 
                kbil    = map (extractDistance nodeId) plist    
            atomically $ mapM_ (writeTChan peerChan) (kbil)

-- Sends the message written by outboundChan to remote Client 
networkClient :: TChan (T.PayLoad,SockAddr,Socket) 
              -> Int 
              -> IO ThreadId
              
-- responsible for reading outboundChan and sending the contents to mentioned address 
networkClient outboundChan workerId = forkIO $ forever $ do 
    msg <- atomically $ readTChan outboundChan
    let pl           = serialise (extractFirst msg) 
    
    N.sendTo (extractThird msg) (LBS.toStrict pl) (extractSecond msg)
      
-- Runs on a seperate thread & and is responsible for writing to kbChan   
addToKbChan :: TChan (Map.Map Int [(T.NodeId,T.NodeEndPoint)]) 
            -> TChan ((T.NodeId,T.NodeEndPoint),Int) 
            -> Int 
            -> IO ThreadId 

addToKbChan kbChan peerChan workerId = forkIO $ forever $ do
    msg <- atomically $ readTChan peerChan 
    rl <- atomically $ isEmptyTChan kbChan 
    let temp4 = fst msg      
    
    case rl of 
        True -> do 
            let temp  = Map.empty 
                temp2 = Map.insert (snd msg) (temp4 : []) temp  
            atomically $ writeTChan kbChan temp2
            print temp2
            putStrLn ""
            
        False -> do 
                kb  <- atomically $ readTChan kbChan 
                if (Map.lookup (snd msg) kb == Nothing)
                    then do
                        let temp = Map.insert (snd msg) (temp4:[]) kb 
                        atomically $ writeTChan kbChan temp 
                        print temp
                        putStrLn ""
                        
                    else do 
                        let temp    = Map.lookup (snd msg) kb 
                            temp2   = fromMaybe [] temp 
                        -- Checks if the nodeId already exists in the HashMap 
                        if (isNodeIdElem temp2 (fst temp4) == False)
                            then do 
                                let temp3   = temp2 ++ (temp4 : [])
                                    payLoad = Map.insert (snd msg) (temp3) kb   
                                atomically $ writeTChan kbChan payLoad
                                print payLoad 
                                putStrLn ""
                            else do 
                                let payLoad = Map.insert (snd msg) (temp2) kb   
                                atomically $ writeTChan kbChan payLoad
                                print payLoad 
                                putStrLn ""

                                                 
-- UDP server which is constantly listenting for requests
runUDPServerForever :: String 
                    -> String 
                    -> TChan(T.PayLoad,SockAddr,SockAddr,Socket) 
                    -> TChan (SockAddr,Socket) 
                    -> IO ()

runUDPServerForever local_ip local_port inboundChan servChan = do
    addrinfos <- getAddrInfo Nothing (Just local_ip) (Just local_port)
    let serveraddr = head addrinfos
    sock <- socket (addrFamily serveraddr) Datagram defaultProtocol
    bind sock (addrAddress serveraddr)
    atomically $ writeTChan servChan ((addrAddress serveraddr),sock) 

    print ("Server now listening for requests at : " ++ local_port)
    putStrLn ""
    forever $
         do
            (mesg, socaddr2) <- N.recvFrom sock 4096
            let remoteMsg = (deserialise (LBS.fromStrict $ mesg) :: T.PayLoad)
            atomically $ writeTChan inboundChan (remoteMsg,socaddr2,(addrAddress serveraddr),sock)
            
-- Load Default peers into kbChan i.e K-buckets 
loadDefaultPeers :: T.NodeId 
                 -> SecretKey
                 -> [SockAddr]
                 -> TChan (T.PayLoad,SockAddr,Socket) 
                 -> TChan ((T.NodeId,T.NodeEndPoint),Int) 
                 -> TChan (SockAddr,Socket) 
                 -> IO ()

loadDefaultPeers nodeId sk peerList outboundChan peerChan servChan = do 
    msg <- atomically $ readTChan servChan 

    let repl  = Prelude.replicate (Prelude.length peerList)
        socka = fst msg
        payl  = T.packFindMsg nodeId sk socka (1) nodeId 

    -- zip3 will produce [(T.PayLoad,SockAddr,Socket)]
    atomically $ mapM_ (writeTChan outboundChan) (zip3 (repl payl) peerList (repl (snd msg)))
    
    -- mapM_ (writeChan peerChan) (zip peerList (replicate (length peerList) 1))

addToPendingResChan :: TChan (T.PayLoad,T.NodeId,SockAddr,Socket)
                    -> TChan (Map.Map C.ByteString [(T.Sequence,T.TimeStamp)])
                    -> IO ThreadId 

addToPendingResChan prhChan pendingResChan = forkIO $ forever $ do 
    msg <- atomically $ readTChan prhChan 
    let recvdPayl   = extractFirst2 msg
        msgType     = T.messageType (T.message (recvdPayl))
        msgSeq      = T.sequence (T.message (recvdPayl))
        recvrNodeId = publicKeytoHex (extractSecond2 msg)
    
    rl <- atomically $ isEmptyTChan pendingResChan 
    ts <- T.getTimeStamp
    case rl of 
        True -> do 
            let temp  = Map.empty 
                temp2 = Map.insert recvrNodeId ((msgSeq,ts):[]) temp 
            atomically $ writeTChan pendingResChan temp2 

        False -> do 
            msg2 <- atomically $ peekTChan pendingResChan  
            case (Map.lookup (recvrNodeId) msg2) of 
                Nothing   -> do 
                    let temp3 = Map.insert recvrNodeId ((msgSeq,ts):[]) msg2 
                    atomically $ writeTChan pendingResChan temp3 

                otherwise -> do 
                    let temp4 = Map.lookup (recvrNodeId) msg2 
                        temp5 = fromMaybe [] temp4
                        temp6 = (msgSeq,ts) 
                        temp7 = Map.insert recvrNodeId (temp5 ++ (temp6:[])) msg2 
                    atomically $ writeTChan pendingResChan temp7 

removeFromPendingResChan :: (T.NodeId,T.Sequence,T.TimeStamp)
                         -> TChan (Map.Map C.ByteString [(T.Sequence,T.TimeStamp)])
                         -> IO Bool 
     
removeFromPendingResChan peerInfo pendingResChan = do 
    msg <- atomically $ peekTChan pendingResChan 

    let peerNodeId = publicKeytoHex (extractFirst peerInfo)
        msgSeq     = extractSecond peerInfo 
        ts         = extractThird peerInfo 
        seqList    = Map.lookup peerNodeId msg 
        
    case (seqList) of 
        Nothing   -> return False 

        otherwise -> do 
            let peerSeqList = fromMaybe [] seqList 
                peerTuple   = (msgSeq,ts)
            
            case (Prelude.elem peerTuple peerSeqList) of 
                True  -> do
                    let newMap = Map.delete peerNodeId msg 
                    atomically $ writeTChan pendingResChan newMap  
                    return True 
                False -> return (False)  


-- | sends PING         -> add to pendingResponse Chan  
-- | sends PONG         ->
-- | sends FIND_NODE    -> add to pendingResponse Chan 
-- | sends FN_RESP      -> 
    
-- | recieves PING       ->
-- | recieves PONG       -> check pendingResponse Chan, accept respons if matches ignore otherwise
-- | recieves FIND_NODE  -> 
-- | recieves FN_RESP    -> check pendingResponse Chan, accept respons if matches ignore otherwise