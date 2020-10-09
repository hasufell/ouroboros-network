{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}
module Ouroboros.Consensus.Shelley.Ledger.Block (
    ShelleyHash (..)
  , ShelleyBlock (..)
  , mkShelleyBlock
  , GetHeader (..)
  , Header (..)
  , mkShelleyHeader
  , NestedCtxt_(..)
    -- * Serialisation
  , encodeShelleyBlock
  , decodeShelleyBlock
  , shelleyBinaryBlockInfo
  , encodeShelleyHeader
  , decodeShelleyHeader
    -- * Conversion
  , fromShelleyPrevHash
  , toShelleyPrevHash
    -- * Re-exported
  , Era
  ) where

import           Codec.CBOR.Decoding (Decoder)
import           Codec.CBOR.Encoding (Encoding)
import           Codec.Serialise (Serialise (..))
import qualified Data.ByteString.Lazy as Lazy
import           Data.Coerce (coerce)
import           Data.FingerTree.Strict (Measured (..))
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           NoThunks.Class (NoThunks (..))

import           Cardano.Binary (Annotator (..), FromCBOR (..),
                     FullByteString (..), ToCBOR (..), serialize)
import qualified Cardano.Crypto.Hash as Crypto

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.HeaderValidation
import           Ouroboros.Consensus.Storage.Common (BinaryBlockInfo (..))
import           Ouroboros.Consensus.Util (ShowProxy (..), hashFromBytesShortE)
import           Ouroboros.Consensus.Util.Condense

import           Cardano.Ledger.Crypto (Crypto, HASH)
import qualified Shelley.Spec.Ledger.API as SL

import           Ouroboros.Consensus.Shelley.Eras (Era, EraCrypto, ShelleyBased)

{-------------------------------------------------------------------------------
  Header hash
-------------------------------------------------------------------------------}

newtype ShelleyHash c = ShelleyHash {
      unShelleyHash :: SL.HashHeader c
    }
  deriving stock    (Eq, Ord, Show, Generic)
  deriving newtype  (ToCBOR, FromCBOR)
  deriving anyclass (NoThunks)

instance Crypto c => Serialise (ShelleyHash c) where
  encode = toCBOR
  decode = fromCBOR

instance Condense (ShelleyHash c) where
  condense = show . unShelleyHash

instance Era era => ConvertRawHash (ShelleyBlock era) where
  toShortRawHash   _ = Crypto.hashToBytesShort . SL.unHashHeader . unShelleyHash
  fromShortRawHash _ = ShelleyHash . SL.HashHeader . hashFromBytesShortE
  hashSize         _ = fromIntegral $ Crypto.sizeHash (Proxy @(HASH (EraCrypto era)))

{-------------------------------------------------------------------------------
  Shelley blocks and headers
-------------------------------------------------------------------------------}

-- | Newtype wrapper to avoid orphan instances
--
-- The phantom type parameter is there to record the additional information
-- we need to work with this block. Most of the code here does not care,
-- but we may need different additional information when running the chain.
data ShelleyBlock era = ShelleyBlock {
      shelleyBlockRaw        :: !(SL.Block era)
    , shelleyBlockHeaderHash :: !(ShelleyHash (EraCrypto era))
    }

deriving instance ShelleyBased era => Show (ShelleyBlock era)
deriving instance ShelleyBased era => Eq   (ShelleyBlock era)

instance Typeable era => ShowProxy (ShelleyBlock era) where

type instance HeaderHash (ShelleyBlock era) = ShelleyHash (EraCrypto era)

mkShelleyBlock :: Era era => SL.Block era -> ShelleyBlock era
mkShelleyBlock raw = ShelleyBlock {
      shelleyBlockRaw        = raw
    , shelleyBlockHeaderHash = ShelleyHash (SL.bhHash (SL.bheader raw))
    }

data instance Header (ShelleyBlock era) = ShelleyHeader {
      shelleyHeaderRaw  :: !(SL.BHeader (EraCrypto era))
    , shelleyHeaderHash :: !(ShelleyHash (EraCrypto era))
    }
  deriving (Generic)

deriving instance ShelleyBased era => Show     (Header (ShelleyBlock era))
deriving instance ShelleyBased era => Eq       (Header (ShelleyBlock era))
deriving instance ShelleyBased era => NoThunks (Header (ShelleyBlock era))

instance Typeable era => ShowProxy (Header (ShelleyBlock era)) where

instance Era era => GetHeader (ShelleyBlock era) where
  getHeader (ShelleyBlock rawBlk hdrHash) = ShelleyHeader {
      shelleyHeaderRaw  = SL.bheader rawBlk
    , shelleyHeaderHash = hdrHash
    }

  blockMatchesHeader hdr blk =
      -- Compute the hash the body of the block (the transactions) and compare
      -- that against the hash of the body stored in the header.
      SL.bbHash txs == SL.bhash hdrBody
    where
      ShelleyHeader { shelleyHeaderRaw = SL.BHeader hdrBody _ } = hdr
      ShelleyBlock  { shelleyBlockRaw  = SL.Block _ txs }       = blk

  headerIsEBB = const Nothing

