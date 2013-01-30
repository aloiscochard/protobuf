{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Data.ProtocolBuffers.Types
  ( Tagged(..)
  , Required
  , Optional
  , Repeated
  , Packed
  , Enumeration(..)
  , Optionally(..)
  , Fixed(..)
  , Signed(..)
  , PackedList(..)
  , PackedField(..)
  , GetValue(..)
  , GetEnum(..)
  ) where

import Control.DeepSeq (NFData)
import Control.Monad.Identity
import Data.Bits
import Data.Foldable as Fold
import Data.Monoid
import Data.Tagged
import Data.Traversable
import Data.Typeable
import GHC.TypeLits

-- | Optional fields. Values that are not found will return 'Nothing'.
type Optional (n :: Nat) a = Tagged n (Optionally a)

-- | Required fields. Parsing will return 'Control.Alternative.empty' if a 'Required' value is not found while decoding.
type Required (n :: Nat) a = Tagged n (Identity a)

-- | Lists of values.
type Repeated (n :: Nat) a = Tagged n [a]

-- | Packed values.
type Packed (n :: Nat) a = Tagged n (PackedField (PackedList a))

instance Show a => Show (Required n a) where
  show (Tagged (Identity x)) = show (Tagged x :: Tagged n a)

instance Eq a => Eq (Required n a) where
  Tagged (Identity x) == Tagged (Identity y) = x == y

-- | Functions for wrapping and unwrapping record fields
class GetValue a where
  type GetValueType a :: *
  -- | Extract a value from it's 'Tagged' representation.
  getValue :: a -> GetValueType a
  -- | Wrap it back up again.
  putValue :: GetValueType a -> a

  -- | An isomorphism lens compatible with the lens package
  value :: Functor f => (GetValueType a -> f (GetValueType a)) -> a -> f a
  value f = fmap putValue . f . getValue

newtype Optionally a = Optionally {runOptionally :: a}
  deriving (Bounded, Eq, Enum, Foldable, Functor, Monoid, Ord, NFData, Show, Traversable, Typeable)

-- | A 'Maybe' lens on an 'Optional' field.
instance GetValue (Optional n a) where
  type GetValueType (Optional n a) = a
  getValue = runOptionally . unTagged
  putValue = Tagged . Optionally

-- | A list lens on an 'Repeated' field.
instance GetValue (Repeated n a) where
  type GetValueType (Repeated n a) = [a]
  getValue = unTagged
  putValue = Tagged

-- | A list lens on an 'Packed' field.
instance GetValue (Packed n a) where
  type GetValueType (Packed n a) = [a]
  getValue = unPackedList . unPackedField . unTagged
  putValue = Tagged . PackedField . PackedList

-- | An 'Identity' lens on an 'Required' field.
instance GetValue (Required n a) where
  type GetValueType (Required n a) = a
  getValue = runIdentity . unTagged
  putValue = Tagged . Identity

-- |
-- A newtype wrapper used to distinguish 'Prelude.Enum's from other field types.
-- 'Enumeration' fields use 'Prelude.fromEnum' and 'Prelude.toEnum' when encoding and decoding messages.
newtype Enumeration a = Enumeration a
  deriving (Bounded, Eq, Enum, Foldable, Functor, Ord, NFData, Traversable, Typeable)

instance Show a => Show (Enumeration (Identity a)) where
  show (Enumeration (Identity a)) = "Enumeration " ++ show a

instance Show a => Show (Enumeration (Maybe a)) where
  show (Enumeration a) = "Enumeration " ++ show a

instance Show a => Show (Enumeration [a]) where
  show (Enumeration a) = "Enumeration " ++ show a

instance Monoid (Enumeration (Identity a)) where
  -- error case is handled by getEnum but we're exposing the instance :-(
  -- really should be a Semigroup instance... if we want a semigroup dependency
  mempty = error "Empty Enumeration"
  _ `mappend` x = x

instance Monoid (Enumeration (Maybe a)) where
  mempty = Enumeration Nothing
  _ `mappend` x = x

instance Monoid (Enumeration [a]) where
  mempty = Enumeration []
  Enumeration x `mappend` Enumeration y = Enumeration (x <> y)

-- | Similar to 'GetValue' but specialized for 'Enumeration' to avoid overlap.
class GetEnum a where
  type GetEnumResult a :: *
  getEnum :: a -> GetEnumResult a
  putEnum :: GetEnumResult a -> a

  -- | An isomorphism lens compatible with the lens package
  enum :: Functor f => (GetEnumResult a -> f (GetEnumResult a)) -> a -> f a
  enum f = fmap putEnum . f . getEnum

instance GetEnum (Enumeration a) where
  type GetEnumResult (Enumeration a) = a
  getEnum (Enumeration x) = x
  putEnum = Enumeration

instance Enum a => GetEnum (Identity a) where
  type GetEnumResult (Identity a) = a
  getEnum = runIdentity
  putEnum = Identity

instance Enum a => GetEnum (Optional n (Enumeration (Maybe a))) where
  type GetEnumResult (Tagged n (Optionally (Enumeration (Maybe a)))) = Maybe a
  getEnum = getEnum . runOptionally . unTagged
  putEnum = Tagged . Optionally . putEnum

instance Enum a => GetEnum (Required n (Enumeration (Identity a))) where
  type GetEnumResult (Tagged n (Identity (Enumeration (Identity a)))) = a
  getEnum = runIdentity . getEnum . runIdentity . unTagged
  putEnum = Tagged . Identity . Enumeration . Identity

instance Enum a => GetEnum (Repeated n (Enumeration [a])) where
  type GetEnumResult (Tagged n [Enumeration [a]]) = [a]
  getEnum = Fold.concatMap getEnum . unTagged
  putEnum = Tagged . (:[]) . Enumeration

-- |
-- A traversable functor used to select packed sequence encoding/decoding.
newtype PackedField a = PackedField {unPackedField :: a}
  deriving (Eq, Foldable, Functor, Monoid, NFData, Ord, Show, Traversable, Typeable)

-- |
-- A list that is stored in a packed format.
newtype PackedList a = PackedList {unPackedList :: [a]}
  deriving (Eq, Foldable, Functor, Monoid, NFData, Ord, Show, Traversable, Typeable)

-- |
-- Signed integers are stored in a zz-encoded form.
newtype Signed a = Signed a
  deriving (Bits, Bounded, Enum, Eq, Floating, Foldable, Fractional, Functor, Integral, Monoid, NFData, Num, Ord, Real, RealFloat, RealFrac, Show, Traversable, Typeable)

-- |
-- Fixed integers are stored in little-endian form without additional encoding.
newtype Fixed a = Fixed a
  deriving (Bits, Bounded, Enum, Eq, Floating, Foldable, Fractional, Functor, Integral, Monoid, NFData, Num, Ord, Real, RealFloat, RealFrac, Show, Traversable, Typeable)
