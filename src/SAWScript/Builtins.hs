{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ConstraintKinds #-}
module SAWScript.Builtins where

import Control.Applicative
import Control.Exception (bracket)
import Control.Lens
import Control.Monad.Error
import Control.Monad.State
import Data.Bits
import Data.Map ( Map )
import qualified Data.Map as Map
import Data.Vector ( Vector )
import qualified Data.Vector as V
import qualified Data.Vector.Storable as SV
import Text.PrettyPrint.Leijen hiding ((<$>))

import Verinf.Symbolic.Lit.ABC_GIA

import qualified Text.LLVM as LLVM
import qualified Verifier.LLVM.AST as L
import qualified Verifier.LLVM.Backend as L
import qualified Verifier.LLVM.Codebase as L
import qualified Verifier.LLVM.SAWBackend as LSAW
--import qualified Verifier.LLVM.BitBlastBackend as LBit
import qualified Verifier.LLVM.Simulator as L

import qualified Verifier.Java.Codebase as JSS
import qualified Verifier.Java.Simulator as JSS
import qualified Verifier.Java.WordBackend as JSS

import Verifier.SAW.BitBlast
import Verifier.SAW.Evaluator
import Verifier.SAW.Prelude
import qualified Verifier.SAW.SBVParser as SBV
import Verifier.SAW.SharedTerm
import Verifier.SAW.Recognizer
import Verifier.SAW.Rewriter
import Verifier.SAW.TypedAST hiding (instantiateVarList)

import qualified Verifier.SAW.Export.SMT.Version1 as SMT1
import qualified Verifier.SAW.Export.SMT.Version2 as SMT2
import Verifier.SAW.Import.AIG

import SAWScript.Options
import SAWScript.Utils

import qualified Verinf.Symbolic as BE
import Verinf.Utils.LogMonad

sawScriptPrims :: forall s. Options -> (Ident -> Value s) -> Map Ident (Value s)
sawScriptPrims opts global = Map.fromList
  -- Key SAWScript functions
  [ ("SAWScriptPrelude.topBind", toValue
      (topBind :: () -> () -> SC s (Value s) -> (Value s -> SC s (Value s)) -> SC s (Value s)))
  , ("SAWScriptPrelude.topReturn", toValue
      (topReturn :: () -> Value s -> SC s (Value s)))
  , ("SAWScriptPrelude.read_sbv", toValue
      (readSBV :: FilePath -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.read_aig", toValue
      (readAIGPrim :: FilePath -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.write_aig", toValue
      (writeAIG :: FilePath -> SharedTerm s -> SC s ()))
  , ("SAWScriptPrelude.write_smtlib1", toValue
      (writeSMTLib1 :: FilePath -> SharedTerm s -> SC s ()))
  , ("SAWScriptPrelude.write_smtlib2", toValue
      (writeSMTLib2 :: FilePath -> SharedTerm s -> SC s ()))
  , ("SAWScriptPrelude.llvm_extract", toValue
      (extractLLVM :: FilePath -> String -> SharedTerm s -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.java_extract", toValue
      (extractJava opts :: String -> String -> SharedTerm s -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.prove", toValue
      (proveABC :: SharedTerm s -> SharedTerm s -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.sat", toValue
      (satABC :: SharedTerm s -> SharedTerm s -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.equal", toValue
      (equalPrim :: SharedTerm s -> SharedTerm s -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.negate", toValue
      (scNegate :: SharedTerm s -> SC s (SharedTerm s)))
  -- Term building
  , ("SAWScriptPrelude.termGlobal", toValue
      (termGlobal :: String -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.termTrue", toValue (termTrue :: SC s (SharedTerm s)))
  , ("SAWScriptPrelude.termFalse", toValue (termFalse :: SC s (SharedTerm s)))
  , ("SAWScriptPrelude.termNat", toValue
      (termNat :: Integer -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.termVec", toValue
      (termVec :: Integer -> SharedTerm s -> Vector (SharedTerm s) -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.termTuple", toValue
      (termTuple :: Integer -> Vector (SharedTerm s) -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.termRecord", toValue
      (termRecord :: Integer -> Vector (String, SharedTerm s) -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.termSelect", toValue
      (termSelect :: SharedTerm s -> String -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.termLocalVar", toValue
      (termLocalVar :: Integer -> SharedTerm s -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.termGlobal", toValue
      (termGlobal :: String -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.termLambda", toValue
      (termLambda :: String -> SharedTerm s -> SharedTerm s -> SC s (SharedTerm s)))
  , ("SAWScriptPrelude.termApp", toValue
      (termApp :: SharedTerm s -> SharedTerm s -> SC s (SharedTerm s)))
  -- Misc stuff
  , ("SAWScriptPrelude.print", toValue
      (myPrint :: () -> Value s -> SC s ()))
  , ("SAWScriptPrelude.bvNatIdent", toValue ("Prelude.bvNat" :: String))
  , ("SAWScript.predNat", toValue (pred :: Integer -> Integer))
  , ("SAWScript.isZeroNat", toValue ((== 0) :: Integer -> Bool))
  , ("SAWScriptPrelude.evaluate", toValue (evaluate global :: () -> SharedTerm s -> Value s))
  , ("Prelude.append", toValue
      (myAppend :: Int -> Int -> () -> Value s -> Value s -> Value s))
  ]

allPrims :: Options -> (Ident -> Value s) -> Map Ident (Value s)
allPrims opts global = Map.union preludePrims (sawScriptPrims opts global)

--topReturn :: (a :: sort 0) -> a -> TopLevel a;
topReturn :: () -> Value s -> SC s (Value s)
topReturn _ = return

--topBind :: (a b :: sort 0) -> TopLevel a -> (a -> TopLevel b) -> TopLevel b;
topBind :: () -> () -> SC s (Value s) -> (Value s -> SC s (Value s)) -> SC s (Value s)
topBind _ _ = (>>=)

-- TODO: Add argument for uninterpreted-function map
readSBV :: FilePath -> SC s (SharedTerm s)
readSBV path =
    mkSC $ \sc -> do
      pgm <- SBV.loadSBV path
      SBV.parseSBVPgm sc (\_ _ -> Nothing) pgm

withBE :: (BE.BitEngine BE.Lit -> IO a) -> IO a
withBE f = do
  be <- BE.createBitEngine
  r <- f be
  BE.beFree be
  return r

{-
unLambda :: SharedContext s -> SharedTerm s -> IO (SharedTerm s)
unLambda sc (STApp _ (Lambda (PVar x _ _) ty tm)) = do
  arg <- scFreshGlobal sc x ty
  instantiateVar sc 0 arg tm >>= unLambda sc
unLambda _ tm = return tm
-}

-- | Read an AIG file representing a theorem or an arbitrary function
-- and represent its contents as a @SharedTerm@ lambda term. This is
-- inefficient but semantically correct.
readAIGPrim :: FilePath -> SC s (SharedTerm s)
readAIGPrim f = mkSC $ \sc -> do
  et <- withReadAiger f $ \ntk -> do
    outputLits <- networkOutputs ntk
    inputLits <- networkInputs ntk
    inType <- scBitvector sc (fromIntegral (SV.length inputLits))
    outType <- scBitvector sc (fromIntegral (SV.length outputLits))
    runErrorT $
      translateNetwork sc ntk outputLits [("x", inType)] outType
  case et of
    Left err -> fail $ "Reading AIG failed: " ++ err
    Right t -> return t

-- | Apply some rewrite rules before exporting, to ensure that terms
-- are within the language subset supported by formats such as SMT-Lib
-- QF_AUFBV or AIG.
prepForExport :: SharedContext s -> SharedTerm s -> IO (SharedTerm s)
prepForExport sc t = do
  ss <- scSimpset sc []  [mkIdent (moduleName preludeModule) "get_single"] []
  rewriteSharedTerm sc ss t

-- | Write a @SharedTerm@ representing a theorem or an arbitrary
-- function to an AIG file.
writeAIG :: FilePath -> SharedTerm s -> SC s ()
writeAIG f t = mkSC $ \sc -> withBE $ \be -> do
  t' <- prepForExport sc t
  mbterm <- bitBlast be t'
  case mbterm of
    Left msg ->
      fail $ "Can't bitblast term: " ++ msg
    Right bterm -> do
      ins <- BE.beInputLits be
      BE.beWriteAigerV be f ins (flattenBValue bterm)

-- | Write a @SharedTerm@ representing a theorem to an SMT-Lib version
-- 1 file.
writeSMTLib1 :: FilePath -> SharedTerm s -> SC s ()
writeSMTLib1 f t = mkSC $ \sc -> do
  -- TODO: better benchmark name than "sawscript"?
  t' <- prepForExport sc t
  let ws = SMT1.qf_aufbv_WriterState sc "sawscript"
  ws' <- execStateT (SMT1.writeFormula t') ws
  mapM_ (print . (text "WARNING:" <+>) . SMT1.ppWarning)
        (map (fmap scPrettyTermDoc) (ws' ^. SMT1.warnings))
  writeFile f (SMT1.render ws')

-- | Write a @SharedTerm@ representing a theorem to an SMT-Lib version
-- 2 file.
writeSMTLib2 :: FilePath -> SharedTerm s -> SC s ()
writeSMTLib2 f t = mkSC $ \sc -> do
  t' <- prepForExport sc t
  let ws = SMT2.qf_aufbv_WriterState sc
  ws' <- execStateT (SMT2.assert t') ws
  mapM_ (print . (text "WARNING:" <+>) . SMT2.ppWarning)
        (map (fmap scPrettyTermDoc) (ws' ^. SMT2.warnings))
  writeFile f (SMT2.render ws')

-- | Bit-blast a @SharedTerm@ representing a theorem and check its
-- satisfiability using ABC.
satABC :: SharedTerm s -> SharedTerm s -> SC s (SharedTerm s)
satABC _script t = mkSC $ \sc -> withBE $ \be -> do
  t' <- prepForExport sc t
  mbterm <- bitBlast be t'
  case (mbterm, BE.beCheckSat be) of
    (Right bterm, Just chk) -> do
      case bterm of
        BBool l -> do
          satRes <- chk l
          case satRes of
            BE.UnSat -> scApplyPreludeFalse sc
            BE.Sat _ -> scApplyPreludeTrue sc
            _ -> fail "ABC returned Unknown for SAT query."
        _ -> fail "Can't prove non-boolean term."
    (_, Nothing) -> fail "Backend does not support SAT checking."
    (Left err, _) -> fail $ "Can't bitblast: " ++ err

scNegate :: SharedTerm s -> SC s (SharedTerm s)
scNegate t = mkSC $ \sc -> do appNot <- scApplyPreludeNot sc ; appNot t

-- | Bit-blast a @SharedTerm@ representing a theorem and check its
-- validity using ABC.
proveABC :: SharedTerm s -> SharedTerm s -> SC s (SharedTerm s)
proveABC script t = do
  t' <- scNegate t
  r <- satABC script t'
  scNegate r

equal :: SharedContext s -> SharedTerm s -> SharedTerm s -> IO (SharedTerm s)
equal sc (STApp _ (Lambda (PVar x1 _ _) ty1 tm1)) (STApp _ (Lambda (PVar _ _ _) ty2 tm2)) = do
  let Just n1 = asBitvectorType ty1
  let Just n2 = asBitvectorType ty2
  unless (n1 == n2) $ fail "Types have different sizes."
  eqBody <- equal sc tm1 tm2
  scLambda sc x1 ty1 eqBody
equal sc tm1@(STApp _ (FTermF _)) tm2@(STApp _ (FTermF _)) = do
  ty1 <- scTypeOf sc tm1
  let Just n1 = asBitvectorType ty1
  ty2 <- scTypeOf sc tm2
  let Just n2 = asBitvectorType ty2
  unless (n1 == n2) $ fail "Types have different sizes."
  n1t <- scNat sc n1
  scBvEq sc n1t tm1 tm2
equal _ _ _ = fail "Incomparable terms."

equalPrim :: SharedTerm s -> SharedTerm s -> SC s (SharedTerm s)
equalPrim t1 t2 = mkSC $ \sc -> equal sc t1 t2

-- Implementations of SharedTerm primitives

termTrue :: SC s (SharedTerm s)
termTrue = mkSC $ \sc -> scCtorApp sc "Prelude.True" []

termFalse :: SC s (SharedTerm s)
termFalse = mkSC $ \sc -> scCtorApp sc "Prelude.False" []

termNat :: Integer -> SC s (SharedTerm s)
termNat n = mkSC $ \sc -> scNat sc n

termVec :: Integer -> SharedTerm s -> Vector (SharedTerm s) -> SC s (SharedTerm s)
termVec _ t v = mkSC $ \sc -> scVector sc t (V.toList v)

-- TODO: termGet

termTuple :: Integer -> Vector (SharedTerm s) -> SC s (SharedTerm s)
termTuple _ tv = mkSC $ \sc -> scTuple sc (V.toList tv)

termRecord :: Integer -> Vector (String, SharedTerm s) -> SC s (SharedTerm s)
termRecord _ v = mkSC $ \sc -> scMkRecord sc (Map.fromList (V.toList v))

termSelect :: SharedTerm s -> String -> SC s (SharedTerm s)
termSelect t s = mkSC $ \sc -> scRecordSelect sc t s

termLocalVar :: Integer -> SharedTerm s -> SC s (SharedTerm s)
termLocalVar n t = mkSC $ \sc -> scLocalVar sc (fromInteger n) t

termGlobal :: String -> SC s (SharedTerm s)
termGlobal name = mkSC $ \sc -> scGlobalDef sc (parseIdent name)

termLambda :: String -> SharedTerm s -> SharedTerm s -> SC s (SharedTerm s)
termLambda s t1 t2 = mkSC $ \sc -> scLambda sc s t1 t2

termApp :: SharedTerm s -> SharedTerm s -> SC s (SharedTerm s)
termApp t1 t2 = mkSC $ \sc -> scApply sc t1 t2

-- evaluate :: (a :: sort 0) -> Term -> a;
evaluate :: (Ident -> Value s) -> () -> SharedTerm s -> Value s
evaluate global _ = evalSharedTerm global

myPrint :: () -> Value s -> SC s ()
myPrint _ v = mkSC $ const (print v)

-- append :: (m n :: Nat) -> (e :: sort 0) -> Vec m e -> Vec n e -> Vec (addNat m n) e;
myAppend :: Int -> Int -> () -> Value s -> Value s -> Value s
myAppend _ _ _ (VWord a x) (VWord b y) = VWord (a + b) (x .|. shiftL y b)
myAppend _ _ _ (VVector xv) (VVector yv) = VVector ((V.++) xv yv)
myAppend _ _ _ _ _ = error "Prelude.append: malformed arguments"

-- | Extract a simple, pure model from the given symbol within the
-- given bitcode file. This code creates fresh inputs for all
-- arguments and returns a term representing the return value. Some
-- verifications will require more complex execution contexts.
--
-- Note! The s and s' type variables in this signature are different.
extractLLVM :: FilePath -> String -> SharedTerm s -> SC s (SharedTerm s')
extractLLVM file func _setup = mkSC $ \_sc -> do
  mdl <- L.loadModule file
  let dl = L.parseDataLayout $ LLVM.modDataLayout mdl
      mg = L.defaultMemGeom dl
      sym = L.Symbol func
  withBE $ \be -> do
    (sbe, mem) <- LSAW.createSAWBackend be dl mg
    cb <- L.mkCodebase sbe dl mdl
    case L.lookupDefine sym cb of
      Nothing -> fail $ "Bitcode file " ++ file ++
                        " does not contain symbol " ++ func ++ "."
      Just md -> L.runSimulator cb sbe mem L.defaultSEH Nothing $ do
        setVerbosity 0
        args <- mapM freshLLVMArg (L.sdArgs md)
        L.callDefine_ sym (L.sdRetType md) args
        mrv <- L.getProgramReturnValue
        case mrv of
          Nothing -> fail "No return value from simulated function."
          Just rv -> return rv

{-
extractLLVMBit :: FilePath -> String -> SC s (SharedTerm s')
extractLLVMBit file func = mkSC $ \_sc -> do
  mdl <- L.loadModule file
  let dl = L.parseDataLayout $ LLVM.modDataLayout mdl
      sym = L.Symbol func
      mg = L.defaultMemGeom dl
  withBE $ \be -> do
    LBit.SBEPair sbe mem <- return $ LBit.createBuddyAll be dl mg
    cb <- L.mkCodebase sbe dl mdl
    case L.lookupDefine sym cb of
      Nothing -> fail $ "Bitcode file " ++ file ++
                        " does not contain symbol " ++ func ++ "."
      Just md -> L.runSimulator cb sbe mem L.defaultSEH Nothing $ do
        setVerbosity 0
        args <- mapM freshLLVMArg (L.sdArgs md)
        L.callDefine_ sym (L.sdRetType md) args
        mrv <- L.getProgramReturnValue
        case mrv of
          Nothing -> fail "No return value from simulated function."
          Just bt -> undefined
-}

freshLLVMArg :: Monad m =>
            (t, L.MemType) -> L.Simulator sbe m (L.MemType, L.SBETerm sbe)
freshLLVMArg (_, ty@(L.IntType bw)) = do
  sbe <- gets L.symBE
  tm <- L.liftSBE $ L.freshInt sbe bw
  return (ty, tm)
freshLLVMArg (_, _) = fail "Only integer arguments are supported for now."

fixPos :: Pos
fixPos = PosInternal "FIXME"

extractJava :: Options -> String -> String -> SharedTerm s -> SC s (SharedTerm s)
extractJava opts cname mname _setup =  mkSC $ \sc -> do
  cb <- JSS.loadCodebase (jarList opts) (classPath opts)
  cls <- lookupClass cb fixPos cname
  (_, meth) <- findMethod cb fixPos mname cls
  oc <- BE.mkOpCache
  bracket BE.createBitEngine BE.beFree $ \be -> do
    de <- BE.mkConstantFoldingDagEngine
    sms <- JSS.mkSymbolicMonadState oc be de
    let fl  = JSS.defaultSimFlags { JSS.alwaysBitBlastBranchTerms = True }
        sbe = JSS.symbolicBackend sms
    JSS.runSimulator cb sbe JSS.defaultSEH (Just fl) $ do
      setVerbosity 0
      args <- mapM (freshJavaArg sbe) (JSS.methodParameterTypes meth)
      rslt <- JSS.execStaticMethod cname (JSS.methodKey meth) args
      dt <- case rslt of
              Nothing -> fail "No return value from JSS."
              Just (JSS.IValue t) -> return t
              Just (JSS.LValue t) -> return t
              _ -> fail "Unimplemented result type from JSS."
      et <- liftIO $ parseVerinfViaAIG sc de dt
      case et of
        Left err -> fail $ "Failed to extract Java model: " ++ err
        Right t -> return t

freshJavaArg :: MonadIO m =>
                JSS.Backend sbe
             -> JSS.Type
             -> m (JSS.AtomicValue d f (JSS.SBETerm sbe) (JSS.SBETerm sbe) r)
--freshJavaArg sbe JSS.BooleanType =
freshJavaArg sbe JSS.ByteType = liftIO (JSS.IValue <$> JSS.freshByte sbe)
--freshJavaArg sbe JSS.CharType =
--freshJavaArg sbe JSS.ShortType =
freshJavaArg sbe JSS.IntType = liftIO (JSS.IValue <$> JSS.freshInt sbe)
freshJavaArg sbe JSS.LongType = liftIO (JSS.LValue <$> JSS.freshLong sbe)
freshJavaArg _ _ = fail "Only byte, int, and long arguments are supported for now."

-- Java lookup functions {{{1

-- | Atempt to find class with given name, or throw ExecException if no class
-- with that name exists.
lookupClass :: JSS.Codebase -> Pos -> String -> IO JSS.Class
lookupClass cb pos nm = do
  maybeCl <- JSS.tryLookupClass cb nm
  case maybeCl of
    Nothing -> do
     let msg = ftext ("The Java class " ++ JSS.slashesToDots nm ++ " could not be found.")
         res = "Please check that the --classpath and --jars options are set correctly."
      in throwIOExecException pos msg res
    Just cl -> return cl

-- | Returns method with given name in this class or one of its subclasses.
-- Throws an ExecException if method could not be found or is ambiguous.
findMethod :: JSS.Codebase -> Pos -> String -> JSS.Class -> IO (JSS.Class, JSS.Method)
findMethod cb pos nm initClass = impl initClass
  where javaClassName = JSS.slashesToDots (JSS.className initClass)
        methodMatches m = JSS.methodName m == nm && not (JSS.methodIsAbstract m)
        impl cl =
          case filter methodMatches (JSS.classMethods cl) of
            [] -> do
              case JSS.superClass cl of
                Nothing ->
                  let msg = ftext $ "Could not find method " ++ nm
                              ++ " in class " ++ javaClassName ++ "."
                      res = "Please check that the class and method are correct."
                   in throwIOExecException pos msg res
                Just superName ->
                  impl =<< lookupClass cb pos superName
            [method] -> return (cl,method)
            _ -> let msg = "The method " ++ nm ++ " in class " ++ javaClassName
                             ++ " is ambiguous.  SAWScript currently requires that "
                             ++ "method names are unique."
                     res = "Please rename the Java method so that it is unique."
                  in throwIOExecException pos (ftext msg) res