{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

-- | Byron digital signatures.
module Ouroboros.Consensus.Byron.Crypto.DSIGN
    ( ByronDSIGN
    , VerKeyDSIGN(..)
    , SignKeyDSIGN(..)
    , SigDSIGN(..)
    , HasSignTag(..)
    ) where

import           Cardano.Binary
import qualified Cardano.Chain.Block as CC.Block
import qualified Cardano.Chain.UTxO as CC.UTxO
import           Cardano.Crypto (SignTag (..), Signature, SigningKey,
                     VerificationKey, keyGen, signRaw, toVerification,
                     verifySignatureRaw)
import           Cardano.Crypto.DSIGN.Class
import qualified Cardano.Crypto.Signing as Crypto
import           Cardano.Prelude (NoUnexpectedThunks, UseIsNormalForm (..))
import           Data.ByteString (ByteString)
import           Data.Coerce (coerce)
import           Data.Proxy (Proxy (..))
import           GHC.Generics (Generic)

import           Ouroboros.Consensus.Util.Condense

import           Ouroboros.Consensus.Byron.Ledger.Config

class (HasSignTag a, Decoded a) => ByronSignable a
instance (HasSignTag a, Decoded a) => ByronSignable a

class HasSignTag a where
  signTag :: ByronConfig -> VerKeyDSIGN ByronDSIGN -> proxy a -> SignTag

signTagFor :: forall a. HasSignTag a
           => ByronConfig -> VerKeyDSIGN ByronDSIGN -> a -> SignTag
signTagFor cfg genKey _ = signTag cfg genKey (Proxy @a)

instance HasSignTag CC.UTxO.TxSigData where
  signTag _ _ = const SignTx

instance HasSignTag (Annotated CC.Block.ToSign ByteString) where
  signTag _ (VerKeyByronDSIGN vk) = const $ SignBlock vk

data ByronDSIGN

instance DSIGNAlgorithm ByronDSIGN where
    -- Context required for Byron digital signatures
    --
    -- We require the ByronConfig (from which we just extract the protocol
    -- magic) as well as the verification key of the genesis stakeholder of
    -- which the signing node is a delegate, which is required for signing
    -- blocks.
    type ContextDSIGN ByronDSIGN = (ByronConfig, VerKeyDSIGN ByronDSIGN)

    newtype VerKeyDSIGN ByronDSIGN = VerKeyByronDSIGN VerificationKey
        deriving (Show, Eq, Generic)
        deriving NoUnexpectedThunks via UseIsNormalForm (VerKeyDSIGN ByronDSIGN)

    newtype SignKeyDSIGN ByronDSIGN = SignKeyByronDSIGN SigningKey
        deriving (Show, Generic)
        deriving NoUnexpectedThunks via UseIsNormalForm (SignKeyDSIGN ByronDSIGN)

    newtype SigDSIGN ByronDSIGN = SigByronDSIGN (Signature CC.Block.ToSign)
        deriving (Show, Eq, Generic)
        deriving NoUnexpectedThunks via UseIsNormalForm (SigDSIGN ByronDSIGN)

    type Signable ByronDSIGN = ByronSignable

    encodeVerKeyDSIGN (VerKeyByronDSIGN pk) = toCBOR pk
    decodeVerKeyDSIGN = VerKeyByronDSIGN <$> fromCBOR

    encodeSignKeyDSIGN (SignKeyByronDSIGN pk) = toCBOR pk
    decodeSignKeyDSIGN = SignKeyByronDSIGN <$> fromCBOR

    encodeSigDSIGN (SigByronDSIGN pk) = toCBOR pk
    decodeSigDSIGN = SigByronDSIGN <$> fromCBOR

    genKeyDSIGN = SignKeyByronDSIGN . snd <$> keyGen

    deriveVerKeyDSIGN (SignKeyByronDSIGN sk) = VerKeyByronDSIGN $ toVerification sk

    signDSIGN (cfg, genKey) a (SignKeyByronDSIGN sk) = return
        . SigByronDSIGN
        . coerce
        $ signRaw (pbftProtocolMagicId cfg) (Just $ signTagFor cfg genKey a) sk (recoverBytes a)

    verifyDSIGN (cfg, genKey) (VerKeyByronDSIGN vk) a (SigByronDSIGN sig) =
        if verifySignatureRaw vk (Crypto.signTag (pbftProtocolMagicId cfg) (signTagFor cfg genKey a) <> recoverBytes a) $ coerce sig
          then Right ()
          else Left "Verification failed"

    abstractSizeVKey _ = error "Ouroboros.Consensus.Byron.Crypto.DSIGN: DSIGNAlgorithm ByronDSIGN"
    abstractSizeSig  _ = error "Ouroboros.Consensus.Byron.Crypto.DSIGN: DSIGNAlgorithm ByronDSIGN"

instance Condense (SigDSIGN ByronDSIGN) where
    condense (SigByronDSIGN s) = show s