{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE KindSignatures            #-}
{-# LANGUAGE NamedFieldPuns            #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TypeApplications          #-}

-- | Implementation of 'ConnectionHandler'
--
module Ouroboros.Network.MuxConnectionHandler
  ( MuxHandle (..)
  , MuxConnectionHandler
  , makeMuxConnectionHandler
  , MuxConnectionManager
  -- * tracing
  , ConnectionHandlerTrace (..)
  ) where

import           Control.Exception (SomeAsyncException)
import           Control.Monad (when)
import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadThrow
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import           Control.Tracer (Tracer, contramap, traceWith)

import           Data.ByteString.Lazy (ByteString)
import           Data.Typeable (Typeable)

import           Network.Mux hiding (miniProtocolNum)

import           Ouroboros.Network.Mux
import           Ouroboros.Network.Protocol.Handshake
import           Ouroboros.Network.ConnectionId (ConnectionId (..))
import           Ouroboros.Network.RethrowPolicy
import           Ouroboros.Network.ConnectionManager.Types

-- | We place an upper limit of `30s` on the time we wait on receiving an SDU.
-- There is no upper bound on the time we wait when waiting for a new SDU.
-- This makes it possible for miniprotocols to use timeouts that are larger
-- than 30s or wait forever.  `30s` for receiving an SDU corresponds to
-- a minimum speed limit of 17kbps.
--
-- ( 8      -- mux header length
-- + 0xffff -- maximum SDU payload
-- )
-- * 8
-- = 524_344 -- maximum bits in an SDU
--
--  524_344 / 30 / 1024 = 17kbps
--
sduTimeout :: DiffTime
sduTimeout = 30


-- | For handshake, we put a limit of `10s` for sending or receiving a single
-- `MuxSDU`.
--
sduHandshakeTimeout :: DiffTime
sduHandshakeTimeout = 10


-- | States of the connection handler thread.
--
-- * 'MuxRunning'      - sucessful Handshake, mux started
-- * 'MuxStopped'      - either mux was gracefully stopped (using 'Mux' or by
--                     'killThread'; the latter is done by
--                     'Ouoroboros.Network.ConnectinoManager.withConnectionManager')
-- * 'MuxPromiseHandshakeClientError'
--                     - the connection handler thread was running client side
--                     of the handshake negotiation, which failed with
--                     'HandshakeException'
-- * 'MuxPromiseHandshakeServerError'
--                     - the conneciton hndler thread was running server side
--                     of the handshake protocol, which faile with
--                     'HandshakeException'
-- * 'MuxPromiseError' - the multiplexer thrown 'MuxError'.
--
data MuxHandle (muxMode :: MuxMode) peerAddr verionNumber bytes m a b where
    MuxRunning
      :: forall muxMode peerAddr versionNumber bytes m a b.
         !(ConnectionId peerAddr)
      -> !versionNumber
      -> !(Mux muxMode m)
      -> !(MuxBundle muxMode bytes m a b)
      -> !(Bundle (StrictTVar m ControlMessage))
      -> MuxHandle muxMode peerAddr versionNumber bytes m a b

    MuxStopped
      :: MuxHandle muxMode peerAddr versionNumber bytes m a b

    MuxPromiseHandshakeClientError
     :: HasInitiator muxMode ~ True
     => !(HandshakeException (HandshakeClientProtocolError versionNumber))
     -> MuxHandle muxMode peerAddr versionNumber bytes m a b

    MuxPromiseHandshakeServerError
      :: HasResponder muxMode ~ True
      => !(HandshakeException (RefuseReason versionNumber))
      -> MuxHandle muxMode peerAddr versionNumber bytes m a b

    MuxPromiseError
     :: !SomeException
     -> MuxHandle muxMode peerAddr versionNumber bytes m a b

instance (Show peerAddr, Show versionNumber)
      => Show (MuxHandle muxMode peerAddr versionNumber bytes m a b) where
    show (MuxRunning connectionId versionNumber _ _ _) = "MuxRunning " ++ show connectionId ++ " " ++ show versionNumber
    show MuxStopped = "MuxStopped"
    show (MuxPromiseHandshakeServerError err) = "MuxPromiseHandshakeServerError " ++ show err
    show (MuxPromiseHandshakeClientError err) = "MuxPromiseHandshakeClientError " ++ show err
    show (MuxPromiseError err)                = "MuxPromiseError " ++ show err

-- | A predicate which returns 'True' if connection handler thread has stopped running.
--
isConnectionHandlerRunning :: MuxHandle muxMode peerAddr verionNumber bytes m a b -> Bool
isConnectionHandlerRunning muxPromise =
    case muxPromise of
      MuxRunning{}                     -> True
      MuxPromiseHandshakeClientError{} -> False
      MuxPromiseHandshakeServerError{} -> False
      MuxPromiseError{}                -> False
      MuxStopped                       -> False


-- | Type of 'ConnectionHandler' implemented in this module.
--
type MuxConnectionHandler muxMode peerAddr versionNumber bytes m a b =
    ConnectionHandler muxMode
                      (ConnectionHandlerTrace versionNumber)
                      peerAddr
                      (MuxHandle muxMode peerAddr versionNumber bytes m a b)
                      m

-- | Type alias for 'ConnectionManager' using 'MuxPromise'.
--
type MuxConnectionManager muxMode socket peerAddr versionNumber bytes m a b =
    ConnectionManager muxMode socket peerAddr
                      (MuxHandle muxMode peerAddr versionNumber bytes m a b) m

-- | To be used as `makeConnectionHandler` field of 'ConnectionManagerArguments'.
--
-- Note: We need to pass `MiniProtocolBundle` what forces us to have two
-- different `ConnectionManager`s: one for `node-to-client` and another for
-- `node-to-node` connections.  But this is ok, as these resources are
-- independent.
--
makeMuxConnectionHandler
    :: forall peerAddr muxMode versionNumber extra agreedOptions m a b.
       ( MonadAsync m
       , MonadCatch m
       , MonadFork  m
       , MonadThrow (STM m)
       , MonadTime  m
       , MonadTimer m
       , MonadMask  m
       , Ord      versionNumber
       , Show     peerAddr
       , Typeable peerAddr
       )
    => Tracer m (WithMuxBearer (ConnectionId peerAddr) MuxTrace)
    -> SingInitiatorResponderMode muxMode
    -- ^ describe whether this is outbound or inbound connection, and bring
    -- evidence that we can use mux with it.
    -> MiniProtocolBundle muxMode
    -> HandshakeArguments (ConnectionId peerAddr) versionNumber extra m
                          (OuroborosBundle muxMode peerAddr ByteString m a b)
                          agreedOptions
    -> (versionNumber -> DataFlowType)
    -> (MuxHandle muxMode peerAddr versionNumber ByteString m a b -> m ())
    -- ^ This method allows to pass control over responders to the server (for
    -- outbound connections), see
    -- 'Ouroboros.Network.ConnectionManager.Server.ControlChannel.newOutboundConnection'.
    -> (ThreadId m, RethrowPolicy)
    -> MuxConnectionHandler muxMode peerAddr versionNumber ByteString m a b
makeMuxConnectionHandler muxTracer singMuxMode
                         miniProtocolBundle
                         handshakeArguments
                         dataFlowTypeFn
                         announceOutboundConnection
                         (mainThreadId, rethrowPolicy) =
    ConnectionHandler $
      case singMuxMode of
        SInitiatorMode          -> WithInitiatorMode          outboundConnectionHandler
        SResponderMode          -> WithResponderMode          inboundConnectionHandler
        SInitiatorResponderMode -> WithInitiatorResponderMode outboundConnectionHandler
                                                              inboundConnectionHandler
  where
    outboundConnectionHandler
      :: HasInitiator muxMode ~ True
      => ConnectionHandlerFn (ConnectionHandlerTrace versionNumber)
                             peerAddr
                             (MuxHandle muxMode peerAddr versionNumber ByteString m a b)
                             m
    outboundConnectionHandler
        muxPromiseVar
        tracer
        connectionId@ConnectionId { remoteAddress }
        muxBearer =
          Action {
              action       = outboundAction,
              errorHandler = exceptionHandling tracer muxPromiseVar remoteAddress OutboundError
            }
      where
        outboundAction = do
          hsResult <- runHandshakeClient (muxBearer sduHandshakeTimeout)
                                         connectionId
                                         handshakeArguments
          case hsResult of
            Left !err -> do
              atomically $ writeTVar muxPromiseVar (Promised (MuxPromiseHandshakeClientError err))
              traceWith tracer (ConnectionHandlerHandshakeClientError err)
            Right (app, versionNumber, _agreedOptions) -> do
              traceWith tracer ConnectionHandlerHandshakeSuccess
              !controlMessageVarBundle
                <- (\a b c -> Bundle (WithHot a) (WithWarm b) (WithEstablished c))
                    <$> newTVarIO Continue
                    <*> newTVarIO Continue
                    <*> newTVarIO Continue
              let muxApp
                    = mkMuxApplicationBundle
                        connectionId
                        (readTVar <$> controlMessageVarBundle)
                        app
              !mux <- newMux miniProtocolBundle
              let muxPromise =
                    MuxRunning
                      connectionId versionNumber mux
                      muxApp controlMessageVarBundle
              atomically $ writeTVar muxPromiseVar (Promised muxPromise)

              -- For outbound connections we need to on demand start receivers.
              -- This is, in a sense, a no man land: the server will not act, as
              -- it's only reacting to inbound connections, and it also does not
              -- belong to initiator (peer-2-peer governor).
              case (singMuxMode, dataFlowTypeFn versionNumber) of
                (SInitiatorResponderMode, DuplexDataFlow) ->
                  announceOutboundConnection muxPromise
                _ -> pure ()

              runMux (WithMuxBearer connectionId `contramap` muxTracer)
                     mux (muxBearer sduTimeout)


    inboundConnectionHandler
      :: HasResponder muxMode ~ True
      => ConnectionHandlerFn (ConnectionHandlerTrace versionNumber)
                             peerAddr
                             (MuxHandle muxMode peerAddr versionNumber ByteString m a b)
                             m
    inboundConnectionHandler muxPromiseVar tracer connectionId@ConnectionId { remoteAddress } muxBearer =
          Action {
              action       = inboundAction,
              errorHandler = exceptionHandling tracer muxPromiseVar remoteAddress InboundError
            }
      where
        inboundAction = do
          hsResult <- runHandshakeServer (muxBearer sduHandshakeTimeout)
                                         connectionId
                                         (\_ _ _ -> Accept) -- we accept all connections
                                         handshakeArguments
          case hsResult of
            Left !err -> do
              atomically $ writeTVar muxPromiseVar (Promised (MuxPromiseHandshakeServerError err))
              traceWith tracer (ConnectionHandlerHandshakeServerError err)
            Right (app, versionNumber, _agreesOptions) -> do
              traceWith tracer ConnectionHandlerHandshakeSuccess
              !controlMessageVarBundle
                <- (\a b c -> Bundle (WithHot a) (WithWarm b) (WithEstablished c))
                    <$> newTVarIO Continue
                    <*> newTVarIO Continue
                    <*> newTVarIO Continue
              let muxApp
                    = mkMuxApplicationBundle
                        connectionId
                        (readTVar <$> controlMessageVarBundle)
                        app
              !mux <- newMux miniProtocolBundle
              atomically $ writeTVar muxPromiseVar
                            (Promised
                              (MuxRunning connectionId
                                          versionNumber
                                          mux
                                          muxApp
                                          controlMessageVarBundle))
              runMux (WithMuxBearer connectionId `contramap` muxTracer)
                         mux (muxBearer sduTimeout)

    -- minimal error handling, just to make adequate changes to
    -- `muxPromiseVar`; Classification of errors is done by
    -- 'withConnectionManager' when the connection handler thread is started..
    exceptionHandling :: forall x.
                         Tracer m (ConnectionHandlerTrace versionNumber)
                      -> StrictTVar m
                           (Promise
                             (MuxHandle muxMode peerAddr versionNumber ByteString m a b))
                      -> peerAddr
                      -> ErrorContext
                      -> m x -> m x
    exceptionHandling tracer muxPromiseVar remoteAddress errorContext io =
      -- handle non-async exceptions
      catchJust
        (\e -> case fromException e :: Maybe SomeAsyncException of
                Just _ -> Nothing
                Nothing -> Just e)
        io
        (\e -> do
          atomically (writeTVar muxPromiseVar (Promised (MuxPromiseError e)))
          let errorCommand = runRethrowPolicy rethrowPolicy errorContext e
          traceWith tracer (ConnectionHandlerError errorCommand errorContext e)
          case errorCommand of
            ShutdownNode -> throwTo mainThreadId (ExceptionInHandler remoteAddress e)
                         >> throwIO e
            ShutdownPeer -> throwIO e)
      -- the default for normal exit and unhandled error is to write
      -- `MusStopped`, but we don't want to override handshake errors.
      `finally` do
        atomically $ do
          st <- readTVar muxPromiseVar
          when (case st of
                  Promised muxPromise -> isConnectionHandlerRunning muxPromise
                  Empty -> True)
            $ writeTVar muxPromiseVar (Promised MuxStopped)


--
-- Tracing
--


-- | 'ConnectionHandlerTrace' is embedded into 'ConnectionManagerTrace' with
-- 'Ouroboros.Network.ConnectionMamanger.Types.ConnectionHandlerTrace'
-- constructor.  It already includes 'ConnectionId' so we don't need to take
-- care of it here.
--
-- TODO: when 'Handshake' will get it's own tracer, independent of 'Mux', it
-- should be embedded into 'ConnectionHandlerTrace'.
--
data ConnectionHandlerTrace versionNumber =
      ConnectionHandlerHandshakeSuccess
    | ConnectionHandlerHandshakeClientError
        !(HandshakeException (HandshakeClientProtocolError versionNumber))
    | ConnectionHandlerHandshakeServerError
        !(HandshakeException (RefuseReason versionNumber))
    | ConnectionHandlerError !ErrorCommand !ErrorContext !SomeException
  deriving Show
