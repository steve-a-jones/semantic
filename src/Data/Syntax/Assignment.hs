{-# LANGUAGE DataKinds, GADTs, InstanceSigs, MultiParamTypeClasses, RankNTypes, ScopedTypeVariables, StandaloneDeriving, TypeFamilies, TypeOperators, UndecidableInstances #-}
-- | Assignment of AST onto some other structure (typically terms).
--
--   Parsing yields an AST represented as a Rose tree labelled with symbols in the language’s grammar and source locations (byte Range and Span). An Assignment represents a (partial) map from AST nodes onto some other structure; in essence, it’s a parser that operates over trees. (For our purposes, this structure is typically Terms annotated with source locations.) Assignments are able to match based on symbol, sequence, and hierarchy; thus, in @x = y@, both @x@ and @y@ might have the same symbol, @Identifier@, the left can be assigned to a variable declaration, while the right can be assigned to a variable reference.
--
--   Assignments can be any of the following primitive rules:
--
--   1. 'symbol' rules match a node against a specific symbol in the source language’s grammar; they succeed iff a) there is a current node, and b) its symbol is equal to the argument symbol. Matching a 'symbol' rule does not advance past the current node, meaning that you can match a node against a symbol and also e.g. match against the node’s 'children'. This also means that some care must be taken, as repeating a symbol with 'many' or 'some' (see below) will never advance past the current node and could therefore loop forever.
--
--   2. 'location' rules always succeed, and produce the current node’s Location (byte Range and Span). If there is no current node (i.e. if matching has advanced past the root node or past the last child node when operating within a 'children' rule), the location is instead the end of the most recently matched node, specified as a zero-width Range and Span. 'location' rules do not advance past the current node, meaning that you can both match a node’s 'location' and other properties.
--
--   3. 'source' rules succeed whenever there is a current node (i.e. matching has not advanced past the root node or the last child node when operating within a 'children' rule), and produce its source as a ByteString. 'source' is intended to match leaf nodes such as e.g. comments. 'source' rules advance past the current node.
--
--   4. 'children' rules apply their argument (an assignment) to the children of the current node, succeeding iff a) there is a current node, b) the argument assignment matches the children, and c) there are no (regular) nodes left over (see below re: tokens), producing the result of matching the argument assignment against the children. 'children' rules can match a node with no child nodes if their argument can successfully match at the end of input.
--
--   5. Via the 'Alternative' instance, 'empty' assignments always fail. This can be used (in combination with the 'Monad' instance) to (for example) fail if a 'source' assignment produces an ill-formatted ByteString. However, see below re: committed choice.
--
--   6. Via the 'Applicative' instance, 'pure' (or via the 'Monad' instance, 'return') assignments always succeed, producing the passed value. They do not advance past the current node. In combination with the 'Alternative' instance, 'pure' can provide default values when optional syntax is not present in the AST.
--
--   Assignments can further be combined in a few different ways:
--
--   1. The 'Functor' instance maps values from the AST (Location, ByteString, etc.) into another structure.
--
--   2. The 'Applicative' instance assigns sequences of (sibling) AST nodes in order, as well as providing 'pure' assignments (see above). Most assignments of a single piece of syntax consist of an 'Applicative' chain of assignments.
--
--   3. The 'Alternative' instance chooses between a set of assignments, as well as providing 'empty' assignments (see above). See below re: committed choice for best practices for efficiency & error reporting when it comes to assigning multiple alternatives. Most high-level assignments (e.g. “declaration” or “statement” assignments) consist of choices among two or more 'Applicative' chains of assignments, mirroring the structure of the parser’s choices. The 'Alternative' instance also enables repetitions via the 'many' (≥ 0 repetitions) and 'some' (≥ 1 repetition) methods. Finally, the 'optional' function uses the 'Alternative' instance to assign a value in 'Maybe', succeeding with 'Nothing' when unmatched.
--
--   4. The 'Monad' instance allows assignments to depend on the results of earlier assignments. In general, most assignments should not be written using the 'Monad' instance; however, some specific situations require it, e.g. assigning 'x += y' to be equivalent to 'x = x + y'.
--
--
--   == Best practices
--
--   Because of their flexibility, the same assignment can often be written in multiple different ways. The following best practices should ensure efficient assignment with clear error messages for ill-formed AST.
--
--   === Committed choice
--
--   Assignments can represent alternatives as either committed or uncommitted choices, both written with '<|>'. “Committed” in this context means that a failure in one of the alternatives will not result in backtracking followed by an attempt of one of the other alternatives; thus, committed choice is more efficient. (By the same token, it enables much better error messages since backtracking erases most of the relevant context.) Committed choices are constructed via the following rules:
--
--   1. 'empty' is dropped from choices:
--   prop> empty <|> a = a -- empty is the left-identity of <|>
--   prop> a <|> empty = a -- empty is the right-identity of <|>
--
--   2. 'symbol' rules construct a committed choice (with only a single alternative).
--
--   3. 'fmap' (and by extension '<$>' and '<$') of a committed choice is a committed choice.
--
--   4. '<*>' (and by extension '*>' and '<*') with a committed choice on the left is a committed choice.
--
--   5. '>>=' (and by extension '>>', '=<<', and '<<') of a committed choice is a committed choice. It may be helpful to think of this and the above rule for '<*>' as “sequences starting with committed choices remain committed choices.”
--
--   6. '<|>' of two committed choices is a committed choice.
--
--   Finally, if a given choice is not a committed choice, it is an uncommitted choice.
--
--   Distilling the above, the rule of thumb is to always start an assignment for a given piece of syntax with either a 'symbol' rule or an 'fmap' over a 'symbol' rule. When assigning multiple pieces of syntax, place any known uncommitted choices at the (rightmost) end of the chain; '<|>' is left-associative, so this guarantees that you’re adding at most one uncommitted choice on top of the ones already present.
--
--   === Matching tokens
--
--   AST symbols are classified by their 'symbolType' as either 'Regular', 'Anonymous', or 'Auxiliary'. 'Auxiliary' never appears in ASTs; 'Regular' is for the symbols of explicitly named productions in the grammar, and 'Anonymous' is for unnamed productions of content such as tokens. Most of the time, assignments are only concerned with the named productions, and thus will be using 'Regular' symbols. Therefore, when matching a committed choice of all-'Regular' symbols, nodes with 'Anonymous' symbols will be skipped. However, in some cases grammars don’t provide a named symbol for e.g. every kind of infix operator, and thus the only way to differentiate between them is by means of a 'symbol' rule for an 'Anonymous' token. In these cases, and before every other kind of assignment, the 'Anonymous' nodes will not be skipped so that matching can succeed.
--
--   Therefore, in addition to the rule of thumb for committed choices (see above), try to match 'Regular' symbols up front, and only match 'Anonymous' ones in the middle of a chain. That will ensure that you don’t have to make redundant effort to explicitly skip 'Anonymous' nodes ahead of multiple alternatives, and can instead rely on them being automatically skipped except when explicitly required.
module Data.Syntax.Assignment
-- Types
( Assignment
, Location
, AST
, Node(..)
, nodeLocation
-- Combinators
, Alternative(..)
, MonadError(..)
, MonadFail(..)
, location
, currentNode
, symbol
, source
, children
, advance
, choice
, token
, while
, until
, manyThrough
-- Results
, Error(..)
, errorCallStack
, nodeError
, firstSet
-- Running
, assign
, runAssignment
-- Implementation details (for testing)
, State(..)
, makeState
, module Parsers
) where

