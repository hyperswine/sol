{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Val.hs — VM values + the builtin Vector: a LINEAR, growable,
-- automatically-SoA container.
--
-- Layout is fixed by the first push:
--   * VInt              --> scalar layout, one unboxed i64 column
--   * product (record / single-variant data / tuple) --> SoA: one column
--     per field, Int fields unboxed (i64, malloc'd — JIT-ready), everything
--     else boxed
--   * anything else     --> scalar boxed column
--
-- push is std::vector push_back: amortized O(1), doubling realloc + copy
-- when full. get is O(1) and RECONSTRUCTS the product from the columns —
-- the deliberately-slower escape hatch; the recursion schemes are the fast
-- path and (when JITted) read the unboxed columns in place, zero
-- marshalling.
--
-- LINEARITY IS WHAT MAKES THIS SOUND: the Vector type is declared linear
-- in the prelude, so the checker guarantees a single owner. That is the
-- licence for in-place mutation (push/set mutate and hand the same store
-- back as the "new" vector) and for lending raw column pointers to native
-- code — nobody else can observe the buffer mid-operation.

module Val where

import Data.Array.IO (IOArray, getElems, newArray_, readArray, writeArray)
import Data.IORef
import Data.Int (Int64)
import Data.List (intercalate)
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrArray, withForeignPtr)
import Foreign.Marshal.Array (withArray)
import Foreign.Ptr (Ptr, nullPtr, castPtr)
import Foreign.Storable (peekElemOff, pokeElemOff)

boolT, listT, atomT :: Int
boolT = 1
listT = 2
atomT = 6

data Value
  = VInt !Integer
  | VNum !Double -- inexact Numeric: arises from Num.div/Num.sqrt etc.; VInt promotes into it on contact
  | VStr String
  | VData !Int !Int [Value]
  | VPap String [Value] !Int -- global or HAL symbol, collected args, remaining
  | VVec (IORef VecStore) -- the linear SoA vector
  | VMod FilePath String -- content-addressed file module: path + AST hash

instance Show Value where
  show = render

vUnit, vTrue, vFalse :: Value
vUnit = VData 0 0 []
vTrue = VData boolT 1 []
vFalse = VData boolT 0 []

vBool :: Bool -> Value
vBool b = if b then vTrue else vFalse

isUnit :: Value -> Bool
isUnit (VData 0 0 []) = True
isUnit _ = False

veq :: Value -> Value -> Bool
veq (VInt a) (VInt b) = a == b
veq (VNum a) (VNum b) = a == b
veq (VInt a) (VNum b) = fromIntegral a == b -- Numeric: 1 == 1.0
veq (VNum a) (VInt b) = a == fromIntegral b
veq (VStr a) (VStr b) = a == b
veq (VData t v fs) (VData t' v' fs') =
  t == t' && v == v' && length fs == length fs' && and (zipWith veq fs fs')
veq _ _ = False

render :: Value -> String
render (VInt i) = show i
render (VNum d) = renderNum d
render (VStr s) = s
render v@(VData t 1 [_, _]) | t == listT = "[" ++ intercalate ", " (renderList v) ++ "]"
  where
    renderList (VData _ 1 [y, r]) = render y : renderList r
    renderList _ = []
render (VData t 0 []) | t == listT = "[]"
render (VData 1 0 []) = "False"
render (VData 1 1 []) = "True"
render (VData 6 0 [VStr a]) = ":" ++ a
render (VData 0 0 []) = "()"
render (VData 4 0 [a, b]) = "(" ++ render a ++ ", " ++ render b ++ ")"
render (VData 5 0 [a, b, c]) = "(" ++ render a ++ ", " ++ render b ++ ", " ++ render c ++ ")"
render (VData t v fs) = "<" ++ show t ++ "." ++ show v ++ (if null fs then "" else " " ++ unwords (map render fs)) ++ ">"
render (VPap g _ n) = "<fn " ++ g ++ "/" ++ show n ++ ">"
render (VVec _) = "<vector>"
render (VMod p h) = "<module " ++ p ++ "#" ++ take 8 h ++ "...>"

-- ---- the SoA store ----------------------------------------------------------

data ColKind = KInt | KNum | KBox deriving (Eq)

data Col
  = CI !Int (ForeignPtr Int64) -- capacity, unboxed i64 column
  | CD !Int (ForeignPtr Double) -- capacity, unboxed f64 column (Numeric)
  | CB !Int (IOArray Int Value) -- capacity, boxed column

data VecRep
  = RUnset
  | RScalar ColKind
  | RSoA !Int [ColKind] -- element tid, per-field kinds
  deriving (Eq)

data VecStore = VecStore
  { vLen :: !Int,
    vCols :: [Col],
    vRep :: VecRep
  }

initialCap :: Int
initialCap = 8

newVec :: IO Value
newVec = VVec <$> newIORef (VecStore 0 [] RUnset)

kindOf :: Value -> ColKind
kindOf (VInt _) = KInt
kindOf (VNum _) = KNum
kindOf _ = KBox

newCol :: ColKind -> Int -> IO Col
newCol KInt cap = CI cap <$> mallocForeignPtrArray cap
newCol KNum cap = CD cap <$> mallocForeignPtrArray cap
newCol KBox cap = CB cap <$> newArray_ (0, cap - 1)

colCap :: Col -> Int
colCap (CI c _) = c
colCap (CD c _) = c
colCap (CB c _) = c

writeCol :: Col -> Int -> Value -> IO ()
writeCol (CI _ fp) i (VInt x) = withForeignPtr fp $ \p -> pokeElemOff p i (fromIntegral x)
writeCol (CI _ _) _ v = ioError (userError ("*** SOL PANIC: Vec: Int column got " ++ render v ++ " (SoA layout is fixed by first push) ***"))
writeCol (CD _ fp) i (VNum x) = withForeignPtr fp $ \p -> pokeElemOff p i x
writeCol (CD _ _) _ v = ioError (userError ("*** SOL PANIC: Vec: Numeric column got " ++ render v ++ " (SoA layout is fixed by first push) ***"))
writeCol (CB _ a) i v = writeArray a i v

readCol :: Col -> Int -> IO Value
readCol (CI _ fp) i = withForeignPtr fp $ \p -> VInt . fromIntegral <$> peekElemOff p i
readCol (CD _ fp) i = withForeignPtr fp $ \p -> VNum <$> peekElemOff p i
readCol (CB _ a) i = readArray a i

growCol :: Int -> Col -> IO Col
growCol len (CI cap fp) = do
  let cap' = cap * 2
  fp' <- mallocForeignPtrArray cap'
  withForeignPtr fp $ \src -> withForeignPtr fp' $ \dst ->
    mapM_ (\i -> peekElemOff src i >>= pokeElemOff dst i) [0 .. len - 1]
  pure (CI cap' fp')
growCol len (CD cap fp) = do
  let cap2 = cap * 2
  fp2 <- mallocForeignPtrArray cap2
  withForeignPtr fp $ \src -> withForeignPtr fp2 $ \dst ->
    mapM_ (\i -> peekElemOff src i >>= pokeElemOff dst i) [0 .. len - 1]
  pure (CD cap2 fp2)
growCol len (CB cap a) = do
  let cap' = cap * 2
  a' <- newArray_ (0, cap' - 1)
  mapM_ (\i -> readArray a i >>= writeArray a' i) [0 .. len - 1]
  pure (CB cap' a')

-- what one pushed value decomposes into, per the store's rep
fieldsFor :: VecRep -> Value -> IO [Value]
fieldsFor (RScalar _) v = pure [v]
fieldsFor (RSoA tid ks) (VData t 0 fs) | t == tid, length fs == length ks = pure fs
fieldsFor (RSoA tid _) v =
  ioError (userError ("*** SOL PANIC: Vec.push: expected product <" ++ show tid ++ ".0 ...>, got " ++ render v ++ " ***"))
fieldsFor RUnset _ = ioError (userError "*** SOL PANIC: Vec: unset layout ***")

-- decide the layout from the first pushed value
repFor :: Value -> VecRep
repFor (VData t 0 fs) | not (null fs), t /= listT, t /= atomT = RSoA t (map kindOf fs)
repFor v = RScalar (kindOf v)

pushVec :: IORef VecStore -> Value -> IO ()
pushVec ref v = do
  st <- readIORef ref
  st1 <- case vRep st of
    RUnset -> do
      let rep = repFor v
          kinds = case rep of RScalar k -> [k]; RSoA _ ks -> ks; _ -> []
      cols <- mapM (`newCol` initialCap) kinds
      pure st {vCols = cols, vRep = rep}
    _ -> pure st
  st2 <-
    if vLen st1 >= minimum (map colCap (vCols st1))
      then do cols' <- mapM (growCol (vLen st1)) (vCols st1); pure st1 {vCols = cols'}
      else pure st1
  fs <- fieldsFor (vRep st2) v
  mapM_ (\(c, f) -> writeCol c (vLen st2) f) (zip (vCols st2) fs)
  writeIORef ref st2 {vLen = vLen st2 + 1}

