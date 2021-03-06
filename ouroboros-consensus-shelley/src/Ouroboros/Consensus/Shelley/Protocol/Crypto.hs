{-# LANGUAGE FlexibleInstances       #-}
{-# LANGUAGE TypeFamilies            #-}
{-# LANGUAGE UndecidableInstances    #-}
{-# LANGUAGE UndecidableSuperClasses #-}
module Ouroboros.Consensus.Shelley.Protocol.Crypto (
    TPraosCrypto
  , StandardCrypto
  ) where

import           Cardano.Crypto.DSIGN.Ed25519 (Ed25519DSIGN)
import           Cardano.Crypto.Hash.Blake2b (Blake2b_224, Blake2b_256)
import           Cardano.Crypto.KES.Sum
import           Cardano.Crypto.VRF.Praos (PraosVRF)

import           Cardano.Ledger.Crypto (Crypto (..))
import           Cardano.Ledger.Era (Era)
import           Cardano.Ledger.Shelley (Shelley)

import           Shelley.Spec.Ledger.API (BHBody, Hash, TxBody)
import           Shelley.Spec.Ledger.BaseTypes (Seed)
import qualified Shelley.Spec.Ledger.Keys as SL (DSignable, KESignable,
                     VRFSignable)
import           Shelley.Spec.Ledger.OCert (OCertSignable)

-- TODO #2668 these constraints and types should be parameterised by @crypto@,
-- not @era@.
class ( Era era
      , SL.DSignable    era (OCertSignable era)
      , SL.DSignable    era (Hash era (TxBody era))
      , SL.KESignable   era (BHBody era)
      , SL.VRFSignable  era Seed
      ) => TPraosCrypto era

data StandardCrypto

instance Crypto StandardCrypto where
  type DSIGN    StandardCrypto = Ed25519DSIGN
  type KES      StandardCrypto = Sum6KES Ed25519DSIGN Blake2b_256
  type VRF      StandardCrypto = PraosVRF
  type HASH     StandardCrypto = Blake2b_256
  type ADDRHASH StandardCrypto = Blake2b_224

instance TPraosCrypto (Shelley StandardCrypto)