import Control.Arrow ((&&&))
import Control.Applicative
import Control.Comonad.Cofree as Cofree
import qualified Control.Comonad.Trans.Cofree as CofreeF (CofreeF(..), headF)
import Control.Monad ((<=<), guard)
import Control.Monad.Error.Class hiding (Error)
import Control.Monad.Fail
import Control.Monad.Free.Freer
import Data.Bifunctor
import Data.ByteString (ByteString)
import Data.Error
import Data.Foldable
import Data.Function
import Data.Functor.Classes
import Data.Ix (Ix(..))
import Data.List.NonEmpty (NonEmpty(..), nonEmpty)
import Data.Maybe
import Data.Record
import Data.Semigroup
import qualified Data.Source as Source (Source, slice, sourceBytes)
import qualified Data.Syntax.Assignment.Table.IntMap as Table
import GHC.Stack
import qualified Info
import Prelude hiding (fail, until)
import Term (runCofree)
import Text.Parser.Combinators as Parsers hiding (choice)
import TreeSitter.Language

-- | Assignment from an AST with some set of 'symbol's onto some other value.
--
--   This is essentially a parser.
type Assignment ast grammar = Freer (Tracing (AssignmentF ast grammar))

data AssignmentF ast grammar a where
  End :: AssignmentF ast grammar ()
  Location :: AssignmentF ast grammar (Record Location)
  CurrentNode :: AssignmentF ast grammar (CofreeF.CofreeF ast (Node grammar) ())
  Source :: AssignmentF ast grammar ByteString
  Children :: Assignment ast grammar a -> AssignmentF ast grammar a
  Advance :: AssignmentF ast grammar ()
  Choose :: Table.Table grammar (Assignment ast grammar a) -> Maybe (Assignment ast grammar a) -> Maybe (Error (Either String grammar) -> Assignment ast grammar a) -> AssignmentF ast grammar a
  Many :: Assignment ast grammar a -> AssignmentF ast grammar [a]
  Alt :: [a] -> AssignmentF ast grammar a
  Label :: Assignment ast grammar a -> String -> AssignmentF ast grammar a
  Fail :: String -> AssignmentF ast grammar a

