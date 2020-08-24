{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

{-# OPTIONS_GHC -Wno-orphans #-}
module Ouroboros.Consensus.Shelley.Ledger.PeerSelection () where

import           Data.Bifunctor (second)
import           Data.Foldable (toList)
import           Data.List (sortOn)
import           Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (catMaybes)
import           Data.Ord (Down (..))

import           Ouroboros.Consensus.Ledger.SupportsPeerSelection

import qualified Shelley.Spec.Ledger.Delegation.Certificates as SL
import qualified Shelley.Spec.Ledger.Keys as SL
import qualified Shelley.Spec.Ledger.LedgerState as SL
import qualified Shelley.Spec.Ledger.TxBody as SL

import           Ouroboros.Consensus.Shelley.Ledger.Block
import           Ouroboros.Consensus.Shelley.Ledger.Ledger

instance LedgerSupportsPeerSelection (ShelleyBlock era) where
  getPeers ShelleyLedgerState { shelleyLedgerState } = catMaybes
      [ (poolStake,) <$> Map.lookup stakePool poolDomainAddresses
      | (stakePool, poolStake) <- orderByStake poolDistr
      ]
    where
      poolDistr :: SL.PoolDistr era
      poolDistr = SL.nesPd shelleyLedgerState

      -- | Sort stake pools by descending stake
      orderByStake ::
           SL.PoolDistr era
        -> [(SL.KeyHash 'SL.StakePool era, PoolStake)]
      orderByStake =
            sortOn (Down . snd)
          . map (second SL.individualPoolStake)
          . Map.toList
          . SL.unPoolDistr

      futurePoolParams, poolParams ::
           Map (SL.KeyHash 'SL.StakePool era) (SL.PoolParams era)
      (futurePoolParams, poolParams) =
          (SL._fPParams pstate, SL._pParams pstate)
        where
          pstate :: SL.PState era
          pstate =
                SL._pstate
              . SL._delegationState
              . SL.esLState
              . SL.nesEs
              $ shelleyLedgerState

      relayToDomainAddress :: SL.StakePoolRelay -> DomainAddress
      relayToDomainAddress = undefined

      -- | Note that a stake pool can have multiple registered relays
      pparamsDomainAddresses ::
           SL.PoolParams era
        -> Maybe (NonEmpty DomainAddress)
      pparamsDomainAddresses =
          NE.nonEmpty . map relayToDomainAddress . toList . SL._poolRelays

      -- | Combine the stake pools registered in the future with the current
      -- pool parameters and remove duplicates.
      poolDomainAddresses ::
           Map (SL.KeyHash 'SL.StakePool era) (NonEmpty DomainAddress)
      poolDomainAddresses =
          Map.unionWith
            (\futureRelays currentRelays -> NE.nub (futureRelays <> currentRelays))
            (Map.mapMaybe pparamsDomainAddresses futurePoolParams)
            (Map.mapMaybe pparamsDomainAddresses poolParams)