-- O(1) access, 0-indexed internally; RECONSTRUCTS the product from columns
getVec :: IORef VecStore -> Int -> IO Value
getVec ref i = do
  st <- readIORef ref
  if i < 0 || i >= vLen st
    then ioError (userError ("*** SOL PANIC: Vec: index " ++ show (i + 1) ++ " out of range (len " ++ show (vLen st) ++ ") ***"))
    else do
      fs <- mapM (`readCol` i) (vCols st)
      pure $ case vRep st of
        RScalar _ -> head fs
        RSoA tid _ -> VData tid 0 fs
        RUnset -> vUnit

setVec :: IORef VecStore -> Int -> Value -> IO ()
setVec ref i v = do
  st <- readIORef ref
  if i < 0 || i >= vLen st
    then ioError (userError "*** SOL PANIC: Vec.set: index out of range ***")
    else do
      fs <- fieldsFor (vRep st) v
      mapM_ (\(c, f) -> writeCol c i f) (zip (vCols st) fs)

lenVec :: IORef VecStore -> IO Int
lenVec ref = vLen <$> readIORef ref

toListVec :: IORef VecStore -> IO [Value]
toListVec ref = do
  n <- lenVec ref
  mapM (getVec ref) [0 .. n - 1]

-- build a fresh scalar-int vector from native results (JIT map output)
vecFromInts :: [Int64] -> IO Value
vecFromInts xs = do
  let n = max 1 (length xs)
  fp <- mallocForeignPtrArray n
  withForeignPtr fp $ \p -> mapM_ (\(i, x) -> pokeElemOff p i x) (zip [0 ..] xs)
  VVec <$> newIORef (VecStore (length xs) [CI n fp] (RScalar KInt))