data Tracing f a where
  Tracing :: { tracingCallSite :: Maybe (String, SrcLoc), runTracing :: f a } -> Tracing f a

assignmentCallSite :: Assignment ast grammar a -> Maybe (String, SrcLoc)
assignmentCallSite (Tracing site _ `Then` _) = site
assignmentCallSite _ = Nothing

tracing :: HasCallStack => f a -> Tracing f a
tracing f = case getCallStack callStack of
  (_ : site : _) -> Tracing (Just site) f
  _ -> Tracing Nothing f

-- | Zero-width production of the current location.
--
--   If assigning at the end of input or at the end of a list of children, the loccation will be returned as an empty Range and Span at the current offset. Otherwise, it will be the Range and Span of the current node.
location :: HasCallStack => Assignment ast grammar (Record Location)
location = tracing Location `Then` return

-- | Zero-width production of the current node.
currentNode :: HasCallStack => Assignment ast grammar (CofreeF.CofreeF ast (Node grammar) ())
currentNode = tracing CurrentNode `Then` return

-- | Zero-width match of a node with the given symbol, producing the current node’s location.
symbol :: (Enum grammar, Ix grammar, HasCallStack) => grammar -> Assignment ast grammar (Record Location)
symbol s = tracing (Choose (Table.singleton s location) Nothing Nothing) `Then` return

-- | A rule to produce a node’s source as a ByteString.
source :: HasCallStack => Assignment ast grammar ByteString
source = tracing Source `Then` return

-- | Match a node by applying an assignment to its children.
children :: HasCallStack => Assignment ast grammar a -> Assignment ast grammar a
children child = tracing (Children child) `Then` return

-- | Advance past the current node.
advance :: HasCallStack => Assignment ast grammar ()
advance = tracing Advance `Then` return

