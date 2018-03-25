module Type where
import Data.List
import Data.Maybe(fromJust)
import Head


--------------------------
instance Functor TI where
   fmap f (TI m) = TI (\e -> let (a, e') = m e in (f a, e'))

instance Applicative TI where
    pure a = TI (\e -> (a, e))
    TI fs <*> TI vs = TI (\e -> let (f, e') = fs e; (a, e'') = vs e' in (f a, e''))

instance Monad TI where
    return x = TI (\e -> (x, e))
    TI m >>= f  = TI (\e -> let (a, e') = m e; TI fa = f a in fa e')

freshVar :: TI SimpleType
freshVar = TI (\e -> let v = "t"++show e in (TVar v, e+1))

runTI (TI m) = let (t, _) = m 0 in t

----------------------------
(/+/)      :: [Assump] -> [Assump] -> [Assump]
a1 /+/ a2    = nubBy assumpEq (a2 ++ a1)

assumpEq (x:>:_) (u:>:_) = (x == u)

t --> t' = TArr t t'

infixr 4 @@
(@@)       :: Subst -> Subst -> Subst
s1 @@ s2    = [ (u, apply s1 t) | (u,t) <- s2 ] ++ s1

infixr 5 ~~
(~~) :: SimpleType -> SimpleType -> Constraint
t1 ~~ t2 = Simp (TEq t1 t2)

----------------------------
class Subs t where
  apply :: Subst -> t -> t
  tv    :: t -> [Id]

instance Subs SimpleType where
  apply s (TVar u)  =
                    case lookup u s of
                       Just t  -> t
                       Nothing -> TVar u
  apply s (TCon u)  =
                    case lookup u s of
                       Just t  -> t
                       Nothing -> TCon u
  apply _ (TLit u)  = TLit u

  apply s (TArr l r) =  TArr (apply s l) (apply s r)
  apply s (TApp c v) =  TApp (apply s c) (apply s v)
  apply _ (TGen n) = TGen n


  tv (TVar u)  = [u]
  tv (TArr l r) = tv l `union` tv r
  tv (TApp c v) = tv c `union` tv v
  tv (TCon _) = []
  tv (TLit _) = []
  tv (TGen _) = []


instance Subs a => Subs [a] where
  apply s     = map (apply s)
  tv          = nub . concat . map tv

instance Subs Assump where
  apply s (i:>:t) = i:>:apply s t
  tv (_:>:t) = tv t

instance Subs Type where
  apply s (Forall qt) = Forall (apply s qt)
  tv (Forall qt)      = tv qt

instance Subs SConstraint where
  apply s (TEq a b) = TEq (apply s a) (apply s b)
  apply s (SConj (c:cs)) = SConj (apply s c:apply s cs)
  apply s (Unt as bs c) = (Unt as bs (apply s c))
  apply s E = E

  --tv (TEq a b)      = tv [a,b]

------------------------------------
varBind :: Id -> SimpleType -> Maybe Subst
varBind u t | t == TVar u   = Just []
            | t == TCon u   = Just []
            | u `elem` tv t = Nothing
            | otherwise     = Just [(u, t)]

mgu (TArr l r,  TArr l' r') = do s1 <- mgu (l,l')
                                 s2 <- mgu ((apply s1 r),(apply s1 r'))
                                 return (s2 @@ s1)
mgu (TApp c v, TApp c' v')  = do s1 <- mgu (c,c')
                                 s2 <- mgu ((apply s1 v) ,  (apply s1 v'))
                                 return (s2 @@ s1)
mgu (t,        TVar u   )   =  varBind u t
mgu (TVar u,   t        )   =  varBind u t
mgu (t,        TCon u   )   =  varBind u t
mgu (TCon u,   t        )   =  varBind u t
mgu (TLit u,   TLit t   )   =  if (u==t || (mLits u t) || (mLits t u)) then Just[] else Nothing
mgu (u,        t        )   =  if u==t then Just [] else Nothing

mLits (TBool _) (TBool _) = True
mLits (TInt _) (TInt _) = True
mLits Bool (TBool _) = True
mLits Int (TInt _) = True
mLits _ _ = False

unify t t' =  case mgu (t,t') of
    Nothing -> error ("unification: trying to unify\n" ++ show t ++ "\nand\n" ++ show t')
    Just s  -> s

{-unify' us t t' = if check us u1 then fromJust u1 else if check us u2 then fromJust u2 else error ("unification: trying to unify\n" ++ show t ++ "\nand\n" ++ show t' ++ "\nuntouchables: " ++ show us) where
    u1 = mgu (t,t')
    u2 = mgu (t',t)-}

check _ (Nothing) = False
check us (Just []) = True
check us (Just ((a,_):ss)) = if a `elem` us then False else check us (Just ss)


appParametros i [] = i
appParametros (TArr _ i) (_:ts) = appParametros i ts

quantify vs qt = Forall (apply s qt) where
    vs' = [v | v <- tv qt, v `elem` vs]
    s = zip vs' (map TGen [0..])

quantifyAll t = quantify (tv t) t

quantifyAssump (i,t) = i:>:quantifyAll t

countTypes (TArr l r) = max (countTypes l) (countTypes r)
countTypes (TApp l r) = max (countTypes l) (countTypes r)
countTypes (TGen n) = n
countTypes _ = 0

freshInstance :: Type -> TI SimpleType
freshInstance (Forall t) = do fs <- mapM (\_ -> freshVar) [0..(countTypes t)]
                              return (inst fs t)

freshSubst (Forall t) = do fs <- mapM (\_ -> freshVar) [0..(countTypes t)]
                           return (fs,t)

freshInstC t c = do (fs,t') <- freshSubst t
                    return (inst fs t', instC fs c)

inst fs (TArr l r) = TArr (inst fs l) (inst fs r)
inst fs (TApp l r) = TApp (inst fs l) (inst fs r)
inst fs (TGen n) = fs !! n
inst _ t = t

instC :: [SimpleType] -> SConstraint -> SConstraint
instC _ (E) = E
instC fs (TEq t t') = (TEq (inst fs t) (inst fs t'))
instC fs (Unt ts is cs) = (Unt (map (inst fs) ts) is (instC fs cs))
instC fs (SConj cs) = (SConj (map (instC fs) cs))

instF fs (Simp c) = (Simp (instC fs c))
instF fs (Impl ts is cs f) = (Impl (map (inst fs) ts) is (instC fs cs) (instF fs f))
instF fs (Conj cs) = (Conj (map (instF fs) cs))

simple (Simp c) = c
simple (Conj (c:cs)) = SConj ([simple c] ++ [simple (Conj cs)])
simple (Impl as bs E f) = Unt as bs (simple f)
simple _ = E

{-unifyConstraints :: [SConstraint] -> [Id] -> Subst
unifyConstraints [] _ = []
unifyConstraints ((TEq t u):cs) un = unifyConstraints cs un @@ unify' un t u
unifyConstraints (Unt us (TEq t u):cs) un = unifyConstraints cs (un ++ us) @@ unify' (un ++ us) t u
unifyConstraints (Unt us c:cs) un = unifyConstraints [c] (un ++ us) @@ unifyConstraints cs (un ++ us)
unifyConstraints ((SConj s):cs) un = unifyConstraints cs un @@ unifyConstraints s un -}

sSolve :: SConstraint -> Subst
sSolve (TEq t u) = unify t u
sSolve (Unt as bs c) = let s = sSolve c in
                          if (intersect (tv (apply s as)) bs /= []) || (intersect bs (dom s) /= [])
                            then error ("S-SImpl error with bs=" ++ show bs)
                            else s
sSolve (SConj []) = []
sSolve (SConj (c:cs)) = let s = sSolve c in (sSolve (SConj (map (apply s) cs))) @@ s
sSolve E = []

dom = map fst

conParameters (TArr a as) = (Forall a):conParameters as
conParameters _ = []

ret (TArr a as) = ret as
ret (a) = a

makeTvar i = TVar i

context = [("Just", TArr (TVar "a") (TApp (TCon "Maybe") (TVar "a"))),
           ("Nothing", TApp (TCon "Maybe") (TVar "a")),
           ("Left", TArr (TVar "a") (TApp (TApp (TCon "Either") (TVar "a")) (TVar "b"))),
           ("Right", TArr (TVar "a") (TApp (TApp (TCon "Either") (TVar "a")) (TVar "b"))),
           ("+", TArr (TLit Int) (TArr (TLit Int) (TLit Int))),
           ("-", TArr (TLit Int) (TArr (TLit Int) (TLit Int))),
           ("*", TArr (TLit Int) (TArr (TLit Int) (TLit Int))),
           ("/", TArr (TLit Int) (TArr (TLit Int) (TLit Int))),
           ("==", TArr (TLit Int) (TArr (TLit Int) (TLit Bool))),
           (">=", TArr (TLit Int) (TArr (TLit Int) (TLit Bool))),
           ("<=", TArr (TLit Int) (TArr (TLit Int) (TLit Bool))),
           (">", TArr (TLit Int) (TArr (TLit Int) (TLit Bool))),
           ("<", TArr (TLit Int) (TArr (TLit Int) (TLit Bool)))]

quantifiedContext ds = map quantifyAssump (context ++ ds)

typeFromAssump (i:>:t) = t
