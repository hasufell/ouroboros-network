{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE MultiWayIf          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Test.ThreadNet.ShelleyShelley (
    tests
  ) where

import           Control.Monad (replicateM)
import qualified Data.Map as Map
import           Data.Maybe (maybeToList)
import           Data.Proxy (Proxy (..))
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Word (Word64)

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.QuickCheck

import           Cardano.Crypto.Hash (ShortHash)
import           Cardano.Slotting.Slot (EpochSize (..), SlotNo (..))

import           Ouroboros.Consensus.BlockchainTime
import           Ouroboros.Consensus.Config.SecurityParam
import           Ouroboros.Consensus.Ledger.SupportsMempool (extractTxs)
import           Ouroboros.Consensus.Node.NetworkProtocolVersion
import           Ouroboros.Consensus.Node.ProtocolInfo
import           Ouroboros.Consensus.NodeId
import           Ouroboros.Consensus.Util.IOLike (IOLike)

import           Ouroboros.Consensus.HardFork.Combinator.Serialisation.Common
                     (isHardForkNodeToNodeEnabled)

import qualified Shelley.Spec.Ledger.BaseTypes as SL
import qualified Shelley.Spec.Ledger.OCert as SL
import qualified Shelley.Spec.Ledger.PParams as SL

import           Ouroboros.Consensus.Shelley.Node (ShelleyGenesis (..))
import           Ouroboros.Consensus.Shelley.Protocol (TPraosCrypto)

import           Ouroboros.Consensus.Cardano.Block (ShelleyEra)
import           Ouroboros.Consensus.Cardano.Node (TriggerHardFork (..))

import           Test.ThreadNet.General
import           Test.ThreadNet.Network (NodeOutput (..),
                     TestNodeInitialization (..))
import           Test.ThreadNet.Util.Expectations (NumBlocks (..))
import           Test.ThreadNet.Util.NodeJoinPlan (trivialNodeJoinPlan)
import           Test.ThreadNet.Util.NodeRestarts (noRestarts)
import           Test.ThreadNet.Util.NodeToNodeVersion (genVersionFiltered)
import           Test.ThreadNet.Util.Seed (runGen)
import qualified Test.Util.BoolProps as BoolProps
import           Test.Util.HardFork.Future (EraSize (..), Future (..))
import           Test.Util.Nightly (askIohkNightlyEnabled)
import           Test.Util.Orphans.Arbitrary ()
import           Test.Util.Slots (NumSlots (..))

import           Test.Consensus.Shelley.MockCrypto (MockCrypto)
import qualified Test.ThreadNet.Infra.Shelley as Shelley
import           Test.ThreadNet.Infra.ShelleyShelley
import           Test.ThreadNet.TxGen.ShelleyShelley

import           Test.ThreadNet.Infra.TwoEras

-- | No Byron era, so our crypto can be trivial.
type Crypto = MockCrypto ShortHash

-- | The varying data of this test
--
-- Note: The Shelley1 nodes in this test all join, propose an update, and
-- endorse it literally as soon as possible. Therefore, if the test reaches the
-- end of the first epoch, the proposal will be adopted.
data TestSetup = TestSetup
  { setupD             :: Shelley.DecentralizationParam
  , setupHardFork      :: Bool
    -- ^ whether the proposal should trigger a hard fork or not
  , setupInitialNonce1 :: SL.Nonce
    -- ^ the initial Shelley 'SL.ticknStateEpochNonce'
    --
    -- We vary it to ensure we explore different leader schedules.
  , setupInitialNonce2 :: SL.Nonce
    -- ^ See 'setupInitialNonce1'.
  , setupK             :: SecurityParam
  , setupPartition     :: Partition
  , setupSlotLength1   :: SlotLength
  , setupSlotLength2   :: SlotLength
  , setupTestConfig    :: TestConfig
  , setupVersion       :: (NodeToNodeVersion, BlockNodeToNodeVersion (ShelleyShelleyBlock Crypto))
  }
  deriving (Show)

instance Arbitrary TestSetup where
  arbitrary = do
    setupD <- arbitrary
                -- The decentralization parameter cannot be 0 in the first
                -- Shelley epoch, since stake pools can only be created and
                -- delegated to via Shelley transactions.
                `suchThat` ((/= 0) . Shelley.decentralizationParamToRational)
    setupK <- SecurityParam <$> choose (8, 10)
                -- If k < 8, common prefix violations become too likely in
                -- Praos mode for thin overlay schedules (ie low d), even for
                -- f=0.2.

    setupInitialNonce1 <- genNonce
    setupInitialNonce2 <- genNonce

    setupSlotLength1 <- arbitrary
    setupSlotLength2 <- arbitrary

    let epochSize    = EpochSize $ shelleyEpochSize setupK
    setupTestConfig <- genTestConfig
                         setupK
                         (epochSize, epochSize)
    let TestConfig{numCoreNodes, numSlots} = setupTestConfig

    setupHardFork        <- frequency [(49, pure True), (1, pure False)]

    -- TODO How reliable is the Byron-based partition duration logic when
    -- reused for Shelley?
    setupPartition       <- genPartition numCoreNodes numSlots setupK

    setupVersion         <- genVersionFiltered
                              isHardForkNodeToNodeEnabled
                              (Proxy @(ShelleyShelleyBlock Crypto))

    pure TestSetup
      { setupD
      , setupHardFork
      , setupInitialNonce1
      , setupInitialNonce2
      , setupK
      , setupPartition
      , setupSlotLength1
      , setupSlotLength2
      , setupTestConfig
      , setupVersion
      }

  -- TODO shrink

-- | Run relatively fewer tests
--
-- These tests are slow, so we settle for running fewer of them in this test
-- suite since it is invoked frequently (eg CI for each push).
oneFifthTestCount :: QuickCheckTests -> QuickCheckTests
oneFifthTestCount (QuickCheckTests n) = QuickCheckTests $
    if 0 == n then 0 else
    max 1 $ n `div` 5

tests :: TestTree
tests = testGroup "ShelleyShelley ThreadNet" $
    [ let name = "simple convergence" in
      askIohkNightlyEnabled $ \enabled ->
      if enabled
      then testProperty name $ \setup ->
             prop_simple_shelleyShelley_convergence setup
      else adjustOption oneFifthTestCount $
           testProperty name $ \setup ->
             prop_simple_shelleyShelley_convergence setup
    ]

prop_simple_shelleyShelley_convergence :: TestSetup -> Property
prop_simple_shelleyShelley_convergence TestSetup
  { setupD
  , setupHardFork
  , setupInitialNonce1
  , setupInitialNonce2
  , setupK
  , setupPartition
  , setupSlotLength1
  , setupSlotLength2
  , setupTestConfig
  , setupVersion
  } =
    prop_general_semisync pga testOutput .&&.
    prop_inSync testOutput .&&.
    prop_ReachesEra2 reachesEra2 .&&.
    prop_noCPViolation .&&.
    ( tabulate "ReachesEra2 label" [label_ReachesEra2 reachesEra2] $
      tabulate "Observed forge during a non-overlay Shelley2 slot"
        [ label_hadActiveNonOverlaySlots
            testOutput
            overlaySlots
        ] $
      tabulatePartitionDuration setupK setupPartition $
      tabulateFinalIntersectionDepth
        setupK
        (NumBlocks finalIntersectionDepth)
        finalBlockEra $
      tabulatePartitionPosition
        (NumSlots numShelley1Slots)
        setupPartition
        (ledgerReachesEra2 reachesEra2) $
      property True
    )
  where
    TestConfig
      { initSeed
      , numCoreNodes
      , numSlots
      } = setupTestConfig

    pga = PropGeneralArgs
        { pgaBlockProperty       = const $ property True
        , pgaCountTxs            = fromIntegral . length . extractTxs
        , pgaExpectedCannotForge = noExpectedCannotForges
        , pgaFirstBlockNo        = 0
        , pgaFixedMaxForkLength  = Just maxForkLength
        , pgaFixedSchedule       =
            -- the leader schedule isn't fixed because the Shelley leader
            -- schedule is (at least ideally) unpredictable
            Nothing
        , pgaSecurityParam       = setupK
        , pgaTestConfig          = setupTestConfig
        , pgaTestConfigB         = testConfigB
        }

    testConfigB = TestConfigB
      { forgeEbbEnv  = Nothing
      , future       =
          if setupHardFork
          then
          -- In this case the PVU will trigger the transition to Shelley.
          --
          -- By FACT (B), the PVU is always successful if we reach the second
          -- era.
          EraCons  setupSlotLength1 epochSizeShelley1 eraSizeShelley1 $
          EraFinal setupSlotLength2 epochSizeShelley2
          else
          EraFinal setupSlotLength1 epochSizeShelley1
      , messageDelay = mkMessageDelay setupPartition
      , nodeJoinPlan = trivialNodeJoinPlan numCoreNodes
      , nodeRestarts = noRestarts
      , txGenExtra   = ShelleyTxGenExtra
        { stgeGenEnv  = mkGenEnv DoNotGeneratePPUs coreNodes
        , stgeStartAt = SlotNo 1
            -- We don't generate any transactions before the transaction
            -- carrying the proposal because they might consume its inputs
            -- before it does, thereby rendering it invalid.
        }
      , version      = setupVersion
      }

    testOutput :: TestOutput (ShelleyShelleyBlock Crypto)
    testOutput =
        runTestNetwork setupTestConfig testConfigB TestConfigMB
            { nodeInfo = \(CoreNodeId nid) ->
                TestNodeInitialization
                  { tniCrucialTxs   =
                      if not setupHardFork then [] else
                      fmap GenTxShelley1 $
                      Shelley.mkSetDecentralizationParamTxs
                        coreNodes
                        (SL.ProtVer majorVersion2 0)
                        (SlotNo $ unNumSlots numSlots)   -- never expire
                        setupD   -- unchanged
                  , tniProtocolInfo =
                      mkProtocolInfoShelleyShelley
                        genesis1
                        setupInitialNonce1
                        (coreNodes !! fromIntegral nid)
                        genesis2
                        setupInitialNonce2
                        (coreNodes !! fromIntegral nid)
                        (TriggerHardForkAtVersion majorVersion2)
                        (TriggerHardForkAtVersion majorVersionMA)
                  }
            , mkRekeyM = Nothing
            }

    maxForkLength :: NumBlocks
    maxForkLength = NumBlocks $ maxRollbacks setupK

    initialKESPeriod :: SL.KESPeriod
    initialKESPeriod = SL.KESPeriod 0

    coreNodes :: [Shelley.CoreNode (ShelleyEra Crypto)]
    coreNodes = runGen initSeed $
        replicateM (fromIntegral n) $
          Shelley.genCoreNode initialKESPeriod
      where
        NumCoreNodes n = numCoreNodes

    -- Shelley1

    genesis1 :: ShelleyGenesis (ShelleyEra Crypto)
    genesis1 =
        Shelley.mkGenesisConfig
          (SL.ProtVer majorVersion1 0)
          setupK
          activeSlotCoeff
          setupD
          setupSlotLength1
          (Shelley.mkKesConfig (Proxy @(ShelleyEra Crypto)) numSlots)
          coreNodes

    -- the Shelley ledger is designed to use a fixed epoch size, so this test
    -- does not randomize it
    epochSizeShelley1 :: EpochSize
    epochSizeShelley1 = sgEpochLength genesis1

    eraSizeShelley1 :: EraSize
    eraSizeShelley1 = EraSize numFirstEraEpochs

    -- Shelley2

    genesis2 :: ShelleyGenesis (ShelleyEra Crypto)
    genesis2 =
        Shelley.mkGenesisConfig
          (SL.ProtVer majorVersion2 0)
          setupK
          activeSlotCoeff
          setupD
          setupSlotLength2
          (Shelley.mkKesConfig (Proxy @(ShelleyEra Crypto)) numSlots)
          coreNodes

    -- the Shelley ledger is designed to use a fixed epoch size, so this test
    -- does not randomize it
    epochSizeShelley2 :: EpochSize
    epochSizeShelley2 = sgEpochLength genesis2

    -- Classifying test cases

    reachesEra2 :: ReachesEra2
    reachesEra2 = ReachesEra2
      { rsEra1Slots  =
          BoolProps.enabledIf $ t > numShelley1Slots
      , rsPV         = BoolProps.enabledIf setupHardFork
      , rsEra2Blocks =
          or $
          [ not $ isFirstEraBlock blk
          | (_nid, no) <- Map.toList testOutputNodes
          , let NodeOutput{nodeOutputForges} = no
          , (blk, _m) <- maybeToList $ Map.maxView nodeOutputForges
                -- the last block the node forged
          ]
      , rsEra2Slots  =
          --- TODO this comment and code are wrong

          BoolProps.requiredIf $
          -- The active slots in the first two Shelley epochs are all overlay
          -- slots, so the first Shelley block will arise from one of those.
          not $ Set.null overlaySlots
      }
      where
        NumSlots t                  = numSlots
        TestOutput{testOutputNodes} = testOutput

    -- All OBFT overlay slots in the second era.
    overlaySlots :: Set SlotNo
    overlaySlots =
        secondEraOverlaySlots
          numSlots
          (NumSlots numShelley1Slots)
          (SL._d (sgProtocolParams genesis2))
          epochSizeShelley2

    numShelley1Slots :: Word64
    numShelley1Slots =
        numFirstEraEpochs * unEpochSize epochSizeShelley1

    finalBlockEra :: String
    finalBlockEra =
        if rsEra2Blocks reachesEra2
        then "Shelley2"
        else "Shelley1"

    finalIntersectionDepth :: Word64
    finalIntersectionDepth = depth
      where
        NumBlocks depth = calcFinalIntersectionDepth pga testOutput

    prop_noCPViolation :: Property
    prop_noCPViolation =
        counterexample
          ( "finalChains: " <>
            show (nodeOutputFinalChain <$> testOutputNodes testOutput)
          ) $
        counterexample "CP violation in final chains!" $
        property $ maxRollbacks setupK >= finalIntersectionDepth

mkProtocolInfoShelleyShelley
  :: forall c m. (IOLike m, TPraosCrypto (ShelleyEra c))
     -- Shelley1
  => ShelleyGenesis (ShelleyEra c)
  -> SL.Nonce
  -> Shelley.CoreNode (ShelleyEra c)
     -- Shelley2
  -> ShelleyGenesis (ShelleyEra c)
  -> SL.Nonce
  -> Shelley.CoreNode (ShelleyEra c)
     -- Hard fork
  -> TriggerHardFork -- ^ Shelley1 to Shelley2
  -> TriggerHardFork -- ^ Shelley2 to ShelleyMA
  -> ProtocolInfo m (ShelleyShelleyBlock c)
mkProtocolInfoShelleyShelley
    genesis1 initialNonce1 coreNode1
    genesis2 initialNonce2 coreNode2
    transition1 transition2 =
    protocolInfoShelleyShelley
        -- Shelley 1
        genesis1
        initialNonce1
        protVer1
        maxMajorPVShelley
        coreNode1
        -- Shelley 2
        genesis2
        initialNonce2
        protVer2
        maxMajorPVShelley
        coreNode2
        -- Hard fork
        transition1
        transition2
  where
    -- Shelley1

    -- the protocol version that each node is endorsing with each Shelley 1
    -- block it forges (ie which the node is ready to run)
    protVer1 :: SL.ProtVer
    protVer1 = SL.ProtVer majorVersion2 0

    -- the protocol version that each node is endorsing with each Shelley block
    -- it forges (ie which the node is ready to run -- but not actually)
    protVer2 :: SL.ProtVer
    protVer2 = SL.ProtVer majorVersionMA 0

{-------------------------------------------------------------------------------
  Constants
-------------------------------------------------------------------------------}

-- | The major protocol version of Shelley1 in this test
majorVersion1 :: Num a => a
majorVersion1 = 0

-- | The major protocol version of Shelley2 in this test
majorVersion2 :: Num a => a
majorVersion2 = majorVersion1 + 1

-- | The major protocol version of ShelleyMA in this test
majorVersionMA :: Num a => a
majorVersionMA = majorVersion2 + 1
