
module Elaboration where

import Control.Exception
import Control.Monad
import Data.IORef
import Data.Maybe
import Lens.Micro.Platform
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS

import Types
import Evaluation
import ElabState
import Errors

-- Context operations
--------------------------------------------------------------------------------

emptyCxt :: Cxt
emptyCxt = Cxt VNil TNil [] [] 0

-- | Add a bound variable.
bind :: Name -> NameOrigin -> VTy -> Cxt -> Cxt
bind x o ~a (Cxt vs tys ns no d) =
  Cxt (VSkip vs) (TBound tys a) (x:ns) (o:no) (d + 1)

-- | Add a bound variable which comes from surface syntax.
bindSrc :: Name -> VTy -> Cxt -> Cxt
bindSrc x = bind x NOSource

-- | Define a new variable.
define :: Name -> VTy -> Val -> Cxt -> Cxt
define x ~a ~t (Cxt vs tys ns no d) =
  Cxt (VDef vs t) (TDef tys a) (x:ns) (NOSource:no) (d + 1)

-- | Lift ("skolemize") a value in an extended context to a function in a
--   non-extended context.
liftVal :: Cxt -> Val -> (Val -> Val)
liftVal cxt t = \ ~x -> eval (VDef (cxt^.vals) x) $ quote (cxt^.len+1) t


-- Constancy constraints
--------------------------------------------------------------------------------

data Occurs
  = Rigid           -- ^ At least one occurrence is not in the spine of any meta.
  | Flex IS.IntSet  -- ^ All occurrences are inside spines of metas. We store the set of such metas.
  | None            -- ^ The variable does not occur.
  deriving (Eq, Show)

instance Semigroup Occurs where
  Flex ms <> Flex ms' = Flex (ms <> ms')
  Rigid   <> _        = Rigid
  _       <> Rigid    = Rigid
  None    <> r        = r
  l       <> None     = l

occurrence :: IS.IntSet -> Occurs
occurrence ms | IS.null  ms = Rigid
              | otherwise   = Flex ms

instance Monoid Occurs where
  mempty = None

-- | Occurs check for the purpose of constancy constraint solving.
occurs :: Lvl -> Lvl -> Val -> Occurs
occurs d topX = occurs' d mempty where

  occurs' :: Lvl -> IS.IntSet -> Val -> Occurs
  occurs' d ms = go where

    goSp ms sp = case forceSp sp of
      SNil           -> mempty
      SApp sp u i    -> goSp ms sp <> go u
      SAppTel a sp u -> go a <> goSp ms sp <> go u
      SProj1 sp      -> goSp ms sp
      SProj2 sp      -> goSp ms sp

    goBind t =
      occurs' (d + 1) ms (t (VVar d))

    go v = case force v of
      VNe (HVar x) sp | x == topX -> occurrence ms <> goSp ms sp
      VNe (HVar x) sp             -> goSp ms sp
      VNe (HMeta m) sp            -> goSp (IS.insert m ms) sp
      VPi _ i a b   -> go a <> goBind b
      VLam _ i a t  -> go a <> goBind t
      VU            -> mempty
      VTel          -> mempty
      VRec a        -> go a
      VTEmpty       -> mempty
      VTCons _ a b  -> go a <> goBind b
      VTempty       -> mempty
      VTcons t u    -> go t <> go u
      VPiTel x a b  -> go a <> goBind b
      VLamTel x a t -> go a <> goBind t


-- | Attempt to solve a constancy constraint.
tryConstancy :: MId -> IO ()
tryConstancy constM = lookupMeta constM >>= \case
  Constancy cxt dom cod blockers -> do

    -- clear blockers
    forM_ (IS.toList blockers) $ \m -> do
      modifyMeta m $ \case
        Unsolved ms a -> Unsolved (IS.delete constM ms) a
        Solved t      -> Solved t
        Constancy{}   -> error "impossible"

    let dropConstancy = alterMeta constM (const Nothing)

    case occurs (cxt^.len + 1) (cxt^.len) cod of
      None    -> unify cxt dom VTEmpty >> dropConstancy
      Rigid   -> dropConstancy
      Flex ms -> do
        -- set new blockers
        forM_ (IS.toList ms) $ \m ->
          modifyMeta m $ \case
            Unsolved ms a -> Unsolved (IS.insert constM ms) a
            _             -> error "impossible"

        writeMeta constM $ Constancy cxt dom cod ms

  _ -> error "impossible"

