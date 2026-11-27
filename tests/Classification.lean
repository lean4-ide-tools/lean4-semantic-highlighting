/-! Regression cases for classification, token ranges, and Unicode. -/

def dotNotation (x : Nat) := x.succ
def dottedConstructor (x : Nat) : List Nat := .cons (x |>.succ) .nil
theorem withLocalLet (x : Nat) : True :=
  let y := x.succ
  .intro

universe u
def TypeAlias := Type
  0
def SortAlias := Sort (u + 1)
abbrev NatAlias := Nat
def InferredList (α : Type) := List α
def ExplicitList (α : Type) : Type := InferredList α
def singletonNat (x : NatAlias) : ExplicitList NatAlias := [x]

structure RecursiveStruct where
  xs : List RecursiveStruct
class RecursiveClass (α : Type) where
  xs : List (RecursiveClass α)

theorem withHypotheses (p q : Prop) (h1 : p ∧ q) (h2 : p → q)
    (h3 : ∀ x : Nat, x = x) : q ∧ 0 = 0 :=
  ⟨h2 h1.1, h3 0⟩
theorem withPolymorphicHypothesis (h : ∀ p : Prop, p → p) (f : ∀ α : Type, α → α) :
    f Nat 0 = f Nat 0 :=
  h _ rfl

inductive Data where
  | item
inductive Pred : Nat → Prop where
  | zero : Pred 0
axiom termAxiom : Nat
opaque termOpaque : Nat := 0
def field (s : RecursiveStruct) := s.xs
def utf16 (α : Type) (x : α) := let «😀» := x; «😀»
def unfinished : Nat := sorry
example : Sort (max u 1 + 1) := Sort (max u 1)

def inferredId (x : β) : β := x
def inferredList (x : γ) : List γ := [x]
def inferredBound (i : Fin m) : Fin m := i
theorem inferredProp (h : φ ∧ True) : φ := h.1

abbrev Statement := Prop
def Claim : Statement := True
def Predicate (_ : Nat) : Statement := Claim
theorem useClaim (evidence : Predicate 0) : Claim := evidence

def Carrier := Type
def Payload : Carrier := Nat
def useCarrier (δ : Carrier) (x : δ) : δ := x
def usePayload (x : Payload) : Payload := x

def iteratedType : Nat → Type
  | 0 => Nat
  | n + 1 => iteratedType n
axiom delayedValue : iteratedType 1000000
