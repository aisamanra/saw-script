-- | Provides 
{- |
Module           : $Header$
Description      : Provides typechecked representation for method specifications and function for creating it from AST representation.
License          : Free for non-commercial use. See LICENSE.
Stability        : provisional
Point-of-contact : jhendrix, atomb
-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ScopedTypeVariables #-}
module SAWScript.JavaMethodSpecIR 
  (-- * MethodSpec record
    JavaMethodSpecIR
  , specName
  , specPos
  , specThisClass
  , specMethod
  , specMethodClass
  , specInitializedClasses
  , specBehaviors
  , specAddBehaviorCommand
  , specAddVarDecl
  , specAddLogicAssignment
  , specAddAliasSet
  , specJavaExprNames
  , specActualTypeMap
  , initMethodSpec
  --, resolveMethodSpecIR
    -- * Method behavior.
  , BehaviorSpec
  , bsLoc
  , bsRefExprs
  , bsMayAliasSet
  , RefEquivConfiguration
  , bsRefEquivClasses
  , bsActualTypeMap
  , bsLogicAssignments
  , bsLogicClasses
  , bsCheckAliasTypes
  , BehaviorCommand(..)
  , bsCommands
    -- * Equivalence classes for references.
  , JavaExprEquivClass
  , ppJavaExprEquivClass
  ) where

-- Imports {{{1

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
#endif
import Control.Monad
import Data.Graph.Inductive (scc, Gr, mkGraph)
import Data.List (intercalate, sort)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import qualified Data.Vector as V

import qualified Verifier.Java.Codebase as JSS
import qualified Verifier.Java.Common as JSS

import Verifier.SAW.SharedTerm

import qualified SAWScript.CongruenceClosure as CC
import SAWScript.CongruenceClosure (CCSet)
import SAWScript.JavaExpr
import SAWScript.Utils

-- ExprActualTypeMap {{{1

-- | Maps Java expressions for references to actual type.
type ExprActualTypeMap = Map JavaExpr JavaActualType

-- Alias definitions {{{1

type JavaExprEquivClass = [JavaExpr]

-- | Returns a name for the equivalence class.
ppJavaExprEquivClass :: JavaExprEquivClass -> String
ppJavaExprEquivClass [] = error "internal: ppJavaExprEquivClass"
ppJavaExprEquivClass [expr] = ppJavaExpr expr
ppJavaExprEquivClass cl = "{ " ++ intercalate ", " (map ppJavaExpr (sort cl)) ++ " }"

-- BehaviorSpec {{{1

-- | Postconditions used for implementing behavior specification. All
-- LogicExprs in behavior commands need to be extracted with
-- useLogicExpr, in a specific shared context, before they can be
-- used.
data BehaviorCommand
     -- | An assertion that is assumed to be true in the specificaiton.
   = AssertPred Pos LogicExpr
     -- | An assumption made in a conditional behavior specification.
   | AssumePred LogicExpr
     -- | Assign Java expression the value given by the mixed expression.
   | EnsureInstanceField Pos JavaExpr JSS.FieldId MixedExpr
     -- | Assign static Java field the value given by the mixed expression.
   | EnsureStaticField Pos JSS.FieldId MixedExpr
     -- | Assign array value of Java expression the value given by the rhs.
   | EnsureArray Pos JavaExpr MixedExpr
     -- | Modify the Java expression to an arbitrary value.
     -- May point to integral type or array.
   | ModifyInstanceField JavaExpr JSS.FieldId
     -- | Modify the Java static field to an arbitrary value.
   | ModifyStaticField JSS.FieldId
     -- | Modify the Java array to an arbitrary value.
     -- May point to integral type or array.
   | ModifyArray JavaExpr JavaActualType
     -- | Specifies value method returns.
   | ReturnValue MixedExpr
  deriving (Show)

data BehaviorSpec = BS {
         -- | Program counter for spec.
         bsLoc :: JSS.Breakpoint
         -- | Maps all expressions seen along path to actual type.
       , bsActualTypeMap :: ExprActualTypeMap
         -- | Stores which Java expressions must alias each other.
       , bsMustAliasSet :: CCSet JavaExprF
         -- | May alias relation between Java expressions.
       , bsMayAliasClasses :: [[JavaExpr]]
         -- | Equations
       , bsLogicAssignments :: [(Pos, JavaExpr, MixedExpr)]
         -- | Commands to execute in reverse order.
       , bsReversedCommands :: [BehaviorCommand]
       } deriving (Show)

-- | Returns list of all Java expressions that are references.
bsExprs :: BehaviorSpec -> [JavaExpr]
bsExprs bs = Map.keys (bsActualTypeMap bs)

-- | Returns list of all Java expressions that are references.
bsRefExprs :: BehaviorSpec -> [JavaExpr]
bsRefExprs bs = filter isRefJavaExpr (bsExprs bs)

bsMayAliasSet :: BehaviorSpec -> CCSet JavaExprF
bsMayAliasSet bs =
  CC.foldr CC.insertEquivalenceClass
           (bsMustAliasSet bs)
           (bsMayAliasClasses bs)

-- | Check that all expressions that may alias have equal types.
bsCheckAliasTypes :: Pos -> BehaviorSpec -> IO ()
bsCheckAliasTypes pos bs = mapM_ checkClass (CC.toList (bsMayAliasSet bs))
  where atm = bsActualTypeMap bs
        checkClass [] = error "internal: Equivalence class empty"
        checkClass (x:l) = do
          let Just xType = Map.lookup x atm
          forM l $ \y -> do
            let Just yType = Map.lookup x atm
            when (xType /= yType) $ do
              let msg = "Different types are assigned to " ++ show x ++ " and " ++ show y ++ "."
                  res = "All references that may alias must be assigned the same type."
              throwIOExecException pos (ftext msg) res

type RefEquivConfiguration = [(JavaExprEquivClass, JavaActualType)]

-- | Returns all possible potential equivalence classes for spec.
bsRefEquivClasses :: BehaviorSpec -> [RefEquivConfiguration]
bsRefEquivClasses bs = 
  map (map parseSet . CC.toList) $ Set.toList $
    CC.mayAliases (bsMayAliasClasses bs) (bsMustAliasSet bs)
 where parseSet l@(e:_) =
         case Map.lookup e (bsActualTypeMap bs) of
           Just tp -> (l,tp)
           Nothing -> error $ "internal: bsRefEquivClass given bad expression: " ++ show e
       parseSet [] = error "internal: bsRefEquivClasses given empty list."

bsPrimitiveExprs :: BehaviorSpec -> [JavaExpr]
bsPrimitiveExprs bs =
  [ e | (e, PrimitiveType _) <- Map.toList (bsActualTypeMap bs) ]
 
bsLogicEqs :: BehaviorSpec -> [(JavaExpr, JavaExpr)]
bsLogicEqs bs =
  [ (lhs, rhs) | (_, lhs, JE rhs) <- bsLogicAssignments bs ]

-- | Returns logic assignments to equivance class.
bsAssignmentsForClass ::  BehaviorSpec -> JavaExprEquivClass
                      -> [LogicExpr]
bsAssignmentsForClass bs cl = res 
  where s = Set.fromList cl
        res = [ rhs 
              | (_, lhs, LE rhs) <- bsLogicAssignments bs
              , Set.member lhs s
              ]

-- | Retuns ordering of Java expressions to corresponding logic value.
bsLogicClasses :: forall s.
                  SharedContext s
               -> Map String JavaExpr
               -> BehaviorSpec
               -> RefEquivConfiguration
               -> IO (Maybe [(JavaExprEquivClass, SharedTerm s, [LogicExpr])])
bsLogicClasses sc _m bs cfg = do
  let allClasses = CC.toList
                   -- Add logic equations.
                   $ flip (foldr (uncurry CC.insertEquation)) (bsLogicEqs bs)
                   -- Add primitive expression.
                   $ flip (foldr CC.insertTerm) (bsPrimitiveExprs bs)
                   -- Create initial set with references.
                   $ CC.fromList (map fst cfg)
  logicClasses <- (catMaybes <$>) $
                  forM allClasses $ \(cl@(e:_)) -> do
                    case Map.lookup e (bsActualTypeMap bs) of
                      Just at -> do
                        mtp <- logicTypeOfActual sc at
                        case mtp of
                          Just tp -> return (Just (cl, tp))
                          Nothing -> return Nothing
                      Nothing -> return Nothing
  let v = V.fromList logicClasses
      -- Create nodes.
      grNodes = [0..] `zip` logicClasses
      -- Create edges
      exprNodeMap = Map.fromList [ (e,n) | (n,(cl,_)) <- grNodes, e <- cl ]
      grEdges = [ (s,t,()) | (t,(cl,_)) <- grNodes
                           , src:_ <- [bsAssignmentsForClass bs cl]
                           , se <- logicExprJavaExprs src
                           , let Just s = Map.lookup se exprNodeMap ]
      -- Compute strongly connected components.
      components = scc (mkGraph grNodes grEdges :: Gr (JavaExprEquivClass, SharedTerm s) ())
  return $ if all (\l -> length l == 1) components
             then Just [ (cl, at, bsAssignmentsForClass bs cl)
                       | [n] <- components
                       , let (cl,at) = v V.! n ]
             else Nothing

-- Command utilities {{{2

-- | Return commands in behavior in order they appeared in spec.
bsCommands :: BehaviorSpec -> [BehaviorCommand]
bsCommands = reverse . bsReversedCommands

bsAddCommand :: BehaviorCommand -> BehaviorSpec -> BehaviorSpec
bsAddCommand bc bs =
  bs { bsReversedCommands = bc : bsReversedCommands bs }

initMethodSpec :: Pos -> JSS.Codebase
               -> JSS.Class -> String
               -> IO JavaMethodSpecIR
initMethodSpec pos cb thisClass mname = do
  (methodClass,method) <- findMethod cb pos mname thisClass
  superClasses <- JSS.supers cb thisClass
  let this = thisJavaExpr thisClass
      initTypeMap | JSS.methodIsStatic method = Map.empty
                  | otherwise = Map.singleton this (ClassInstance thisClass)
      initBS = BS { bsLoc = JSS.BreakEntry
                  , bsActualTypeMap = initTypeMap
                  , bsMustAliasSet =
                      if JSS.methodIsStatic method then
                        CC.empty
                      else
                        CC.insertTerm this CC.empty
                  , bsMayAliasClasses = []
                  , bsLogicAssignments = []
                  , bsReversedCommands = []
                  }
      initMS = MSIR { specPos = pos
                    , specThisClass = thisClass
                    , specMethodClass = methodClass
                    , specMethod = method
                    , specJavaExprNames = Map.empty
                    , specInitializedClasses =
                        map JSS.className superClasses
                    , specBehaviors = initBS
                    }
  return initMS

-- JavaMethodSpecIR {{{1

data JavaMethodSpecIR = MSIR {
    specPos :: Pos
    -- | Class used for this instance.
  , specThisClass :: JSS.Class
    -- | Class where method is defined.
  , specMethodClass :: JSS.Class
    -- | Method to verify.
  , specMethod :: JSS.Method
    -- | Mapping from user-visible Java state names to JavaExprs
  , specJavaExprNames :: Map String JavaExpr
    -- | Class names expected to be initialized using JVM "/" separators.
    -- (as opposed to Java "." path separators). Currently this is set
    -- to the list of superclasses of specThisClass.
  , specInitializedClasses :: [String]
    -- | Behavior specifications for method at different PC values.
    -- A list is used because the behavior may depend on the inputs.
  , specBehaviors :: BehaviorSpec  -- Map JSS.Breakpoint [BehaviorSpec]
  }

-- | Return user printable name of method spec (currently the class + method name).
specName :: JavaMethodSpecIR -> String
specName ir =
 let clName = JSS.className (specThisClass ir)
     mName = JSS.methodName (specMethod ir)
  in JSS.slashesToDots clName ++ ('.' : mName)

-- TODO: error if already declared
specAddVarDecl :: String -> JavaExpr -> JavaActualType
               -> JavaMethodSpecIR -> JavaMethodSpecIR
specAddVarDecl name expr jt ms = ms { specBehaviors = bs'
                                    , specJavaExprNames = ns' }
  where bs = specBehaviors ms
        bs' = bs { bsActualTypeMap =
                     Map.insert expr jt (bsActualTypeMap bs)
                 , bsMustAliasSet =
                     if JSS.isRefType (jssTypeOfJavaExpr expr) then
                       CC.insertTerm expr (bsMustAliasSet bs)
                     else
                       bsMustAliasSet bs
                 }
        ns' = Map.insert name expr (specJavaExprNames ms)

specAddLogicAssignment :: Pos -> JavaExpr -> MixedExpr
                       -> JavaMethodSpecIR -> JavaMethodSpecIR
specAddLogicAssignment pos expr t ms = ms { specBehaviors = bs' }
  where bs = specBehaviors ms
        las = bsLogicAssignments bs
        bs' = bs { bsLogicAssignments = (pos, expr, t) : las }

specAddAliasSet :: [JavaExpr] -> JavaMethodSpecIR -> JavaMethodSpecIR
specAddAliasSet exprs ms = ms { specBehaviors = bs' }
  where bs = specBehaviors ms
        bs' = bs { bsMayAliasClasses = exprs : bsMayAliasClasses bs }

specAddBehaviorCommand :: BehaviorCommand
                       -> JavaMethodSpecIR -> JavaMethodSpecIR
specAddBehaviorCommand bc ms =
  ms { specBehaviors = bsAddCommand bc (specBehaviors ms) }

specActualTypeMap :: JavaMethodSpecIR -> Map JavaExpr JavaActualType
specActualTypeMap = bsActualTypeMap . specBehaviors