newConstancy :: Cxt -> VTy -> (Val -> Val) -> IO ()
newConstancy cxt dom cod =
  tryConstancy =<< newMeta (Constancy cxt dom (cod (VVar (cxt^.len))) mempty)

-- Unification
--------------------------------------------------------------------------------

-- | Checks that a spine consists only of distinct bound vars.
--   Returns a partial variable renaming on success, alongside the size
--   of the spine, and the list of variables in the spine.
--   May throw `SpineError`.
checkSp :: Spine -> IO (Renaming, Lvl, [Lvl])
checkSp = (over _3 reverse <$>) . go . forceSp where
  go :: Spine -> IO (Renaming, Lvl, [Lvl])
  go = \case
    SNil        -> pure (mempty, 0, [])
    SApp sp u i -> do
      (!r, !d, !xs) <- go sp
      case force u of
        VVar x | IM.member x r -> throwIO $ NonLinearSpine x
               | otherwise     -> pure (IM.insert x d r, d + 1, x:xs)
        _      -> throwIO SpineNonVar
    SAppTel a sp u -> do
      (!r, !d, !xs) <- go sp
      case force u of
        VVar x | IM.member x r -> throwIO $ NonLinearSpine x
               | otherwise     -> pure (IM.insert x d r, d + 1, x:xs)
        _    -> throwIO SpineNonVar
    SProj1 _ -> throwIO SpineProjection
    SProj2 _ -> throwIO SpineProjection

-- | Close a type in a cxt by wrapping it in Pi types and explicit strengthenings.
closingTy :: Cxt -> Ty -> Ty
closingTy cxt = go (cxt^.types) (cxt^.names) (cxt^.len) where
  go TNil                  []     d b = b
  go (TDef tys a)          (x:ns) d b = go tys ns (d-1) (Skip b)
  go (TBound tys (VRec a)) (x:ns) d b = go tys ns (d-1) (PiTel x (quote (d-1) a) b)
  go (TBound tys a)        (x:ns) d b = go tys ns (d-1) (Pi x Expl (quote (d-1) a) b)
  go _                     _      _ _ = error "impossible"

-- | Close a term by wrapping it in `Int` number of lambdas, while taking the domain
--   types from the `VTy`, and the binder names from a list. If we run out of provided
--   binder names, we pick the names from the Pi domains.
closingTm :: (VTy, Int, [Name]) -> Tm -> Tm
closingTm = go 0 where
  getName []     x = x
  getName (x:xs) _ = x

  go d (a, 0, _)   rhs = rhs
  go d (a, len, xs) rhs = case force a of
    VPi (getName xs -> x) i a b  ->
      Lam x i (quote d a)  $ go (d + 1) (b (VVar d), len-1, drop 1 xs) rhs
    VPiTel (getName xs -> x) a b ->
      LamTel x (quote d a) $ go (d + 1) (b (VVar d), len-1, drop 1 xs) rhs
    _            -> error "impossible"

