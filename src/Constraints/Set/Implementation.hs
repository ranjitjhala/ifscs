{-# LANGUAGE FlexibleContexts, ScopedTypeVariables, DeriveDataTypeable #-}
{-# LANGUAGE BangPatterns #-}
module Constraints.Set.Implementation (
  ConstraintError(..),
  Variance(..),
  Inclusion,
  SetExpression(..),
  ConstraintSystem,
  SolvedSystem,
  emptySet,
  universalSet,
  setVariable,
  atom,
  term,
  (<=!),
  constraintSystem,
  solveSystem,
  leastSolution,
  -- * Debugging
  ConstraintEdge(..),
  solvedSystemGraphElems
  ) where

import Control.Exception
import Control.Failure
import Control.Monad.State.Strict
import qualified Data.Foldable as F
import qualified Data.Graph.Interface as G
import qualified Data.Graph.LazyHAMT as HAMT
import Data.Graph.Algorithms.Matching.DFS
import Data.Hashable
import Data.IntSet ( IntSet )
import qualified Data.IntSet as IS
import Data.List ( intercalate )
import Data.Map ( Map )
import qualified Data.Map as M
import Data.Maybe ( catMaybes, mapMaybe )
import Data.Monoid
import Data.HashSet ( HashSet )
import qualified Data.HashSet as HS
import Data.Typeable
import Data.Vector.Persistent ( Vector )
import qualified Data.Vector.Persistent as V

import Constraints.Set.ConstraintGraph ( ConstraintEdge(..) )
import qualified Constraints.Set.ConstraintGraph as CG

import Debug.Trace
debug = flip trace

-- FIXME: Build up a mutable graph (in ST) with an efficient edge
-- existence test and then convert to a LazyHAMT afterward.
--
-- Also, see about reducing the actual graph to be over Ints instead
-- of requiring complex comparisons (compare is taking 25% of the
-- runtime).
--
-- It shouldn't be necessary to keep node labels at all; just their
-- ids.  The saturation process never references them

-- 1) Take the list of initial constraints and simplify them using the
-- rewrite rules.  Once they are solved, all constraints are in
-- *atomic form*.
--
-- One approach is to fold over the list of constraints and simplify
-- each one until it is in atomic form (simplification can produce
-- multiple constraints).  Once at atomic form, add the constraint to
-- a set.

-- 2) Use the atomic constraints to build the closure graph.

emptySet :: SetExpression v c
emptySet = EmptySet

universalSet :: SetExpression v c
universalSet = UniversalSet

setVariable :: v -> SetExpression v c
setVariable = SetVariable

-- | Atomic terms have a label and arity zero.
atom :: c -> SetExpression v c
atom conLabel = ConstructedTerm conLabel [] []

-- | This returns a function to create terms from lists of
-- SetExpressions.  It is meant to be partially applied so that as
-- many terms as possible can share the same reference to a label and
-- signature.
term :: c -> [Variance] -> ([SetExpression v c] -> SetExpression v c)
term = ConstructedTerm

(<=!) :: SetExpression v c -> SetExpression v c -> Inclusion v c
(<=!) = (:<=)

constraintSystem :: [Inclusion v c] -> ConstraintSystem v c
constraintSystem = ConstraintSystem

data Variance = Covariant | Contravariant
              deriving (Eq, Ord, Show)

data SetExpression v c = EmptySet
                       | UniversalSet
                       | SetVariable v
                       | ConstructedTerm c [Variance] [SetExpression v c]
                       deriving (Eq, Ord)

instance (Show v, Show c) => Show (SetExpression v c) where
  show EmptySet = "∅"
  show UniversalSet = "U"
  show (SetVariable v) = show v
  show (ConstructedTerm c _ es) =
    concat [ show c, "("
           , intercalate ", " (map show es)
           , ")"
           ]

-- | An inclusion is a constraint of the form se1 ⊆ se2
data Inclusion v c = (SetExpression v c) :<= (SetExpression v c)
                                 deriving (Eq, Ord)

