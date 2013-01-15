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
import Data.Foldable
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Monoid
import Data.Serialize.Get
import Data.Tagged
import Data.Traversable

import GHC.Generics
import GHC.TypeLits

import Data.ProtocolBuffers.Types
import Data.ProtocolBuffers.Wire

decodeMessage :: Decode a => Get a
decodeMessage = decode =<< go HashMap.empty where
  go msg = do
    mfield <- Just <$> getField <|> return Nothing
    case mfield of
      Just v  -> go $! HashMap.insertWith (flip (++)) (fieldTag v) [v] msg
      Nothing -> return msg

decodeLengthPrefixedMessage :: Decode a => Get a
decodeLengthPrefixedMessage = do
  len <- getWord32le
  isolate (fromIntegral len) decodeMessage

class Decode (a :: *) where
  decode :: (Alternative m, Monad m) => HashMap Tag [Field] -> m a
  default decode :: (Alternative m, Monad m, Generic a, GDecode (Rep a)) => HashMap Tag [Field] -> m a
  decode = fmap to . gdecode

class GDecode (f :: * -> *) where
  gdecode :: (Alternative m, Monad m) => HashMap Tag [Field] -> m (f a)

instance GDecode a => GDecode (M1 i c a) where
  gdecode = fmap M1 . gdecode

instance (GDecode a, GDecode b) => GDecode (a :*: b) where
  gdecode msg = liftA2 (:*:) (gdecode msg) (gdecode msg)

instance (GDecode x, GDecode y) => GDecode (x :+: y) where
  gdecode msg = L1 <$> gdecode msg <|> R1 <$> gdecode msg

instance (Wire a, Monoid a, SingI n) => GDecode (K1 i (Optional n a)) where
  gdecode msg =
    let tag = fromIntegral $ fromSing (sing :: Sing n)
    in case HashMap.lookup tag msg of
      Just val -> K1 . Tagged <$> foldMapM decodeWire val
      Nothing  -> pure $ K1 mempty

instance (Wire a, SingI n) => GDecode (K1 i (Repeated n a)) where
  gdecode msg =
    let tag = fromIntegral $ fromSing (sing :: Sing n)
    in case HashMap.lookup tag msg of
      Just val -> K1 . Tagged <$> traverse decodeWire val
      Nothing  -> pure $ K1 mempty

instance (Wire a, Monoid a, SingI n) => GDecode (K1 i (Required n a)) where
  gdecode msg =
    let tag = fromIntegral $ fromSing (sing :: Sing n)
    in case HashMap.lookup tag msg of
      Just val -> K1 . Tagged . Identity <$> foldMapM decodeWire val
      Nothing  -> empty

{-
instance (Wire a, Monoid a, Tl.Nat n) => GDecode (K1 i (Packed n a)) where
  decode = error "packed fields are not implemented"
-}

foldMapM :: (Monad m, Foldable t, Monoid b) => (a -> m b) -> t a -> m b
foldMapM f = foldlM go mempty where
  go !acc el = mappend acc `liftM` f el