choice :: (Enum grammar, Eq (ast (AST ast grammar)), Ix grammar, HasCallStack) => [Assignment ast grammar a] -> Assignment ast grammar a
choice [] = empty
choice alternatives
  | null choices = asum alternatives
  | otherwise    = tracing (Choose (Table.fromListWith (<|>) choices) (wrap . tracing . Alt . toList <$> nonEmpty atEnd) (mergeHandlers handlers)) `Then` return
  where (choices, atEnd, handlers) = foldMap toChoices alternatives
        toChoices :: (Enum grammar, Ix grammar) => Assignment ast grammar a -> ([(grammar, Assignment ast grammar a)], [Assignment ast grammar a], [Error (Either String grammar) -> Assignment ast grammar a])
        toChoices rule = case rule of
          Tracing _ (Choose t a h) `Then` continue -> (Table.toList (fmap (>>= continue) t), toList ((>>= continue) <$> a), toList ((continue <=<) <$> h))
          Tracing _ (Many  child)   `Then` _ -> let (c, _, _) = toChoices child in (fmap (rule <$) c, [rule], [])
          Tracing _ (Label child _) `Then` _ -> let (c, _, _) = toChoices child in (fmap (rule <$) c, [rule], [])
          Tracing _ (Alt as) `Then` continue -> foldMap (toChoices . continue) as
          _ -> ([], [rule], [])

        mergeHandlers [] = Nothing
        mergeHandlers hs = Just (\ err -> asum (hs <*> [err]))

-- | Match and advance past a node with the given symbol.
token :: (Enum grammar, Ix grammar, HasCallStack) => grammar -> Assignment ast grammar (Record Location)
token s = symbol s <* advance


-- | Collect a list of values passing a predicate.
while :: (Alternative m, Monad m, HasCallStack) => (a -> Bool) -> m a -> m [a]
while predicate step = many $ do
  result <- step
  guard (predicate result)
  pure result

-- | Collect a list of values failing a predicate.
until :: (Alternative m, Monad m, HasCallStack) => (a -> Bool) -> m a -> m [a]
until = while . (not .)

-- | Match the first operand until the second operand matches, returning both results. Like 'manyTill', but returning the terminal value.
manyThrough :: (Alternative m, HasCallStack) => m a -> m b -> m ([a], b)
manyThrough step stop = go
  where go = (,) [] <$> stop <|> first . (:) <$> step <*> go


-- | A location specified as possibly-empty intervals of bytes and line/column positions.
type Location = '[Info.Range, Info.Span]

-- | An AST node labelled with symbols and source location.
type AST f grammar = Cofree f (Node grammar)