instance (Show v, Show c) => Show (Inclusion v c) where
  show (lhs :<= rhs) = concat [ show lhs, " ⊆ ", show rhs ]

-- | A constraint system is a set of constraints in DNF.  The
-- disjuncts are implicit.
data ConstraintSystem v c = ConstraintSystem [Inclusion v c]
                          deriving (Eq, Ord, Show)

data ConstraintError v c = NoSolution (Inclusion v c)
                         | NoVariableLabel v
                         deriving (Eq, Ord, Show, Typeable)

instance (Typeable v, Typeable c, Show v, Show c) => Exception (ConstraintError v c)

-- | Simplify one set expression.
simplifyInclusion :: (Failure (ConstraintError v c) m, Eq v, Eq c)
                     => [Inclusion v c]
                     -> Inclusion v c
                     -> m [Inclusion v c]
simplifyInclusion acc i =
  case i of
    -- Eliminate constraints of the form A ⊆ A
    SetVariable v1 :<= SetVariable v2 ->
      if v1 == v2 then return acc else return (i : acc)
    UniversalSet :<= EmptySet ->
      failure (NoSolution i)
    ConstructedTerm c1 s1 ses1 :<= ConstructedTerm c2 s2 ses2 ->
      let sigLen = length s1
          triples = zip3 s1 ses1 ses2
      in case c1 == c2 && s1 == s2 && sigLen == length ses1 && sigLen == length ses2 of
        False -> failure (NoSolution i)
        True -> foldM simplifyWithVariance acc triples
    UniversalSet :<= ConstructedTerm _ _ _ -> failure (NoSolution i)
    ConstructedTerm _ _ _ :<= EmptySet -> failure (NoSolution i)
    -- Eliminate constraints of the form A ⊆ 1
    _ :<= UniversalSet -> return acc
    -- 0 ⊆ A
    EmptySet :<= _ -> return acc
    -- Keep anything else (atomic forms)
    _ -> return (i : acc)

simplifyWithVariance :: (Failure (ConstraintError v c) m, Eq v, Eq c)
                        => [Inclusion v c]
                        -> (Variance, SetExpression v c, SetExpression v c)
                        -> m [Inclusion v c]
simplifyWithVariance acc (Covariant, se1, se2) =
  simplifyInclusion acc (se1 :<= se2)
simplifyWithVariance acc (Contravariant, se1, se2) =
  simplifyInclusion acc (se2 :<= se1)

simplifySystem :: (Failure (ConstraintError v c) m, Eq v, Eq c)
                  => ConstraintSystem v c
                  -> m (ConstraintSystem v c)
simplifySystem (ConstraintSystem is) = do
  is' <- foldM simplifyInclusion [] is
  return $! ConstraintSystem is'


type IFGraph = CG.Graph
type SolvedGraph = HAMT.Gr () ConstraintEdge

data SolvedSystem v c = SolvedSystem { systemIFGraph :: SolvedGraph
                                     , systemSetToIdMap :: Map (SetExpression v c) Int
                                     , systemIdToSetMap :: Vector (SetExpression v c)
                                     }


-- | Compute the least solution for the given variable
--
-- LS(y) = All source nodes with a predecessor edge to y, plus LS(x)
-- for all x where x has a predecessor edge to y.
leastSolution :: forall c m v . (Failure (ConstraintError v c) m, Ord v, Ord c)
                 => SolvedSystem v c
                 -> v
                 -> m [SetExpression v c]
leastSolution (SolvedSystem g0 m v) varLabel = do
  case M.lookup (SetVariable varLabel) m of
    Nothing -> failure ex
    Just nid -> return $ catMaybes $ xdfsWith G.pre' addTerm [nid] g0
  where
    ex :: ConstraintError v c
    ex = NoVariableLabel varLabel

    -- We only want to add ConstructedTerms to the output list
    addTerm :: G.Context SolvedGraph -> Maybe (SetExpression v c)
    addTerm (G.Context _ (G.LNode nid _) _) = do
      se <- V.index v nid
      case se of
        ConstructedTerm _ _ _ -> return se
        _ -> Nothing

