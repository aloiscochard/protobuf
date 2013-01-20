{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module Data.ProtocolBuffers.Decode
  ( Decode(..)
  , decodeMessage
  , decodeLengthPrefixedMessage
  ) where

import Control.Applicative
import Control.Monad
import Control.Monad.Identity
import qualified Data.ByteString as B
import Data.Foldable
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Int (Int64)
import Data.Monoid
import Data.Serialize.Get
import Data.Tagged
import Data.Traversable

import GHC.Generics
import GHC.TypeLits

import Data.ProtocolBuffers.Types
import Data.ProtocolBuffers.Wire

-- |
-- Decode a Protocol Buffers message.
decodeMessage :: Decode a => Get a
{-# INLINE decodeMessage #-}
decodeMessage = decode =<< go HashMap.empty where
  go msg = do
    mfield <- Just <$> getField <|> return Nothing
    case mfield of
      Just v  -> go $! HashMap.insertWith (flip (++)) (fieldTag v) [v] msg
      Nothing -> return msg

-- |
-- Decode a Protocol Buffers message prefixed with a 32-bit integer describing it's length.
decodeLengthPrefixedMessage :: Decode a => Get a
{-# INLINE decodeLengthPrefixedMessage #-}
decodeLengthPrefixedMessage = do
  len :: Int64 <- getVarInt
  bs <- getBytes $ fromIntegral len
  case runGetState decodeMessage bs 0 of
    Right (val, bs')
      | B.null bs' -> return val
      | otherwise  -> fail $ "Unparsed bytes leftover in decodeLengthPrefixedMessage: " ++ show (B.length bs')
    Left err  -> fail err

class Decode (a :: *) where
  decode :: HashMap Tag [Field] -> Get a
  default decode :: (Generic a, GDecode (Rep a)) => HashMap Tag [Field] -> Get a
  decode = fmap to . gdecode

-- | Untyped message decoding, @ 'decode' = 'id' @
instance Decode (HashMap Tag [Field]) where
  decode = pure

class GDecode (f :: * -> *) where
  gdecode :: HashMap Tag [Field] -> Get (f a)

instance GDecode a => GDecode (M1 i c a) where
  gdecode = fmap M1 . gdecode

instance (GDecode a, GDecode b) => GDecode (a :*: b) where
  gdecode msg = liftA2 (:*:) (gdecode msg) (gdecode msg)

instance (GDecode x, GDecode y) => GDecode (x :+: y) where
  gdecode msg = L1 <$> gdecode msg <|> R1 <$> gdecode msg

instance (DecodeWire a, Monoid a, SingI n) => GDecode (K1 i (Optional n a)) where
  gdecode msg =
    let tag = fromIntegral $ fromSing (sing :: Sing n)
    in case HashMap.lookup tag msg of
      Just val -> K1 . Tagged <$> foldMapM decodeWire val
      Nothing  -> pure $ K1 mempty

instance (DecodeWire a, SingI n) => GDecode (K1 i (Repeated n a)) where
  gdecode msg =
    let tag = fromIntegral $ fromSing (sing :: Sing n)
    in case HashMap.lookup tag msg of
      Just val -> K1 . Tagged <$> traverse decodeWire val
      Nothing  -> pure $ K1 mempty

instance (DecodeWire a, Monoid a, SingI n) => GDecode (K1 i (Required n a)) where
  gdecode msg =
    let tag = fromIntegral $ fromSing (sing :: Sing n)
    in case HashMap.lookup tag msg of
      Just val -> K1 . Tagged . Identity <$> foldMapM decodeWire val
      Nothing  -> empty

instance (DecodeWire (PackedList a), SingI n) => GDecode (K1 i (Packed n a)) where
  gdecode msg =
    let tag = fromIntegral $ fromSing (sing :: Sing n)
    in case HashMap.lookup tag msg of
      -- probably should do this in a more efficient way:
      Just val -> K1 . Tagged <$> foldMapM decodeWire val
      Nothing  -> empty

foldMapM :: (Monad m, Foldable t, Monoid b) => (a -> m b) -> t a -> m b
foldMapM f = foldlM go mempty where
  go !acc el = mappend acc `liftM` f el
