{-# language GADTs             #-}
{-# language LambdaCase        #-}
{-# language NamedFieldPuns    #-}
{-# language OverloadedStrings #-}
{-# language Rank2Types        #-}
{-# language TupleSections     #-}

{-# language ScopedTypeVariables     #-}

module Pact.Analyze.Check
  ( checkTopFunction
  , verifyModule
  , failedTcOrAnalyze
  , describeCheckResult
  , CheckFailure(..)
  , CheckSuccess(..)
  , CheckResult
  ) where

import Control.Concurrent.MVar
import Control.Monad.Except (runExcept, runExceptT)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader
import Control.Monad.State.Strict (evalStateT)
import Control.Monad.Trans.RWS.Strict (RWST(..))
import Control.Lens hiding (op, (.>), (...))
import Data.Maybe (catMaybes, mapMaybe)
import Data.Text (Text)
import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.HashMap.Strict as HM
import Data.Traversable (for)
import Data.Set (Set)
import Data.SBV hiding (Satisfiable, Unsatisfiable, Unknown, ProofError, name)
import qualified Data.SBV as SBV
import qualified Data.SBV.Internals as SBVI
import qualified Data.Text as T
import Pact.Typechecker hiding (debug)
import Pact.Types.Runtime hiding (Term, WriteType(..), TableName, Type, EObject)
import qualified Pact.Types.Runtime as Pact
import Pact.Types.Typecheck hiding (Var, UserType, Object, Schema)
import qualified Pact.Types.Typecheck as TC

import Pact.Analyze.Analyze (Analyze, AnalyzeFailure, allocateSymbolicCells,
                             analyzeTerm, analyzeTermO, analyzeProp,
                             describeAnalyzeFailure, mkAnalyzeEnv,
                             mkInitialAnalyzeState, mkQueryEnv, runAnalyze,
                             queryAction, mkInitialAnalyzeState,
                             checkInvariantsHeld, runConstraints)
import Pact.Analyze.Prop
import Pact.Analyze.Translate
import Pact.Analyze.Types
import Pact.Compile (expToCheck, expToInvariant)

data CheckFailure
  = Invalid SBVI.SMTModel
  | Unsatisfiable
  | Unknown String -- reason
  | SatExtensionField SBVI.SMTModel
  | ProofError [String]
  | TypecheckFailure (Set TC.Failure)
  | AnalyzeFailure AnalyzeFailure
  | TranslateFailure TranslateFailure
  | PropertyParseError Exp
  --
  -- TODO: maybe remove this constructor from from CheckFailure.
  --
  | CodeCompilationFailed String
  deriving (Show)

describeCheckFailure :: CheckFailure -> Text
describeCheckFailure = \case
  Invalid model ->
    "Invalidating model found:\n" <>
    T.pack (show model)
  Unsatisfiable  -> "This property is unsatisfiable"
  Unknown reason ->
    "The solver returned unknown with reason:\n" <>
    T.pack (show reason)
  SatExtensionField model ->
    "The solver return a model, but in an extension field containing infinite / epsilon:\n" <>
    T.pack (show model)
  ProofError lines' ->
    "The prover errored:\n" <>
    T.unlines (T.pack <$> lines')
  TypecheckFailure fails ->
    "The module failed to typecheck:\n" <>
    (T.unlines $ map
      (\(Failure ti s) -> T.pack (renderInfo (_tiInfo ti) ++ " error: " ++ s))
      (Set.toList fails))
  AnalyzeFailure err        -> describeAnalyzeFailure err
  TranslateFailure err      -> describeTranslateFailure err
  PropertyParseError expr   -> "Couldn't parse property: " <> T.pack (show expr)
  CodeCompilationFailed msg -> T.pack msg

data CheckSuccess
  = SatisfiedProperty SBVI.SMTModel
  | ProvedTheorem
  deriving (Show)

describeCheckSuccess :: CheckSuccess -> Text
describeCheckSuccess = \case
  SatisfiedProperty model ->
    "Property satisfied with model:\n" <>
    T.pack (show model)
  ProvedTheorem           -> "Property proven valid"

type CheckResult
  = Either CheckFailure CheckSuccess

describeCheckResult :: CheckResult -> Text
describeCheckResult = either describeCheckFailure describeCheckSuccess

checkFunctionBody
  :: [(Text, TC.UserType, [(Text, SchemaInvariant Bool)])]
  -> Maybe Check
  -> [AST Node]
  -> [(Text, Pact.Type TC.UserType)]
  -> Map Node Text
  -> IO CheckResult
checkFunctionBody tables (Just check) body argTys nodeNames =
  case runExcept (evalStateT (runReaderT (unTranslateM (translateBody body)) nodeNames) 0) of
    Left reason -> pure $ Left $ TranslateFailure reason

    Right tm -> do
      compileFailureVar <- newEmptyMVar

      checkResult <- runCheck check $ do
        let tables' = tables & traverse %~ (\(a, b, _c) -> (a, b))
        aEnv <- mkAnalyzeEnv argTys tables
        state0
          <- mkInitialAnalyzeState tables' <$> allocateSymbolicCells tables'

        let prop = check ^. ckProp

            go :: Analyze AVal -> Symbolic (S Bool)
            go act = do
              let eAnalysis = runIdentity $ runExceptT $ runRWST (runAnalyze act) aEnv state0
              case eAnalysis of
                Left cf -> do
                  liftIO $ putMVar compileFailureVar cf
                  pure false
                Right (propResult, state1, constraints) -> do
                  let qEnv = mkQueryEnv aEnv state1 propResult
                      qAction = (&&&)
                        <$> analyzeProp prop
                        <*> checkInvariantsHeld
                  runConstraints constraints
                  eQuery <- runExceptT $ runReaderT (queryAction qAction) qEnv
                  case eQuery of
                    Left cf' -> do
                      liftIO $ putMVar compileFailureVar cf'
                      pure false
                    Right symAction -> pure $ symAction

        case tm of
          ETerm   body'' _ -> go . (fmap mkAVal) . analyzeTerm $ body''
          EObject body'' _ -> go . (fmap AnObj) . analyzeTermO $ body''

      mVarVal <- tryTakeMVar compileFailureVar
      pure $ case mVarVal of
        Nothing -> checkResult
        Just cf -> Left (AnalyzeFailure cf)

checkFunctionBody tables Nothing body argTys nodeNames =
  case runExcept (evalStateT (runReaderT (unTranslateM (translateBody body)) nodeNames) 0) of
    Left reason -> pure $ Left $ TranslateFailure reason

    Right tm -> do
      compileFailureVar <- newEmptyMVar

      checkResult <- runProvable $ do
        let tables' = tables & traverse %~ (\(a, b, _c) -> (a, b))
        aEnv <- mkAnalyzeEnv argTys tables
        state0
          <- mkInitialAnalyzeState tables' <$> allocateSymbolicCells tables'

        let go :: Analyze AVal -> Symbolic (S Bool)
            go act = do
              let eAnalysis = runIdentity $ runExceptT $ runRWST (runAnalyze act) aEnv state0
              case eAnalysis of
                Left cf -> do
                  liftIO $ putMVar compileFailureVar cf
                  pure false
                Right (propResult, state1, _log) -> do
                  let qEnv = mkQueryEnv aEnv state1 propResult
                  eQuery <- runExceptT $ runReaderT (queryAction checkInvariantsHeld) qEnv
                  case eQuery of
                    Left cf' -> do
                      liftIO $ putMVar compileFailureVar cf'
                      pure false
                    Right symAction -> pure $ symAction

        case tm of
          ETerm   body'' _ -> go . (fmap mkAVal) . analyzeTerm $ body''
          EObject body'' _ -> go . (fmap AnObj) . analyzeTermO $ body''

      mVarVal <- tryTakeMVar compileFailureVar
      pure $ case mVarVal of
        Nothing -> checkResult
        Just cf -> Left (AnalyzeFailure cf)

checkTopFunction
  :: [(Text, TC.UserType, [(Text, SchemaInvariant Bool)])]
  -> TopLevel Node
  -> Maybe Check
  -> IO CheckResult
checkTopFunction tables (TopFun (FDefun _ _ _ args body' _)) check =
  let nodes :: [Node]
      nodes = _nnNamed <$> args

      -- Extract the plain/unmunged names from the source code. We use the
      -- munged names for let/bind/with-read/etc -bound variables, but plain
      -- names for the args for usability. Because let/bind/etc can't shadow
      -- these unmunged names, we retain our SSA property.
      names :: [Text]
      names = _nnName <$> args

      argTys :: [(Text, Pact.Type TC.UserType)]
      argTys = zip names (_aTy <$> nodes)

      nodeNames :: Map Node Text
      nodeNames = Map.fromList $ zip nodes names

  in checkFunctionBody tables check body' argTys nodeNames

checkTopFunction _ _ _ = pure $ Left $ CodeCompilationFailed "Top-Level Function analysis can only work on User defined functions (i.e. FDefun)"

runProvable :: Provable a => a -> IO CheckResult
runProvable provable = do
  ThmResult smtRes <- proveWith (z3 {verbose=False}) provable
  pure $ case smtRes of
    SBV.Unsatisfiable{}           -> Right ProvedTheorem
    SBV.Satisfiable _config model -> Left $ Invalid model
    SBV.SatExtField _config model -> Left $ SatExtensionField model
    SBV.Unknown _config reason    -> Left $ Unknown reason
    SBV.ProofError _config strs   -> Left $ ProofError strs

-- This does not use the underlying property -- this merely dispatches to
-- sat/prove appropriately, and accordingly translates sat/unsat to
-- semantically-meaningful results.
runCheck :: Provable a => Check -> a -> IO CheckResult
runCheck (Satisfiable _prop) provable = do
  (SatResult smtRes) <- sat provable
  pure $ case smtRes of
    SBV.Unsatisfiable{} -> Left Unsatisfiable
    SBV.Satisfiable _config model -> Right $ SatisfiedProperty model
    SBV.SatExtField _config model -> Left $ SatExtensionField model
    SBV.Unknown _config reason -> Left $ Unknown reason
    SBV.ProofError _config strs -> Left $ ProofError strs
runCheck (Valid _prop) provable = do
  ThmResult smtRes <- proveWith (z3 {verbose=False}) provable
  pure $ case smtRes of
    SBV.Unsatisfiable{} -> Right ProvedTheorem
    SBV.Satisfiable _config model -> Left $ Invalid model
    SBV.SatExtField _config model -> Left $ SatExtensionField model
    SBV.Unknown _config reason -> Left $ Unknown reason
    SBV.ProofError _config strs -> Left $ ProofError strs

failedTcOrAnalyze
  :: [(Text, TC.UserType, [(Text, SchemaInvariant Bool)])]
  -> TcState
  -> TopLevel Node
  -> Maybe Check
  -> IO CheckResult
failedTcOrAnalyze tables tcState fun check =
    if Set.null failures
    then checkTopFunction tables fun check
    else pure $ Left $ TypecheckFailure failures
  where
    failures = tcState ^. tcFailures

verifyModule :: ModuleData -> IO (HM.HashMap Text [CheckResult])
verifyModule (_mod, modRefs) = do

  -- All tables defined in this module. We're going to look through these for
  -- their schemas, which we'll look through for invariants.
  let tables = flip mapMaybe (HM.toList modRefs) $ \case
        (name, Ref (table@TTable {})) -> Just (name, table)
        _                             -> Nothing

  -- TODO: need mapMaybe for HashMap
  let schemas = HM.fromList $ flip mapMaybe (HM.toList modRefs) $ \case
        (name, Ref (schema@TSchema {})) -> Just (name, schema)
        _                               -> Nothing

  -- All function definitions in this module. We're going to look through these
  -- for properties.
  let defns = flip HM.filter modRefs $ \ref -> case ref of
        Ref (TDef {}) -> True
        _             -> False

  tablesWithInvariants <- for tables $ \(tabName, tab) -> do
    (TopTable _info _name (TyUser schema), _tcState)
      <- runTC 0 False $ typecheckTopLevel (Ref tab)

    let schemaName = unTypeName (_utName schema)

    -- look through every meta-property in the schema for invariants
    let metas :: [(Text, Exp)]
        metas = schemas ^@.. ix schemaName . tMeta . _Just . mMetas . itraversed

    let invariants :: [(Text, SchemaInvariant Bool)]
        invariants = catMaybes $ flip fmap metas $ \(metaName, meta) -> do
          "invariant" <- pure metaName
          SomeSchemaInvariant expr TBool
            <- expToInvariant (_utFields schema) meta
          [v] <- pure $ Set.toList (invariantVars expr)
          pure (v, expr)

    pure (tabName, schema, invariants)

  -- convert metas to checks
  defnsWithChecks <- for defns $ \ref -> do
    -- look through every meta-property in the definition for invariants
    let Ref defn = ref
        metas :: [(Text, Exp)]
        metas = defn ^@.. tMeta . _Just . mMetas . itraversed
    let checks :: [Check]
        checks = catMaybes $ flip fmap metas $ \(metaName, meta) -> do
          "property" <- pure metaName
          expToCheck meta
    pure (ref, checks)

  -- Now the meat of verification! For each definition in the module we check
  -- 1. that is maintains all invariants
  -- 2. that is passes any properties declared for it
  for defnsWithChecks $ \(ref, props) -> do
    (fun, tcState) <- runTC 0 False $ typecheckTopLevel ref
    case fun of
      TopFun (FDefun {}) -> do
        result  <- failedTcOrAnalyze tablesWithInvariants tcState fun Nothing
        results <- forM props $
          failedTcOrAnalyze tablesWithInvariants tcState fun . Just
        pure $ result : results
      _ -> pure []
