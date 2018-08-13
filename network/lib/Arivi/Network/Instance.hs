{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Arivi.Network.Instance
    ( openConnection
    ) where

import Arivi.Env
import Arivi.Network.Connection as Conn
import Arivi.Network.ConnectionHandler
import Arivi.Network.Exception
import Arivi.Network.Handshake
import Arivi.Network.StreamClient
import Arivi.Network.Types as ANT
    ( ConnectionHandle(..)
    , NodeId
    , PersonalityType(..)
    , TransportType(..)
    )
import Arivi.Utils.Logging
import Arivi.Utils.Statsd
import Control.Exception (try)

import Control.Monad.Reader
import Crypto.PubKey.Ed25519 (SecretKey)
import Data.HashMap.Strict as HM
import Data.IORef
import Data.Time.Clock
import Data.Time.Units
import Network.Socket
import Text.InterpolatedString.Perl6

doEncryptedHandshake ::
       Conn.IncompleteConnection -> SecretKey -> IO Conn.CompleteConnection
doEncryptedHandshake connection sk = do
    (ephemeralKeyPair, serialisedParcel) <- initiatorHandshake sk connection
    sendFrame
        (Conn.waitWrite connection)
        (Conn.socket connection)
        (frame serialisedParcel)
    hsRespParcel <-
        appropos (Conn.waitWrite connection) (Conn.socket connection)
    return $ receiveHandshakeResponse connection ephemeralKeyPair hsRespParcel
  where
    frame msg =
        case transportType connection of
            TCP -> createFrame msg
            UDP -> msg
    appropos =
        case transportType connection of
            TCP -> readHandshakeRespSock
            UDP -> readUdpHandshakeRespSock

openConnection ::
       forall m. (HasLogging m, HasSecretKey m, HasStatsdClient m)
    => HostName
    -> PortNumber
    -> TransportType
    -> NodeId
    -> m (Either AriviNetworkException ConnectionHandle)
openConnection host portNum tt rnId = do
    rethandle <-
        $(withLoggingTH)
            (LogNetworkStatement [qc|Opening Connection to host {host} |])
            LevelDebug $ do
            let cId = makeConnectionId host portNum tt
            sock <- liftIO $ createSocket host (read (show portNum)) tt
            conn <-
                liftIO $
                mkIncompleteConnection cId rnId host portNum tt INITIATOR sock 2
            case tt of
                TCP -> openTcpConnection conn
                UDP -> openUdpConnection conn
    incrementCounter "Connection Established"
    return rethandle

openTcpConnection ::
       forall m. (MonadIO m, HasLogging m, HasSecretKey m, HasStatsdClient m)
    => Conn.IncompleteConnection
    -> m (Either AriviNetworkException ConnectionHandle)
openTcpConnection conn = do
    sk <- getSecretKey
    incrementCounter "Outgoing handshake attempted"
    initTime <- liftIO getCurrentTime
    res <- liftIO $ try $ doEncryptedHandshake conn sk
    fragmentsHM <- liftIO $ newIORef HM.empty
    case res of
        Left e -> return $ Left e
        Right updatedConn -> do
            finalTime <- liftIO getCurrentTime
            time
                "Connection establishment time"
                (convertUnit
                     (read (show (diffUTCTime finalTime initTime)) :: Second) :: Millisecond)
            incrementCounter "Outgoing handshake completed"
            return . Right $
                ConnectionHandle
                    { ANT.send = sendTcpMessage updatedConn
                    , ANT.recv = readTcpSock updatedConn fragmentsHM
                    , ANT.close = closeConnection (Conn.socket updatedConn)
                    }

openUdpConnection ::
       (MonadIO m, HasLogging m, HasSecretKey m)
    => Conn.IncompleteConnection
    -> m (Either AriviNetworkException ConnectionHandle)
openUdpConnection conn = do
    sk <- getSecretKey
    res <- liftIO $ try $ doEncryptedHandshake conn sk
    case res of
        Left e -> return $ Left e
        Right updatedConn ->
            return . Right $
            ConnectionHandle
                { ANT.send = sendUdpMessage updatedConn
                , ANT.recv = readUdpSock updatedConn
                , ANT.close = closeConnection (Conn.socket updatedConn)
                }
