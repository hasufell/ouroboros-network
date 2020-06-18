{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}

module Test.Ouroboros.Network.ConnectionManager
  ( tests
  ) where

import           Prelude hiding (read)

import           Control.Exception (Exception (..), SomeException)
import           Control.Monad (forever, (>=>))
import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadThrow
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import           Control.Monad.Class.MonadSay
import           Control.Monad.IOSim
import           Control.Tracer (Tracer (..), nullTracer)

import           Data.Foldable (traverse_)
import           Data.List (find, intercalate, nub)
import           Data.Maybe (isJust, isNothing, mapMaybe)
import qualified Data.Map.Strict as Map

import           Network.Mux.Types

import           Test.QuickCheck
import           Test.Tasty (TestTree, testGroup)
import           Test.Tasty.QuickCheck (testProperty)

import           Ouroboros.Network.ConnectionId (ConnectionId (..))
import           Ouroboros.Network.Snocket (Snocket (..), Accept (..), Accepted (..),
                   AddressFamily(TestFamily), TestAddress (..))
import           Ouroboros.Network.ConnectionManager.Core
import           Ouroboros.Network.ConnectionManager.Types

import           Ouroboros.Network.Testing.Utils (Delay (..))


tests :: TestTree
tests =
  testGroup "Ouroboros.Network.ConnectionManager"
  [ testProperty "pure connection manager" prop_connectionManager
  ]


data PeerAddr = PeerAddr Int (Maybe DataFlowType)
  deriving Show

instance Eq PeerAddr where
    PeerAddr addr _ == PeerAddr addr' _ =
             addr   ==          addr'

instance Ord PeerAddr where
    PeerAddr addr _ `compare` PeerAddr addr' _ =
             addr   `compare`          addr'

instance Arbitrary PeerAddr where
    -- we only generate remote addresses, which are positive integers.  We
    -- resize the address space to make it less likely to generate the same
    -- address twice.
    arbitrary = PeerAddr <$> (getPositive <$> resize 750 arbitrary)
                         <*> oneof [ pure Nothing
                                 , pure (Just UnidirectionalDataFlow)
                                 , pure (Just DuplexDataFlow)
                                 ]
    shrink (PeerAddr addr df) =
      [ PeerAddr addr' df
      | addr' <- shrink addr
      ]
      ++
      [ PeerAddr addr df'
      | df' <- case df of
                Nothing -> []
                Just UnidirectionalDataFlow -> [Nothing]
                Just DuplexDataFlow         -> [Just UnidirectionalDataFlow]
      ]


data ConnState = UnconnectedState
               | ConnectedState
               | AcceptedState
               | ListeningState
               | ClosedState

data Bound = Bound | NotBound

data FDState = FDState {
    fdLocalAddress    :: PeerAddr,
    fdRemoteAddress   :: Maybe PeerAddr,
    fdConnectionState :: ConnState,
    fdBound           :: Bound
  }

newtype FD m = FD (StrictTVar m FDState)

-- TODO: use `IOException` instead
data SnocketErr =
      InvalidArgument
    | AcceptErr
    | ConnectErr
    | BindErr
    | ListenErr
  deriving Show

instance Exception SnocketErr


-- | A pure snocket.  Reading always blocks forever, writing is immediate.
--
-- This very roughly captures socket semantics, but it's good enough for the
-- time being for the testing we want to do.  In particular this does not rule
-- out situations which the kernel would forbid, e.g. have the two connections
-- with the same four-tuples.
--
-- TODO: 'connect' should use a random delay.
--
pureSnocket :: forall m.
               ( MonadDelay m
               , MonadMonotonicTime m
               , MonadSTM   m
               , MonadThrow m
               , MonadThrow (STM m)
               )
            => [PeerAddr]
            -- list of remote addresses which connect to us
            -> Snocket m (FD m) (TestAddress PeerAddr)
