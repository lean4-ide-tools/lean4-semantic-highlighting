import SemanticHighlighting.Compat

namespace SemanticHighlighting
open Lean Lean.Lsp Lean.Server.FileWorker
open Compat

private def typeForSortResult?
  (type : Expr) (localParam := false)
: MetaM (Option SemanticTokenType) := do
  let some u ← Meta.typeFormerTypeLevel type | return none
  if (← instantiateLevelMVars u).isAlwaysZero then
    return some .enum
  if localParam then
    if (← Meta.whnfD type).isSort then
      return some .typeParameter
  return some .type

private def classifyLocal
  (isBinder : Bool) (localDecl : LocalDecl)
: MetaM (Option SemanticTokenType) := do
  let localType ← instantiateMVars localDecl.type
  if let some tokenType ← typeForSortResult? localType (localParam := !localDecl.isAuxDecl) then
    return some tokenType
  if localDecl.isAuxDecl then
    return some .function
  if localDecl.isImplementationDetail then
    return none
  if isBinder then
    unless ← Meta.isProp localType do return some .parameter
  return some .variable

private def classifyConstant (info : ConstantInfo) (us : List Level) : MetaM SemanticTokenType := do
  let env ← getEnv
  if env.isProjectionFn info.name then
    return .property
  match info with
  | .ctorInfo _ => return .enumMember
  | .inductInfo _ =>
    if isClass env info.name then
      return .interface
    if isStructure env info.name then
      return .struct
    return (← typeForSortResult? (info.instantiateTypeLevelParams us)).getD .type
  | .thmInfo _ | .recInfo _ => return .function
  | _ => return (← typeForSortResult? (info.instantiateTypeLevelParams us)).getD .function

private def findConstInfoWithEnv?
  (ctx : Elab.ContextInfo) (finalEnv : Environment) (declName : Name)
: Option (Environment × ConstantInfo) :=
  -- A declaration can exist before its structure/class metadata has been registered.
  -- Prefer the completed command environment even when the earlier context has its type.
  match finalEnv.find? declName with
  | some info => some (finalEnv, info)
  | none => (ctx.env.find? declName).map (ctx.env, ·)

private def getSemanticTokenSyntax (stx : Syntax) : Syntax :=
  if stx.isOfKind Parser.Term.identProjKind then
    stx[0]
  else if stx.isOfKind ``Parser.Term.dotIdent then
    stx[1]
  else if stx.isOfKind ``Parser.Term.explicitUniv && stx[0].isOfKind ``Parser.Term.dotIdent then
    stx[0][1]
  else match stx with
  | `(Parser.Command.declId|$id$[.{$_ls,*}]?) => id.raw
  | _ => stx

private def getAppFnSyntax? (stx : Syntax) : Option Syntax :=
  if stx.isOfKind ``Parser.Term.app then some stx[0] else none

private def collectTermInfoBasedSemanticToken
  (finalEnv : Environment)
  (ctx : Elab.ContextInfo) (ti : Elab.TermInfo)
: IO (Option Token) := do
  let stx := getSemanticTokenSyntax ti.stx
  if ti.expr.isSort then
    unless stx.isOfKind ``Parser.Term.type || stx.isOfKind ``Parser.Term.sort || stx.isOfKind ``Parser.Term.prop do
      return none
    let stx := stx[0]
    let .original .. := stx.getHeadInfo
      | return none
    return tokenOfSyntax? stx .class
  match ti.expr.getAppFn with
  | Expr.fvar fvarId .. =>
    let some localDecl := ti.lctx.find? fvarId
      | return none
    let some stx :=
      if let `($_:ident) := stx then
        some stx
      else if localDecl.isAuxDecl then
        getAppFnSyntax? stx
      else
        none
      | return none
    let .original .. := stx.getHeadInfo
      | return none
    let `($_:ident) := stx
      | return none
    if localDecl.isAuxDecl then
      if let some declName := ti.lctx.auxDeclToFullName.get? fvarId then
        if let some info := finalEnv.find? declName then
          return ← classify stx finalEnv (some <$> classifyConstant info [])
    classify stx ctx.env (classifyLocal ti.isBinder localDecl)
  | Expr.const declName us =>
    let `($_:ident) := stx
      | return none
    let .original .. := stx.getHeadInfo
      | return none
    match findConstInfoWithEnv? ctx finalEnv declName with
    | some (env, info) => classify stx env (some <$> classifyConstant info us)
    | none => return none
  | _ => return none
where
  classify (stx : Syntax) (env : Environment) (action : MetaM (Option SemanticTokenType)) := do
    -- Unfold type aliases without evaluating recursive definitions in a type annotation.
    let ctx := { ctx with env, options := Meta.smartUnfolding.set ctx.options false }
    let kind? ← ti.runMetaM ctx <| tryCatchRuntimeEx
      (Meta.withConfig (fun cfg => { cfg with iota := false }) action) (fun _ => pure none)
    return kind?.bind (tokenOfSyntax? stx ·)

/-- Collects all semantic tokens from the given `Elab.InfoTree`. -/
def collectInfoTokens (snapshotEnv : Environment) (i : Elab.InfoTree) : IO (Array Token) :=
  List.toArray <$> i.deepestNodesM fun ctx info _ => do
    let .ofTermInfo ti := info | return none
    collectTermInfoBasedSemanticToken (completedEnvironment ctx snapshotEnv) ctx ti

end SemanticHighlighting
