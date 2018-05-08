module Control.Abstract.Evaluator.Spec where

import Analysis.Abstract.Evaluating (evaluating)
import Control.Abstract
import Data.Abstract.Module
import qualified Data.Abstract.Number as Number
import Data.Abstract.Package
import qualified Data.Abstract.Value as Value
import Data.Algebra
import Data.Bifunctor (first)
import Data.Functor.Const
import Data.Sum
import SpecHelpers hiding (Term, reassociate)

spec :: Spec
spec = parallel $ do
  it "constructs integers" $ do
    (expected, _) <- evaluate (integer 123)
    expected `shouldBe` Right (Value.injValue (Value.Integer (Number.Integer 123)))

  it "calls functions" $ do
    (expected, _) <- evaluate $ do
      identity <- lambda [name "x"] (term (variable (name "x")))
      call identity [integer 123]
    expected `shouldBe` Right (Value.injValue (Value.Integer (Number.Integer 123)))

evaluate
  = runM
  . fmap (first reassociate)
  . evaluating
  . runReader (PackageInfo (name "test") Nothing)
  . runReader (ModuleInfo "test/Control/Abstract/Evaluator/Spec.hs")
  . Value.runValueError
  . runEnvironmentError
  . runAddressError
  . runValue
runValue = runEvalClosure (runValue . runTerm) . runReturn . runLoopControl

reassociate :: Either String (Either (SomeExc exc1) (Either (SomeExc exc2) (Either (SomeExc exc3) result))) -> Either (SomeExc (Sum '[Const String, exc1, exc2, exc3])) result
reassociate (Left s) = Left (SomeExc (injectSum (Const s)))
reassociate (Right (Right (Right (Right a)))) = Right a

term :: TermEvaluator Value -> Subterm Term (TermEvaluator Value)
term eval = Subterm (Term eval) eval

type TermEffects
  = '[ LoopControl Value
     , Return Value
     , EvalClosure Term Value
     , Resumable (AddressError Precise Value)
     , Resumable (EnvironmentError Value)
     , Resumable (Value.ValueError Precise Value)
     , Reader ModuleInfo
     , Reader PackageInfo
     , Fail
     , Fresh
     , Reader (Environment Precise Value)
     , State (Environment Precise Value)
     , State (Heap Precise Value)
     , State (ModuleTable (Environment Precise Value, Value))
     , State (Exports Precise Value)
     , State (JumpTable Term)
     , IO
     ]

type TermEvaluator = Evaluator Precise Term Value TermEffects

type Value = Value.Value Precise
newtype Term = Term { runTerm :: TermEvaluator Value }

instance Show Term where showsPrec d _ = showParen (d > 10) $ showString "Term _"

instance FreeVariables Term where freeVariables _ = []
