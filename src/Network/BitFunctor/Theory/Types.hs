{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes  #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FunctionalDependencies  #-}

module Network.BitFunctor.Theory.Types where

import Data.Text
import Data.Char
import Data.Foldable
import Data.Monoid
import Control.Monad
import Data.Binary
import qualified Data.Map.Strict as Map
import qualified Data.List as List
import qualified Data.Text.Encoding as TE

import Network.BitFunctor.Common

-- remove from here
class (PartOrd a) where
    partCompare :: a -> a -> PartOrdering

-- can be statement code
class (Codeable a) where
    toText :: a -> Text
    fromText :: Text -> a
    isFQExtractable :: a -> Bool
    isTheoriable :: a -> Bool
    isSelfReference :: a -> Bool

class (Ord k, Eq k) => Keyable a k | a -> k where
    toKey :: a -> k
    fromKey :: k -> a -> a

-- can be statement name
class (Keyable a k) => Nameable a k where
    toPrefix :: Char -> a -> Text
    toSuffix :: a -> Text
    fromSuffix :: Text -> a
    changePrefix :: Text -> a -> a 
    toFQName :: Char -> a -> Text
    toFQName c x = let p = toPrefix c x in
                   let s = toSuffix x in 
                   if Data.Text.null p then s                                    
                                       else if Data.Text.null s then p
                                            else p <> (singleton c) <> s
    toFQNameWithPrefixMap :: Char -> Map.Map Text Text -> a -> Text
    toFQNameWithPrefixMap c m x = let p' = toPrefix c x in
                     let p = Map.findWithDefault p' p' m in
                     let s = toSuffix x in 
                     if Data.Text.null p then s                                    
                                       else if Data.Text.null s then p
                                            else p <> (singleton c) <> s
    changeNameWith:: (k -> k -> Bool) -> k -> k -> a -> a
    changeNameWith f kf kt x = if (f kf $ toKey x) then fromKey kt x else x
    changeNameWithKey :: k -> k -> a -> a
    changeNameWithKey = changeNameWith (==)
    
 
type CodeA a b = Either a [Either a b]

toTextWithMap :: (Codeable a, Codeable b) => (b -> Text) -> CodeA a b -> Text
toTextWithMap _ (Left x) = toText x
toTextWithMap f (Right mab) = List.foldl (\acc c -> acc <> (case c of
                                                             Left x -> toText x
                                                             Right c -> f c)) empty mab


fromCodeA :: (Codeable b, Nameable b k, Codeable a) => Char -> CodeA a b -> Text
fromCodeA c = toTextWithMap $ \ct -> if (isFQExtractable ct) then toFQName c ct
                                                             else toText ct


fromCodeWithPrefixMapA :: (Codeable b, Nameable b k, Codeable a) => Char -> Map.Map Text Text -> CodeA a b -> Text
fromCodeWithPrefixMapA c mtt = toTextWithMap $ \ct -> if (isFQExtractable ct) then toFQNameWithPrefixMap c mtt ct
                                                             else toText ct


instance (Codeable a, Codeable b) => Codeable (Either a b) where
    fromText t = Left (fromText t)
    toText (Left x) = toText x
    toText (Right x) = toText x
    isFQExtractable (Left x) = False
    isFQExtractable (Right x) = isFQExtractable x
    isTheoriable (Left x) = False
    isTheoriable (Right x) = isTheoriable x
    isSelfReference (Left x) = False
    isSelfReference (Right x) = isSelfReference x

instance Codeable a => Codeable [a] where
    fromText t = []    
    toText l = List.foldl (\acc c -> acc <> (toText c)) empty l
    isFQExtractable l = False
    isTheoriable l = False
    isSelfReference l = False

class (Binary s, Eq s, Nameable a k, Codeable c, Codeable c', Nameable c' a, PartOrd s) =>
                                       StatementC a k c c' s | s -> a, s -> c, s -> c' where
    toStatementName :: s -> a
    toStatementCode :: s -> CodeA c c'
    changeStatementCode :: CodeA c c' -> s -> s
    changeStatementName :: a -> s -> s
    toStatementKey ::  s -> k
    toStatementKey = toKey . toStatementName
 
class (Binary t, StatementC a k c c' s) => TheoryC a k c c' s t | t -> s where
    fromStatementList :: [s] -> t
    fromStatementMap :: Map.Map k s -> t
    toStatementList :: t -> [s]
    
    toStatementMap ::  t -> Map.Map k s
    toStatementMap tt = let stsl = toStatementList tt in
                        let kstsl = List.map (\s -> (toStatementKey s, s)) stsl in
                        Map.fromList kstsl

    insertStatementKey :: k -> s -> t -> Map.Map k s
    insertStatementKey kk ss tt = let stsm = toStatementMap tt in                            
                                  Map.insert kk ss stsm

    lookupStatementKey :: k -> t -> Maybe s
    lookupStatementKey kk tt = let stsm = toStatementMap tt in                            
                               Map.lookup kk stsm

    theorySize :: t -> Int
    theorySize tt = let stsm = toStatementMap tt in
                    Map.size stsm   
  
