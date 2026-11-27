import SemanticHighlighting.Classifier
import SemanticHighlighting.Syntax

namespace SemanticHighlighting
open Lean Lean.Lsp Lean.Server Lean.Server.FileWorker Lean.Server.RequestM
open Compat

/-- Recompute tokens from existing snapshots, using the host's syntax and LSP pipeline. -/
def computeTokens
  (doc : EditableDocument) (beginPos : SourcePos)
  (endPos? : Option SourcePos) (snaps : List Snapshots.Snapshot)
: RequestM SemanticTokens := do
  let mut tokens := #[]
  for snap in snaps do
    checkCancelled
    if snap.endPos <= beginPos then continue
    tokens := tokens ++ collectSyntaxTokens doc.meta.text snap.stx ++ (← collectInfoTokens snap.env snap.infoTree)
  checkCancelled
  let absolute := toAbsolute doc.meta.text beginPos endPos? tokens
  checkCancelled
  let absolute := resolveOverlaps absolute
  checkCancelled
  return encode absolute

private def handleFull
  (_ : SemanticTokensParams) (_ : LspResponse SemanticTokens)
  (state : SemanticTokensState)
: RequestM (LspResponse SemanticTokens × SemanticTokensState) := do
  checkCancelled
  let doc ← readDoc
  -- The previous handler already performed the timed wait. The completeness flag must
  -- describe exactly the prefix used here, which may have grown since that handler ran.
  let (snaps, _, isComplete) ← doc.cmdSnaps.getFinishedPrefix
  let response ← computeTokens doc 0 none snaps
  return ({ response, isComplete }, state)

private def handleRange
  (p : SemanticTokensRangeParams)
  (previous : RequestTask SemanticTokens)
: RequestM (RequestTask SemanticTokens) := do
  -- Capture the request's document before scheduling work, and propagate previous errors.
  let doc ← readDoc
  bindRequestTaskCostly previous fun _ => do
    checkCancelled
    let beginPos := doc.meta.text.lspPosToUtf8Pos p.range.start
    let endPos := doc.meta.text.lspPosToUtf8Pos p.range.end
    mapTaskCostly (doc.cmdSnaps.waitUntil (·.endPos >= endPos)) fun (snaps, _) =>
      computeTokens doc beginPos endPos snaps

initialize
  chainStatefulLspRequestHandler "textDocument/semanticTokens/full"
    SemanticTokensParams SemanticTokens SemanticTokensState handleFull (fun _ => pure ())
  chainLspRequestHandler "textDocument/semanticTokens/range"
    SemanticTokensRangeParams SemanticTokens handleRange

end SemanticHighlighting