solveSystem :: (Failure (ConstraintError v c) m, Eq c, Eq v, Ord c, Ord v)
               => ConstraintSystem v c
               -> m (SolvedSystem v c)
solveSystem s = do
  s' <- simplifySystem s
  return $! constraintsToIFGraph s'

constraintsToIFGraph :: (Ord v, Ord c) => ConstraintSystem v c -> SolvedSystem v c
constraintsToIFGraph (ConstraintSystem is) =
  SolvedSystem { systemIFGraph = G.mkGraph ns es
               , systemSetToIdMap = m
               , systemIdToSetMap = v
               }
  where
    s0 = BuilderState { exprIdMap = mempty
                      , idExprMap = mempty
                      , lruCache = Nothing -- LRU.newLRU (Just 10000)
                      }
    -- The initial graph has all of the nodes we need; after that we
    -- just need to saturate the edges through transitive closure
    (g, bs) = runState act s0 -- (buildInitialGraph is >>= saturateGraph) s0
    act = do
      theGraph <- buildInitialGraph is
      BuilderState m0 v0 _ <- get
      put $ BuilderState m0 v0 (Just 0)
      saturateGraph theGraph
    BuilderState m v _ = bs
    ns = map (\(nid, _) -> G.LNode nid ()) $ CG.graphNodes g
    es = map (\(s,d,l) -> G.LEdge (G.Edge s d) l) $ CG.graphEdges g

data BuilderState v c = BuilderState { exprIdMap :: Map (SetExpression v c) Int
                                     , idExprMap :: Vector (SetExpression v c)
                                     , lruCache :: Maybe Int -- LRU.LRU Int ()
                                     }
type BuilderMonad v c = State (BuilderState v c)

-- | Build an initial IF constraint graph that contains all of the
-- vertices and the edges induced by the initial simplified constraint
-- system.
buildInitialGraph :: (Ord v, Ord c) => [Inclusion v c] -> BuilderMonad v c IFGraph
buildInitialGraph is = do
  res <- foldM (addInclusion True) (CG.emptyGraph, mempty) is
  return (fst res)