mkShelleyHeader :: Era era => SL.BHeader (EraCrypto era) -> Header (ShelleyBlock era)
mkShelleyHeader raw = ShelleyHeader {
      shelleyHeaderRaw  = raw
    , shelleyHeaderHash = ShelleyHash (SL.bhHash raw)
    }

instance Era era => HasHeader (ShelleyBlock era)  where
  getHeaderFields = getBlockHeaderFields

instance Era era => HasHeader (Header (ShelleyBlock era)) where
  getHeaderFields hdr = HeaderFields {
      headerFieldHash    = shelleyHeaderHash hdr
    , headerFieldSlot    =          SL.bheaderSlotNo  . SL.bhbody . shelleyHeaderRaw $ hdr
    , headerFieldBlockNo = coerce . SL.bheaderBlockNo . SL.bhbody . shelleyHeaderRaw $ hdr
    }

instance Era era => GetPrevHash (ShelleyBlock era) where
  headerPrevHash =
      fromShelleyPrevHash
    . SL.bheaderPrev
    . SL.bhbody
    . shelleyHeaderRaw

instance Era era => Measured BlockMeasure (ShelleyBlock era) where
  measure = blockMeasure

instance Era era => StandardHash (ShelleyBlock era)

instance Era era => HasAnnTip (ShelleyBlock era)

-- The 'ValidateEnvelope' instance lives in the
-- "Ouroboros.Consensus.Shelley.Ledger.Ledger" module because of the
-- dependency on the 'LedgerConfig'.

{-------------------------------------------------------------------------------
  Conversions
-------------------------------------------------------------------------------}

-- | From @cardano-ledger-specs@ to @ouroboros-consensus@
fromShelleyPrevHash :: SL.PrevHash (EraCrypto era) -> ChainHash (ShelleyBlock era)
fromShelleyPrevHash SL.GenesisHash   = GenesisHash
fromShelleyPrevHash (SL.BlockHash h) = BlockHash (ShelleyHash h)

-- | From @ouroboros-consensus@ to @cardano-ledger-specs@
toShelleyPrevHash :: ChainHash (Header (ShelleyBlock era)) -> SL.PrevHash (EraCrypto era)
toShelleyPrevHash GenesisHash                 = SL.GenesisHash
toShelleyPrevHash (BlockHash (ShelleyHash h)) = SL.BlockHash h

{-------------------------------------------------------------------------------
  NestedCtxt
-------------------------------------------------------------------------------}

data instance NestedCtxt_ (ShelleyBlock era) f a where
  CtxtShelley :: NestedCtxt_ (ShelleyBlock era) f (f (ShelleyBlock era))

deriving instance Show (NestedCtxt_ (ShelleyBlock era) f a)

instance TrivialDependency (NestedCtxt_ (ShelleyBlock era) f) where
  type TrivialIndex (NestedCtxt_ (ShelleyBlock era) f) = f (ShelleyBlock era)
  hasSingleIndex CtxtShelley CtxtShelley = Refl
  indexIsTrivial = CtxtShelley

instance SameDepIndex (NestedCtxt_ (ShelleyBlock era) f)
instance HasNestedContent f (ShelleyBlock era)

{-------------------------------------------------------------------------------
  Serialisation
-------------------------------------------------------------------------------}

instance Era era => ToCBOR (ShelleyBlock era) where
  -- Don't encode the header hash, we recompute it during deserialisation
  toCBOR = toCBOR . shelleyBlockRaw

instance ShelleyBased era => FromCBOR (Annotator (ShelleyBlock era)) where
  fromCBOR = fmap mkShelleyBlock <$> fromCBOR

instance Era era => ToCBOR (Header (ShelleyBlock era)) where
  -- Don't encode the header hash, we recompute it during deserialisation
  toCBOR = toCBOR . shelleyHeaderRaw

instance Era era => FromCBOR (Annotator (Header (ShelleyBlock era))) where
  fromCBOR = fmap mkShelleyHeader <$> fromCBOR

encodeShelleyBlock :: Era era => ShelleyBlock era -> Encoding
encodeShelleyBlock = toCBOR

decodeShelleyBlock :: ShelleyBased era => Decoder s (Lazy.ByteString -> ShelleyBlock era)
decodeShelleyBlock = (. Full) . runAnnotator <$> fromCBOR

shelleyBinaryBlockInfo :: Era era => ShelleyBlock era -> BinaryBlockInfo
shelleyBinaryBlockInfo blk = BinaryBlockInfo {
      -- Drop the 'encodeListLen' that precedes the header and the body (= tx
      -- seq)
      headerOffset = 1
      -- The Shelley decoders use annotations, so this is cheap
    , headerSize   = fromIntegral $ Lazy.length (serialize (getHeader blk))
    }

encodeShelleyHeader :: Era era => Header (ShelleyBlock era) -> Encoding
encodeShelleyHeader = toCBOR

decodeShelleyHeader :: Era era => Decoder s (Lazy.ByteString -> Header (ShelleyBlock era))
decodeShelleyHeader = (. Full) . runAnnotator <$> fromCBOR

{-------------------------------------------------------------------------------
  Condense
-------------------------------------------------------------------------------}

instance ShelleyBased era => Condense (ShelleyBlock era) where
  condense = show . shelleyBlockRaw

instance Era era => Condense (Header (ShelleyBlock era)) where
  condense = show . shelleyHeaderRaw