-- | Strengthens a value, returns a quoted normal result. This performs scope
--   checking, meta occurs checking and (recursive) pruning at the same time.
--   May throw `StrengtheningError`.
strengthen :: Str -> Val -> IO Tm
strengthen str = go where

  -- we only prune all-variable spines with illegal var occurrences,
  -- we don't prune illegal cyclic meta occurrences.
  prune :: MId -> Spine -> IO ()
  prune m sp = do

    let pruning :: Maybe [Bool]
        pruning = go [] sp where
          go acc SNil                    = pure acc
          go acc (SApp sp (VVar x) i)    = go (isJust (IM.lookup x (str^.ren)) : acc) sp
          go acc (SAppTel _ sp (VVar x)) = go (isJust (IM.lookup x (str^.ren)) : acc) sp
          go _   _                       = Nothing

    case pruning of
      Nothing                    -> pure ()  -- spine is not a var substitution
      Just pruning | and pruning -> pure ()  -- no pruneable vars
      Just pruning               -> do

        metaTy <- lookupMeta m >>= \case
          Unsolved _ a -> pure a
          _            -> error "impossible"

        -- note: this can cause recursive pruning of metas in types
        (prunedTy :: Ty) <- do
          let go :: [Bool] -> Str -> VTy -> IO Ty
              go [] str a = strengthen str a
              go (True:pr) str (force -> VPi x i a b) =
                Pi x i <$> strengthen str a <*> go pr (liftStr str) (b (VVar (str^.cod)))
              go (True:pr) str (force -> VPiTel x a b) =
                PiTel x <$> strengthen str a <*> go pr (liftStr str) (b (VVar (str^.cod)))
              go (False:pr) str (force -> VPi x i a b) =
                go pr (skipStr str) (b (VVar (str^.cod)))
              go (False:pr) str (force -> VPiTel x a b) =
                go pr (skipStr str) (b (VVar (str^.cod)))
              go _ _ _ = error "impossible"

          go pruning (Str 0 0 mempty Nothing) metaTy

        m' <- newMeta $ Unsolved mempty (eval VNil prunedTy)

        let argNum = length pruning
            body = go pruning metaTy (Meta m') 0 where
              go [] a acc d = acc
              go (True:pr) (force -> VPi x i a b) acc d =
                go pr (b (VVar d)) (App acc (Var (argNum - d - 1)) i) (d + 1)
              go (True:pr) (force -> VPiTel x a b) acc d =
                go pr (b (VVar d)) (AppTel (quote argNum a) acc (Var (argNum - d - 1))) (d + 1)
              go (False:pr) (force -> VPi x i a b) acc d =
                go pr (b (VVar d)) acc (d + 1)
              go (False:pr) (force -> VPiTel x a b) acc d =
                go pr (b (VVar d)) acc (d + 1)
              go _ _ _ _ = error "impossible"

        let rhs = closingTm (metaTy, argNum, []) body
        writeMeta m $ Solved (eval VNil rhs)

  go t = case force t of
    VNe (HVar x) sp  -> case IM.lookup x (str^.ren) of
                          Nothing -> throwIO $ ScopeError x
                          Just x' -> goSp (Var (str^.dom - x' - 1)) (forceSp sp)
    VNe (HMeta m) sp -> if Just m == str^.occ then
                          throwIO OccursCheck
                        else do
                          prune m sp
                          case force (VNe (HMeta m) sp) of
                            VNe (HMeta m) sp -> goSp (Meta m) sp
                            _                -> error "impossible"

    VPi x i a b      -> Pi x i <$> go a <*> goBind b
    VLam x i a t     -> Lam x i <$> go a <*> goBind t
    VU               -> pure U
    VTel             -> pure Tel
    VRec a           -> Rec <$> go a
    VTEmpty          -> pure TEmpty
    VTCons x a b     -> TCons x <$> go a <*> goBind b
    VTempty          -> pure Tempty
    VTcons t u       -> Tcons <$> go t <*> go u
    VPiTel x a b     -> PiTel x <$> go a <*> goBind b
    VLamTel x a t    -> LamTel x <$> go a <*> goBind t

  goBind t = strengthen (liftStr str) (t (VVar (str^.cod)))

  goSp h = \case
    SNil           -> pure h
    SApp sp u i    -> App <$> goSp h sp <*> go u <*> pure i
    SAppTel a sp u -> AppTel <$> go a <*> goSp h sp <*> go u
    SProj1 sp      -> Proj1 <$> goSp h sp
    SProj2 sp      -> Proj2 <$> goSp h sp

-- | May throw `UnifyError`.
solveMeta :: Cxt -> MId -> Spine -> Val -> IO ()
solveMeta cxt m sp rhs = do

  -- these normal forms are only used in error reporting
  let ~topLhs = quote (cxt^.len) (VNe (HMeta m) sp)
      ~topRhs = quote (cxt^.len) rhs

  -- check spine
  (ren, spLen, spVars) <- checkSp sp
         `catch` (throwIO . SpineError (cxt^.names) topLhs topRhs)

  --  strengthen right hand side
  rhs <- strengthen (Str spLen (cxt^.len) ren (Just m)) rhs
         `catch` (throwIO . StrengtheningError (cxt^.names) topLhs topRhs)

  (blocked, metaTy) <- lookupMeta m >>= \case
    Unsolved blocked a -> pure (blocked, a)
    _                  -> error "impossible"

  let spVarNames = map (lvlName (cxt^.names)) spVars
  let closedRhs = closingTm (metaTy, spLen, spVarNames) rhs
  writeMeta m (Solved (eval VNil closedRhs))

  -- try solving unblocked constraints
  forM_ (IS.toList blocked) tryConstancy

