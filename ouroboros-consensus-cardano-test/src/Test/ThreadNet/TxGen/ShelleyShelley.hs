{-# LANGUAGE EmptyCase           #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Test.ThreadNet.TxGen.ShelleyShelley (
  -- * Re-exports
  module Test.ThreadNet.TxGen.Shelley,
  ) where

import           Data.SOP.Strict (NS (..))
import           Test.QuickCheck (Gen)

-- Upstream libraries

import           Cardano.Crypto.Hash (HashAlgorithm)
import           Cardano.Slotting.EpochInfo (fixedSizeEpochInfo)

-- Consensus

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Ledger.Basics
import           Ouroboros.Consensus.Node.ProtocolInfo (NumCoreNodes (..))
import           Ouroboros.Consensus.NodeId (CoreNodeId)
import           Test.ThreadNet.TxGen (TxGen (..))

-- HardFork

import           Ouroboros.Consensus.HardFork.Combinator
import qualified Ouroboros.Consensus.HardFork.Combinator.State.Types as HFC
import qualified Ouroboros.Consensus.HardFork.Combinator.Util.Telescope as Tele

-- Shelley

import           Ouroboros.Consensus.Shelley.Ledger
import           Test.Consensus.Shelley.MockCrypto (MockCrypto)
import           Test.ThreadNet.TxGen.Shelley

-- Shelley via Cardano

import           Ouroboros.Consensus.Cardano.Block (ShelleyEra)

import           Test.ThreadNet.Infra.ShelleyShelley

{-------------------------------------------------------------------------------
  Transaction generation
-------------------------------------------------------------------------------}

instance TxGen (ShelleyShelleyBlock (MockCrypto h)) where
  type TxGenExtra (ShelleyShelleyBlock (MockCrypto h)) = ShelleyTxGenExtra h
  testGenTxs _coreNodeId _numCoreNodes _curSlotNo _cfg _extra _lst =
      pure []

_testGenTxs :: forall h.
     HashAlgorithm h
  => CoreNodeId
  -> NumCoreNodes
  -> SlotNo
  -> TopLevelConfig (ShelleyShelleyBlock (MockCrypto h))
  -> TxGenExtra (ShelleyShelleyBlock (MockCrypto h))
  -> LedgerState (ShelleyShelleyBlock (MockCrypto h))
  -> Gen [GenTx (ShelleyShelleyBlock (MockCrypto h))]
_testGenTxs _coreNodeId _numCoreNodes curSlotNo cfg extra lst =
      map inj <$> shelleyGenTxs curSlotNo lcfgCurrent extra lstCurrent
    where
      TopLevelConfig {
          topLevelConfigLedger
        , topLevelConfigProtocol
        } = cfg

      ShelleyShelleyConsensusConfig cfgPartial1 cfgPartial2 =
          topLevelConfigProtocol
      ShelleyShelleyLedgerConfig lcfgPartial1 lcfgPartial2  =
          topLevelConfigLedger

      currentNS ::
          NS (HFC.Current LedgerState) (ShelleyShelleyEras (MockCrypto h))
      currentNS =
          Tele.tip $
          getHardForkState $
          hardForkLedgerStatePerEra $ lst

      (inj, cfgPartialCurrent, lcfgPartialCurrent, lstCurrent) =
          case currentNS of
            Z x     ->
                (GenTxShelley1, cfgPartial1, lcfgPartial1, HFC.currentState x)
            S (Z x) ->
                (GenTxShelley2, cfgPartial2, lcfgPartial2, HFC.currentState x)
            S (S x) ->
                case x of {}

      -- Suitable only for this narrow context: both eras have identical epochs
      epochInfo :: EpochInfo Identity
      epochInfo =
          fixedSizeEpochInfo $
          epochSizeFromPartial cfgPartialCurrent

      lcfgCurrent :: LedgerConfig (ShelleyBlock (ShelleyEra (MockCrypto h)))
      lcfgCurrent =
          completeLedgerConfig
              (Proxy :: Proxy (ShelleyBlock (ShelleyEra (MockCrypto h))))
              epochInfo
              lcfgPartialCurrent