data PredSegment = PS {-# UNPACK #-} !Int {-# UNPACK #-} !Int
                 deriving (Eq, Ord)

instance Hashable PredSegment where
  hash (PS l r) = l `combine` r

-- | Adds an inclusion to the constraint graph (adding vertices if
-- necessary).  Returns the set of nodes that are affected (and will
-- need more transitive edges).
addInclusion :: (Eq c, Ord v, Ord c)
                => Bool
                -> (IFGraph, HashSet PredSegment)
                -> Inclusion v c
                -> BuilderMonad v c (IFGraph, HashSet PredSegment)
addInclusion removeCycles acc i =
  case i of
    -- This is the key to an inductive form graph (rather than
    -- standard form)
    e1@(SetVariable v1) :<= e2@(SetVariable v2) ->
      case compare v1 v2 of
        EQ -> error "Constraints.Set.Solver.addInclusion: invalid A ⊆ A constraint"
        LT -> addEdge removeCycles acc Pred e1 e2
        GT -> addEdge removeCycles acc Succ e1 e2
    e1@(ConstructedTerm _ _ _) :<= e2@(SetVariable _) ->
      addEdge removeCycles acc Pred e1 e2
    e1@(SetVariable _) :<= e2@(ConstructedTerm _ _ _) ->
      addEdge removeCycles acc Succ e1 e2
    _ -> error "Constraints.Set.Solver.addInclusion: unexpected expression"

-- Track both a visited set and a "the nodes on the cycle" set
checkChain :: Bool -> ConstraintEdge -> IFGraph -> Int -> Int -> Maybe IntSet
checkChain False _ _ _ _ = Nothing
checkChain True tgt g from to = do
  chain <- snd $ checkChainWorker (mempty, Nothing) tgt g from to
  return $ IS.insert from chain

-- Only checkChainWorker adds things to the visited set
checkChainWorker :: (IntSet, Maybe IntSet) -> ConstraintEdge -> IFGraph -> Int -> Int -> (IntSet, Maybe IntSet)
checkChainWorker (visited, chain) tgt g from to
  | from == to = (visited, Just (IS.singleton to))
  | otherwise =
    let visited' = IS.insert from visited
    in CG.foldlPred (checkChainEdges tgt g to) (visited', chain) g from

-- Once we have a branch of the DFS that succeeds, just keep that
-- value.  This manages augmenting the set of nodes on the chain
checkChainEdges :: ConstraintEdge
                   -> IFGraph
                   -> Int
                   -> (IntSet, Maybe IntSet)
                   -> Int
                   -> ConstraintEdge
                   -> (IntSet, Maybe IntSet)
checkChainEdges _ _ _ acc@(_, Just _) _ _ = acc
checkChainEdges tgt g to acc@(visited, Nothing) v lbl
  | tgt /= lbl = acc
  | IS.member v visited = acc
  | otherwise =
    -- If there was no hit on this branch, just return the accumulator
    -- from the recursive call (which has an updated visited set)
    case checkChainWorker acc tgt g v to of
      acc'@(_, Nothing) -> acc'
      (visited', Just chain) -> (visited', Just (IS.insert v chain))

checkCycles :: BuilderMonad v c Bool
checkCycles = do
  BuilderState _ _ cnt <- get
  case cnt of
    Nothing -> return True
    Just c -> return $ c <= 1000

-- | Add an edge in the constraint graph between the two expressions
-- with the given label.  Adds nodes for the expressions if necessary.
--
-- FIXME: Instead of just returning a simple set here, we can return a
-- set of pairs (edges) that we know will need to be added.  Adding
-- those edges would then add more, &c.  This would save asymptotic
-- work when re-visiting the source nodes (already visited nodes can
-- be ignored).
addEdge :: (Eq v, Eq c, Ord v, Ord c)
           => Bool
           -> (IFGraph, HashSet PredSegment)
           -> ConstraintEdge
           -> SetExpression v c
           -> SetExpression v c
           -> BuilderMonad v c (IFGraph, HashSet PredSegment)
addEdge removeCycles acc@(!g0, !affected) etype e1 e2 = do
  (eid1, g1) <- getEID e1 g0
  (eid2, g2) <- getEID e2 g1
  case eid1 == eid2 || CG.edgeExists g2 eid1 eid2 of
    True -> return acc
    False -> do
      -- b <- checkCycles
      -- case b && removeCycles of
      case False of
        True -> tryCycleDetection removeCycles g2 affected etype eid1 eid2
        False -> simpleAddEdge g2 affected etype eid1 eid2
  -- case LRU.lookup eid1 cache of
  --   (_, Nothing) -> do
  --     put $ BuilderState m v (LRU.insert eid1 () cache)
  --     tryCycleDetection removeCycles g2 affected etype eid1 eid2
  --   (cache', Just _) -> do
  --     put $ BuilderState m v cache'
  --     simpleAddEdge g2 affected etype eid1 eid2

simpleAddEdge :: IFGraph -> HashSet PredSegment -> ConstraintEdge -> Int -> Int -> BuilderMonad v c (IFGraph, HashSet PredSegment)
simpleAddEdge g2 affected etype eid1 eid2 = do
  let !g3 = CG.insEdge eid1 eid2 etype g2
  case etype of
    Pred -> return $ (g3, HS.insert (PS eid1 eid2) affected)
    Succ -> return $ (g3, CG.foldlPred (addPredPred eid1) affected g3 eid1)
  where
    addPredPred _ acc _ Succ = acc
    addPredPred eid acc pid Pred =
      HS.insert (PS pid eid) acc

-- With cycle elimination the count of affected nodes each iteration
-- is an order of magnitude higher than it should be...

tryCycleDetection :: (Ord c, Ord v) => Bool -> IFGraph
                     -> HashSet PredSegment -> ConstraintEdge
                     -> Int -> Int -> BuilderMonad v c (IFGraph, HashSet PredSegment)
tryCycleDetection _ g2 affected Succ eid1 eid2 = simpleAddEdge g2 affected Succ eid1 eid2
tryCycleDetection removeCycles g2 affected etype eid1 eid2 =
  case checkChain removeCycles (otherLabel etype) g2 eid1 eid2 of
    Just chain | not (IS.null chain) -> do
      -- Make all of the nodes in the cycle refer to the min element
      -- (the reference bit is taken care of in the node lookup and in
      -- the result lookup).
      --
      -- For each of the nodes in @rest@, repoint their incoming and
      -- outgoing edges.
      BuilderState m v c <- get
      -- Find all of the edges from any node pointing to a node in
      -- @rest@.  Also find all edges from @rest@ out into the rest of
      -- the graph.  Then resolve those back to inclusions using @v@
      -- and call addInclusion over these new inclusions (after
      -- blowing away the old ones)
      let (representative, rest) = IS.deleteFindMin chain
          thisExp = V.unsafeIndex v representative
          newIncoming = IS.foldr' (srcsOf g2 v chain thisExp) [] rest
          newInclusions = IS.foldr' (destsOf g2 v chain thisExp) newIncoming rest
          g3 = IS.foldr' CG.removeNode g2 rest
          m' = IS.foldr' (replaceWith v representative) m rest
      put $! BuilderState m' v (maybe Nothing (Just . (+1)) c)
      foldM (addInclusion False) (g3, affected) newInclusions `debug`
        ("Removing " ++ show (IS.size chain) ++ " cycle (" ++ show eid1 ++
         " to " ++ show eid2 ++ "). " ++ show (CG.numNodes g3) ++
         " nodes left in the graph.") --   Re-adding " ++ show (length newInclusions) ++ " inclusions.")
      -- Nothing was affected because we didn't add any edges
    _ -> simpleAddEdge g2 affected etype eid1 eid2
  where
    otherLabel Succ = Pred
    otherLabel Pred = Succ

srcsOf g v chain newDst oldId acc =
  CG.foldlPred (\a srcId _ ->
                 case IS.member srcId chain of
                   True -> a
                   False -> (V.unsafeIndex v srcId :<= newDst) : a) acc g oldId

destsOf g v chain newSrc oldId acc =
  CG.foldlSucc (\a dstId _ ->
                 case IS.member dstId chain of
                   True -> a
                   False -> (newSrc :<= V.unsafeIndex v dstId) : a) acc g oldId

-- | Change the ID of the node with ID @i@ to @repr@
replaceWith :: (Ord k) => Vector k -> a -> Int -> Map k a -> Map k a
replaceWith v repr i m =
  case M.lookup se m of
    Nothing -> m
    Just _ -> M.insert se repr m
  where
    se = V.unsafeIndex v i

-- | Get the ID for the expression node.  Inserts a new node into the
-- graph if needed.
getEID :: (Ord v, Ord c)
          => SetExpression v c
          -> IFGraph
          -> BuilderMonad v c (Int, IFGraph)
getEID e g = do
  BuilderState m v c <- get
  case M.lookup e m of
    -- Even if we find the ID for the expression, we have to check to
    -- see if the node has been renamed due to cycle elimination
    Just i -> return (i, g)
    Nothing -> do
      let eid = V.length v
          !v' = V.snoc v e
          !m' = M.insert e eid m
          !g' = CG.insNode eid g
      put $! BuilderState m' v' c
      return (eid, g')

-- | For each node L in the graph, follow its predecessor edges to
-- obtain set X.  For each ndoe in X, follow its successor edges
-- giving a list of R.  Generate L ⊆ R and simplify it with
-- 'simplifyInclusion'.  These are new edges (collect them all in a
-- set, discarding existing edges).
--
-- After a pass, insert all of the new edges
--
-- Repeat until no new edges are found.
--
-- An easy optimization is to base the next iteration only on the
-- newly-added edges (since any additions in the next iteration must
-- be due to those new edges).  It would require searching forward
-- (for pred edges) and backward (for succ edges).
--
-- Also perform online cycle detection per FFSA98
--
-- This function can fail if a constraint generated by the saturation
-- implies that no solution is possible.  I think that probably
-- shouldn't ever happen but I have no proof.
saturateGraph :: (Eq v, Eq c, Ord v, Ord c)
                 => IFGraph
                 -> BuilderMonad v c IFGraph
saturateGraph g0 = closureEdges es0 g0
  where
    -- Initialize the saturation worklist with all of the predecessor
    -- edges in the initial graph
    es0 = HS.fromList $ mapMaybe predToPredSeg $ CG.graphEdges g0
    predToPredSeg (l, r, Pred) = return $ PS l r
    predToPredSeg _ = Nothing

    simplify v e (IE l r) =
      let incl = V.unsafeIndex v l :<= V.unsafeIndex v r
          Just incl' = simplifyInclusion e incl
      in incl'
    -- Here is our problem (possibly also related to the self loops
    -- appearing).  We find new edges with findEdge, which just
    -- consults adjacency links.  Some of these refer to old nodes
    -- that were eliminated?  Shouldn't...  But the edges identified
    -- might not exist (and will never exist because their endpoints
    -- are collapsed).
    closureEdges ns g
      | HS.null ns = return g
      | otherwise = do
        BuilderState m v _ <- get `debug` show (HS.size ns)
        let nextEdges = F.foldl' (findEdge m v g) mempty ns
            inclusions = F.foldl' (simplify v) [] nextEdges
        case null inclusions of
          True -> return g
          False -> do
            (g', affectedNodes) <- foldM (addInclusion True) (g, mempty) inclusions
            closureEdges affectedNodes g'

{-# INLINE findEdge #-}
findEdge :: (Ord k) => Map k Int -> Vector k -> IFGraph
            -> HashSet InclusionEndpoints -> PredSegment
            -> HashSet InclusionEndpoints
findEdge m v g s (PS l x) =
  CG.foldlSucc (toNewInclusion m v g l) s g x

data InclusionEndpoints = IE {-# UNPACK #-} !Int {-# UNPACK #-} !Int
                        deriving (Eq)

instance Hashable InclusionEndpoints where
  hash (IE l r) = l `combine` r

{-# INLINE toNewInclusion #-}
toNewInclusion :: (Ord k) => Map k Int -> Vector k -> IFGraph
                  -> Int -> HashSet InclusionEndpoints
                  -> Int -> ConstraintEdge
                  -> HashSet InclusionEndpoints
toNewInclusion _ _ _ _ acc _ Pred = acc
toNewInclusion m v g l acc r Succ =
  -- let l' = M.findWithDefault l (V.unsafeIndex v l) m
  --     r' = M.findWithDefault r (V.unsafeIndex v r) m
  -- in
   case CG.edgeExists g l r of
    True -> acc
    False -> HS.insert (IE l r) acc

solvedSystemGraphElems :: (Eq v, Eq c) => SolvedSystem v c -> ([(Int, SetExpression v c)], [(Int, Int, ConstraintEdge)])
solvedSystemGraphElems (SolvedSystem g _ v) = (ns, es)
  where
    ns = map (\(G.LNode nid _) -> (nid, V.unsafeIndex v nid)) $ G.labNodes g
    es = map (\(G.LEdge (G.Edge s d) l) -> (s, d, l)) $ G.labEdges g