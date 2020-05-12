{-# LANGUAGE BangPatterns         #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE DeriveFoldable       #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE NamedFieldPuns       #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE RankNTypes           #-}
-- Undecidable instances are need for 'Show' instance of 'ConnectionState'.
{-# LANGUAGE UndecidableInstances #-}

-- | The implementation of connection manager's resource managment.
--
module Ouroboros.Network.ConnectionManager.Core
  ( withConnectionManager
  ) where

import           Control.Exception (assert)
import           Control.Monad (when, (<=<))
import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadThrow hiding (handle)
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Tracer (traceWith, contramap)
import           Data.Foldable (traverse_)
import           Data.Functor (($>))
import           Data.Proxy (Proxy (..))
import           Data.Typeable (Typeable)

import           Data.Map (Map)
import qualified Data.Map as Map

import           Network.Mux.Trace (WithMuxBearer (..))

import           Ouroboros.Network.ConnectionId
import           Ouroboros.Network.ConnectionManager.Types
import           Ouroboros.Network.Snocket


-- | Internal type to the 'ConnectionManager'; this the state the connection manager
-- keeps per peer.
--
data ConnectionState peerAddr handle m = ConnectionState {
      -- | A uniqe connection identifier.
      --
      csConnectionId :: ConnectionId peerAddr,

      -- | The connection manager shares a handle between inbound and
      -- outbound connections.
      --
      csHandleVar    :: !(StrictTVar m (Promise handle)),

      -- | Action which stop the connection.
      --
      csThread       :: !(Async m ()),

      -- | Internal state of the 'ConnectionHandle'.  It can be 'Inbound',
      -- 'Outbound' or 'Duplex'.
      --
      csDirection    :: !Direction

    }

instance ( Show peerAddr
         , Show (ThreadId m)
         , MonadAsync m 
         ) => Show (ConnectionState peerAddr handle m) where
    show ConnectionState { csConnectionId, csThread, csDirection } =
      concat
        [ "ConnectionState ("
        , show csConnectionId
        , ") ("
        , show (asyncThreadId (Proxy :: Proxy m) csThread)
        , ") ("
        , show csDirection
        , ")"
        ]


data ConnectionType connectionState
    -- | Handshake negotiated a duplex connection.
    --
    = DuplexConnection          !connectionState

    -- | An inbound connection, might not be yet negotiated.  If negotiated
    -- then it s unidirectional.
    --
    | InboundConnection         !connectionState

    -- | An outbound connection, might not be yet negotiated.  If negotiated
    -- then it is unidirectional.
    --
    | OutboundConnection        !connectionState

    -- | When we include a unidirectional connection when the other side alrady
    -- exists we need to track both of them.  Neither of them could be not yet
    -- negotiated.
    --
    | InboundOutboundConnection !connectionState
                                !connectionState

  deriving (Show, Foldable)


-- | Wedge product
-- <https://hackage.haskell.org/package/smash/docs/Data-Wedge.html#t:Wedge> 
--
data Wedge a b =
    Nowhere
  | Here a
  | There b

-- | 'ConnectionManager' state: for each peer we keep a 'ConnectionState'.
--
-- It is important we can lookup by remote @peerAddr@; this way we can find if
-- the connection manager is already managing a connection towards that
-- @peerAddr@ and reuse the 'ConnectionState'.
--
type ConnectionManagerState peerAddr handle m
  = Map peerAddr (ConnectionType (ConnectionState peerAddr handle m))


-- | Entry point for using the connection manager.  This is a classic @with@ style
-- combinator, which cleans resources on exit of the callback (whether cleanly
-- or through an exception).
-- 
-- Including a connection (either inbound or outbound) is an indepotent
-- operation on connection manager state.  The connection manager will always
-- return the handle that was first to be included in its state.
--
-- Once an inbound connection is passed to the 'ConnectionManager', the manager
-- is responsible for the resource.
--
withConnectionManager
    :: forall muxMode peerAddr socket handlerTrace handle m a.
       ( Monad             m
       -- We use 'MonadFork' to rethrow exceptions in the main thread.
       , MonadFork         m
       , MonadAsync        m
       , MonadEvaluate     m
       , MonadMask         m
       , MonadThrow   (STM m)

       , Ord      peerAddr
       , Show     peerAddr
       , Typeable peerAddr
       )
    => ConnectionManagerArguments muxMode handlerTrace socket peerAddr handle m
    -> (ConnectionManager         muxMode              socket peerAddr handle m -> m a)
    -- ^ Continuation which receives the 'ConnectionManager'.  It must not leak
    -- outside of scope of this callback.  Once it returns all resources
    -- will be closed.
    -> m a
withConnectionManager ConnectionManagerArguments {
                        connectionManagerTracer    = tracer,
                        connectionManagerMuxTracer = muxTracer,
                        connectionManagerIPv4Address,
                        connectionManagerIPv6Address,
                        connectionManagerAddressType,
                        connectionHandler,
                        connectionSnocket,
                        connectionDataFlow
                      } k = do
    stateVar <- newTMVarIO (Map.empty :: ConnectionManagerState peerAddr handle m)
    let connectionManager :: ConnectionManager muxMode socket peerAddr handle m
        connectionManager =
          case connectionHandler of
            ConnectionHandler (WithInitiatorMode outboundHandler) ->
              ConnectionManager
                (WithInitiatorMode
                  (includeOutboundConnectionImpl stateVar outboundHandler))

            ConnectionHandler (WithResponderMode inboundHandler) ->
              ConnectionManager
                (WithResponderMode
                  InboundConnectionManager {
                      icmIncludeConnection =
                        includeInboundConnectionImpl stateVar inboundHandler,
                      icmNumberOfConnections =
                        countConnections stateVar
                    })

            ConnectionHandler (WithInitiatorResponderMode outboundHandler inboundHandler) ->
              ConnectionManager
                (WithInitiatorResponderMode
                  (includeOutboundConnectionImpl stateVar outboundHandler)
                  InboundConnectionManager {
                      icmIncludeConnection =
                        includeInboundConnectionImpl stateVar inboundHandler,
                      icmNumberOfConnections =
                        countConnections stateVar
                    })

    k connectionManager
      `finally` do
        traceWith tracer ShutdownConnectionManager
        state <- atomically $ readTMVar stateVar
        traverse_
          (traverse_
            (\ConnectionState {  csThread }
              -- cleanup handler for that thread will close socket associated
              -- with the thread
              -> cancel csThread ))
          state
  where
    countConnections :: StrictTMVar m (ConnectionManagerState peerAddr handle m) -> STM m Int
    countConnections stateVar =
          Map.size
        . Map.filter
            -- count only inbound connections
            (\conn -> case conn of
              DuplexConnection ConnectionState { csDirection = Duplex }                  -> True
              DuplexConnection ConnectionState { csDirection = Unidirectional Inbound }  -> True
              DuplexConnection ConnectionState { csDirection = Unidirectional Outbound } -> False
              InboundConnection {}         -> True
              OutboundConnection {}        -> False
              InboundOutboundConnection {} -> True)
      <$> readTMVar stateVar


    -- Start connection thread and run connection handler on it.
    --
    runConnectionHandler :: StrictTMVar m (ConnectionManagerState peerAddr handle m)
                         -> ConnectionHandlerFn handlerTrace peerAddr handle m
                         -> Provenance
                         -- ^ initialt connection state
                         -> socket
                         -- ^ resource to include in the state
                         -> peerAddr
                         -> m (ConnectionState peerAddr handle m)
    runConnectionHandler stateVar handler provenance socket peerAddr = do
      localAddress <- getLocalAddr connectionSnocket socket
      let connectionId = ConnectionId { remoteAddress = peerAddr
                                      , localAddress
                                      }
          direction = Unidirectional provenance
      !handleVar <- newTVarIO Empty
      let cleanup =
            modifyTMVar_ stateVar $ \state' -> do
              close connectionSnocket socket

              case state' Map.! peerAddr of
                DuplexConnection ConnectionState { csDirection } -> do
                  traceWith tracer (ConnectionFinished connectionId csDirection)
                  pure $ Map.delete peerAddr state'

                InboundConnection ConnectionState {}
                  | provenance == Inbound
                  -> do
                    traceWith tracer (ConnectionFinished connectionId direction)
                    pure $ Map.delete peerAddr state'
                  | otherwise
                  -> pure state'

                OutboundConnection ConnectionState {}
                  | provenance == Outbound
                  -> do
                    traceWith tracer (ConnectionFinished connectionId direction)
                    pure $ Map.delete peerAddr state'
                  | otherwise
                  -> pure state'

                InboundOutboundConnection inbound outbound ->
                  case provenance of
                    Inbound -> do
                      traceWith tracer (ConnectionFinished connectionId direction)
                      pure $ Map.update (const (Just (OutboundConnection outbound))) peerAddr state'
                    Outbound -> do
                      traceWith tracer (ConnectionFinished connectionId direction)
                      pure $ Map.update (const (Just (InboundConnection inbound))) peerAddr state'

      case handler
            handleVar
            (ConnectionHandlerTrace connectionId `contramap` tracer)
            connectionId
            (\bearerTimeout ->
              toBearer
                connectionSnocket
                bearerTimeout
                (WithMuxBearer connectionId `contramap` muxTracer)
                socket) of
        Action action errorHandler -> do
          -- start connection thread
          thread <-
            mask $ \unmask ->
              async $ errorHandler (unmask action `finally` cleanup)
          traceWith tracer (IncludedConnection connectionId direction)
          return ConnectionState {
                  csConnectionId = connectionId,
                  csHandleVar    = handleVar,
                  csThread       = thread,
                  csDirection    = direction
              }


    -- Include a connection in the 'State'; we use this for both inbound and
    -- outbound (via 'includeOutboundConnection' below) connections.
    --
    -- This operation is idempotent.  If we try to include the connection to the
    -- same peer multiple times, it will also return the already existing handle
    -- and it will close the given one.  Why closing it here, and not by the
    -- caller? This makes it more homogeneus:  the connection mamanger is
    -- responsible for handling all connections weather included or not in
    -- its state.
    includeConnection
        :: StrictTMVar m (ConnectionManagerState peerAddr handle m)
        -> ConnectionHandlerFn handlerTrace peerAddr handle m
        -> Provenance
        -- ^ initialt connection state
        -> socket
        -- ^ resource to include in the state
        -> peerAddr
        -- ^ remote address used as an identifier of the resource
        -> m handle
    includeConnection stateVar
                      handler
                      provenance
                      socket
                      peerAddr =

        let -- update state for a connection which negotiated duplex data flow
            updateDuplexFn ::   Maybe (ConnectionType (ConnectionState peerAddr handle m))
                           -> ( Maybe Direction
                              , Maybe (ConnectionType (ConnectionState peerAddr handle m))
                              )
            updateDuplexFn Nothing  = (Nothing, Nothing)
            updateDuplexFn (Just c) =
              case c of
                DuplexConnection conn ->
                  let direction = csDirection conn <> Unidirectional provenance
                  in ( Just direction
                     , Just (DuplexConnection conn { csDirection = direction })
                     )
                InboundConnection conn ->
                  let direction = csDirection conn <> Unidirectional provenance
                  in ( Just direction
                     , Just (DuplexConnection conn { csDirection = direction })
                     )
                OutboundConnection conn ->
                  let direction = csDirection conn <> Unidirectional provenance
                  in ( Just direction
                     , Just (DuplexConnection conn { csDirection = direction })
                     )
                -- impossible case in our setup: this means that we have two
                -- connections with exactly the same connection ids.
                InboundOutboundConnection {} ->
                  ( Nothing
                  , Just c
                  )

            resolve :: (STM m handle, ConnectionId peerAddr) -> m handle
            resolve (stm, connectionId) = do
              (handle, mbDirection) <- atomically $ do
                -- await for handshake negotiation;  This is blocking only for
                -- connections that were not recorded by the connection mananger
                -- prior to calling `includeConnection`.
                handle <- stm
                -- classify the connection
                case connectionDataFlow handle of
                  Nothing ->
                    throwSTM (ConnectionManagerPromiseError peerAddr)

                  -- We don't need to update in 'UnidirectionalDataFlow', since
                  -- 'includeConnection' is using @Unidirectional provenance@,
                  -- see below.
                  Just UnidirectionalDataFlow ->
                    pure (handle, Just (Unidirectional provenance))

                  -- But if duplex connection was negotiated we need to update
                  -- the connection state.
                  Just DuplexDataFlow -> do
                    state <- takeTMVar stateVar
                    let (mbDirection, state') = Map.alterF updateDuplexFn peerAddr state
                    putTMVar stateVar state'
                    pure (handle, mbDirection)

              traverse_ (traceWith tracer . NegotiatedConnection connectionId)
                        mbDirection
              pure handle

        in
        either resolve pure <=< modifyTMVar stateVar $ \state ->
          let direction = Unidirectional provenance in
          case Map.lookup peerAddr state of

            -----------------
            -- New connection
            --

            Nothing -> do
              conn <- runConnectionHandler stateVar handler provenance socket peerAddr
              pure ( Map.insert peerAddr
                                (case provenance of
                                  Inbound  -> InboundConnection  conn
                                  Outbound -> OutboundConnection conn)
                                state
                   , Left ( handleSTM (csHandleVar conn)
                          , csConnectionId conn
                          )
                   )

            ----------------------
            -- Existing duplex connection
            --

            Just (DuplexConnection conn@ConnectionState { csConnectionId,
                                                          csDirection,
                                                          csHandleVar }) ->
              if   csDirection == Duplex
                || csDirection == direction
                then do
                  -- We are already running a connection in that direction.
                  -- There are two cases:
                  --
                  -- 1. for inbound connections: this means we've been contacted
                  --    twice from the same peer.  We might be using two ports (or
                  --    two addresses), and the other end didn't realised they lead
                  --    to the same peer.
                  -- 2. for outbound connections: this would be impossible,
                  --    rulled out by the kernel, since we bind outgonig
                  --    connections to a our inbound address.
                  --
                  close connectionSnocket socket
                  traceWith tracer (ConnectionExists csConnectionId direction)
                  throwIO (ConnectionExistsError peerAddr direction)
                else do
                  -- We have a duplex connection which can be used, we can
                  -- release the spare socket.
                  close connectionSnocket socket

                  pure ( Map.update (const (Just (DuplexConnection
                                                   conn { csDirection = Duplex })))
                                    peerAddr state
                       -- note: though we return stm action, it is guaranteed to
                       -- not block: 'DuplexConnection's must be negotiated.
                       , Left ( handleSTM csHandleVar
                              , csConnectionId
                              )
                       )

            Just (InboundConnection inbound@ConnectionState { csConnectionId,
                                                              csDirection,
                                                              csHandleVar }) ->
              assert (csDirection == Unidirectional Inbound) $ do
              when (provenance == Inbound) $
                throwIO (ConnectionExistsError peerAddr direction)
              promise <- fmap connectionDataFlow
                         <$> atomically (readTVar csHandleVar)
              case promise of
                    Empty ->
                      pure ( state
                           , Left ( handleSTM csHandleVar
                                  , csConnectionId
                                  )
                           )
                    Promised Nothing ->
                      -- 'Nothing' indicates that either handhsake or mux
                      -- errored before negotiation was done.
                      -- We don't need to close the socket nor we need to
                      -- update the state, this will be done by the error
                      -- handler attached to the connection thread.
                      throwIO (ConnectionManagerPromiseError peerAddr)

                    Promised (Just DuplexDataFlow) ->
                      pure ( Map.update (const (Just $ DuplexConnection inbound))
                                        peerAddr state
                             -- non-blocking, connection negotiation finished
                           , Left ( handleSTM csHandleVar
                                  , csConnectionId
                                  )
                           )

                    Promised (Just UnidirectionalDataFlow) -> do
                      -- todo: start the connection, update the state to
                      -- 'InboundOutboundConnection'
                      outbound@ConnectionState { csHandleVar = handleVar }
                        <- runConnectionHandler stateVar handler provenance socket peerAddr
                      pure ( Map.update (const (Just $ InboundOutboundConnection
                                                         inbound
                                                         outbound))
                                        peerAddr state
                           , Left ( handleSTM handleVar
                                  , csConnectionId
                                  )
                           )

            Just (OutboundConnection outbound@ConnectionState { csConnectionId,
                                                                csDirection,
                                                                csHandleVar }) ->
              assert (csDirection == Unidirectional Outbound) $ do
              when (provenance == Outbound) $
                throwIO (ConnectionExistsError peerAddr direction)
              promise <- atomically (readTVar csHandleVar)
              case promise of
                Empty ->
                  -- release the lock, return stm action to await on resolving
                  -- the promise.
                  pure ( state
                       , Left ( handleSTM csHandleVar
                              , csConnectionId
                              )
                       )

                Promised handle ->
                  case connectionDataFlow handle of
                    Nothing ->
                      -- 'Nothing' indicates that either handhsake or mux
                      -- errored before negotiation was done.  The socket will
                      -- be closed and the state will be updated by the
                      -- connection thread error handler.
                      throwIO (ConnectionManagerPromiseError peerAddr)

                    Just DuplexDataFlow ->
                      pure ( Map.update (const (Just $ DuplexConnection outbound)) peerAddr state
                           , Right handle
                           )

                    Just UnidirectionalDataFlow -> do
                      -- run connection  handler on the provided socket, return
                      -- stm action which allows to await for negotiation on
                      -- the new connection.
                      inbound@ConnectionState { csHandleVar = handleVar }
                        <- runConnectionHandler stateVar handler provenance socket peerAddr
                      pure ( Map.update (const (Just $ InboundOutboundConnection
                                                         inbound
                                                         outbound ))
                                        peerAddr state
                           , Left ( handleSTM handleVar
                                  , csConnectionId
                                  )
                           )

            Just InboundOutboundConnection {} -> 
              throwIO (ConnectionExistsError peerAddr direction)


    includeInboundConnectionImpl
        :: StrictTMVar m (ConnectionManagerState peerAddr handle m)
        -> ConnectionHandlerFn handlerTrace peerAddr handle m
        -> socket
        -- ^ resource to include in the state
        -> peerAddr
        -- ^ remote address used as an identifier of the resource
        -> m handle
    includeInboundConnectionImpl stateVar
                                 handler
                                 socket
                                 peerAddr = do
      let direction = Unidirectional Inbound
      mbMuxPromiseVar <-
        modifyTMVar stateVar $ \state ->
          case Map.lookup peerAddr state of
            -- How this case could happen?  We connected first and the
            -- connection turned out to be duplex.  Since in this case we bind
            -- to our local address, this means that the other end must have
            -- openned their connection towards us when it didn't yet had one,
            -- e.g. this must be a simultanous open.  Though for some reason
            -- the connection we openned is by now negotiated.  This is quite
            -- unlikely to happen in already rare case!
            --
            -- Note: even though we use multiple addresses, we use at most one
            -- ipv4 and at most one ipv6 address.
            Just (DuplexConnection conn@ConnectionState { csConnectionId,
                                                          csDirection,
                                                          csHandleVar }) ->
              case csDirection of
                Unidirectional Outbound -> do
                  let conn' = conn  { csDirection = Duplex }
                  pure ( Map.update (const (Just (DuplexConnection conn')))
                                    peerAddr state
                       , Just csHandleVar )

                -- @Unidirectional Outbound@ or @Duplex@
                _ -> do
                  close connectionSnocket socket
                  traceWith tracer (ConnectionExists csConnectionId direction)
                  throwIO (ConnectionExistsError peerAddr direction)

            -- Inbound connection already exists, this is impossible.
            Just (InboundConnection conn) -> do
              close connectionSnocket socket
              traceWith tracer (ConnectionExists (csConnectionId conn) direction)
              throwIO (ConnectionExistsError peerAddr direction)

            -- This is like the `DuplexConnection` case: a simultanous open but
            -- the connection is likely not yet negotiated.
            --
            Just (OutboundConnection outbound) -> do
              inbound <- runConnectionHandler stateVar handler Inbound socket peerAddr
              pure ( Map.update (const (Just (InboundOutboundConnection inbound outbound)))
                                peerAddr state
                   , Just (csHandleVar inbound) )

            -- Impossible case: inbound connection already exists, this would
            -- be forbidden by the kernel.
            Just (InboundOutboundConnection inbound _outbound) -> do
              close connectionSnocket socket
              traceWith tracer (ConnectionExists (csConnectionId inbound) direction)
              throwIO (ConnectionExistsError peerAddr direction)

            Nothing -> pure (state, Nothing)

      case mbMuxPromiseVar of
        Nothing -> do
          traceWith tracer (ConnectionNotFound peerAddr direction)
          includeConnection stateVar handler Inbound socket peerAddr

        Just handleVar -> do
          traceWith tracer (ReusedConnection peerAddr Duplex)
          atomically $ handleSTM handleVar



    includeOutboundConnectionImpl
        :: StrictTMVar m (ConnectionManagerState peerAddr handle m)
        -> ConnectionHandlerFn handlerTrace peerAddr handle m
        -> peerAddr
        -> m handle
    includeOutboundConnectionImpl stateVar handler peerAddr = do
        let direction = Unidirectional Outbound
        -- We progress in three steps:
        --
        -- 1. Check if we have an openned connection towards that peer.
        -- 2. If necessary await for `handle`.  This will block until
        --    handshake is done and mux is started.  At this point we will know
        --    weather we can use duplex connections or not.  If we can reuse
        --    the recorded connection return the resolved `handle`.
        -- 3. Otherwise, connect and try to include new socket using
        --    'includeConnection'.
        --
        -- In steps 1 and 3 we hold a lock on `state` in a non blocking
        -- way but is not the case for 2. During 2 the state could have
        -- changed, i.e. the peer might contacted us before we contacted them.
        -- Simultaneous open will not error on this level
        -- (though it will when running the handshake mini-protocol).
        --

        -- step 1. Check if we already have an existing connection.  Return
        -- 'Wedge' where 'There' represents the case in which we might need to
        -- block until handhshake is done.
        wMuxPromiseVar <-
          modifyTMVar stateVar $ \state ->
            case Map.lookup peerAddr state of
              Just (DuplexConnection conn@ConnectionState { csConnectionId,
                                                            csDirection,
                                                            csHandleVar }) ->
                  case csDirection of
                    Unidirectional Inbound -> do
                      let conn' = conn  { csDirection = Duplex }
                      pure ( Map.update (const (Just (DuplexConnection conn')))
                                        peerAddr state
                            -- 'Here' holds a non-blocking stm action
                           , Here csHandleVar )

                    -- `Unidirectional Outbound` or `Duplex`
                    _ -> do
                      traceWith tracer (ConnectionExists csConnectionId direction)
                      throwIO (ConnectionExistsError peerAddr direction)

              Just (InboundConnection conn) -> do
                pure ( state
                     -- 'There' might block
                     , There (csHandleVar conn) ) 

              Just (OutboundConnection outbound) -> do
                traceWith tracer (ConnectionExists (csConnectionId outbound) direction)
                throwIO (ConnectionExistsError peerAddr direction)

              Just (InboundOutboundConnection _inbound outbound) -> do
                traceWith tracer (ConnectionExists (csConnectionId outbound) direction)
                throwIO (ConnectionExistsError peerAddr direction)

              Nothing -> pure (state, Nowhere)


        -- step 2.  Await for resloving 'handle' (see 'There' case below).
        mbMuxPromiseVar <-
          case wMuxPromiseVar of
            Nowhere -> do
              traceWith tracer (ConnectionNotFound peerAddr direction)
              pure Nothing

            -- non-blocking case
            Here handleVar -> do
              traceWith tracer (ReusedConnection peerAddr Duplex)
              pure (Just handleVar)

            There handleVar -> do
              -- Possibly a blocking case, after resolving the promise we need
              -- to check the connection state again.
              --
              _ <- atomically $ handleSTM handleVar
              -- We don't need to access 'stateVar' in the same transaction as
              -- 'handleVar'.  Even if there were two racing threads at
              -- this point, atomicity of the following 'STM' action is enough
              -- to protect us from using the same duplex connection twice in
              -- outbound direction or using two unidirectional outbound
              -- connections.
              modifyTMVar stateVar $ \state ->
                case Map.lookup peerAddr state of
                  Just (DuplexConnection conn@ConnectionState { csDirection,
                                                                csConnectionId,
                                                                csHandleVar }) ->
                      case csDirection of
                        Unidirectional Inbound -> do
                          let conn' = conn  { csDirection = Duplex }
                          pure ( Map.update (const (Just (DuplexConnection conn')))
                                            peerAddr state
                               , Just csHandleVar )

                        -- @Unidirectional Outbound@ or @Duplex@
                        _ -> do
                          traceWith tracer (ConnectionExists csConnectionId direction)
                          throwIO (ConnectionExistsError peerAddr direction)

                  Just (InboundConnection inbound) -> do
                    p <- atomically (readTVar (csHandleVar inbound))
                    case p of
                      Empty -> throwIO (ConnectionManagerInternalError peerAddr)
                      Promised handle ->
                        case connectionDataFlow handle of
                          Nothing ->
                            -- 'Nothing' indicates that either handhsake or mux
                            -- errored before negotiation was done.
                            throwIO (ConnectionManagerPromiseError peerAddr)

                          Just DuplexDataFlow -> do
                            traceWith tracer (ReusedConnection peerAddr Duplex)
                            pure ( Map.update (const (Just $ DuplexConnection inbound)) peerAddr state
                                 , Just (csHandleVar inbound) )

                          Just UnidirectionalDataFlow -> do
                            traceWith tracer (ConnectionNotFound peerAddr direction)
                            pure ( state, Nothing )

                  Just (OutboundConnection outbound) -> do
                    traceWith tracer (ConnectionExists (csConnectionId outbound) direction)
                    throwIO (ConnectionExistsError peerAddr direction)

                  Just (InboundOutboundConnection _inbound outbound) -> do
                    traceWith tracer (ConnectionExists (csConnectionId outbound) direction)
                    throwIO (ConnectionExistsError peerAddr direction)

                  Nothing -> do
                    traceWith tracer (ConnectionNotFound peerAddr direction)
                    pure (state, Nothing)

        -- step 3. By now either return the mux promised (which must be
        -- resolved, so we can use 'unsafeHandleSTM').
        --
        case mbMuxPromiseVar :: Maybe (StrictTVar m (Promise handle)) of
          Just handleVar -> unsafeHandleSTM handleVar

          Nothing ->
            bracketOnError
              (openToConnect connectionSnocket peerAddr)
              (close connectionSnocket)
              $ \socket -> do
                addr <-
                  case connectionManagerAddressType peerAddr of
                    Nothing -> pure Nothing
                    Just IPv4Address ->
                      traverse_ (bind connectionSnocket socket) connectionManagerIPv4Address
                        $> connectionManagerIPv4Address
                    Just IPv6Address ->
                      traverse_ (bind connectionSnocket socket) connectionManagerIPv6Address
                        $> connectionManagerIPv6Address
                traceWith tracer (ConnectTo addr peerAddr)
                connect connectionSnocket socket peerAddr
                  `catch` \e -> traceWith tracer (ConnectError addr peerAddr e)
                             >> throwIO e
                includeConnection stateVar handler
                                  Outbound socket peerAddr

    handleSTM :: StrictTVar m (Promise handle) -> STM m handle
    handleSTM v = do
      mm <- readTVar v
      case mm of
        Promised handle -> pure handle
        Empty -> retry

    -- a non-blocking version of 'handleSTM'
    unsafeHandleSTM :: StrictTVar m (Promise handle) -> m handle
    unsafeHandleSTM v = atomically $ do
      mm <- readTVar v
      case mm of
        Promised handle -> pure handle
        Empty -> error "connection-manager: invariant violation"

--
-- Utils
--


-- | Like 'modifyMVar_' but strict
--
modifyTMVar_ :: ( MonadSTM  m
                , MonadMask m
                )
             => StrictTMVar m a -> (a -> m a) -> m ()
modifyTMVar_ m io =
    mask $ \unmask -> do
      a <- atomically (takeTMVar m)
      a' <- unmask (io a) `onException` atomically (putTMVar m a)
      atomically (putTMVar m a')


-- | Like 'modifyMVar' but strict in @a@ and for 'TMVar's
--
modifyTMVar :: ( MonadEvaluate m
               , MonadMask     m
               , MonadSTM      m
               )
            => StrictTMVar m a
            -> (a -> m (a, b))
            -> m b
modifyTMVar m k =
  mask $ \restore -> do
    a      <- atomically (takeTMVar m)
    (!a',b) <- restore (k a >>= evaluate) `onException` atomically (putTMVar m a)
    atomically (putTMVar m a')
    return b
