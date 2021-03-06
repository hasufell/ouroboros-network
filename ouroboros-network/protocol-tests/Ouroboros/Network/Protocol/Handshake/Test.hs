{-# LANGUAGE GADTs               #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Ouroboros.Network.Protocol.Handshake.Test where

import           Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as BL
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Typeable (Typeable, cast)
import           Data.List (nub)
import           Data.Maybe (fromMaybe, isJust)
import qualified Data.Map as Map
import           GHC.Generics

import qualified Codec.CBOR.Read as CBOR
import qualified Codec.CBOR.Term as CBOR

import           Control.Monad.IOSim (runSimOrThrow)
import           Control.Monad.Class.MonadAsync (MonadAsync)
import           Control.Monad.Class.MonadST (MonadST)
import           Control.Monad.Class.MonadThrow ( MonadCatch
                                                , MonadThrow
                                                )
import           Control.Tracer (nullTracer)

import           Network.TypedProtocol.Proofs

import           Test.Ouroboros.Network.Testing.Utils (prop_codec_cborM, splits2, splits3)

import           Ouroboros.Network.Channel
import           Ouroboros.Network.Codec
import           Ouroboros.Network.CodecCBORTerm
import           Ouroboros.Network.Driver.Simple ( runConnectedPeers
                                                 , runConnectedPeersAsymmetric
                                                 )

import           Ouroboros.Network.Protocol.Handshake.Type
import           Ouroboros.Network.Protocol.Handshake.Client
import           Ouroboros.Network.Protocol.Handshake.Server
import           Ouroboros.Network.Protocol.Handshake.Codec
import           Ouroboros.Network.Protocol.Handshake.Version
import           Ouroboros.Network.Protocol.Handshake.Direct

import qualified Codec.CBOR.Write    as CBOR

import           Test.QuickCheck
import           Test.Tasty (TestTree, testGroup)
import           Test.Tasty.QuickCheck (testProperty)

tests :: TestTree
tests =
  testGroup "Ouroboros.Network.Protocol.Handshake"
  [ testProperty "connect"               prop_connect
  , testProperty "channel ST"            prop_channel_ST
  , testProperty "channel IO"            prop_channel_IO
  , testProperty "pipe IO"               prop_pipe_IO
  , testProperty "channel asymmetric ST" prop_channel_asymmetric_ST
  , testProperty "channel asymmetric IO" prop_channel_asymmetric_IO
  , testProperty "pipe asymmetric IO"    prop_pipe_asymmetric_IO
  , testProperty "codec RefuseReason"    prop_codec_RefuseReason
  , testProperty "codec"                 prop_codec_Handshake
  , testProperty "codec 2-splits"        prop_codec_splits2_Handshake
  , testProperty "codec 3-splits"      $ withMaxSuccess 30
                                         prop_codec_splits3_Handshake
  , testProperty "codec cbor"            prop_codec_cbor
  , testGroup "Generators"
    [ testProperty "ArbitraryVersions" $
        checkCoverage prop_arbitrary_ArbitraryVersions
    , testProperty "arbitrary ArbitraryValidVersions"
        prop_arbitrary_ArbitraryValidVersions
    , testProperty "shrink ArbitraryValidVersions"
        prop_shrink_ArbitraryValidVersions
    ]
  ]

--
-- Test Versions
--
-- Notes: Associated data are choosen in such a way that a decoder will fail
-- interpreting one of them as the other.  This is done on purpose for testing
-- missencoded data (protocol version & associated version data mismatch)
--

-- |
-- Testing version number
--
data VersionNumber
  = Version_0
  | Version_1
  | Version_2
  deriving (Eq, Ord, Enum, Bounded, Show)

instance Arbitrary VersionNumber where
  arbitrary = elements [minBound .. maxBound]

versionNumberCodec :: CodecCBORTerm (String, Maybe Int) VersionNumber
versionNumberCodec = CodecCBORTerm { encodeTerm, decodeTerm }
  where
    encodeTerm Version_0 = CBOR.TInt 0
    encodeTerm Version_1 = CBOR.TInt 1
    encodeTerm Version_2 = CBOR.TInt 2

    decodeTerm (CBOR.TInt 0) = Right Version_0
    decodeTerm (CBOR.TInt 1) = Right Version_1
    decodeTerm (CBOR.TInt 2) = Right Version_2
    decodeTerm (CBOR.TInt n) = Left ("unknown version", Just n)
    decodeTerm _              = Left ("unknown tag", Nothing)


versionNumberHandshakeCodec :: ( MonadST    m
                               , MonadThrow m
                               )
                            => Codec (Handshake VersionNumber CBOR.Term)
                                      CBOR.DeserialiseFailure m ByteString
versionNumberHandshakeCodec = codecHandshake versionNumberCodec

-- |
-- Data Associated with @'Version_0'@
--
data Data_0 = C0 | C1 | C2
  deriving (Eq, Show, Typeable, Generic)

instance Acceptable Data_0 where
  acceptableVersion l r | l == r = Accept l
                        | otherwise =  Refuse $ T.pack ""

data0CodecCBORTerm :: CodecCBORTerm Text Data_0
data0CodecCBORTerm = CodecCBORTerm {encodeTerm, decodeTerm}
    where
      -- We are using @CBOR.TInt@ instead of @CBOR.TInteger@, since for small
      -- integers generated by QuickCheck they will be encoded as @TkInt@ and then
      -- are decodec back to @CBOR.TInt@ rather than @COBR.TInteger@.  The same for
      -- other @CodecCBORTerm@ records.
      encodeTerm C0 = CBOR.TInt 0
      encodeTerm C1 = CBOR.TInt 1
      encodeTerm C2 = CBOR.TInt 2

      decodeTerm (CBOR.TInt 0) = Right C0
      decodeTerm (CBOR.TInt 1) = Right C1
      decodeTerm (CBOR.TInt 2) = Right C2
      decodeTerm n             = Left $ T.pack $ "decodeTerm Data_0: unrecognised tag: " ++ show n

instance Arbitrary Data_0 where
  arbitrary = elements [C0, C1, C2]

instance CoArbitrary Data_0 where

-- |
-- Data associated with @'Version_1'@
--
data Data_1 = Data_1 Bool
  deriving (Eq, Show, Typeable, Generic)

instance Acceptable Data_1 where
  acceptableVersion l r | l == r = Accept l
                        | otherwise =  Refuse $ T.pack ""

data1CodecCBORTerm :: CodecCBORTerm Text Data_1
data1CodecCBORTerm = CodecCBORTerm {encodeTerm, decodeTerm}
    where
      encodeTerm (Data_1 b) = CBOR.TBool b

      decodeTerm (CBOR.TBool b) = Right (Data_1 b)
      decodeTerm _              = Left $ T.pack "decodeTerm Data_1: wrong encoding"

instance Arbitrary Data_1 where
  arbitrary = Data_1 <$> arbitrary
  shrink = genericShrink

instance CoArbitrary Data_1

-- |
-- Data associated with @'Version_2'@
--
data Data_2 = Data_2 Word Word
  deriving (Eq, Show, Typeable, Generic)

instance Acceptable Data_2 where
  acceptableVersion l r | l == r = Accept l
                        | otherwise =  Refuse $ T.pack ""

data2CodecCBORTerm :: CodecCBORTerm Text Data_2
data2CodecCBORTerm = CodecCBORTerm {encodeTerm, decodeTerm}
    where
      encodeTerm (Data_2 n m) = CBOR.TList [CBOR.TInt (fromIntegral n), CBOR.TInt (fromIntegral m)]
      decodeTerm (CBOR.TList (CBOR.TInt n : CBOR.TInt m : _)) = Right (Data_2 (fromIntegral n) (fromIntegral m))
      decodeTerm _ = Left $ T.pack "decodeTerm Data_2: wrong encoding"

instance Arbitrary Data_2 where
  arbitrary = Data_2 <$> arbitrary <*> arbitrary
  shrink = genericShrink

instance CoArbitrary Data_2 where

--
-- ProtocolVersion generators
--

-- |
-- Generate a valid @'ProtocolVersion' 'VersionNumber' r@
--
genValidVersion
  :: VersionNumber
  -> Gen (Sigma (Version (DictVersion VersionNumber ()) Bool))
genValidVersion Version_0 = do
  (d0 :: Data_0) <- arbitrary
  return $ Sigma d0 (Version
                      (Application (d0 ==))
                      (DictVersion data0CodecCBORTerm (\_ _ -> ())))
genValidVersion Version_1 = do
  (d1 :: Data_1) <- arbitrary
  return $ Sigma d1 (Version
                      (Application (d1 ==))
                      (DictVersion data1CodecCBORTerm (\_ _ -> ())))
genValidVersion Version_2 = do
  (d2 :: Data_2) <- arbitrary
  return $ Sigma d2 (Version
                      (Application (d2 ==))
                      (DictVersion data2CodecCBORTerm (\_ _ -> ())))


-- |
-- Generate an invalid @'ProtocolVersion' 'VersionNumber' r@.
--
genInvalidVersion
  :: VersionNumber
  -> Gen (Sigma (Version (DictVersion VersionNumber ()) Bool))
genInvalidVersion Version_0 = arbitrary >>= \b ->
  if b
    then do
      (d1 :: Data_1) <- arbitrary
      return $ Sigma d1 (Version
                          (Application (d1 ==))
                          (DictVersion data1CodecCBORTerm (\_ _ -> ())))
    else do
      (d2 :: Data_2) <- arbitrary
      return $ Sigma d2 (Version
                          (Application (d2 ==))
                          (DictVersion data2CodecCBORTerm (\_ _ -> ())))
genInvalidVersion Version_1 = arbitrary >>= \b ->
  if b
    then do
      (d0 :: Data_0) <- arbitrary
      return $ Sigma d0 (Version
                          (Application (d0 ==))
                          (DictVersion data0CodecCBORTerm (\_ _ -> ())))
    else do
      (d2 :: Data_2) <- arbitrary
      return $ Sigma d2 (Version
                          (Application (d2 ==))
                          (DictVersion data2CodecCBORTerm (\_ _ -> ())))
genInvalidVersion Version_2 = arbitrary >>= \b ->
  if b
    then do
      (d0 :: Data_0) <- arbitrary
      return $ Sigma d0 (Version
                          (Application (d0 ==))
                          (DictVersion data0CodecCBORTerm (\_ _ -> ())))
    else do
      (d1 :: Data_1) <- arbitrary
      return $ Sigma d1 (Version
                          (Application (d1 ==))
                          (DictVersion data1CodecCBORTerm (\_ _ -> ())))

-- |
-- Generate valid @Versions@.
--
genValidVersions :: Gen (Versions VersionNumber (DictVersion VersionNumber ()) Bool)
genValidVersions = do
  vns <- nub <$> resize 3 (listOf1 (arbitrary :: Gen VersionNumber))
  vs <- traverse genValidVersion vns
  return $ Versions $ Map.fromList $ zip vns vs

-- |
-- Generate possible invalid @Versions@.
--
genVersions :: Gen (Versions VersionNumber (DictVersion VersionNumber ()) Bool)
genVersions = do
  vns <- nub <$> resize 3 (listOf1 (arbitrary :: Gen VersionNumber))
  vs <- traverse (\v -> oneof [genValidVersion v, genInvalidVersion v]) vns
  return $ Versions $ Map.fromList $ zip vns vs

newtype ArbitraryValidVersions = ArbitraryValidVersions {
      runArbitraryValidVersions :: Versions VersionNumber (DictVersion VersionNumber ()) Bool
    }

instance Show ArbitraryValidVersions where
    show (ArbitraryValidVersions (Versions vs)) = show $ map (\(vn, Sigma vData (Version _ DictVersion {})) -> (vn, show vData)) $ Map.toList vs

instance Arbitrary ArbitraryValidVersions where
    arbitrary = ArbitraryValidVersions <$> genValidVersions
    shrink (ArbitraryValidVersions (Versions vs)) =
      [ ArbitraryValidVersions (Versions $ Map.fromList vs')
      | vs' <- shrinkList (const []) (Map.toList vs)
      ]

prop_arbitrary_ArbitraryValidVersions
  :: ArbitraryValidVersions
  -> Bool
prop_arbitrary_ArbitraryValidVersions (ArbitraryValidVersions vs) = Map.foldlWithKey' (\r vn s -> r && validVersion vn s) True (getVersions vs)

prop_shrink_ArbitraryValidVersions
  :: ArbitraryValidVersions
  -> Bool
prop_shrink_ArbitraryValidVersions a = all id
  [ Map.foldlWithKey' (\r vn s -> r && validVersion vn s) True (getVersions vs')
  | ArbitraryValidVersions vs' <- shrink a
  ]

-- |
-- Generators for pairs of arbitrary list of versions.
--
data ArbitraryVersions =
  ArbitraryVersions
    (Versions VersionNumber (DictVersion VersionNumber ()) Bool)
    (Versions VersionNumber (DictVersion VersionNumber ()) Bool)

instance Show ArbitraryVersions where
    show (ArbitraryVersions (Versions vs) (Versions vs')) = "ArbitraryVersions " ++ fn vs ++ " " ++ fn vs'
         where
           fn x = show $ map (\(vn, Sigma vData (Version _ DictVersion {})) -> (vn, show vData)) $ Map.toList x

instance Arbitrary ArbitraryVersions where
    arbitrary = frequency
      [ (1, (\v -> ArbitraryVersions v v) <$> genVersions)
      , (2, ArbitraryVersions <$> genVersions <*> genVersions)
      ]
    shrink (ArbitraryVersions (Versions vs) (Versions vs')) = 
      [ ArbitraryVersions (Versions $ Map.fromList vs'') (Versions vs')
      | vs'' <- shrinkList (const []) (Map.toList vs)
      ] ++
      [ ArbitraryVersions (Versions vs) (Versions $ Map.fromList vs'')
      | vs'' <- shrinkList (const []) (Map.toList vs')
      ]


-- |
-- Check if a @'ProtocolVersion' 'VersionNumber' r@ is valid.
--
validVersion :: VersionNumber -> Sigma (Version (DictVersion VersionNumber ()) Bool) -> Bool
validVersion Version_0 (Sigma d (Version _ DictVersion {})) = isJust (cast d :: Maybe Data_0)
validVersion Version_1 (Sigma d (Version _ DictVersion {})) = isJust (cast d :: Maybe Data_1)
validVersion Version_2 (Sigma d (Version _ DictVersion {})) = isJust (cast d :: Maybe Data_2)


prop_arbitrary_ArbitraryVersions :: ArbitraryVersions -> Property
prop_arbitrary_ArbitraryVersions (ArbitraryVersions (Versions vs) (Versions vs')) =
    -- in 80% of cases the intersection is non-empty
    cover 80 intersect "non-empty intersection" $

    -- in 10% of cases the intersection is empty
    cover 10 (not intersect) "empty intersection" $

    -- in 25% of cases the common max version is valid
    cover 25 (case Map.lookupMax intersection of
               Nothing -> False
               Just (vn, s)  -> validVersion vn s)
               "valid common max version" $

    -- in 40% of cases all the versions in @vs'@ are either not in @vs@ or are
    -- not valid
    cover 40
      (Map.foldlWithKey' (\r vn s -> r && (not (vn `elem` knownVersionNumbers) || not (validVersion vn s))) True vs)
      "all versions are either unknown or not valid" $

    property True
  where
    intersection = vs `Map.intersection` vs'
    intersect    = not (Map.null intersection)

    knownVersionNumbers = Map.keys vs'

-- | Run a handshake protocol, without going via a channel.
--
prop_connect :: ArbitraryVersions -> Property
prop_connect (ArbitraryVersions clientVersions serverVersions) =
  let (serverRes, clientRes) = pureHandshake
        (\DictVersion {} -> Dict)
        (\DictVersion {} vData vData' ->
            case acceptableVersion vData vData' of
                 Accept _ -> True
                 _        -> False
        )
        serverVersions
        clientVersions
  in case runSimOrThrow
           (connect
              (handshakeClientPeer
                cborTermVersionDataCodec
                (\DictVersion {} -> acceptableVersion)
                clientVersions)
              (handshakeServerPeer
                cborTermVersionDataCodec
                (\DictVersion {} -> acceptableVersion)
                serverVersions)) of
      (clientRes', serverRes', TerminalStates TokDone TokDone) ->
           fromMaybe False clientRes === either (const False) fst clientRes'
        .&&.
           fromMaybe False serverRes === either (const False) fst serverRes'
--
-- Properties using a channel
--

-- | Run a simple block-fetch client and server using connected channels.
--
prop_channel :: ( MonadAsync m
                , MonadCatch m
                , MonadST m
                )
             => m (Channel m ByteString, Channel m ByteString)
             -> Versions VersionNumber (DictVersion VersionNumber ()) Bool
             -> Versions VersionNumber (DictVersion VersionNumber ()) Bool
             -> m Property
prop_channel createChannels clientVersions serverVersions =
  let (serverRes, clientRes) = pureHandshake
        (\DictVersion {} -> Dict)
        (\DictVersion {} vData vData' ->
            case acceptableVersion vData vData' of
                 Accept _ -> True
                 _        -> False
        )
        serverVersions
        clientVersions
  in do
    (clientRes', serverRes') <-
      runConnectedPeers
        createChannels nullTracer versionNumberHandshakeCodec
        (handshakeClientPeer
          cborTermVersionDataCodec
          (\DictVersion {} -> acceptableVersion)
          clientVersions)
        (handshakeServerPeer
          cborTermVersionDataCodec
          (\DictVersion {} -> acceptableVersion)
          serverVersions)
    pure $
      case (clientRes', serverRes') of
        -- buth succeeded, we just check that the application (which is
        -- a boolean value) is the one that was put inside 'Version'
        (Right c, Right s) -> Just (fst c) === clientRes
                         .&&. Just (fst s) === serverRes

        -- both failed
        (Left{}, Left{})   -> property True

        -- it should not happen that one protocol succeeds and the other end
        -- fails
        _                  -> property False


-- | Run 'prop_channel' in the simulation monad.
--
prop_channel_ST :: ArbitraryVersions -> Property
prop_channel_ST (ArbitraryVersions clientVersions serverVersions) =
    runSimOrThrow (prop_channel createConnectedChannels clientVersions serverVersions)


-- | Run 'prop_channel' in the IO monad.
--
prop_channel_IO :: ArbitraryVersions -> Property
prop_channel_IO (ArbitraryVersions clientVersions serverVersions) =
    ioProperty (prop_channel createConnectedChannels clientVersions serverVersions)


-- | Run 'prop_channel' in the IO monad using local pipes.
--
prop_pipe_IO :: ArbitraryVersions -> Property
prop_pipe_IO (ArbitraryVersions clientVersions serverVersions) =
    ioProperty (prop_channel createPipeConnectedChannels clientVersions serverVersions)

--
-- Asymmetric tests
--


-- | Run a simple handshake client and server using connected channels.
-- The server can only decode a subset of versions send by client.
-- This test is using a fixed serverver 'Versions' which can only accept
-- a single version 'Version_1' (it cannot decode any other version).
--
prop_channel_asymmetric
    :: ( MonadAsync m
       , MonadCatch m
       , MonadST m
       )
    => m (Channel m ByteString, Channel m ByteString)
    -> Versions VersionNumber (DictVersion VersionNumber ()) Bool
    -- ^ client versions
    -> m Property
prop_channel_asymmetric createChannels clientVersions = do
    (clientRes', serverRes') <-
      runConnectedPeersAsymmetric
        createChannels
        nullTracer
        versionNumberHandshakeCodec
        (codecHandshake versionNumberCodec')
        (handshakeClientPeer
          cborTermVersionDataCodec
          (\DictVersion {} -> acceptableVersion)
          clientVersions)
        (handshakeServerPeer
          cborTermVersionDataCodec
          (\DictVersion {} -> acceptableVersion)
          serverVersions)
    pure $
      case (clientRes', serverRes') of
        (Right (c, _), Right (s, _))
                           ->      Just c === clientRes
                              .&&. Just s === serverRes
        (Left{}, Left{})   -> property True
        _                  -> property False

  where
    -- server versions
    serverVersions :: Versions VersionNumber (DictVersion VersionNumber ()) Bool
    serverVersions =
      Versions
        $ Map.singleton
            Version_1
            (Sigma
              (Data_1 True)
              (Version (Application (Data_1 True ==))
              (DictVersion data1CodecCBORTerm (\_ _ -> ()))))

    -- This codec does not know how to decode 'Version_0' and 'Version_2'.
    versionNumberCodec' :: CodecCBORTerm (String, Maybe Int) VersionNumber
    versionNumberCodec' = CodecCBORTerm { encodeTerm, decodeTerm }
      where
        encodeTerm Version_1 = CBOR.TInt 1
        encodeTerm _         = error "server encoder error"

        decodeTerm (CBOR.TInt 1) = Right Version_1
        decodeTerm (CBOR.TInt n) = Left ("unknown version", Just n)
        decodeTerm _             = Left ("unknown tag", Nothing)

    (serverRes, clientRes) =
      pureHandshake
        (\DictVersion {} -> Dict)
        (\DictVersion {} vData vData' ->
            case acceptableVersion vData vData' of
                 Accept _ -> True
                 _        -> False
        )
        serverVersions
        clientVersions



-- | Run 'prop_channel' in the simulation monad.
--
prop_channel_asymmetric_ST :: ArbitraryVersions -> Property
prop_channel_asymmetric_ST (ArbitraryVersions clientVersions _serverVersions) =
    runSimOrThrow (prop_channel_asymmetric createConnectedChannels clientVersions)


-- | Run 'prop_channel' in the IO monad.
--
prop_channel_asymmetric_IO :: ArbitraryVersions -> Property
prop_channel_asymmetric_IO (ArbitraryVersions clientVersions _serverVersions) =
    ioProperty (prop_channel_asymmetric createConnectedChannels clientVersions)


-- | Run 'prop_channel' in the IO monad using local pipes.
--
prop_pipe_asymmetric_IO :: ArbitraryVersions -> Property
prop_pipe_asymmetric_IO (ArbitraryVersions clientVersions _serverVersions) =
    ioProperty (prop_channel_asymmetric createPipeConnectedChannels clientVersions)


--
-- Codec tests
--

instance Eq (AnyMessage (Handshake VersionNumber CBOR.Term)) where
  AnyMessage (MsgProposeVersions vs) == AnyMessage (MsgProposeVersions vs')
    = vs == vs'

  AnyMessage (MsgAcceptVersion vNumber vParams) == AnyMessage (MsgAcceptVersion vNumber' vParams')
    = vNumber == vNumber' && vParams == vParams'

  AnyMessage (MsgRefuse vReason) == AnyMessage (MsgRefuse vReason')
    = vReason == vReason'

  _ == _ = False

instance Arbitrary (AnyMessageAndAgency (Handshake VersionNumber CBOR.Term)) where
  arbitrary = oneof
    [     AnyMessageAndAgency (ClientAgency TokPropose)
        . MsgProposeVersions
        . fmap (\(Sigma vData (Version _ (DictVersion codec _))) -> encodeTerm codec vData)
        . getVersions
      <$> genVersions

    ,     AnyMessageAndAgency (ServerAgency TokConfirm)
        . uncurry MsgAcceptVersion
      <$> genValidVersion'

    ,     AnyMessageAndAgency (ServerAgency TokConfirm)
        . MsgRefuse
        . runArbitraryRefuseReason
      <$> arbitrary
    ]
    where
      genValidVersion' :: Gen (VersionNumber, CBOR.Term)
      genValidVersion' = do
        vn <- arbitrary
        Sigma vData (Version _ (DictVersion codec _)) <- genValidVersion vn
        pure (vn, encodeTerm codec vData)


newtype ArbitraryRefuseReason = ArbitraryRefuseReason {
    runArbitraryRefuseReason :: RefuseReason VersionNumber
  }
  deriving (Eq, Show)


instance Arbitrary ArbitraryRefuseReason where
    arbitrary = ArbitraryRefuseReason <$> oneof
      [ VersionMismatch
          <$> arbitrary
          -- this argument is not supposed to be sent, only received:
          <*> pure []
      , HandshakeDecodeError <$> arbitrary <*> arbitraryText
      , Refused <$> arbitrary <*> arbitraryText
      ]
      where
        arbitraryText = T.pack <$> arbitrary


--
--  TODO: these tests should be moved to 'ouroboros-network-framework'
--

-- TODO: we are not testing the cases where we decode version numbers that we do
-- not know about.
prop_codec_RefuseReason
  :: ArbitraryRefuseReason
  -> Bool
prop_codec_RefuseReason (ArbitraryRefuseReason vReason) = 
  case CBOR.deserialiseFromBytes
        (decodeRefuseReason versionNumberCodec)
        (CBOR.toLazyByteString $ encodeRefuseReason versionNumberCodec vReason) of
    Left _ -> False
    Right (bytes, vReason') -> BL.null bytes && vReason' == vReason

prop_codec_Handshake
  :: AnyMessageAndAgency (Handshake VersionNumber CBOR.Term)
  -> Bool
prop_codec_Handshake msg =
  runSimOrThrow (prop_codecM (codecHandshake versionNumberCodec) msg)

prop_codec_splits2_Handshake
  :: AnyMessageAndAgency (Handshake VersionNumber CBOR.Term)
  -> Bool
prop_codec_splits2_Handshake msg =
  runSimOrThrow (prop_codec_splitsM splits2 (codecHandshake versionNumberCodec) msg)

prop_codec_splits3_Handshake
  :: AnyMessageAndAgency (Handshake VersionNumber CBOR.Term)
  -> Bool
prop_codec_splits3_Handshake msg =
  runSimOrThrow (prop_codec_splitsM splits3 (codecHandshake versionNumberCodec) msg)

prop_codec_cbor
  :: AnyMessageAndAgency (Handshake VersionNumber CBOR.Term)
  -> Bool
prop_codec_cbor msg =
  runSimOrThrow (prop_codec_cborM (codecHandshake versionNumberCodec) msg)
