{-# language ConstraintKinds #-}

module Types (
  module Types,
  module Text.Megaparsec,
  ) where

import Text.Megaparsec (SourcePos(..), unPos, initialPos)
import Lens.Micro.Platform
import GHC.Stack

import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet        as IS

type Dbg = HasCallStack

-- Raw syntax
--------------------------------------------------------------------------------

-- | We wrap `SourcePos` to avoid printing it in `Show`, as that would be
--   unreadable because of clutter.
newtype SPos = SPos SourcePos deriving (Eq, Ord, Read)
instance Show SPos where show _ = ""

type Name = String
data Icit = Impl | Expl deriving (Eq)

instance Show Icit where
  show Expl = "explicit"
  show Impl = "implicit"

icit :: Icit -> a -> a -> a
icit Impl i e = i
icit Expl i e = e

-- | Surface syntax.
data Raw
  = RVar Name                        -- ^ x
  | RLam Name (Maybe Raw) Icit Raw   -- ^ λ x. t  or λ{x}. t with optional type annotation
                                     --   on x
  | RApp Raw Raw Icit                -- ^ t u  or  t {u}
  | RU                               -- ^ U
  | RPi Name Icit Raw Raw            -- ^ (x : A) → B  or  {x : A} → B
  | RLet Name Raw Raw Raw            -- ^ let x : A = t in u
  | RHole                            -- ^ _
  | RSrcPos SPos Raw                 -- ^ source position annotation, added by parsing

deriving instance Show Raw


-- Types
--------------------------------------------------------------------------------

-- | Elaboration problem identifier.
type MId = Int

-- | Blocked problems.
type Blocking  = IS.IntSet

data MetaEntry
    -- | Unsolved meta which may block Unchecked entries.
  = Unsolved Blocking ~VTy
  | Solved ~Val
    -- | In (Unchecked Γ t A res), we postpone checking t in Γ with A. After
    --   performing checking, we have to unify the result with res, which
    --   stands for the result of checking.
  | Unchecked Cxt Raw VTy (MId, Spine)
    -- | An Unchecked becomes Checked after solution, and we only need to record
    --   the elaboration result. This gets inlined into the syntax when we do zonking.
  | Checked Tm

type MCxt = IM.IntMap MetaEntry

-- | A partial mapping from levels to levels. Undefined domain represents
--   out-of-scope variables.
type Renaming = IM.IntMap Lvl

-- | Explicit strengthening. We use this for pruning and checking meta solution
--   candidates.
data Str = Str {
  _strDom :: Lvl,        -- ^ size of renaming domain
  _strCod :: Lvl,        -- ^ size of renaming codomain
  _strRen :: Renaming,   -- ^ partial renaming
  _strOcc :: Maybe MId   -- ^ meta for occurs checking
  }

-- | Lift a `Str` over a bound variable.
liftStr :: Str -> Str
liftStr (Str c d r occ) = Str (c + 1) (d + 1) (IM.insert d c r) occ

-- | Skip a bound variable.
skipStr :: Str -> Str
skipStr (Str c d r occ) = Str c (d + 1) r occ

-- | Value environment. `VSkip` skips over a bound variable.
data Vals  = VNil | VDef Vals ~Val | VSkip Vals

-- | Type environment.
data Types = TNil | TDef Types ~VTy | TBound Types ~VTy

type Ix    = Int
type Lvl   = Int
type Ty    = Tm
type VTy   = Val

-- | Extending `Types` with any type.
pattern TSnoc :: Types -> VTy -> Types
pattern TSnoc as a <- ((\case TBound as a -> Just (as, a)
                              TDef as a   -> Just (as, a)
                              TNil        -> Nothing) -> Just (as, a))

lvlName :: Cxt -> Lvl -> Name
lvlName cxt x = cxtNames cxt !! (cxtLen cxt - x - 1)

-- | We need to distinguish invented names from source names, as
--   we don't want the former to shadow the latter during name lookup
--   in elaboration.
data NameOrigin =
    NOSource        -- ^ Names which come from surface syntax.
  | NOInserted      -- ^ Names of binders inserted by elaboration.


-- | Context for elaboration and unification.
data Cxt = Cxt {
  cxtVals       :: Vals,
  cxtTypes      :: Types,
  cxtNames      :: [Name],
  cxtNameOrigin :: [NameOrigin],
  cxtLen        :: Int}

instance Show Cxt where show = show . cxtNames

data Tm
  = Var Ix                -- ^ x
  | Let Name Ty Tm Tm     -- ^ let x : A = t in u
  | Pi Name Icit Ty Ty    -- ^ (x : A) → B)  or  {x : A} → B
  | Lam Name Icit Ty Tm   -- ^ λ(x : A).t  or  λ{x : A}.t
  | App Tm Tm Icit        -- ^ t u  or  t {u}
  | U                     -- ^ U
  | Check MId Tm          -- ^ Postponed checking problem, with MId problem identifier, and
                          --   Tm a fresh meta spine represnting eventual checking result.
  | Meta MId              -- ^ α
  | Skip Tm               -- ^ explicit strengthening (convenience feature for closing types)

data Spine
  = SNil
  | SApp Spine ~Val Icit

valsLen :: Vals -> Int
valsLen = go 0 where
  go acc VNil        = acc
  go acc (VDef vs _) = go (acc + 1) vs
  go acc (VSkip vs)  = go (acc + 1) vs

data Head
  = HVar Lvl
  | HMeta MId
  deriving (Eq, Show)

data Val
  = VNe Head Spine
  | VPi Name Icit ~VTy (VTy -> VTy)
  | VLam Name Icit ~VTy (Val -> Val)
  | VU

pattern VVar :: Lvl -> Val
pattern VVar x = VNe (HVar x) SNil

pattern VMeta :: MId -> Val
pattern VMeta m = VNe (HMeta m) SNil

-- Lenses
--------------------------------------------------------------------------------

makeFields ''Cxt
makeFields ''Str
