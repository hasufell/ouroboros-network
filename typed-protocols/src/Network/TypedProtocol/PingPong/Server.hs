{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}

module Network.TypedProtocol.PingPong.Server where

import           Numeric.Natural (Natural)

import           Network.TypedProtocol.Core
import           Network.TypedProtocol.PingPong.Type


data PingPongServer m a = PingPongServer {
    -- | The client sent us a ping message. We have no choices here, and
    -- the response is nullary, all we have are local effects.
    recvMsgPing  :: m (PingPongServer m a)

    -- | The client terminated. Here we have a pure return value, but we
    -- could have done another action in 'm' if we wanted to.
  , recvMsgDone  :: a
  }

-- | The standard stateless ping-pong server instance.
--
pingPongServerStandard
  :: Applicative m
  => PingPongServer m ()
pingPongServerStandard =
    PingPongServer {
      recvMsgPing = pure pingPongServerStandard,
      recvMsgDone = ()
    }

-- | An example ping-pong server instance that counts the number of ping
-- messages.
--
pingPongServerCount
  :: Applicative m
  => PingPongServer m Natural
pingPongServerCount = go 0
  where
   go !c = PingPongServer {
      recvMsgPing = pure $ go (succ c),
      recvMsgDone = c
    }

-- | Interpret a particular server action sequence into the server side of the
-- 'PingPong' protocol.
--
pingPongServerPeer
  :: Monad m
  => PingPongServer m a
  -> Peer AsServer StIdle m a
pingPongServerPeer PingPongServer{..} =

    -- In the 'StIdle' the server is awaiting a request message
    await TokIdle $ \req ->

    -- The client got to choose between two messages and we have to handle
    -- either of them
    case req of

      -- The client sent the done transition, so we're in the 'StDone' state
      -- so all we can do is stop using 'done', with a return value.
      MsgDone -> done recvMsgDone

      -- The client sent us a ping request, so now we're in the 'StBusy' state
      -- which means it's the server's turn to send.
      MsgPing -> effect $ do
        next <- recvMsgPing
        pure $ yield MsgPong (pingPongServerPeer next)