-- | Create a fresh meta with given type, return
--   the meta applied to all bound variables.
freshMeta :: Cxt -> VTy -> IO Tm
freshMeta cxt (quote (cxt^.len) -> a) = do
  let metaTy = closingTy cxt a
  m <- newMeta $ Unsolved mempty (eval VNil metaTy)

  let vars :: Types -> (Spine, Lvl)
      vars TNil                                 = (SNil, 0)
      vars (TDef (vars -> (sp, !d)) _)          = (sp, d + 1)
      vars (TBound (vars -> (sp, !d)) (VRec a)) = (SAppTel a sp (VVar d), d + 1)
      vars (TBound (vars -> (sp, !d)) _)        = (SApp sp (VVar d) Expl, d + 1)

  let sp = fst $ vars (cxt^.types)
  pure (quote (cxt^.len) (VNe (HMeta m) sp))

-- | Wrap the inner `UnifyError` arising from unification in an `UnifyErrorWhile`.
--   This decorates an error with one additional piece of context.
unifyWhile :: Cxt -> Val -> Val -> IO ()
unifyWhile cxt l r =
  unify cxt l r
  `catch`
  (report (cxt^.names) . UnifyErrorWhile (quote (cxt^.len) l) (quote (cxt^.len) r))

-- | May throw `UnifyError`.
unify :: Cxt -> Val -> Val -> IO ()
unify cxt l r = go l r where

  unifyError =
    throwIO $ UnifyError (cxt^.names) (quote (cxt^.len) l) (quote (cxt^.len) r)

  -- if both sides are meta-headed, we simply try to check both spines
  flexFlex m sp m' sp' = do
    try @SpineError (checkSp sp) >>= \case
      Left{}  -> solveMeta cxt m' sp' (VNe (HMeta m) sp)
      Right{} -> solveMeta cxt m sp (VNe (HMeta m') sp')

  implArity :: Cxt -> (Val -> Val) -> Int
  implArity cxt b = go 0 (cxt^.len + 1) (b (VVar (cxt^.len))) where
    go acc len a = case force a of
      VPi _ Impl _ b -> go (acc + 1) (len + 1) (b (VVar len))
      _              -> acc

  go t t' = case (force t, force t') of
    (VLam x _ a t, VLam _ _ _ t')            -> goBind x a t t'
    (VLam x i a t, t')                       -> goBind x a t (\ ~v -> vApp t' v i)
    (t, VLam x' i' a' t')                    -> goBind x' a' (\ ~v -> vApp t v i') t'
    (VPi x i a b, VPi x' i' a' b') | i == i' -> go a a' >> goBind x a b b'
    (VU, VU)                                 -> pure ()
    (VTel, VTel)                             -> pure ()
    (VRec a, VRec a')                        -> go a a'
    (VTEmpty, VTEmpty)                       -> pure ()
    (VTCons x a b, VTCons x' a' b')          -> go a a' >> goBind x a b b'
    (VTempty, VTempty)                       -> pure ()
    (VTcons t u, VTcons t' u')               -> go t t' >> go u u'
    (VPiTel x a b, VPiTel x' a' b')          -> go a a' >> goBind x (VRec a) b b'
    (VLamTel x a t, VLamTel x' a' t')        -> goBind x (VRec a) t t'
    (VLamTel x a t, t')                      -> goBind x (VRec a) t (vAppTel a t')
    (t, VLamTel x' a' t')                    -> goBind x' (VRec a') (vAppTel a' t) t'
    (VNe h sp, VNe h' sp') | h == h'         -> goSp (forceSp sp) (forceSp sp')
    (VNe (HMeta m) sp, VNe (HMeta m') sp')   -> flexFlex m sp m' sp'
    (VNe (HMeta m) sp, t')                   -> solveMeta cxt m sp t'
    (t, VNe (HMeta m') sp')                  -> solveMeta cxt m' sp' t

    (VPiTel x a b, VPi x' Impl a' b') | implArity cxt b < implArity cxt b' + 1 -> do
      let cxt' = bindSrc x' a' cxt
      m <- freshMeta cxt' VTel
      let vm = eval (cxt'^.vals) m
      go a (VTCons x' a' (liftVal cxt vm))
      let b2 ~x1 ~x2 = b (VTcons x1 x2)
      newConstancy cxt' vm (b2 (VVar (cxt^.len)))
      goBind x' a' (\ ~x1 -> VPiTel x (liftVal cxt vm x1) (b2 x1)) b'

    (VPi x' Impl a' b', VPiTel x a b) | implArity cxt b < implArity cxt b' + 1-> do
      let cxt' = bindSrc x' a' cxt
      m <- freshMeta cxt' VTel
      let vm = eval (cxt'^.vals) m
      go a (VTCons x' a' (liftVal cxt vm))
      let b2 ~x1 ~x2 = b (VTcons x1 x2)
      newConstancy cxt' vm (b2 (VVar (cxt^.len)))
      goBind x' a' b' (\ ~x1 -> VPiTel x (liftVal cxt vm x1) (b2 x1))

    (VPiTel x a b, t) -> go a VTEmpty >> go (b VTempty) t
    (t, VPiTel x a b) -> go a VTEmpty >> go t (b VTempty)
    _                 -> unifyError

  goBind x a t t' =
    let v = VVar (cxt^.len) in unify (bindSrc x a cxt) (t v) (t' v)

  goSp sp sp' = case (sp, sp') of
    (SNil, SNil)                            -> pure ()
    (SApp sp u i, SApp sp' u' i') | i == i' -> goSp sp sp' >> go u u'
    (SAppTel _ sp u, SAppTel _ sp' u')      -> goSp sp sp' >> go u u'
    _                                       -> error "impossible"


-- Elaboration
--------------------------------------------------------------------------------

-- | Insert fresh implicit applications.
insert' :: Cxt -> IO (Tm, VTy) -> IO (Tm, VTy)
insert' cxt act = do
  (t, va) <- act
  let go t va = case force va of
        VPi x Impl a b -> do
          m <- freshMeta cxt a
          let mv = eval (cxt^.vals) m
          go (App t m Impl) (b mv)
        va -> pure (t, va)
  go t va

-- | Insert fresh implicit applications to a term which is not
--   an implicit lambda (i.e. neutral).
insert :: Cxt -> IO (Tm, VTy) -> IO (Tm, VTy)
insert cxt act = act >>= \case
  (t@(Lam _ Impl _ _), va) -> pure (t, va)
  (t                 , va) -> insert' cxt (pure (t, va))

check :: Cxt -> Raw -> VTy -> IO Tm
check cxt topT ~topA = case (topT, force topA) of
  (RSrcPos p t, a) ->
    addSrcPos p (check cxt t a)

  (RLam x ann i t, VPi x' i' a b) | i == i' -> do
    ann <- case ann of
      Just ann -> do
        ann <- check cxt ann VU
        unifyWhile cxt (eval (cxt^.vals) ann) a
        pure ann
      Nothing ->
        pure $ quote (cxt^.len) a
    t <- check (bind x NOSource a cxt) t (b (VVar (cxt^.len)))
    pure $ Lam x i ann t

  (t, VPi x Impl a b) -> do
    t <- check (bind x NOInserted a cxt) t (b (VVar (cxt^.len)))
    pure $ Lam x Impl (quote (cxt^.len) a) t

  -- inserting a new curried function lambda
  (t, VNe (HMeta _) _) -> do
    x <- ("Γ"++) . show <$> readIORef nextMId
    dom <- freshMeta cxt VTel
    let vdom = eval (cxt^.vals) dom
    let cxt' = bind x NOInserted (VRec vdom) cxt
    (t, liftVal cxt -> a) <- insert cxt' $ infer cxt' t
    newConstancy cxt vdom a
    unifyWhile cxt topA (VPiTel x vdom a)
    pure $ LamTel x dom t

  (RLet x a t u, topA) -> do
    a <- check cxt a VU
    let ~va = eval (cxt^.vals) a
    t <- check cxt t va
    let ~vt = eval (cxt^.vals) t
    u <- check (define x va vt cxt) u topA
    pure $ Let x a t u

  (RHole, topA) -> do
    freshMeta cxt topA

  (t, topA) -> do
    (t, va) <- insert cxt $ infer cxt t
    unifyWhile cxt va topA
    pure t

-- | We specialcase top-level lambdas (serving as postulates) for better
--   printing: we don't print them in meta spines. We prefix the top
--   lambda-bound names with '*'.
inferTopLams :: Cxt -> Raw -> IO (Tm, VTy)
inferTopLams cxt = \case
  RLam x ann i t -> do
    a <- case ann of
      Just ann -> check cxt ann VU
      Nothing  -> freshMeta cxt VU
    let ~va = eval (cxt^.vals) a
    (t, liftVal cxt -> b) <- inferTopLams (bind ('*':x) NOSource va cxt) t
    pure (Lam x i a t, VPi x i va b)
  RSrcPos p t ->
    addSrcPos p $ inferTopLams cxt t

  t -> insert cxt $ infer cxt t

infer :: Cxt -> Raw -> IO (Tm, VTy)
infer cxt = \case
  RSrcPos p t -> addSrcPos p $ infer cxt t

  RU -> pure (U, VU)

  RVar x -> do
    let go :: [Name] -> [NameOrigin] -> Types -> Int -> IO (Tm, VTy)
        go (y:xs) (NOSource:os) (TSnoc _  a) i | x == y || ('*':x) == y = pure (Var i, a)
        go (_:xs) (_       :os) (TSnoc as _) i = go xs os as (i + 1)
        go []     []            TNil         _ = report (cxt^.names) (NameNotInScope x)
        go _ _ _ _ = error "impossible"
    go (cxt^.names) (cxt^.nameOrigin) (cxt^.types) 0

  RPi x i a b -> do
    a <- check cxt a VU
    let ~va = eval (cxt^.vals) a
    b <- check (bind x NOSource va cxt) b VU
    pure (Pi x i a b, VU)

  RApp t u i -> do
    (t, va) <- case i of Expl -> insert' cxt $ infer cxt t
                         _    -> infer cxt t
    case force va of
      va -> do
        a0 <- eval (cxt^.vals) <$> freshMeta cxt VU
        a1 <- freshMeta (bind "x" NOInserted a0 cxt) VU
        let a1' x = eval (VDef (cxt^.vals) x) a1
        unifyWhile cxt va (VPi "x" i a0 a1')
        u <- check cxt u a0
        pure (App t u i, a1' (eval (cxt^.vals) u))

  -- -- variant with better error messages and fewer generated metavariables
  -- RApp t u i -> do
  --   (t, va) <- case i of Expl -> insert' cxt $ infer cxt t
  --                        _    -> infer cxt t
  --   case force va of
  --     VPi x i' a b -> do
  --       unless (i == i') $
  --         report (cxt^.names) $ IcitMismatch i i'
  --       u <- check cxt u a
  --       pure (App t u i, b (eval (cxt^.vals) u))
  --     VNe (HMeta m) sp -> do
  --       a    <- eval (cxt^.vals) <$> freshMeta cxt VU
  --       cod  <- freshMeta (bind "x" NOInserted a cxt) VU
  --       let b ~x = eval (VDef (cxt^.vals) x) cod
  --       unifyWhile cxt (VNe (HMeta m) sp) (VPi "x" i a b)
  --       u <- check cxt u a
  --       pure (App t u i, b (eval (cxt^.vals) u))
  --     _ ->
  --       report (cxt^.names) $ ExpectedFunction (quote (cxt^.len) va)

  RLam x ann i t -> do
    a <- case ann of
      Just ann -> check cxt ann VU
      Nothing  -> freshMeta cxt VU
    let ~va = eval (cxt^.vals) a
    let cxt' = bind x NOSource va cxt
    (t, liftVal cxt -> b) <- insert cxt' $ infer cxt' t
    pure (Lam x i a t, VPi x i va b)

  RHole -> do
    a <- freshMeta cxt VU
    let ~va = eval (cxt^.vals) a
    t <- freshMeta cxt va
    pure (t, va)

  RLet x a t u -> do
    a <- check cxt a VU
    let ~va = eval (cxt^.vals) a
    t <- check cxt t va
    let ~vt = eval (cxt^.vals) t
    (u, b) <- infer (define x va vt cxt) u
    pure (Let x a t u, b)
