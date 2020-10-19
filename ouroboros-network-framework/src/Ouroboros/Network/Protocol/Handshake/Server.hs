{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Ouroboros.Network.Protocol.Handshake.Server
  ( handshakeServerPeer
  ) where

import qualified Data.Map as Map
import           Data.List (intersect)

import           Network.TypedProtocol.Core

import           Ouroboros.Network.Protocol.Handshake.Codec
import           Ouroboros.Network.Protocol.Handshake.Type
import           Ouroboros.Network.Protocol.Handshake.Version


-- | Server following the handshake protocol; it accepts highest version offered
-- by the peer that also belongs to the server @versions@.
--
-- TODO: GADT encoding of the server (@Handshake.Server@ module).
--
handshakeServerPeer
  :: Ord vNumber
  => VersionDataCodec vParams vNumber vData
  -> (vData -> vData -> Accept)
  -- ^ accept should return 'vData', e.g.
  -- ```
  -- data Accept vData
  --  Accepted vData
  --  Refuse Text
  -- ```
  -> Versions vNumber vData r
  -> Peer (Handshake vNumber vParams)
          AsServer StPropose m
          (Either (RefuseReason vNumber) (r, vNumber, vData))
handshakeServerPeer VersionDataCodec {encodeData, decodeData} acceptVersion versions =
    -- await for versions proposed by a client
    Await (ClientAgency TokPropose) $ \msg -> case msg of

      MsgProposeVersions vMap ->
        -- Compute intersection of local and remote versions.  We cannot
        -- intersect @vMap@ and @getVersions versions@ as the values have
        -- different types.
        case map fst (Map.toDescList vMap) `intersect` map fst (Map.toDescList (getVersions versions)) of
          [] ->
            let vReason = VersionMismatch (Map.keys $ getVersions versions) []
            in Yield (ServerAgency TokConfirm)
                     (MsgRefuse vReason)
                     (Done TokDone (Left vReason))

          vNumber:_ ->
            case (getVersions versions Map.! vNumber, vMap Map.! vNumber) of
              (Version app vData, vParams) -> case decodeData vParams of
                Left err ->
                  let vReason = HandshakeDecodeError vNumber err
                  in Yield (ServerAgency TokConfirm)
                           (MsgRefuse vReason)
                           (Done TokDone $ Left vReason)

                Right vData' ->
                  case acceptVersion vData vData' of

                    -- We agree on the version; send back the agreed version
                    -- number @vNumber@ and encoded data associated with our
                    -- version.
                    Accept ->
                      Yield (ServerAgency TokConfirm)
                            -- TODO: we should combine @vData@ & @vData'@ and
                            -- send options that we will use.
                            (MsgAcceptVersion vNumber (encodeData vData))
                            (Done TokDone $ Right $
                              -- TODO: there's no sense to `runApplication` with
                              -- both data and return it at the same time, we
                              -- could just return negotitiated `vData`.
                              -- Altother the `Application` type is not useful
                              -- at this level.
                              ( runApplication app vData vData'
                              , vNumber
                              , vData
                              ))

                    -- We disagree on the version.
                    Refuse err ->
                      let vReason = Refused vNumber err
                      in Yield (ServerAgency TokConfirm)
                               (MsgRefuse vReason)
                               (Done TokDone $ Left $ vReason)

