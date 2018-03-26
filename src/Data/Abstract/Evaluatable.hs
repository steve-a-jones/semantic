{-# LANGUAGE DefaultSignatures, MultiParamTypeClasses, UndecidableInstances, GADTs, StandaloneDeriving #-}
module Data.Abstract.Evaluatable
( Evaluatable(..)
, module Addressable
, module Analysis
, module FreeVariables
, module Value
, MonadEvaluator(..)
, Unspecialized(..)
) where

import Control.Abstract.Addressable as Addressable
import Control.Abstract.Analysis as Analysis
import Control.Abstract.Value as Value
import Data.Abstract.FreeVariables as FreeVariables
import Data.Abstract.Value
import Data.Functor.Classes
import Data.Proxy
import Data.Semigroup.Foldable
import Data.Semigroup.App
import Data.Term
import Prologue

data Unspecialized a b where
  Unspecialized :: { getUnspecialized :: Prelude.String } -> Unspecialized value value

instance Eq1 (Unspecialized a) where
  liftEq _ (Unspecialized a) (Unspecialized b) = a == b

deriving instance Eq (Unspecialized a b)
deriving instance Show (Unspecialized a b)
instance Show1 (Unspecialized a) where
  liftShowsPrec _ _ = showsPrec

-- | The 'Evaluatable' class defines the necessary interface for a term to be evaluated. While a default definition of 'eval' is given, instances with computational content must implement 'eval' to perform their small-step operational semantics.
class Evaluatable constr where
  eval :: ( FreeVariables term
          , MonadAddressable (LocationFor value) value m
          , MonadAnalysis term value m
          , MonadValue value m
          , Show (LocationFor value)
          , MonadThrow (Unspecialized value) m
          )
       => SubtermAlgebra constr term (m value)
  default eval :: (MonadThrow (Unspecialized value) m, Show1 constr) => SubtermAlgebra constr term (m value)
  eval expr = throwException (Unspecialized ("Eval unspecialized for " ++ liftShowsPrec (const (const id)) (const id) 0 expr ""))

-- | If we can evaluate any syntax which can occur in a 'Union', we can evaluate the 'Union'.
instance Apply Evaluatable fs => Evaluatable (Union fs) where
  eval = Prologue.apply (Proxy :: Proxy Evaluatable) eval

-- | Evaluating a 'TermF' ignores its annotation, evaluating the underlying syntax.
instance Evaluatable s => Evaluatable (TermF s a) where
  eval = eval . termFOut


-- Instances

-- | '[]' is treated as an imperative sequence of statements/declarations s.t.:
--
--   1. Each statement’s effects on the store are accumulated;
--   2. Each statement can affect the environment of later statements (e.g. by 'modify'-ing the environment); and
--   3. Only the last statement’s return value is returned.
instance Evaluatable [] where
  -- 'nonEmpty' and 'foldMap1' enable us to return the last statement’s result instead of 'unit' for non-empty lists.
  eval = maybe unit (runApp . foldMap1 (App . subtermValue)) . nonEmpty