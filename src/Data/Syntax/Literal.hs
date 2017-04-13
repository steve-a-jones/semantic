{-# LANGUAGE DataKinds, DeriveAnyClass, DeriveGeneric #-}
module Data.Syntax.Literal where

import Data.Functor.Classes.Eq.Generic
import Data.Functor.Classes.Show.Generic
import Data.Syntax.Comment
import Data.Functor.Union
import GHC.Generics
import Prologue

-- Boolean

newtype Boolean a = Boolean Bool
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 Boolean where liftEq = genericLiftEq
instance Show1 Boolean where liftShowsPrec = genericLiftShowsPrec


-- Numeric

-- | A literal integer of unspecified width. No particular base is implied.
newtype Integer a = Integer { integerContent :: ByteString }
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 Data.Syntax.Literal.Integer where liftEq = genericLiftEq
instance Show1 Data.Syntax.Literal.Integer where liftShowsPrec = genericLiftShowsPrec

-- TODO: Should IntegerLiteral hold an Integer instead of a ByteString?
-- TODO: Do we care about differentiating between hex/octal/decimal/binary integer literals?
-- TODO: Float/Double literals.


-- Strings, symbols

newtype String a = String { stringElements :: [Union '[InterpolationElement, TextElement] a] }
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 String where liftEq = genericLiftEq
instance Show1 String where liftShowsPrec = genericLiftShowsPrec

-- TODO: Should string literal bodies include escapes too?

-- | An interpolation element within a string literal.
newtype InterpolationElement a = InterpolationElement { interpolationBody :: a }
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 InterpolationElement where liftEq = genericLiftEq
instance Show1 InterpolationElement where liftShowsPrec = genericLiftShowsPrec


-- | A sequence of textual contents within a string literal.
newtype TextElement a = TextElement { textElementContent :: ByteString }
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 TextElement where liftEq = genericLiftEq
instance Show1 TextElement where liftShowsPrec = genericLiftShowsPrec


newtype Symbol a = SymbolLiteral { symbolContent :: ByteString }
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 Symbol where liftEq = genericLiftEq
instance Show1 Symbol where liftShowsPrec = genericLiftShowsPrec

-- TODO: Character literals.


-- Collections

newtype ArrayLiteral a = ArrayLiteral { arrayElements :: [Union '[Identity, Comment] a] }
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 ArrayLiteral where liftEq = genericLiftEq
instance Show1 ArrayLiteral where liftShowsPrec = genericLiftShowsPrec


newtype HashLiteral a = HashLiteral { hashElements :: [Union '[KeyValue, Comment] a] }
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 HashLiteral where liftEq = genericLiftEq
instance Show1 HashLiteral where liftShowsPrec = genericLiftShowsPrec


data KeyValue a = KeyValue { key :: !a, value :: !a }
  deriving (Eq, Foldable, Generic1, Show)

instance Eq1 KeyValue where liftEq = genericLiftEq
instance Show1 KeyValue where liftShowsPrec = genericLiftShowsPrec

-- TODO: Object literals as distinct from hash literals? Or coalesce object/hash literals into “key-value literals”?
-- TODO: Function literals (lambdas, procs, anonymous functions, what have you).
-- TODO: Regexp literals.