data Node grammar = Node
  { nodeSymbol :: !grammar
  , nodeByteRange :: {-# UNPACK #-} !Info.Range
  , nodeSpan :: {-# UNPACK #-} !Info.Span
  }
  deriving (Eq, Show)

nodeLocation :: Node grammar -> Record Location
nodeLocation Node{..} = nodeByteRange :. nodeSpan :. Nil

nodeError :: HasCallStack => [Either String grammar] -> Node grammar -> Error (Either String grammar)
nodeError expected Node{..} = Error nodeSpan expected (Just (Right nodeSymbol))


firstSet :: (Enum grammar, Ix grammar) => Assignment ast grammar a -> [grammar]
firstSet = iterFreer (\ (Tracing _ assignment) _ -> case assignment of
  Choose table _ _ -> Table.tableAddresses table
  Label child _ -> firstSet child
  _ -> []) . ([] <$)


-- | Run an assignment over an AST exhaustively.
assign :: (Enum grammar, Ix grammar, Symbol grammar, Show grammar, Eq (ast (AST ast grammar)), Foldable ast, Functor ast)
       => Source.Source             -- ^ The source for the parse tree.
       -> Assignment ast grammar a  -- ^ The 'Assignment to run.
       -> AST ast grammar           -- ^ The root of the ast.
       -> Either (Error String) a   -- ^ 'Either' an 'Error' or an assigned value.
assign source assignment ast = bimap (fmap (either id show)) fst (runAssignment source assignment (makeState [ast]))
{-# INLINE assign #-}

-- | Run an assignment of nodes in a grammar onto terms in a syntax over an AST exhaustively.
runAssignment :: forall grammar a ast. (Enum grammar, Ix grammar, Symbol grammar, Eq (ast (AST ast grammar)), Foldable ast, Functor ast)
              => Source.Source                                                 -- ^ The source for the parse tree.
              -> Assignment ast grammar a                                      -- ^ The 'Assignment' to run.
              -> State ast grammar                                             -- ^ The current state.
              -> Either (Error (Either String grammar)) (a, State ast grammar) -- ^ 'Either' an 'Error' or an assigned value & updated state.
runAssignment source = \ assignment state -> go assignment state >>= requireExhaustive (assignmentCallSite assignment)
  -- Note: We explicitly bind source above in order to ensure that the where clause can close over them; they don’t change through the course of the run, so holding one reference is sufficient. On the other hand, we don’t want to accidentally capture the assignment and state in the where clause, since they change at every step—and capturing when you meant to shadow is an easy mistake to make, & results in hard-to-debug errors. Binding them in a lambda avoids that problem while also being easier to follow than a pointfree definition.
  where go :: Assignment ast grammar result -> State ast grammar -> Either (Error (Either String grammar)) (result, State ast grammar)
        go assignment = iterFreer run ((pure .) . (,) <$> assignment)
        {-# INLINE go #-}

        run :: Tracing (AssignmentF ast grammar) x
            -> (x -> State ast grammar -> Either (Error (Either String grammar)) (result, State ast grammar))
            -> State ast grammar
            -> Either (Error (Either String grammar)) (result, State ast grammar)
        run t yield initialState = expectedSymbols `seq` state `seq` maybe (anywhere Nothing) atNode (listToMaybe stateNodes)
          where atNode (node :< f) = case runTracing t of
                  Location -> yield (nodeLocation node) state
                  CurrentNode -> yield (node CofreeF.:< (() <$ f)) state
                  Source -> yield (Source.sourceBytes (Source.slice (nodeByteRange node) source)) (advanceState state)
                  Children child -> do
                    (a, state') <- go child state { stateNodes = toList f, stateCallSites = maybe id (:) (tracingCallSite t) stateCallSites } >>= requireExhaustive (tracingCallSite t)
                    yield a (advanceState state' { stateNodes = stateNodes, stateCallSites = stateCallSites })
                  Advance -> yield () (advanceState state)
                  Choose choices _ handler | Just choice <- Table.lookup (nodeSymbol node) choices -> (go choice state `catchError` (maybe throwError (flip go state .) handler)) >>= uncurry yield
                  _ -> anywhere (Just node)

                anywhere node = case runTracing t of
                  End -> requireExhaustive (tracingCallSite t) ((), state) >>= uncurry yield
                  Location -> yield (Info.Range stateOffset stateOffset :. Info.Span statePos statePos :. Nil) state
                  Many rule -> fix (\ recur state -> (go rule state >>= \ (a, state') -> first (a:) <$> if state == state' then pure ([], state') else recur state') `catchError` const (pure ([], state))) state >>= uncurry yield
                  Alt (a:as) -> sconcat (flip yield state <$> a:|as)
                  Label child label -> go child state `catchError` (\ err -> throwError err { errorExpected = [Left label] }) >>= uncurry yield
                  Fail s -> throwError ((makeError node) { errorActual = Just (Left s) })
                  Choose _ (Just atEnd) _ | Nothing <- node -> go atEnd state >>= uncurry yield
                  _ -> Left (makeError node)

                state@State{..} = if not (null expectedSymbols) && all ((== Regular) . symbolType) expectedSymbols then skipTokens initialState else initialState
                expectedSymbols = firstSet (t `Then` return)
                makeError = withStateCallStack (tracingCallSite t) state $ maybe (Error (Info.Span statePos statePos) (fmap Right expectedSymbols) Nothing) (nodeError (fmap Right expectedSymbols))

requireExhaustive :: Symbol grammar => Maybe (String, SrcLoc) -> (result, State ast grammar) -> Either (Error (Either String grammar)) (result, State ast grammar)
requireExhaustive callSite (a, state) = let state' = skipTokens state in case stateNodes state' of
  [] -> Right (a, state')
  (node :< _) : _ -> Left (withStateCallStack callSite state (nodeError [] node))

withStateCallStack :: Maybe (String, SrcLoc) -> State ast grammar -> (HasCallStack => a) -> a
withStateCallStack callSite state action = withCallStack (freezeCallStack (fromCallSiteList (maybe id (:) callSite (stateCallSites state)))) action

skipTokens :: Symbol grammar => State ast grammar -> State ast grammar
skipTokens state = state { stateNodes = dropWhile ((/= Regular) . symbolType . nodeSymbol . CofreeF.headF . runCofree) (stateNodes state) }

-- | Advances the state past the current (head) node (if any), dropping it off stateNodes, and updating stateOffset & statePos to its end; or else returns the state unchanged.
advanceState :: State ast grammar -> State ast grammar
advanceState state@State{..}
  | (Node{..} Cofree.:< _) : rest <- stateNodes = State (Info.end nodeByteRange) (Info.spanEnd nodeSpan) stateCallSites rest
  | otherwise = state

-- | State kept while running 'Assignment's.
data State ast grammar = State
  { stateOffset :: {-# UNPACK #-} !Int    -- ^ The offset into the Source thus far reached, measured in bytes.
  , statePos :: {-# UNPACK #-} !Info.Pos  -- ^ The (1-indexed) line/column position in the Source thus far reached.
  , stateCallSites :: ![(String, SrcLoc)] -- ^ The symbols & source locations of the calls thus far.
  , stateNodes :: ![AST ast grammar]      -- ^ The remaining nodes to assign. Note that 'children' rules recur into subterms, and thus this does not necessarily reflect all of the terms remaining to be assigned in the overall algorithm, only those “in scope.”
  }

deriving instance (Eq grammar, Eq (ast (AST ast grammar))) => Eq (State ast grammar)
deriving instance (Show grammar, Show (ast (AST ast grammar))) => Show (State ast grammar)

makeState :: [AST ast grammar] -> State ast grammar
makeState = State 0 (Info.Pos 1 1) []


-- Instances

instance (Enum grammar, Eq (ast (AST ast grammar)), Ix grammar) => Semigroup (Assignment ast grammar a) where
  (<>) = (<|>)

instance (Enum grammar, Eq (ast (AST ast grammar)), Ix grammar) => Monoid (Assignment ast grammar a) where
  mempty = empty
  mappend = (<|>)

instance (Enum grammar, Eq (ast (AST ast grammar)), Ix grammar) => Alternative (Assignment ast grammar) where
  empty :: HasCallStack => Assignment ast grammar a
  empty = tracing (Alt []) `Then` return

  (<|>) :: forall a. HasCallStack => Assignment ast grammar a -> Assignment ast grammar a -> Assignment ast grammar a
  Return a <|> _ = Return a
  l@(Tracing cs _ `Then` _) <|> r@Return{} = Tracing cs (Alt [l, r]) `Then` id
  l@(Tracing callSiteL la `Then` continueL) <|> r@(Tracing callSiteR ra `Then` continueR) = go callSiteL la continueL callSiteR ra continueR
    where go :: forall l r . Maybe (String, SrcLoc) -> AssignmentF ast grammar l -> (l -> Assignment ast grammar a) -> Maybe (String, SrcLoc) -> AssignmentF ast grammar r -> (r -> Assignment ast grammar a) -> Assignment ast grammar a
          go callSiteL la continueL callSiteR ra continueR = case (la, ra) of
            (Alt [], _) -> r
            (_, Alt []) -> l
            (Fail _, _) -> r
            (Children cl, Children cr) -> alternate (Children (Left <$> cl <|> Right <$> cr))
            (Location, Location) -> distribute Location
            (CurrentNode, CurrentNode) -> distribute CurrentNode
            (Advance, Advance) -> distribute Advance
            (End, End) -> distribute End
            (Source, Source) -> distribute Source
            (Alt ls, Alt rs) -> alternate (Alt ((Left <$> ls) <> (Right <$> rs)))
            (Alt ls, _) -> rebuild (Alt ((continueL <$> ls) <> pure r)) id
            (_, Alt rs) -> rebuild (Alt (pure l <> (continueR <$> rs))) id
            _           -> rebuild (Alt [l, r]) id
            where distribute :: (l ~ lr, r ~ lr) => AssignmentF ast grammar lr -> Assignment ast grammar a
                  distribute a = rebuild a (uncurry (<|>) . (continueL &&& continueR))
                  alternate :: AssignmentF ast grammar (Either l r) -> Assignment ast grammar a
                  alternate a = rebuild a (either continueL continueR)
                  rebuild :: AssignmentF ast grammar x -> (x -> Assignment ast grammar a) -> Assignment ast grammar a
                  rebuild a c = Tracing (callSiteL <|> callSiteR) a `Then` c

  many :: HasCallStack => Assignment ast grammar a -> Assignment ast grammar [a]
  many a = tracing (Many a) `Then` return

instance MonadFail (Assignment ast grammar) where
  fail :: HasCallStack => String -> Assignment ast grammar a
  fail s = tracing (Fail s) `Then` return

instance (Enum grammar, Eq (ast (AST ast grammar)), Ix grammar, Show grammar, Show (ast (AST ast grammar))) => Parsing (Assignment ast grammar) where
  try :: HasCallStack => Assignment ast grammar a -> Assignment ast grammar a
  try = id

  (<?>) :: HasCallStack => Assignment ast grammar a -> String -> Assignment ast grammar a
  a <?> s = tracing (Label a s) `Then` return

  unexpected :: HasCallStack => String -> Assignment ast grammar a
  unexpected = fail

  eof :: HasCallStack => Assignment ast grammar ()
  eof = tracing End `Then` return

  notFollowedBy :: (HasCallStack, Show a) => Assignment ast grammar a -> Assignment ast grammar ()
  notFollowedBy a = a *> unexpected (show a) <|> pure ()

instance (Enum grammar, Eq (ast (AST ast grammar)), Ix grammar, Show grammar) => MonadError (Error (Either String grammar)) (Assignment ast grammar) where
  throwError :: HasCallStack => Error (Either String grammar) -> Assignment ast grammar a
  throwError err = fail (show err)

  catchError :: HasCallStack => Assignment ast grammar a -> (Error (Either String grammar) -> Assignment ast grammar a) -> Assignment ast grammar a
  catchError rule handler = iterFreer (\ (Tracing cs assignment) continue -> case assignment of
    Choose choices atEnd Nothing -> Tracing cs (Choose (fmap (>>= continue) choices) (fmap (>>= continue) atEnd) (Just handler)) `Then` return
    Choose choices atEnd (Just onError) -> Tracing cs (Choose (fmap (>>= continue) choices) (fmap (>>= continue) atEnd) (Just (\ err -> (onError err >>= continue) <|> handler err))) `Then` return
    _ -> Tracing cs assignment `Then` ((`catchError` handler) . continue)) (fmap pure rule)

instance Show1 f => Show1 (Tracing f) where
  liftShowsPrec sp sl d = liftShowsPrec sp sl d . runTracing

instance (Enum grammar, Ix grammar, Show grammar, Show (ast (AST ast grammar))) => Show1 (AssignmentF ast grammar) where
  liftShowsPrec sp sl d a = case a of
    End -> showString "End" . showChar ' ' . sp d ()
    Advance -> showString "Advance" . showChar ' ' . sp d ()
    Location -> showString "Location" . sp d (Info.Range 0 0 :. Info.Span (Info.Pos 1 1) (Info.Pos 1 1) :. Nil)
    CurrentNode -> showString "CurrentNode"
    Source -> showString "Source" . showChar ' ' . sp d ""
    Children a -> showsUnaryWith showChild "Children" d a
    Choose choices atEnd _ -> showsBinaryWith (liftShowsPrec showChild showChildren) (liftShowsPrec showChild showChildren) "Choose" d choices atEnd
    Many a -> showsUnaryWith (liftShowsPrec (\ d a -> sp d [a]) (sl . pure)) "Many" d a
    Alt as -> showsUnaryWith (const sl) "Alt" d (toList as)
    Label child string -> showsBinaryWith (liftShowsPrec sp sl) showsPrec "Label" d child string
    Fail s -> showsUnaryWith showsPrec "Fail" d s
    where showChild = liftShowsPrec sp sl
          showChildren = liftShowList sp sl