-- gather rows by index into a fresh same-layout vector (JIT filter output)
gatherRows :: IORef VecStore -> [Int] -> IO Value
gatherRows ref idxs = do
  st <- readIORef ref
  let n = length idxs
      kinds = case vRep st of RScalar k -> [k]; RSoA _ ks -> ks; RUnset -> []
  cols' <- mapM (`newCol` max initialCap n) kinds
  mapM_
    ( \(j, i) ->
        mapM_ (\(c, c') -> readCol c i >>= writeCol c' j) (zip (vCols st) cols')
    )
    (zip [0 ..] idxs)
  VVec <$> newIORef (VecStore n cols' (vRep st))

-- the JIT lend: raw pointers to the unboxed columns (boxed slots are null;
-- the jittability guard proves they are never dereferenced). Sound only
-- because the vector is linear — no other owner can touch the store while
-- native code holds these.
withColPtrs :: VecStore -> (Ptr (Ptr Int64) -> IO a) -> IO a
withColPtrs st k = go (vCols st) []
  where
    go [] acc = withArray (reverse acc) k
    go (CI _ fp : r) acc = withForeignPtr fp $ \p -> go r (p : acc)
    go (CD _ fp : r) acc = withForeignPtr fp $ \p -> go r (castPtr p : acc)
    go (CB _ _ : r) acc = go r (nullPtr : acc)

-- which columns are unboxed ints, and is the layout scalar?
layoutInfo :: VecStore -> Maybe (Bool, [ColKind], String)
layoutInfo st = case vRep st of
  RScalar k -> Just (True, [k], "s:" ++ [kChar k])
  RSoA tid ks -> Just (False, ks, "r" ++ show tid ++ ":" ++ map kChar ks)
  RUnset -> Nothing
  where
    kChar KInt = 'i'
    kChar KNum = 'd'
    kChar KBox = 'b'

-- inexact Numeric rendering: integral values print bare ("2" not "2.0") so
-- a computation that lands back on an integer renders like one; everything
-- else prints the shortest Double form
renderNum :: Double -> String
renderNum d
  | isNaN d = "nan"
  | isInfinite d = if d > 0 then "inf" else "-inf"
  | d == fromIntegral r = show r
  | otherwise = show d
  where
    r = round d :: Integer

-- fresh scalar KNum vector from JITted map output
vecFromNums :: [Double] -> IO Value
vecFromNums xs = do
  let n = max 1 (length xs)
  fp <- mallocForeignPtrArray n
  withForeignPtr fp $ \p -> mapM_ (\(i, x) -> pokeElemOff p i x) (zip [0 ..] xs)
  VVec <$> newIORef (VecStore (length xs) [CD n fp] (RScalar KNum))
