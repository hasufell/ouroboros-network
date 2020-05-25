{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}

-- | Intended to be imported qualified.
--
module Ouroboros.Network.ConnectionManager.Server.ControlChannel
  ( ControlMessage (..)
  , SomeControlMessage (..)
  , ControlChannel (..)
  , ServerControlChannel
  , newControlChannel
  , newOutboundConnection

  -- * Internals
  , peekAlt
  ) where

import           Control.Applicative (Alternative (..))
import           Control.Exception (SomeException)
import           Control.Monad.Class.MonadSTM.Strict

import           Data.ByteString.Lazy (ByteString)
import           Data.Sequence.Strict (StrictSeq (..), (|>), (><))
import qualified Data.Sequence.Strict as Seq

import           Network.Mux (Mux)
import           Network.Mux.Types (MuxMode)

import           Ouroboros.Network.Mux (MiniProtocol (..), MiniProtocolNum)
import           Ouroboros.Network.ConnectionId
import           Ouroboros.Network.MuxConnectionHandler


-- | We run a monitoring thread, which listens on these events.
--
data ControlMessage (muxMode :: MuxMode) peerAddr versionNumber m a b

    -- | After accepting a connection and awaiting for 'MuxHandle' we either
    -- can start all mini-protocols or handle errors.
    = NewInboundConnection
      !(MuxHandle muxMode peerAddr versionNumber ByteString m a b)

    -- | After creating an outbound connection, we need to on-demand start
    -- responder protocols.
    --
    | NewOutboundConnection
      !(MuxHandle muxMode peerAddr versionNumber ByteString m a b)

    -- | A mini-protocol thrown an exception; we will either bring whole
    -- connection down or the node (if this happend to be a fatal error).
    --
    | MiniProtocolException
      !(Mux muxMode m)
      !(ConnectionId peerAddr)
      !MiniProtocolNum
      !SomeException  

    -- | Event raised after a successful completion of a mini-protocol.
    --
    | MiniProtocolCompleted
       !(Mux muxMode m)
       !(ConnectionId peerAddr)
       !(MiniProtocol muxMode ByteString m a b)

instance (Show peerAddr, Show versionNumber)
      => Show (ControlMessage muxMode peerAddr versionNumber m a b) where
      show (NewInboundConnection mp) = "NewInboundConnection " ++ show mp
      show (NewOutboundConnection mp) = "NewInboundConnection " ++ show mp
      show (MiniProtocolException _ connectionId miniProtocolNum err) =
        concat
          [ "MiniProtocolException "
          , show connectionId
          , " "
          , show miniProtocolNum
          , " "
          , show err
          ]
      show (MiniProtocolCompleted _ connectionId MiniProtocol { miniProtocolNum }) =
        concat
          [ "MiniProtocolCompleted "
          , show connectionId
          , " "
          , show miniProtocolNum
          ]


data SomeControlMessage peerAddr versionNumber where
    SomeControlMessage :: forall muxMode peerAddr versionNumber m a b.
                          ControlMessage muxMode peerAddr versionNumber m a b
                       -> SomeControlMessage peerAddr versionNumber

deriving instance (Show peerAddr, Show versionNumber)
               => Show (SomeControlMessage peerAddr versionNumber)


-- | Server control channel.  It allows to pass 'STM' transactions which will
-- resolve to 'ControlMessages'.   Server's monitoring thread is the consumer
-- of this messages; there are two produceres: accept loop and connection
-- handler for outbound connections.
--
data ControlChannel m srvCntrlMsg =
  ControlChannel {
    -- | Read a single 'ControlMessage' instructrion from the channel.
    --
    readControlMessage :: m srvCntrlMsg,

    -- | Write a 'ControlMessage' to the channel.
    --
    writeControlMessage :: STM m srvCntrlMsg -> m ()
  }


type ServerControlChannel m muxMode peerAddr versionNumber a b =
    ControlChannel m (ControlMessage muxMode peerAddr versionNumber m a b)


newControlChannel :: forall m srvCntrlMsg.
                     MonadSTM m
                  => m (ControlChannel m srvCntrlMsg)
newControlChannel = do
    channel <- newTVarIO Seq.Empty
    pure $ ControlChannel {
        readControlMessage  = readControlMessage channel,
        writeControlMessage = writeControlMessage channel
      }
  where
    readControlMessage
      :: StrictTVar m
           (StrictSeq
             (STM m srvCntrlMsg))
      -> m srvCntrlMsg
    readControlMessage channel = atomically $ do
      (srvCntrlMsg, rest) <- readTVar channel >>= peekAlt
      writeTVar channel rest
      pure srvCntrlMsg

    writeControlMessage
      :: StrictTVar m
           (StrictSeq
             (STM m srvCntrlMsg))
      -> STM m srvCntrlMsg
      -> m ()
    writeControlMessage channel srvCntrlMsgSTM = atomically $
      modifyTVar channel (|> srvCntrlMsgSTM)


newOutboundConnection
    :: Applicative (STM m)
    => ControlChannel m (ControlMessage muxMode peerAddr versionNumber m a b)
    -> MuxHandle muxMode peerAddr versionNumber ByteString m a b
    -> m ()
newOutboundConnection serverControlChannel =
    writeControlMessage serverControlChannel . pure . NewOutboundConnection


--
-- Internals
--

-- | 'peekAlt' finds first non 'empty' element and returns it together with the
-- sequence of all the other ones (preserving their original order).  Only the
-- returned non-empty element is dropped from the sequence.  It is expressed
-- using 'Alternative' applicative functor, instead of `STM m` for
-- testing purposes.
--
peekAlt :: Alternative m
        => StrictSeq (m a)
        -> m (a, StrictSeq (m a))
peekAlt = go Seq.Empty
  where
    -- in the cons case we either can resolve 'stm', in which case we
    -- return the value together with list of all other transactions, or
    -- (`<|>`) we push it on the `acc` and recrurse.
    go !acc (stm :<| stms) =
      ((\a -> (a, acc >< stms)) <$> stm)
      <|>
      go (acc |> stm) stms
    -- in the 'Empty' case, we just need to 'retry' the trasaction (hence we
    -- use 'empty').
    go _acc Seq.Empty = empty
