{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

module Ouroboros.Network.Protocol.BlockFetch.Codec
  ( codecBlockFetch
  , codecBlockFetchId

  , byteLimitsBlockFetch
  , timeLimitsBlockFetch
  ) where

import           Control.Monad.Class.MonadST
import           Control.Monad.Class.MonadTime

import qualified Data.ByteString.Lazy as LBS

import qualified Codec.CBOR.Decoding as CBOR
import qualified Codec.CBOR.Encoding as CBOR
import qualified Codec.CBOR.Read as CBOR
import           Text.Printf

import           Ouroboros.Network.Block (HeaderHash, Point)
import qualified Ouroboros.Network.Block as Block
import           Ouroboros.Network.Codec
import           Ouroboros.Network.Driver.Limits
import           Ouroboros.Network.Protocol.BlockFetch.Type
import           Ouroboros.Network.Protocol.Limits

-- | Byte Limit.
byteLimitsBlockFetch :: forall bytes block. (bytes -> Word) -> ProtocolSizeLimits (BlockFetch block) bytes
byteLimitsBlockFetch = ProtocolSizeLimits stateToLimit
  where
    stateToLimit :: forall (pr :: PeerRole) (st :: BlockFetch block).
                    PeerHasAgency pr st -> Word
    stateToLimit (ClientAgency TokIdle)      = smallByteLimit
    stateToLimit (ServerAgency TokBusy)      = smallByteLimit
    stateToLimit (ServerAgency TokStreaming) = largeByteLimit

-- | Time Limits
--
-- `TokIdle' No timeout
-- `TokBusy` `longWait` timeout
-- `TokStreaming` `longWait` timeout
timeLimitsBlockFetch :: forall block. ProtocolTimeLimits (BlockFetch block)
timeLimitsBlockFetch = ProtocolTimeLimits stateToLimit
  where
    stateToLimit :: forall (pr :: PeerRole) (st :: BlockFetch block).
                    PeerHasAgency pr st -> Maybe DiffTime
    stateToLimit (ClientAgency TokIdle)      = waitForever
    stateToLimit (ServerAgency TokBusy)      = longWait
    stateToLimit (ServerAgency TokStreaming) = longWait

-- | Codec for chain sync that encodes/decodes blocks
--
-- NOTE: See 'wrapCBORinCBOR' and 'unwrapCBORinCBOR' if you want to use this
-- with a block type that has annotations.
codecBlockFetch
  :: forall block m.
     MonadST m
  => (block            -> CBOR.Encoding)
  -> (forall s. CBOR.Decoder s block)
  -> (HeaderHash block -> CBOR.Encoding)
  -> (forall s. CBOR.Decoder s (HeaderHash block))
  -> Codec (BlockFetch block) CBOR.DeserialiseFailure m LBS.ByteString
codecBlockFetch encodeBlock decodeBlock
                encodeBlockHash decodeBlockHash =
    mkCodecCborLazyBS encode decode
 where
  encode :: forall (pr :: PeerRole) st st'.
            PeerHasAgency pr st
         -> Message (BlockFetch block) st st'
         -> CBOR.Encoding
  encode (ClientAgency TokIdle) (MsgRequestRange (ChainRange from to)) =
    CBOR.encodeListLen 3 <> CBOR.encodeWord 0 <> encodePoint from
                                              <> encodePoint to
  encode (ClientAgency TokIdle) MsgClientDone =
    CBOR.encodeListLen 1 <> CBOR.encodeWord 1
  encode (ServerAgency TokBusy) MsgStartBatch =
    CBOR.encodeListLen 1 <> CBOR.encodeWord 2
  encode (ServerAgency TokBusy) MsgNoBlocks =
    CBOR.encodeListLen 1 <> CBOR.encodeWord 3
  encode (ServerAgency TokStreaming) (MsgBlock block) =
    CBOR.encodeListLen 2 <> CBOR.encodeWord 4 <> encodeBlock block
  encode (ServerAgency TokStreaming) MsgBatchDone =
    CBOR.encodeListLen 1 <> CBOR.encodeWord 5

  decode :: forall (pr :: PeerRole) s (st :: BlockFetch block).
            PeerHasAgency pr st
         -> CBOR.Decoder s (SomeMessage st)
  decode stok = do
    len <- CBOR.decodeListLen
    key <- CBOR.decodeWord
    case (stok, key, len) of
      (ClientAgency TokIdle, 0, 3) -> do
        from <- decodePoint
        to   <- decodePoint
        return $ SomeMessage $ MsgRequestRange (ChainRange from to)
      (ClientAgency TokIdle, 1, 1) -> return $ SomeMessage MsgClientDone
      (ServerAgency TokBusy, 2, 1) -> return $ SomeMessage MsgStartBatch
      (ServerAgency TokBusy, 3, 1) -> return $ SomeMessage MsgNoBlocks
      (ServerAgency TokStreaming, 4, 2) -> SomeMessage . MsgBlock
                                          <$> decodeBlock
      (ServerAgency TokStreaming, 5, 1) -> return $ SomeMessage MsgBatchDone

      --
      -- failures per protocol state
      --

      (ClientAgency TokIdle, _, _) ->
        fail (printf "codecBlockFetch (%s) unexpected key (%d, %d)" (show stok) key len)
      (ServerAgency TokStreaming, _ , _) ->
        fail (printf "codecBlockFetch (%s) unexpected key (%d, %d)" (show stok) key len)
      (ServerAgency TokBusy, _, _) ->
        fail (printf "codecBlockFetch (%s) unexpected key (%d, %d)" (show stok) key len)



  encodePoint :: Point block -> CBOR.Encoding
  encodePoint = Block.encodePoint encodeBlockHash

  decodePoint :: forall s. CBOR.Decoder s (Point block)
  decodePoint = Block.decodePoint decodeBlockHash


codecBlockFetchId
  :: forall block m. Monad m
  => Codec (BlockFetch block) CodecFailure m (AnyMessage (BlockFetch block))
codecBlockFetchId = Codec encode decode
 where
  encode :: forall (pr :: PeerRole) st st'.
            PeerHasAgency pr st
         -> Message (BlockFetch block) st st'
         -> AnyMessage (BlockFetch block)
  encode _ = AnyMessage

  decode :: forall (pr :: PeerRole) (st :: BlockFetch block).
            PeerHasAgency pr st
         -> m (DecodeStep (AnyMessage (BlockFetch block))
                          CodecFailure m (SomeMessage st))
  decode stok = return $ DecodePartial $ \bytes -> case (stok, bytes) of
    (_, Nothing) -> return $ DecodeFail CodecFailureOutOfInput
    (ClientAgency TokIdle,      Just (AnyMessage msg@(MsgRequestRange {}))) -> return (DecodeDone (SomeMessage msg) Nothing)
    (ClientAgency TokIdle,      Just (AnyMessage msg@(MsgClientDone {})))   -> return (DecodeDone (SomeMessage msg) Nothing)
    (ServerAgency TokBusy,      Just (AnyMessage msg@(MsgStartBatch {})))   -> return (DecodeDone (SomeMessage msg) Nothing)
    (ServerAgency TokBusy,      Just (AnyMessage msg@(MsgNoBlocks {})))     -> return (DecodeDone (SomeMessage msg) Nothing)
    (ServerAgency TokStreaming, Just (AnyMessage msg@(MsgBlock {})))        -> return (DecodeDone (SomeMessage msg) Nothing)
    (ServerAgency TokStreaming, Just (AnyMessage msg@(MsgBatchDone {})))    -> return (DecodeDone (SomeMessage msg) Nothing)
    (_, _) -> return $ DecodeFail (CodecFailure "codecBlockFetchId: no matching message")
