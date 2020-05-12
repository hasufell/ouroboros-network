{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- 'withInitiatorMode' has @HasInitiator muxMode ~ True@ constraint, which is
-- not redundant at all!  It limits case analysis.
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

-- | Connection manager core types.
--
-- Connection manager is responsible for managing uni- or bi-directional
-- connections and threads which are running network applications.  In
-- particular it is responsible for:
--
-- * opening new connection / reusing connections (for bidirectional
--   connections)
-- * running handshake negotation, starting the multiplexer
-- * error handling for connection threads
--
-- First and last tasks are implemented directly in
-- 'Ouroboros.Network.ConnectionManager.  Core' using the type interface
-- provided in this module.  The second task is delegated to
-- 'ConnectionHandler' (see
-- 'Ouroboros.Network.ConnectionManager.ConnectionHandler.makeConnectionHandler').
--
-- When a connection is included by either 'includeOutboundConnection' or
-- 'includeOutboundConnection', the connection manager returns an @STM@ action
-- which allows to await until the connection is ready (handshake negotation is
-- done and mux is started).  The @STM@ action returns
-- @'Promise' ('Ouroboros.Network.ConnectionManager.ConnectionHandler.MuxPromise' ...)@.
-- It gives access to 'Network.Mux.Mux' as well as 'ConnectionId',
-- negotiated application version and 'Ouroboros.Network.Mux.ControlMessage'
-- 'TVar's: all that is needed to manage all mini-protocols by either
-- "Ouroboros.Network.ConnectionManager.Server" or peer-2-peer governor
-- (see @withPeerStateActions@ in @ouroboros-network@ package).
--
-- To support bi-directional connections we need to be able to (on-demand)
-- start responder sides of mini-protocols on incoming connections.  The
-- interface to give control over bi-directional outbound connection to the
-- server is using an @STM@ queue (see 'ControlChannel') over which messages
-- are passed to the server.  The server runs a single thread which accepts
-- them and acts on them.
--
-- >   ┌────────────────────────────────┐                                          ┌───────────────────┐
-- >   │                                │                                          │                   │
-- >   │  includeInboundConnection      ├─────────────────────────────────────────▶│  PeerStateActions │
-- >   │   / includeOutboundConnection  │                                 ┏━━━━━━━▶│                   │
-- >   │                                ├──┐                              ┃        └───────────────────┘
-- >   └───────────────┬────────────────┘  │                              ┃
-- >                   │                   │                              ┃
-- >                   │                   │                              ┃
-- >                   │                   │                              ┃
-- >                   │                   │                              ┃
-- >                   ▼                   │                              ┃
-- >   ┌────────────────────────────────┐  │                              ┃
-- >   │                                │  │     ┏━━━━━━━━━━━━━━━━━━━━━━━━┻━┓
-- >   │      ConnectionHandler         │  │     ┃                          ┃
-- >   │                                ┝━━┿━━━━▶┃   'Promise' handle       ┃
-- >   │     inbound / outbound         │  │     ┃                          ┃
-- >   │                 ┃              │  │     ┗━┳━━━━━━━━━━━━━━━━━━━━━━━━┛
-- >   └─────────────────╂──────────────┘  │       ┃
-- >                     ┃                 │       ┃
-- >                     ▼                 │       ┃
-- >              ┏━━━━━━━━━━━━━━━━━┓      │       ┃
-- >              ┃ Control Channel ┃      │       ┃
-- >              ┗━━━━━━┳━━━━━━━━━━┛      │       ┃
-- >                     ┃                 │       ┃
-- >                     ┃                 │       ┃
-- >                     ▼                 │       ┃
-- >   ┌────────────────────────────────┐  │       ┃
-- >   │                                │◀─┘       ┃
-- >   │            Server              │          ┃
-- >   │                                │◀━━━━━━━━━┛
-- >   └────────────────────────────────┘
--
module Ouroboros.Network.ConnectionManager.Types
  ( -- * Connection manager core types
    Provenance (..)
  , Direction (..)
  , ConnectionHandler (..)
  , ConnectionHandlerFn
  , DataFlowType (..)
  , Action (..)
  , ConnectionManagerArguments (..)
  , AddressType (..)
    -- * 'ConnectionManager'
  , ConnectionManager (..)
  , InboundConnectionManager (..)
  , IncludeOutboundConnection
  , includeOutboundConnection
  , IncludeInboundConnection
  , includeInboundConnection
  , numberOfConnections
    -- * Exceptions
  , ExceptionInHandler (..)
  , ConnectionManagerError (..)
    -- * Mux types
  , WithMuxMode (..)
  , WithMuxTuple
  , withInitiatorMode
  , withResponderMode
  , SingInitiatorResponderMode (..)
    -- * Tracing
  , ConnectionManagerTrace (..)
   -- * Auxiliary types
  , Promise (..)
  ) where

import           Control.Exception ( Exception
                                   , SomeException )
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadTime (DiffTime)
import           Control.Tracer (Tracer)
import           Data.Typeable (Typeable)

import           Network.Mux.Types ( MuxBearer
                                   , MuxMode (..)
                                   , HasInitiator
                                   , HasResponder
                                   )
import           Network.Mux.Trace ( MuxTrace
                                   , WithMuxBearer )

import           Ouroboros.Network.ConnectionId (ConnectionId)
import           Ouroboros.Network.Snocket (Snocket)


-- | Each connection is is either initiated locally (outbound) or by a remote
-- peer (inbound).
--
data Provenance =
    --  | An inbound connection: one that was initiated by a remote peer.
    --
    Inbound

    -- | An outbound connection: one that was initiated by us.
    --
  | Outbound
  deriving (Eq, Show)


-- | Direction in which a connection is used.  This is fixed for connections
-- that negotiated 'UnidirectionalDataFlow', but might evolve for
-- 'DuplexDataFlow' ones.
--
data Direction =
    Unidirectional !Provenance
  | Duplex
  deriving (Eq, Show)

instance Semigroup Direction where
    Unidirectional Inbound  <> Unidirectional Inbound  = Unidirectional Inbound
    Unidirectional Outbound <> Unidirectional Outbound = Unidirectional Outbound

    Unidirectional Inbound  <> Unidirectional Outbound = Duplex
    Unidirectional Outbound <> Unidirectional Inbound  = Duplex

    Duplex <> _ = Duplex
    _ <> Duplex = Duplex

--
-- Mux types
--
-- TODO: find a better place for them, maybe 'Ouroboros.Network.Mux'
--

data WithMuxMode (muxMode :: MuxMode) a b where
    WithInitiatorMode          :: a -> WithMuxMode InitiatorMode a b
    WithResponderMode          :: b -> WithMuxMode ResponderMode a b
    WithInitiatorResponderMode :: a -> b -> WithMuxMode InitiatorResponderMode a b

type WithMuxTuple muxMode a = WithMuxMode muxMode a a

withInitiatorMode :: HasInitiator muxMode ~ True
                  => WithMuxMode muxMode a b
                  -> a
withInitiatorMode (WithInitiatorMode          a  ) = a
withInitiatorMode (WithInitiatorResponderMode a _) = a

withResponderMode :: HasResponder muxMode ~ True
                  => WithMuxMode muxMode a b
                  -> b
withResponderMode (WithResponderMode            b) = b
withResponderMode (WithInitiatorResponderMode _ b) = b


-- | Singletons for matching the 'muxMode'.
--
data SingInitiatorResponderMode (muxMode :: MuxMode) where
    SInitiatorMode          :: SingInitiatorResponderMode InitiatorMode
    SResponderMode          :: SingInitiatorResponderMode ResponderMode
    SInitiatorResponderMode :: SingInitiatorResponderMode InitiatorResponderMode


-- | Each connection get negotiate weather it's uni- or bi-directionalal.
--
data DataFlowType
    = UnidirectionalDataFlow
    | DuplexDataFlow
  deriving (Eq, Show)


-- | Promise is a strict version of 'Maybe'
--
data Promise a
    = Promised !a
    | Empty
  deriving Functor


-- | Split error handling from action.  The indentend usage is:
-- ```
-- \(Action action errorHandler) -> mask (errorHandler (unmask action))
-- ```
-- This allows to attach various error handlers to the action, e.g. both
-- `finally` and `catch`.
data Action m a = Action {
    action       :: m a,
    errorHandler :: m a -> m a
  }


-- | Action which is executed by thread designated for a given connection.
--
type ConnectionHandlerFn handlerTrace peerAddr handle m
     = StrictTVar m (Promise handle)
    -> Tracer m handlerTrace
    -> ConnectionId peerAddr
    -> (DiffTime -> MuxBearer m)
    -> Action m ()


newtype ConnectionHandler muxMode handlerTrace peerAddr handle m =
    ConnectionHandler
      (WithMuxTuple muxMode (ConnectionHandlerFn handlerTrace peerAddr handle m))

-- | Exception which where caught in the connection thread and were re-thrown
-- in the main thread by the 'rethrowPolicy'.
--
data ExceptionInHandler peerAddr where
    ExceptionInHandler :: !peerAddr
                       -> !SomeException
                       -> ExceptionInHandler peerAddr
  deriving Typeable

instance   Show peerAddr => Show (ExceptionInHandler peerAddr) where
    show (ExceptionInHandler peerAddr e) = "ExceptionInHandler "
                                        ++ show peerAddr
                                        ++ " "
                                        ++ show e
instance ( Show peerAddr
         , Typeable peerAddr ) => Exception (ExceptionInHandler peerAddr)


data ConnectionManagerError peerAddr
  = ConnectionExistsError         !peerAddr !Direction

  -- | 'getConnectionMode' returned 'Nothing', which indicates either a mux or
  -- handshake error.  The handshake or mux error is reported / handled else
  -- where (by the thread owning the result of 'handle', e.g. server or
  -- peer state actions).
  --
  | ConnectionManagerPromiseError !peerAddr
  | ConnectionManagerInternalError !peerAddr
  deriving (Show, Typeable)

instance ( Show peerAddr
         , Typeable peerAddr ) => Exception (ConnectionManagerError peerAddr)

-- | Connection manager supports `IPv4` and `IPv6` addresses.
--
data AddressType = IPv4Address | IPv6Address
  deriving Show


-- | Assumptions \/ arguments for a 'ConnectionManager'.
--
-- Move to `Core`!
--
data ConnectionManagerArguments (muxMode :: MuxMode) handlerTrace socket peerAddr handle m =
    ConnectionManagerArguments {
        connectionManagerTracer      :: Tracer m (ConnectionManagerTrace peerAddr handlerTrace),

        -- | Mux trace.
        --
        connectionManagerMuxTracer   :: Tracer m (WithMuxBearer (ConnectionId peerAddr) MuxTrace),

        -- | Local @IPv4@ address of the connection manager.  If given, outbound
        -- connections to an @IPv4@ address will bound to it.
        --
        connectionManagerIPv4Address :: Maybe peerAddr,

        -- | Local @IPv6@ address of the connection manager.  If given, outbound
        -- connections to an @IPv6@ address will bound to it.
        --
        connectionManagerIPv6Address :: Maybe peerAddr,

        connectionManagerAddressType :: peerAddr -> Maybe AddressType,

        -- | Callback which runs in a thread dedicated for a given connection.
        --
        connectionHandler            :: ConnectionHandler muxMode handlerTrace peerAddr handle m,

        -- | Snocket for the 'socket' type.
        --
        connectionSnocket            :: Snocket m socket peerAddr,

        -- | 'handle' contains negotiated version information which allows us
        -- to decide which 'DataFlowType' is supported.  The 'handle' might
        -- also contain errors if negotiation failed, or starting mux failed,
        -- hence the result is a 'Maybe'.
        connectionDataFlow           :: handle -> Maybe DataFlowType
      }


type IncludeOutboundConnection        peerAddr handle m
    =           peerAddr -> m handle
type IncludeInboundConnection  socket peerAddr handle m
    = socket -> peerAddr -> m handle


-- | Inbound connection manager.  For a server implementation we also need to
-- know how many connections are now managed by the connection manager.
--
-- This type is an internal detail of 'Ouroboros.Network.ConnectionManager'
--
data InboundConnectionManager (muxMode :: MuxMode) socket peerAddr handle m where
    InboundConnectionManager
      :: HasResponder muxMode ~ True
      => { icmIncludeConnection   :: IncludeInboundConnection socket peerAddr handle m
         , icmNumberOfConnections :: STM m Int
         }
      -> InboundConnectionManager muxMode socket peerAddr handle m

-- | 'ConnectionManager'.
--
-- We identify resources (e.g. 'Network.Socket.Socket') by their address.   It
-- is enough for us to use just the remote address rather than connection
-- identifier, since we just need one connection towards that peer, even if we
-- are connected through multiple addresses.  It is safe to share a connection
-- manager with all the accepting sockets.
--
-- Explain `muxMode` here! Including examples!
--
newtype ConnectionManager (muxMode :: MuxMode) socket peerAddr handle m = ConnectionManager {
    getConnectionManager
      :: WithMuxMode muxMode (IncludeOutboundConnection                 peerAddr handle m)
                             (InboundConnectionManager  muxMode socket peerAddr handle m)
  }

--
-- ConnectionManager API
--

-- | Include outbound connection into 'ConnectionManager'.
--
includeOutboundConnection :: HasInitiator muxMode ~ True
                          => ConnectionManager muxMode socket peerAddr handle m
                          -> IncludeOutboundConnection        peerAddr handle m
includeOutboundConnection = withInitiatorMode . getConnectionManager

-- | Include an inbound connection into 'ConnectionManager'.
--
includeInboundConnection :: HasResponder muxMode ~ True
                         => ConnectionManager muxMode socket peerAddr handle m
                         -> IncludeInboundConnection  socket peerAddr handle m
includeInboundConnection =  icmIncludeConnection . withResponderMode . getConnectionManager

-- | Number of currently included connections.
--
-- Note: we count all connection: both inbound and outbound.  In a future
-- version we could count only inbound connections, but this will require
-- tracking state inside mux if the responder side has started running (through
-- on-demand interface).  This is currently not exposed by mux.
--
numberOfConnections :: HasResponder muxMode ~ True
                    => ConnectionManager muxMode socket peerAddr handle m
                    -> STM m Int
numberOfConnections = icmNumberOfConnections . withResponderMode . getConnectionManager

--
-- Tracing
--

-- | 'ConenctionManagerTrace' contains a hole for a trace of single connection
-- which is filled with 'ConnectionHandlerTrace'.
--
data ConnectionManagerTrace peerAddr a
  = IncludedConnection        !(ConnectionId peerAddr) !Direction
  | NegotiatedConnection      !(ConnectionId peerAddr) !Direction
  | ConnectTo                 !(Maybe peerAddr) !peerAddr
  | ConnectError              !(Maybe peerAddr) !peerAddr !SomeException
  | ReusedConnection          !peerAddr                !Direction
  | ConnectionFinished        !(ConnectionId peerAddr) !Direction
  | ErrorFromHandler          !(ConnectionId peerAddr) !SomeException
  | RethrownErrorFromHandler                           !(ExceptionInHandler peerAddr)
  | ConnectionHandlerTrace    !(ConnectionId peerAddr) !a
  | ShutdownConnectionManager
  | ConnectionExists          !(ConnectionId peerAddr) !Direction
  | ConnectionNotFound        !peerAddr !Direction
  deriving Show
