{-# LANGUAGE DataKinds, GADTs, RankNTypes, ScopedTypeVariables, TypeOperators #-}
module Diffing.Interpreter
( diffTerms
) where

import Prologue
import Data.Align.Generic (galignWith)
import Analysis.Decorator
import Control.Monad.Free.Freer
import Data.Diff
import Data.Record
import Data.Term
import Diffing.Algorithm
import Diffing.Algorithm.RWS

-- | Diff two à la carte terms recursively.
diffTerms :: (Diffable syntax, Eq1 syntax, GAlign syntax, Show1 syntax, Traversable syntax)
          => Term syntax (Record fields1)
          -> Term syntax (Record fields2)
          -> Diff syntax (Record fields1) (Record fields2)
diffTerms t1 t2 = stripDiff (fromMaybe (replacing t1' t2') (runAlgorithm (diff t1' t2')))
  where (t1', t2') = ( defaultFeatureVectorDecorator constructorNameAndConstantFields t1
                     , defaultFeatureVectorDecorator constructorNameAndConstantFields t2)

-- | Run an 'Algorithm' to completion in an 'Alternative' context using the supplied comparability & equivalence relations.
runAlgorithm :: forall syntax fields1 fields2 m result
             .  (Diffable syntax, Eq1 syntax, GAlign syntax, Traversable syntax, Alternative m, Monad m)
             => Algorithm
               (Term syntax (Record (FeatureVector ': fields1)))
               (Term syntax (Record (FeatureVector ': fields2)))
               (Diff syntax (Record (FeatureVector ': fields1)) (Record (FeatureVector ': fields2)))
               result
             -> m result
runAlgorithm = iterFreerA (\ yield step -> case step of
  Diffing.Algorithm.Diff t1 t2 -> runAlgorithm (algorithmForTerms t1 t2) <|> pure (replacing t1 t2) >>= yield
  Linear (Term (In ann1 f1)) (Term (In ann2 f2)) -> merge (ann1, ann2) <$> galignWith (runAlgorithm . diffThese) f1 f2 >>= yield
  RWS as bs -> traverse (runAlgorithm . diffThese) (rws comparableTerms equivalentTerms as bs) >>= yield
  Delete a -> yield (deleting a)
  Insert b -> yield (inserting b)
  Replace a b -> yield (replacing a b)
  Empty -> empty
  Alt a b -> yield a <|> yield b)