pureSnocket remoteAddresses =
    Snocket {
      getLocalAddr, getRemoteAddr, addrFamily,
      open, openToConnect,
      connect, listen, accept,
      bind, close, toBearer
    }
  where
    getLocalAddr (FD v) =
      TestAddress . fdLocalAddress <$> atomically (readTVar v)

    getRemoteAddr (FD v) = do
      mbRemote <- fdRemoteAddress <$> atomically (readTVar v)
      case mbRemote of
        Nothing   -> throwIO InvalidArgument
        Just addr -> pure (TestAddress addr)

    addrFamily _ = TestFamily

    open _ =
      FD <$>
        newTVarIO FDState {
            fdLocalAddress = PeerAddr 0 Nothing,
            fdRemoteAddress = Nothing,
            fdConnectionState = UnconnectedState,
            fdBound = NotBound
          }

    openToConnect _ =
      FD <$>
        newTVarIO FDState {
            fdLocalAddress = PeerAddr 0 Nothing,
            fdRemoteAddress = Nothing,
            fdConnectionState = UnconnectedState,
            fdBound = NotBound
          }

    connect (FD v) (TestAddress remoteAddr) =
      atomically $ do
        fds@FDState { fdConnectionState } <- readTVar v
        case fdConnectionState of
          UnconnectedState ->
            writeTVar v fds { fdRemoteAddress = Just remoteAddr
                            , fdConnectionState = ConnectedState }
          _ -> throwIO ConnectErr

    bind (FD v) (TestAddress localAddr) =
      atomically $ do
        fds@FDState { fdBound } <- readTVar v
        case fdBound of
          NotBound -> writeTVar v fds { fdLocalAddress = localAddr
                                      , fdBound = Bound
                                      }
          Bound -> throwIO BindErr


    accept :: FD m -> Accept m SomeException (TestAddress PeerAddr) (FD m)
    accept (FD v) = Accept $ go remoteAddresses
      where
        go [] = pure (AcceptException (toException AcceptErr), Accept $ go [])
        go (x : xs) = do
          v' <- atomically $ do
            FDState { fdLocalAddress = localAddr } <- readTVar v
            newTVar FDState {
                        -- this is not adequate
                        fdLocalAddress = localAddr,
                        fdRemoteAddress = Just x,
                        fdConnectionState = AcceptedState,
                        fdBound = Bound
                      }
          pure (Accepted (FD v') (TestAddress x), Accept $ go xs)


    toBearer _ _ _ =
      MuxBearer {
          write   = \_ _ -> getMonotonicTime,
          read    = \_ -> forever (threadDelay 3600),
          sduSize = 1500
        }

    listen (FD v) = atomically $ do
      fds@FDState{ fdConnectionState } <- readTVar v
      case fdConnectionState of
        UnconnectedState ->
          writeTVar v (fds { fdConnectionState = ListeningState })
        _ -> throwIO ListenErr

    close (FD v) =
      atomically $ modifyTVar v (\fds -> fds { fdConnectionState = ClosedState })


-- | A connection handler which does not do any effects, other than blocking idefinitely.
--
pureConnectionHandler :: MonadTimer m
                      => DiffTime
                      -- ^ delay before 'Promise' is resolved.
                      -> ConnectionHandler InitiatorResponderMode handlerTrace peerAddr peerAddr m
pureConnectionHandler delay =
    ConnectionHandler $
      WithInitiatorResponderMode
        (\v _ ConnectionId { remoteAddress } _ -> Action
          (do threadDelay delay
              atomically (writeTVar v (Promised remoteAddress))
              forever (threadDelay 86400))
          id)
        (\v _ ConnectionId { remoteAddress } _ -> Action
          (do threadDelay delay
              atomically (writeTVar v (Promised remoteAddress))   
              forever (threadDelay 86400))
          id)


-- | More useful than `Either a a` to distinguish which data is used for
-- /inbound/ and which is used for /outbound/ connections.
--
data InOrOut a = In a | Out a
  deriving (Eq, Show)

fromInOrOut :: InOrOut a -> a
fromInOrOut (In a) = a
fromInOrOut (Out a) = a

inbounds :: [InOrOut a] -> [a]
inbounds []           = []
inbounds (In a  : as) = a : inbounds as
inbounds (Out _ : as) =     inbounds as

{-
outbounds :: [InOrOut a] -> [a]
outbounds []           = []
outbounds (In  _ : as) =     outbounds as
outbounds (Out a : as) = a : outbounds as
-}

instance Arbitrary a => Arbitrary (InOrOut a) where
    arbitrary = either In Out <$> arbitrary
    shrink (In a)  = In `map` shrink a
    shrink (Out a) = Out `map` shrink a

type TestConnectionManagerTrace = ConnectionManagerTrace (TestAddress PeerAddr) ()

-- | This property interleaves inbound and outbound connections and then
-- verifies that:
--
-- * all threads forked by the connection manager are killed when the callback
--   exists
-- * the number of connections managed by the connection manager is right
--   (taking bidirectional connections into account) .
--
prop_connectionManager
    :: Delay
    -> Maybe (Negative Int)
    -- local address, by using a nagative integer we force it to be
    -- different from any one from the list of remote addresses.
    -> (NonEmptyList (InOrOut PeerAddr))
    -- A list of addresses to which we connect or which connect to us.  We use
    -- 'Blind' since we show the arguments using `counterexample` in a nicer
    -- way.
    -> Property
prop_connectionManager (Delay promiseDelay) myAddress' (NonEmpty remoteAddresses) =
    let lbl = if nub remoteAddresses == remoteAddresses
                then "no-failure"
                else "cm-failure"
    in classify True lbl $
    let tr = runSimTrace experiment
        cmTrace :: [TestConnectionManagerTrace]
        cmTrace = selectTraceEventsDynamic tr
    in
           (case traceResult True tr of
             Left err ->
                 counterexample
                   (show err ++ "\n" ++ intercalate "\n" (show `map` traceEvents tr))
                   False
             Right p  -> p)
      .&&. verifyTrace cmTrace
  where
    verifyTrace :: [TestConnectionManagerTrace] -> Property
    verifyTrace =
          Map.foldlWithKey'
            (\p k t -> vrf k t .&&. p)
            (property True)
        . Map.fromListWith (++)
        -- group traces by 'PeerAddr'
        . mapMaybe (\t -> (,[t]) <$> cmtPeerAddr t)
      where
        vrf :: TestAddress PeerAddr -> [TestConnectionManagerTrace] -> Property
        vrf (TestAddress peerAddr) tr =
                case df of
                 -- if peer supports 'DuplexDataFlow' the connection manager must
                 -- negotiated it.
                 Just DuplexDataFlow ->
                     counterexample "connection manager should negotiated duplex connection"
                   . isJust
                   . find (\msg -> case msg of
                            NegotiatedConnection  _ Duplex -> True
                            _ -> False)
                   $ tr

                 -- if peer supports 'UnidreictionDataFlow' only Unidirectional
                 -- connection could be negotiated
                 Just UnidirectionalDataFlow ->
                     counterexample "connection manager should negotiated unidirectional connection"
                   . isJust
                   . find (\msg -> case msg of
                            NegotiatedConnection  _ (Unidirectional _) -> True
                            _ -> False)
                   $ tr

                 Nothing -> property True

          .&&. if isInAndOut
                 then case df of
                   -- if peer suppoer duplex data flow and the connection
                   -- manager included inbound and outbound connection, it must
                   -- reuse a connection
                   Just DuplexDataFlow ->
                       counterexample "connection manager should reuse a connection"
                     . isJust
                     . find (\msg -> case msg of
                              ReusedConnection {} -> True
                              _ -> False)
                     $ tr

                  -- otherwise it must not reuse a connection
                   _ ->
                       counterexample "connection manager should not reuse a connection"
                     . isNothing
                     . find (\msg -> case msg of
                              ReusedConnection {} -> True
                              _ -> False)
                     $ tr
                 else property True


          where
            isInAndOut :: Bool
            isInAndOut = In  peerAddr `elem` remoteAddresses
                      && Out peerAddr `elem` remoteAddresses

            df = case peerAddr of
              PeerAddr _ df1 -> df1


    myAddress :: Maybe (TestAddress PeerAddr)
    myAddress = (\(Negative addr) -> TestAddress (PeerAddr addr Nothing)) <$> myAddress'

    experiment :: forall s. IOSim s Property
    experiment =
        withConnectionManager
          ConnectionManagerArguments {
              connectionManagerTracer = sayTracer :: Tracer (IOSim s) TestConnectionManagerTrace,
              connectionManagerMuxTracer = nullTracer,
              connectionManagerIPv4Address = myAddress,
              connectionManagerIPv6Address = Nothing,
              connectionManagerAddressType = const Nothing,
              connectionHandler = pureConnectionHandler promiseDelay,
              connectionSnocket,
              connectionDataFlow = \(TestAddress (PeerAddr _ df)) -> df
            }
          $ \connectionManager -> do
            fd <- open connectionSnocket TestFamily
            case myAddress of
              Just localAddr ->
                bind connectionSnocket fd localAddr
              Nothing ->
                pure ()

            let go :: [Async (IOSim s) (TestAddress PeerAddr)]
                   -> Accept (IOSim s) SomeException (TestAddress PeerAddr) (FD (IOSim s))
                   -> [InOrOut PeerAddr]
                   -> IOSim s [Async (IOSim s) (TestAddress PeerAddr)]
                go threads _acceptOne [] = pure threads
                go threads acceptOne (Out x : xs) = do
                  thread <-
                    async $
                      includeOutboundConnection connectionManager (TestAddress x)
                  go (thread : threads) acceptOne xs
                go threads (Accept acceptOne) (In x : xs) = do
                  r <- acceptOne
                  case r of
                    (Accepted fd' _, acceptNext) -> do
                      thread <-
                        async $
                          includeInboundConnection connectionManager fd' (TestAddress x)
                      go (thread : threads) acceptNext xs
                    (AcceptException err, _acceptNext) ->
                      throwIO err

            threads <- go [] (accept connectionSnocket fd) remoteAddresses
            -- awaits until all 'Promise's are resolved (or throw an exception)
            traverse_ (waitCatch >=> checkException) threads
            n <- atomically $ numberOfConnections connectionManager

            let -- filter connection which will error during handshake, count
                -- only inbound connections
                lowerBound = length
                           . nub
                           . inbounds
                           . filter ((\(PeerAddr _ a) -> isJust a). fromInOrOut)            
                           $ remoteAddresses

                -- count all connections
                upperBound = length
                           . nub
                           . map fromInOrOut
                           $ remoteAddresses
            pure $ counterexample (show remoteAddresses) $
              counterexample ("lowerBound: " ++ show lowerBound ++ " ≰ " ++ show n) (lowerBound <= n)
              .&&.
              counterexample ("upperBound: " ++ show n ++ " ≰ " ++ show upperBound) (n <= upperBound)

    connectionSnocket :: forall s. Snocket (IOSim s) (FD (IOSim s)) (TestAddress PeerAddr)
    connectionSnocket = pureSnocket (inbounds remoteAddresses)

    checkException :: Either SomeException a -> IOSim s ()
    checkException Right {}   = pure ()
    checkException (Left err) =
      case fromException err :: Maybe (ConnectionManagerError (TestAddress PeerAddr)) of
        Nothing                                 -> pure ()
        Just ConnectionManagerPromiseError {}   -> pure ()
        Just ConnectionExistsError {}           -> pure ()
        Just e@ConnectionManagerInternalError{} -> throwIO e


--
-- Utils
--

sayTracer :: forall m a. (MonadSay m, Show a) => Tracer m a
sayTracer = Tracer $ say . show


cmtPeerAddr :: ConnectionManagerTrace peerAddr a -> Maybe peerAddr
cmtPeerAddr (IncludedConnection connId _)     = Just $ remoteAddress connId
cmtPeerAddr (NegotiatedConnection connId _)   = Just $ remoteAddress connId
cmtPeerAddr (ConnectTo _ peerAddr)            = Just $ peerAddr
cmtPeerAddr (ConnectError _ peerAddr _)       = Just $ peerAddr
cmtPeerAddr (ReusedConnection peerAddr _)     = Just $ peerAddr
cmtPeerAddr (ConnectionFinished connId _)     = Just $ remoteAddress connId
cmtPeerAddr (ErrorFromHandler connId _)       = Just $ remoteAddress connId
cmtPeerAddr (RethrownErrorFromHandler {})     = Nothing
cmtPeerAddr (ConnectionHandlerTrace connId _) = Just $ remoteAddress connId
cmtPeerAddr ShutdownConnectionManager         = Nothing
cmtPeerAddr (ConnectionExists connId _)       = Just $ remoteAddress connId
cmtPeerAddr (ConnectionNotFound peerAddr _)   = Just peerAddr
