{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Bytecode.hs — Core --> Sol VM bytecode.
--
-- The Sol VM is a register machine, per the design discussion:
--   * scalar band     : LOADI/MOVE/ADD/.../CMP/JMP/JZ/CALL/RET
--   * HAL band        : HCALL op rd [args] — the single trap into Haskell;
--                       every unknown global becomes an HCALL, exactly like
--                       every unknown name in a .fpr file becomes fpr_g_*
--   * no ALLOC/FREE   : data construction is MK (compile-time known shape)
--   * no closure op   : lambda lifting already removed closures; APPLY is
--                       only PAP saturation (the VM twin of fpr_apply)
--
-- Frame sizing is computed at compile time (fnSlots), the slotsNeeded
-- analog from Codegen.hs: CALL just tells the VM how big a frame to make.
--
-- Fuel contract (same as the C runtime's): the VM decrements fuel at EVERY
-- function entry; structured control flow means recursion is the only loop,
-- so function entry is a guaranteed safepoint.

module Bytecode where

import Control.Monad (foldM)
import Control.Monad.State.Strict
import Data.List (foldl')
import qualified Data.Map.Strict as M
import Lang (Core (..), Name, Prog)

type Reg = Int

type Label = Int

data Instr
  = LoadI Reg Integer
  | LoadS Reg String
  | Move Reg Reg
  | -- arithmetic / comparison band (saturated prim ops become real opcodes)
    Arith2 ArithOp Reg Reg Reg
  | -- control
    Jmp Label
  | Jz Reg Label -- jump if reg holds False
  | LabelI Label -- pseudo-instr, removed by assemble
  | Call Reg Name [Reg] -- static saturated call: fuel check at entry
  | Apply Reg Reg Reg -- rd <- apply rf ra   (generic PAP apply)
  | MkPap Reg Name -- global-as-value (arity known statically)
  | Ret Reg
  | -- data band
    Mk Reg Int Int [Reg] -- rd <- <tid.var fields>
  | TagEq Reg Int Int Reg -- rd <- Bool(tag rs == tid.var)
  | Proj Reg Int Reg -- rd <- field i of rs
  | ErrI String
  | -- HAL band: the one trap into Haskell (IO, STM file ops, prims)
    HCall Reg Name [Reg]
  deriving (Show)

data ArithOp = OAdd | OSub | OMul | ODiv | OLt | OLe | OGt | OGe | OEq | ONe
  deriving (Show, Eq)

arithOps :: M.Map Name ArithOp
arithOps =
  M.fromList
    [ ("+", OAdd), ("-", OSub), ("*", OMul), ("/", ODiv),
      ("<", OLt), ("<=", OLe), (">", OGt), (">=", OGe),
      ("==", OEq), ("!=", ONe)
    ]

data Fn = Fn
  { fnArity :: !Int,
    fnSlots :: !Int, -- frame size, computed at compile time
    fnCode :: [Instr] -- assembled: labels resolved to indices
  }

type BProg = M.Map Name Fn

-- what the compiler needs to know about call targets to pick CALL vs
-- HCALL vs APPLY: arity of globals (from the program) and of HAL symbols
data CallInfo = CallInfo
  { ciProg :: M.Map Name Int, -- global name -> arity
    ciHal :: M.Map Name Int -- HAL symbol -> arity
  }

data CEnv = CEnv
  { cNext :: !Int, -- next free frame slot
    cHigh :: !Int, -- high-water mark == slotsNeeded
    cEnv :: M.Map Name Reg,
    cLbl :: !Int,
    cOut :: [Instr] -- reversed
  }

type C = State CEnv

emit :: Instr -> C ()
emit i = modify (\s -> s {cOut = i : cOut s})

freshReg :: C Reg
freshReg = do
  s <- get
  let r = cNext s
  put s {cNext = r + 1, cHigh = max (cHigh s) (r + 1)}
  pure r

freshLbl :: C Label
freshLbl = do
  s <- get
  put s {cLbl = cLbl s + 1}
  pure (cLbl s)

withVar :: Name -> Reg -> C a -> C a
withVar x r m = do
  old <- gets cEnv
  modify (\s -> s {cEnv = M.insert x r old})
  a <- m
  modify (\s -> s {cEnv = old})
  pure a

-- flatten an application spine
spine :: Core -> (Core, [Core])
spine = go []
  where
    go acc (CApp f a) = go (a : acc) f
    go acc f = (f, acc)

compileProg :: M.Map Name Int -> Prog -> BProg
compileProg halArity prog = M.mapWithKey one prog
  where
    ci = CallInfo (M.map (length . fst) prog) halArity
    one _ (ps, body) =
      let env0 = M.fromList (zip ps [0 ..])
          st0 = CEnv (length ps) (length ps) env0 0 []
          (r, st) = runState (cExpr ci body) st0
          code = reverse (Ret r : cOut st)
       in Fn (length ps) (cHigh st) (assemble code)

cExpr :: CallInfo -> Core -> C Reg
cExpr ci = go
  where
    go :: Core -> C Reg
    go = \case
      CInt i -> do r <- freshReg; emit (LoadI r i); pure r
      CStr s -> do r <- freshReg; emit (LoadS r s); pure r
      CErr m -> do r <- freshReg; emit (ErrI m); pure r
      CVar x -> do
        env <- gets cEnv
        case M.lookup x env of
          Just r -> pure r
          Nothing -> globalValue x
      e@CApp {} -> app (spine e)
      CLam {} -> error "internal: CLam survived lambda lifting"
      CLet x a b -> do
        ra <- go a
        withVar x ra (go b)
      CIf c t e -> do
        rd <- freshReg
        lElse <- freshLbl
        lEnd <- freshLbl
        rc <- go c
        emit (Jz rc lElse)
        rt <- go t
        emit (Move rd rt)
        emit (Jmp lEnd)
        emit (LabelI lElse)
        re <- go e
        emit (Move rd re)
        emit (LabelI lEnd)
        pure rd
      CMk t v fs -> do
        rs <- mapM go fs
        rd <- freshReg
        emit (Mk rd t v rs)
        pure rd
      CTagEq t v e -> do
        rs <- go e
        rd <- freshReg
        emit (TagEq rd t v rs)
        pure rd
      CProj i e -> do
        rs <- go e
        rd <- freshReg
        emit (Proj rd i rs)
        pure rd

    -- a global referenced as a VALUE (not saturated call): make a PAP.
    -- zero-arity program globals (CAFs) are just called.
    globalValue :: Name -> C Reg
    globalValue g = case M.lookup g (ciProg ci) of
      Just 0 -> do r <- freshReg; emit (Call r g []); pure r
      Just _ -> do r <- freshReg; emit (MkPap r g); pure r
      Nothing -> do r <- freshReg; emit (MkPap r g); pure r -- prim/HAL as value

    app :: (Core, [Core]) -> C Reg
    app (h, args) = do
      env <- gets cEnv
      let isLocal v = M.member v env
      case h of
        CVar g
          -- saturated arithmetic/compare: real opcodes, the RISC band
          | Just op <- M.lookup g arithOps,
            [a, b] <- args,
            not (isLocal g) -> do
              ra <- go a
              rb <- go b
              rd <- freshReg
              emit (Arith2 op rd ra rb)
              pure rd
          | not (isLocal g), Just ar <- M.lookup g (ciProg ci), length args >= ar ->
              saturatedThenApply (\rd rs -> Call rd g rs) ar args
          | not (isLocal g), Just ar <- M.lookup g (ciHal ci), length args >= ar ->
              saturatedThenApply (\rd rs -> HCall rd g rs) ar args
        _ -> do
          -- under-applied global, local var, or computed head: generic APPLY
          rf <- go h
          foldM applyOne rf args
      where
        saturatedThenApply mk ar as = do
          rs <- mapM go (take ar as)
          rd <- freshReg
          emit (mk rd rs)
          foldM applyOne rd (drop ar as)
        applyOne rf a = do
          ra <- go a
          rd <- freshReg
          emit (Apply rd rf ra)
          pure rd

-- resolve labels to instruction indices, drop pseudo-instrs
assemble :: [Instr] -> [Instr]
assemble code = map patch (filter notLabel code)
  where
    notLabel LabelI {} = False
    notLabel _ = True
    table = M.fromList (go 0 code)
    go _ [] = []
    go n (LabelI l : rest) = (l, n) : go n rest
    go n (_ : rest) = go (n + 1) rest
    at l = M.findWithDefault (error "assemble: missing label") l table
    patch (Jmp l) = Jmp (at l)
    patch (Jz r l) = Jz r (at l)
    patch i = i

-- pretty disassembly for --asm
disasm :: Name -> Fn -> String
disasm n (Fn ar slots code) =
  unlines $
    (n ++ " (arity " ++ show ar ++ ", frame " ++ show slots ++ " slots):")
      : [pad i ++ "  " ++ show ins | (i, ins) <- zip [0 :: Int ..] code]
  where
    pad i = let s = show i in replicate (4 - length s) ' ' ++ s
