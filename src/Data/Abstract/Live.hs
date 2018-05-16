{-# LANGUAGE DataKinds, GeneralizedNewtypeDeriving, TypeFamilies, TypeOperators #-}
module Data.Abstract.Live where

import Data.Abstract.Address
import Data.Semilattice.Lower
import Data.Set as Set
import Prologue

-- | A set of live addresses (whether roots or reachable).
newtype Live location value = Live { unLive :: Set location }
  deriving (Eq, Lower, Monoid, Ord, Semigroup)

fromAddresses :: (Foldable t, Ord location) => t (Address location value) -> Live location value
fromAddresses = Prologue.foldr liveInsert lowerBound

-- | Construct a 'Live' set containing only the given address.
liveSingleton :: Address location value -> Live location value
liveSingleton = Live . Set.singleton . unAddress

-- | Insert an address into a 'Live' set.
liveInsert :: Ord location => Address location value -> Live location value -> Live location value
liveInsert addr = Live . Set.insert (unAddress addr) . unLive

-- | Delete an address from a 'Live' set, if present.
liveDelete :: Ord location => Address location value -> Live location value -> Live location value
liveDelete addr = Live . Set.delete (unAddress addr) . unLive

-- | Compute the (asymmetric) difference of two 'Live' sets, i.e. delete every element of the second set from the first set.
liveDifference :: Ord location => Live location value -> Live location value -> Live location value
liveDifference = fmap Live . (Set.difference `on` unLive)

-- | Test whether an 'Address' is in a 'Live' set.
liveMember :: Ord location => Address location value -> Live location value -> Bool
liveMember addr = Set.member (unAddress addr) . unLive

-- | Decompose a 'Live' set into a pair of one member address and the remaining set, or 'Nothing' if empty.
liveSplit :: Live location value -> Maybe (Address location value, Live location value)
liveSplit = fmap (bimap Address Live) . Set.minView . unLive


instance Show location => Show (Live location value) where
  showsPrec d = showsUnaryWith showsPrec "Live" d . Set.toList . unLive
