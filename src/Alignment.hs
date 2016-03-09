module Alignment where

import Category
import Control.Arrow
import Control.Comonad.Cofree
import Control.Monad
import Control.Monad.Free
import Data.Copointed
import Data.Functor.Both as Both
import Data.Functor.Identity
import qualified Data.List as List
import Data.Maybe
import Data.Option
import qualified Data.OrderedMap as Map
import qualified Data.Set as Set
import Diff
import Line
import Patch
import Prelude hiding (fst, snd)
import qualified Prelude
import Range
import Row
import Source hiding ((++))
import SplitDiff
import Syntax
import Term

-- | Assign line numbers to the lines on each side of a list of rows.
numberedRows :: [Row a] -> [Both (Int, Line a)]
numberedRows = countUp (pure 1)
  where countUp from (Row row : rows) = ((,) <$> from <*> row) : countUp ((+) <$> from <*> (valueOf <$> row)) rows
        countUp _ [] = []
        valueOf (Line []) = 0
        valueOf _ = 1

-- | Determine whether a line contains any patches.
hasChanges :: Line (SplitDiff leaf Info) -> Bool
hasChanges = or . fmap (or . (True <$))

-- | Split a diff, which may span multiple lines, into rows of split diffs paired with the Range of characters spanned by that Row on each side of the diff.
splitDiffByLines :: Both (Source Char) -> Diff leaf Info -> [Row (SplitDiff leaf Info, Range)]
splitDiffByLines sources = iter (\ (Annotated info syntax) -> splitAnnotatedByLines ((Free .) . Annotated) sources info syntax) . fmap (splitPatchByLines sources)

-- | Split a patch, which may span multiple lines, into rows of split diffs.
splitPatchByLines :: Both (Source Char) -> Patch (Term leaf Info) -> [Row (SplitDiff leaf Info, Range)]
splitPatchByLines sources patch = zipWithDefaults makeRow (pure mempty) $ fmap (fmap (first (Pure . constructor patch))) <$> lines
    where lines = maybe [] . cata . splitAbstractedTerm (:<) <$> sources <*> unPatch patch
          constructor (Replace _ _) = SplitReplace
          constructor (Insert _) = SplitInsert
          constructor (Delete _) = SplitDelete

-- | Split a term comprised of an Info & Syntax up into one `outTerm` (abstracted by a constructor) per line in `Source`.
splitAbstractedTerm :: (Info -> Syntax leaf outTerm -> outTerm) -> Source Char -> Info -> Syntax leaf [Line (outTerm, Range)] -> [Line (outTerm, Range)]
splitAbstractedTerm makeTerm source (Info range categories) syntax = case syntax of
  Leaf a -> pure . ((`makeTerm` Leaf a) . (`Info` categories) &&& id) <$> actualLineRanges range source
  Indexed children -> adjoinChildLines (Indexed . fmap copoint) (Identity <$> children)
  Fixed children -> adjoinChildLines (Fixed . fmap copoint) (Identity <$> children)
  Keyed children -> adjoinChildLines (Keyed . Map.fromList) (Map.toList children)
  where adjoinChildLines constructor children = let (lines, next) = foldr childLines ([], end range) children in
          fmap (wrapLineContents (makeBranchTerm (\ info -> makeTerm info . constructor) categories next)) . foldr (adjoinLinesBy (openRangePair source)) [] $
            (pure . (,) Nothing <$> actualLineRanges (Range (start range) next) source) ++ lines

        childLines child (lines, next) = let childRange = unionLineRangesFrom (rangeAt next) (copoint child) in
             ((fmap (first (Just . (<$ child))) <$> copoint child)
          ++ (pure . (,) Nothing <$> actualLineRanges (Range (end childRange) next) source)
          ++ lines, start childRange)

-- | Split an annotated diff into rows of split diffs.
splitAnnotatedByLines :: (Info -> Syntax leaf outTerm -> outTerm) -> Both (Source Char) -> Both Info -> Syntax leaf [Row (outTerm, Range)] -> [Row (outTerm, Range)]
splitAnnotatedByLines makeTerm sources infos syntax = case syntax of
  Leaf a -> zipWithDefaults makeRow (pure mempty) $ fmap <$> ((\ categories range -> pure (makeTerm (Info range categories) (Leaf a), range)) <$> categories) <*> (actualLineRanges <$> ranges <*> sources)
  Indexed children -> adjoinChildRows (Indexed . fmap copoint) (Identity <$> children)
  Fixed children -> adjoinChildRows (Fixed . fmap copoint) (Identity <$> children)
  Keyed children -> adjoinChildRows (Keyed . Map.fromList) (List.sortOn (rowRanges . Prelude.snd) $ Map.toList children)
  where ranges = characterRange <$> infos
        categories = Diff.categories <$> infos

        adjoinChildRows constructor children = let (rows, next) = foldr childRows ([], end <$> ranges) children in
          fmap (Row . (wrapLineContents <$> (makeBranchTerm (\ info -> makeTerm info . constructor) <$> categories <*> next) <*>) . unRow) . foldr (adjoinRowsBy (openRangePair <$> sources)) [] $
            zipWithDefaults makeRow (pure mempty) (fmap (pure . (,) Nothing) <$> (actualLineRanges <$> (Range <$> (start <$> ranges) <*> next) <*> sources)) ++ rows

        childRows child (rows, next) = let childRanges = unionLineRangesFrom <$> (rangeAt <$> next) <*> sequenceA (unRow <$> copoint child) in
          -- We depend on source ranges increasing monotonically. If a child invalidates that, e.g. if it’s a move in a Keyed node, we don’t output rows for it in this iteration. (It will still show up in the diff as context rows.) This works around https://github.com/github/semantic-diff/issues/488.
          if or $ (>) . end <$> childRanges <*> next
            then (rows, next)
            else    ((fmap (first (Just . (<$ child))) <$> copoint child)
                 ++ zipWithDefaults makeRow (pure mempty) (fmap (pure . (,) Nothing) <$> (actualLineRanges <$> (Range <$> (end <$> childRanges) <*> next) <*> sources))
                 ++ rows, start <$> childRanges)

-- | Wrap a list of child terms in a branch.
makeBranchTerm :: (Info -> [inTerm] -> outTerm) -> Set.Set Category -> Int -> [(Maybe inTerm, Range)] -> (outTerm, Range)
makeBranchTerm constructor categories next children = (constructor (Info range categories) . catMaybes $ Prelude.fst <$> children, range)
  where range = unionRangesFrom (rangeAt next) $ Prelude.snd <$> children

-- | Compute the union of the ranges in a list of ranged lines.
unionLineRangesFrom :: Range -> [Line (a, Range)] -> Range
unionLineRangesFrom start lines = unionRangesFrom start (lines >>= (fmap Prelude.snd . unLine))

-- | Returns the ranges of a list of Rows.
rowRanges :: [Row (a, Range)] -> Both (Maybe Range)
rowRanges rows = maybeConcat . join <$> Both.unzip (fmap (fmap Prelude.snd . unLine) . unRow <$> rows)

-- | Openness predicate for (Range, a) pairs.
openRangePair :: Source Char -> (a, Range) -> Bool
openRangePair source pair = openRange source (Prelude.snd pair)

-- | Does this Range in this Source end with a newline?
openRange :: Source Char -> Range -> Bool
openRange source range = (at source <$> maybeLastIndex range) /= Just '\n'
