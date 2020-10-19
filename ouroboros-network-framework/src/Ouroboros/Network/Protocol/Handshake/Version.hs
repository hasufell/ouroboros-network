{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeOperators              #-}

module Ouroboros.Network.Protocol.Handshake.Version
  ( Versions (..)
  , Application (..)
  , Version (..)
  , Accept (..)
  , Acceptable (..)
  , Dict (..)
  , DictVersion (..)
  , pickVersions
  , VersionMismatch (..)

  -- * Simple or no versioning
  , simpleSingletonVersions
  , foldMapVersions
  , combineVersions
  ) where

import           Data.Foldable (toList)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Text (Text)
import           Data.Typeable ((:~:) (Refl), Typeable, eqT)
import           GHC.Stack (HasCallStack)

import           Ouroboros.Network.CodecCBORTerm


-- Description of versions.
--
-- - Each particular version is a function from a pair of version data
--   (peculiar to that version, existentially-quantified) to some result
--   type (called `r` in this module).
-- - A version-numbering scheme, and the set of supported versions, is
--   defined simultaneously by a `Map` keyed on something, perhaps `Word32` in
--   a real-world instance. The `Sigma` GADT pairs the particular version data
--   with each version definition.

-- | The set of versions supported by the local agent are described by a map
-- keyed on the version identifier.
--
-- If one needs to combine multiple versions the simplest way is to use
-- one of the combinators: 'foldMapVersions', 'combineVersions' or the
-- 'Semigroup' instance directly:
--
-- >
-- > fold $ (simpleSingletonVersions ...)
-- >       :| [ (simpleSingletonVersions ...)
-- >          , (simpleSingletonVersions ...)
-- >          , ...
-- >          ]
-- >
--
newtype Versions vNum vData r = Versions
  { getVersions :: Map vNum (Version vData r)
  }
  deriving (Semigroup)

instance Functor (Versions vNum extra) where
    fmap f (Versions vs) = Versions $ Map.map (fmap f)  vs


-- | Useful for folding multiple 'Versions'.
--
-- A 'foldMap' restricted to the 'Versions' 'Semigroup'.
--
-- PRECONDITION: @f x@ is non-empty.
--
foldMapVersions :: (Ord vNum, Foldable f, HasCallStack)
                => (x -> Versions vNum extra r)
                -> f x
                -> Versions vNum extra r
foldMapVersions f fx = case toList fx of
    [] -> error "foldMapVersions: precondition violated"
    xs -> foldl1 (<>) (map f xs)

combineVersions :: (Ord vNum, Foldable f, HasCallStack)
                => f (Versions vNum extra r)
                -> Versions vNum extra r
combineVersions = foldMapVersions id

-- |
-- A @'Maybe'@ like type which better explains its purpose.
--
data Accept
  = Accept
  | Refuse !Text
  deriving (Eq, Show)

class Acceptable v where
  acceptableVersion :: v -> v -> Accept

-- | Takes a pair of version data: local then remote.
newtype Application vData r = Application
  { runApplication :: vData -> vData -> r
  }
  deriving Functor


data Version vData r = Version
  { versionApplication :: Application vData r
  , versionData        :: vData
  }
  deriving Functor

data VersionMismatch vNum where
  NoCommonVersion     :: VersionMismatch vNum
  InconsistentVersion :: vNum -> VersionMismatch vNum

data Dict constraint thing where
  Dict :: constraint thing => Dict constraint thing

-- | 'DictVersion' is used to instantiate the 'extra' param of 'Version'.
-- 'hanshakeParams' is instatiated in either "Ouroboros.Network.NodeToNode" or
-- "Ouroboros.Network.NodeToClient" to 'HandshakeParams'.
--
data DictVersion vNumber vData where
     DictVersion :: ( Typeable vData
                    , Acceptable vData
                    , Show vData
                    )
                 => CodecCBORTerm Text vData
                 -> DictVersion vNumber vData

-- | Pick the version with the highest version number (by `Ord vNum`) common
-- in both maps.
--
-- This is a useful guide for comparison with a version negotiation scheme for
-- use in production between different processes. If the `Versions` maps
-- used by each process are given to `pickVersions`, it should come up with
-- the same result as the production version negotiation.
--
-- It is _assumed_ that if the maps agree on a key, then the existential
-- types in the `Sigma` value at the key are also equal.
--
-- So, the issue here is that they may not have the same version data type.
-- This becomes a non-issue on the network because the decoder/encoder
-- basically fills the role of a safe dynamic type cast.
pickVersions
  :: Ord vNum
  => Versions vNum vData r
  -> Versions vNum vData r
  -> Either (VersionMismatch vNum) (r, r)
pickVersions lversions rversions = case Map.toDescList commonVersions of
  [] -> Left NoCommonVersion
  (vNum, (Version lapp ldata, Version rapp rdata)) : _ ->
      -- TODO: data negotiation!
      Right ( runApplication lapp ldata rdata
            , runApplication rapp rdata ldata
            )
  where
  commonVersions = getVersions lversions `intersect` getVersions rversions
  intersect = Map.intersectionWith (,)

--
-- Simple version negotation
--

-- | Singleton smart constructor for 'Versions'.
--
simpleSingletonVersions
  :: vNum
  -> vData
  -> r
  -> Versions vNum vData r
simpleSingletonVersions vNum vData r =
  Versions
    $ Map.singleton vNum
      (Version (Application (\_ _ -> r)) vData)
