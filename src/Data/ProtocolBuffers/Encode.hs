{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module Data.ProtocolBuffers.Encode
  ( Encode(..)
  , encodeMessage
  , encodeLengthPrefixedMessage
  ) where

import qualified Data.ByteString as B
import Data.Foldable
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Serialize.Put
import Data.Tagged

import GHC.Generics
import GHC.TypeLits

import Data.ProtocolBuffers.Wire

-- |
-- Encode a Protocol Buffers message.
encodeMessage :: Encode a => a -> Put
encodeMessage = encode

-- |
-- Encode a Protocol Buffers message prefixed with a 32-bit integer describing it's length.
encodeLengthPrefixedMessage :: Encode a => a -> Put
{-# INLINE encodeLengthPrefixedMessage #-}
encodeLengthPrefixedMessage msg = do
  let msg' = runPut $ encodeMessage msg
  putWord32le . fromIntegral $ B.length msg'
  putByteString msg'

class Encode (a :: *) where
  encode :: a -> Put
  default encode :: (Generic a, GEncode (Rep a)) => a -> Put
  encode = gencode . from

instance Encode (HashMap Tag [Field]) where
  encode = traverse_ step . HashMap.toList where
    step = uncurry (traverse_ . encodeWire)

class GEncode (f :: * -> *) where
  gencode :: f a -> Put

instance GEncode a => GEncode (M1 i c a) where
  gencode = gencode . unM1

instance (GEncode a, GEncode b) => GEncode (a :*: b) where
  gencode (x :*: y) = gencode x >> gencode y

instance (GEncode a, GEncode b) => GEncode (a :+: b) where
  gencode (L1 x) = gencode x
  gencode (R1 y) = gencode y

instance (Wire a, Foldable f, SingI n) => GEncode (K1 i (Tagged (n :: Nat) (f a))) where
  gencode = traverse_ (encodeWire tag) . unTagged . unK1 where
    tag = fromIntegral $ fromSing (sing :: Sing n)
