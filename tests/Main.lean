import Lean.Data.Lsp
import Lean.Data.Lsp.Ipc
import SemanticHighlighting.Compat

open Lean Lean.Lsp Lean.JsonRpc

abbrev RpcMessage := Lean.JsonRpc.Message

namespace Tests

open SemanticHighlighting.Compat

#if_decl String.ofList then
  def stringFromChars := String.ofList
else
  def stringFromChars := String.mk

#if_decl String.trimAscii then
  def trimString (s : String) : String := s.trimAscii.toString
else
  def trimString (s : String) : String := s.trim

#if_decl Lean.Server.FileWorker.docKinds then
  def hasVersoTokens := true
else
  def hasVersoTokens := false

#if_decl Lean.Parser.Term.isIdentOrDotIdentOrProj then
  def hasDottedUniverses := true
else
  def hasDottedUniverses := false

def ensure (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

def parse [FromJson α] (json : Json) : IO α :=
  IO.ofExcept (fromJson? json)

structure Client where
  nextId : Nat := 0
  replies : Array RpcMessage := #[]
  events : Array RpcMessage := #[]
  legend : SemanticTokensLegend := ⟨#[], #[]⟩

abbrev TestM := StateT Client Ipc.IpcM

def send [ToJson α] (method : String) (params : α) : TestM Unit :=
  Ipc.writeNotification ⟨method, params⟩

def startRequest [ToJson α] (method : String) (params : α) : TestM RequestID := do
  let id := (← get).nextId + 1
  modify fun s => { s with nextId := id }
  Ipc.writeRequest ⟨id, method, params⟩
  return id

def pump : TestM Unit := do
  let msg ← Ipc.readMessage
  match msg with
  | .request id _ _ =>
    (← Ipc.stdin).writeLspResponse ⟨id, Json.null⟩
    modify fun s => { s with events := s.events.push msg }
  | .notification .. => modify fun s => { s with events := s.events.push msg }
  | _ => modify fun s => { s with replies := s.replies.push msg }

def messageId? : RpcMessage → Option RequestID
  | .response id _ | .responseError id .. => some id
  | _ => none

partial def response (id : RequestID) : TestM RpcMessage := do
  if let some msg := (← get).replies.find? (messageId? · == some id) then
    modify fun s => { s with replies := s.replies.filter (messageId? · != some id) }
    return msg
  pump
  response id

def request [ToJson α] (method : String) (params : α) : TestM Json := do
  let msg ← response (← startRequest method params)
  match msg with
  | .response _ result => return result
  | _ => throw <| IO.userError s!"{method}: {(toJson msg).compress}"

partial def waitEvent (predicate : RpcMessage → Bool) (after : Nat := 0) : TestM Unit := do
  if ((← get).events.extract after).any predicate then return
  pump
  waitEvent predicate after

def initializeClient : TestM Unit := do
  let params := Json.mkObj [("capabilities", Json.mkObj [
    ("workspace", Json.mkObj [("semanticTokens", Json.mkObj [("refreshSupport", toJson true)])])])]
  let result ← request "initialize" params
  let capabilities ← IO.ofExcept <| result.getObjVal? "capabilities"
  let options ← IO.ofExcept <| capabilities.getObjValAs? SemanticTokensOptions "semanticTokensProvider"
  modify fun s => { s with legend := options.legend }
  send "initialized" InitializedParams.mk

def openDoc (root : System.FilePath) (name text : String) : TestM DocumentUri := do
  let uri := System.Uri.pathToUri (root / name)
  send "textDocument/didOpen" ({ textDocument := {
    uri, languageId := "lean4", version := 1, text } } : DidOpenTextDocumentParams)
  return uri

def sync (uri : DocumentUri) (version : Nat := 1) : TestM Unit := do
  discard <| request "textDocument/waitForDiagnostics" (WaitForDiagnosticsParams.mk uri version)
  for event in (← get).events do
    if let .notification "textDocument/publishDiagnostics" (some params) := event then
      let diags : PublishDiagnosticsParams ← parse (toJson params)
      if diags.uri == uri && diags.version? == some version then
        for diag in diags.diagnostics do
          ensure (diag.severity? != some .error) s!"Unexpected diagnostic: {diag.message}"

structure Token where
  line : Nat
  column : Nat
  length : Nat
  kind : String
  modifiers : Nat
  spelling : String
  deriving BEq, Repr

def decode (result : SemanticTokens) (legend : SemanticTokensLegend) (text : String)
    (allowEmpty := false) :
    IO (Array Token) := do
  ensure (result.data.size % 5 == 0) "Invalid delta encoding"
  let lines := (text.splitOn "\n").toArray
  let mut tokens := #[]
  let mut line := 0
  let mut column := 0
  let mut previousEnd : Lsp.Position := ⟨0, 0⟩
  for i in [:result.data.size / 5] do
    let offset := i * 5
    let deltaLine := result.data[offset]!
    line := line + deltaLine
    column := (if deltaLine == 0 then column else 0) + result.data[offset + 1]!
    let length := result.data[offset + 2]!
    let kind := result.data[offset + 3]!
    ensure (line < lines.size && (length > 0 || allowEmpty) && kind < legend.tokenTypes.size)
      s!"Invalid token: {line}:{column}+{length}, kind {kind}"
    let source := lines[line]!
    ensure (column + length <= source.utf16Length) s!"Token past line end: {line}:{column}+{length}"
    ensure (previousEnd <= (⟨line, column⟩ : Lsp.Position)) "Overlapping tokens"
    previousEnd := ⟨line, column + length⟩
    let start := source.utf16PosToCodepointPos column
    let stop := source.utf16PosToCodepointPos (column + length)
    let spelling := stringFromChars <| source.toList.drop start |>.take (stop - start)
    ensure (spelling.utf16Length == length) "Token splits a UTF-16 surrogate pair"
    tokens := tokens.push ⟨line, column, length, legend.tokenTypes[kind]!,
      result.data[offset + 4]!, spelling⟩
  return tokens

def fullMethod := "textDocument/semanticTokens/full"
def rangeMethod := "textDocument/semanticTokens/range"

def tokens (uri : DocumentUri) (text : String) (range? : Option Range := none)
    (allowEmpty := false) : TestM (Array Token) := do
  let result ← match range? with
    | none => request fullMethod ({ textDocument := ⟨uri⟩ } : SemanticTokensParams)
    | some range => request rangeMethod ({ textDocument := ⟨uri⟩, range } : SemanticTokensRangeParams)
  decode (← parse result) (← get).legend text allowEmpty

def expect (tokens : Array Token) (spelling kind : String) (count? : Option Nat := none) : IO Unit := do
  let found := tokens.filter (·.spelling == spelling)
  ensure (!found.isEmpty && found.all (·.kind == kind) && count?.all (· == found.size))
    s!"Expected {spelling} as {kind} ({count?}): {repr found}"

def classification (root : System.FilePath) : TestM Unit := do
  let text ← IO.FS.readFile (root / "tests/Classification.lean")
  let uri ← openDoc root "tests/Classification.lean" text
  sync uri
  let ts ← tokens uri text
  for (spelling, kind) in #[
      ("Type", "class"), ("Sort", "class"), ("Prop", "class"), ("α", "typeParameter"),
      ("Nat", "type"), ("List", "type"), ("NatAlias", "type"), ("InferredList", "type"),
      ("ExplicitList", "type"), ("RecursiveStruct", "struct"), ("RecursiveClass", "interface"),
      ("Data", "type"), ("Pred", "enum"), ("p", "enum"), ("q", "enum"),
      ("h1", "variable"), ("h2", "variable"), ("h3", "variable"), ("h", "variable"),
      ("succ", "enumMember"), ("cons", "enumMember"), ("nil", "enumMember"),
      ("item", "enumMember"), ("termAxiom", "function"), ("termOpaque", "function"),
      ("dotNotation", "function"), ("xs", "property")] do
    expect ts spelling kind
  expect ts "RecursiveClass" "interface" (some 2)
  expect ts "InferredList" "type" (some 2)
  expect ts "β" "typeParameter" (some 2)
  expect ts "γ" "typeParameter" (some 2)
  expect ts "m" "variable" (some 2)
  expect ts "φ" "enum" (some 2)
  expect ts "δ" "typeParameter" (some 3)
  expect ts "Claim" "enum" (some 3)
  expect ts "Predicate" "enum" (some 2)
  expect ts "evidence" "variable" (some 2)
  expect ts "Payload" "type" (some 3)
  expect ts "delayedValue" "function" (some 1)
  ensure ((ts.filter (·.spelling == "«😀»")).map (·.kind) == #["parameter", "variable"])
    "Unicode local binder/use mismatch"
  ensure (ts.any (fun t => t.spelling == "x" && t.kind == "parameter")) "Missing binder token"
  ensure (ts.any (fun t => t.spelling == "x" && t.kind == "variable")) "Missing local use token"
  for (start, stop) in #[(0, (text.splitOn "\n").length - 1), (2, 4), (17, 21), (23, 24), (2, 2)] do
    let ranged ← tokens uri text (some ⟨⟨start, 0⟩, ⟨stop, 0⟩⟩)
    ensure (ranged == ts.filter (fun t => start <= t.line && t.line < stop)) "Full/range mismatch"
  IO.println s!"PASS classification, UTF-16, and full/range consistency ({ts.size} tokens)"

def dottedUniverses (root : System.FilePath) : TestM Unit := do
  if !hasDottedUniverses then return
  let text := "def universeCons (n : Nat) : List Nat := .cons.{0} n .nil\n"
  let uri ← openDoc root "tests/DottedUniverses.lean" text
  sync uri
  expect (← tokens uri text) "cons" "enumMember" (some 1)
  IO.println "PASS explicit universes on dotted constructors"

def edits (root : System.FilePath) : TestM Unit := do
  let text := "def Alias := Nat\ndef use := Alias\n"
  let uri ← openDoc root "tests/Edit.lean" text
  sync uri
  expect (← tokens uri text) "Alias" "type" (some 2)
  let text := "def Alias := 0\ndef use := Alias\n"
  send "textDocument/didChange" ({
    textDocument := ⟨uri, some 2⟩
    contentChanges := #[.fullChange text] } : DidChangeTextDocumentParams)
  sync uri 2
  expect (← tokens uri text) "Alias" "function" (some 2)
  send "textDocument/didChange" ({
    textDocument := ⟨uri, some 3⟩
    contentChanges := #[.rangeChange ⟨⟨0, 13⟩, ⟨0, 14⟩⟩ "Nat"] } : DidChangeTextDocumentParams)
  let text := "def Alias := Nat\ndef use := Alias\n"
  sync uri 3
  expect (← tokens uri text) "Alias" "type" (some 2)
  IO.println "PASS full and incremental edits"

def docs (root : System.FilePath) : TestM (Array Token) := do
  let path := if hasVersoTokens then "tests/Documentation.lean" else "tests/DocumentationLegacy.lean"
  let text ← IO.FS.readFile (root / path)
  let uri ← openDoc root path text
  sync uri
  -- Lean 4.35 emits an empty string token at the end of fenced documentation code.
  -- Preserve and compare it too; ordinary classification tests forbid empty tokens.
  let ts ← tokens uri text (allowEmpty := true)
  return ts.filter fun t =>
    if hasVersoTokens then 4 <= t.line && t.line <= 15
    else t.line != 1 && t.line != 10

def benchmark (root : System.FilePath) : TestM Nat := do
  let text := String.intercalate "\n" <| (List.range 300).map fun i =>
    s!"def value{i} (x : Nat) := x.succ"
  let uri ← openDoc root "tests/Large.lean" text
  sync uri
  let params : SemanticTokensParams := ⟨⟨uri⟩⟩
  discard <| request fullMethod params
  let mut timings : List Nat := []
  for _ in [:5] do
    let start ← IO.monoNanosNow
    discard <| request fullMethod params
    timings := ((← IO.monoNanosNow) - start) :: timings
  return (timings.mergeSort (· <= ·))[2]!

def partialAndCancel (root : System.FilePath) : TestM Unit := do
  let text := "import Lean\ndef before := Nat\n#eval IO.println \"highlighting-ready\"\n" ++
    "#eval IO.sleep 8000\ndef after := Nat\n"
  let uri ← openDoc root "tests/Slow.lean" text
  waitEvent fun
    | .notification "textDocument/publishDiagnostics" (some params) =>
      match fromJson? (toJson params) with
      | .ok (p : PublishDiagnosticsParams) =>
        p.uri == uri && p.diagnostics.any (fun d => trimString d.message == "highlighting-ready")
      | .error _ => false
    | _ => false
  let cancelled ← startRequest rangeMethod ({
    textDocument := ⟨uri⟩
    range := ⟨⟨0, 0⟩, ⟨6, 0⟩⟩ } : SemanticTokensRangeParams)
  send "$/cancelRequest" (Json.mkObj [("id", toJson cancelled)])
  let cancelledFull ← startRequest fullMethod ({ textDocument := ⟨uri⟩ } : SemanticTokensParams)
  send "$/cancelRequest" (Json.mkObj [("id", toJson cancelledFull)])
  let start ← IO.monoMsNow
  let ts ← tokens uri text
  ensure ((← IO.monoMsNow) - start < 6000) "Full request waited for the whole file"
  expect ts "before" "type"
  ensure (!ts.any (·.spelling == "after")) "Expected an incomplete prefix"
  let mark := (← get).events.size
  waitEvent (fun
    | .request _ "workspace/semanticTokens/refresh" _ => true
    | _ => false) mark
  for id in #[cancelled, cancelledFull] do
    let msg ← response id
    match msg with
    | .responseError _ code .. => ensure (code == .requestCancelled) "Wrong cancellation error"
    | _ => throw <| IO.userError s!"Expected cancellation: {(toJson msg).compress}"
  sync uri
  expect (← tokens uri text) "after" "type"
  IO.println "PASS partial results, refresh, and cancelled full/range requests"

def withServer (cwd : System.FilePath) (cmd : String) (args : Array String)
    (test : TestM α) (timeoutSeconds : Nat := 45)
    (env : Array (String × Option String) := #[]) : IO α := do
  let proc ← IO.Process.spawn { toStdioConfig := Ipc.ipcStdioConfig, cmd, args, cwd, env, setsid := true }
  let done ← IO.mkRef false
  let exited ← IO.mkRef false
  let stop := do
    -- `lake serve` owns another process, which in turn owns file workers.
    -- Stop the entire test server so descendants cannot keep the protocol pipes open.
    let result ← IO.Process.output <| if System.Platform.isWindows then
      { cmd := "taskkill", args := #["/PID", toString proc.pid, "/T", "/F"] }
    else
      { cmd := "kill", args := #["-TERM", "--", s!"-{proc.pid}"] }
    if result.exitCode != 0 then try proc.kill catch _ => pure ()
  -- Bound protocol failures so a regression cannot hang the test runner indefinitely.
  let _ ← IO.asTask do
    for _ in [:timeoutSeconds * 10] do
      if ← done.get then return
      IO.sleep 100
    IO.eprintln s!"Language-server test exceeded {timeoutSeconds} seconds"
    stop
  try
    (do
      initializeClient
      let result ← test
      discard <| request "shutdown" Json.null
      send "exit" Json.null
      let code ← Ipc.waitForExit
      exited.set true
      ensure (code == 0) "Server exited unsuccessfully"
      return result).run' {} |>.run proc
  finally
    done.set true
    unless ← exited.get do
      try stop catch _ => pure ()

def libraryPath (root : System.FilePath) : System.FilePath :=
  let stem := SemanticHighlighting.Compat.libraryStem
  root / ".lake/build/lib" /
    (if System.Platform.isWindows then s!"{stem}.dll"
     else if System.Platform.isOSX then s!"lib{stem}.dylib" else s!"lib{stem}.so")

def expectDemo (ts : Array Token) : IO Unit := do
  for (spelling, kind) in #[
      ("Items", "type"), ("Predicate", "type"), ("Tree", "struct"),
      ("Renderable", "interface"), ("Signal", "type"), ("NonemptyItems", "enum"),
      ("cons", "enumMember"), ("go", "enumMember"), ("stop", "enumMember"),
      ("value", "property"), ("hp", "variable"), ("step", "variable")] do
    expect ts spelling kind

private partial def copySources (source target : System.FilePath) : IO Unit := do
  if ← source.isDir then
    IO.FS.createDirAll target
    for entry in ← source.readDir do
      unless entry.fileName == ".lake" do
        copySources entry.path (target / entry.fileName)
  else
    IO.FS.writeBinFile target (← IO.FS.readBinFile source)

private def runLake (cwd : System.FilePath) (args : Array String) : IO Unit := do
  let result ← IO.Process.output { cmd := "lake", args, cwd := some cwd }
  ensure (result.exitCode == 0) s!"lake {args}: {result.stdout}\n{result.stderr}"

/-- VS Code user settings work with ordinary projects and standalone files. -/
def userSettingsActivation (root : System.FilePath) : IO Unit := do
  let result ← IO.Process.output {
    cmd := "lake", args := #["run", "vscode-settings", "--direct"], cwd := some root }
  ensure (result.exitCode == 0) s!"Could not generate VS Code settings: {result.stderr}"
  let settings ← IO.ofExcept <| Json.parse result.stdout
  let args ← IO.ofExcept <| settings.getObjValAs? (Array String) "lean4.serverArgs"
  let library ← IO.FS.realPath (libraryPath root)
  ensure (args == #[s!"--plugin={library}"]) "Settings point to the wrong plugin"
  ensure (← IO.ofExcept <| settings.getObjValAs? Bool "editor.semanticHighlighting.enabled")
    "Settings do not enable semantic highlighting"
  let text ← IO.FS.readFile (root / "examples/Consumer/Demo.lean")
  IO.FS.withTempDir fun workspace => do
    for mode in #["lake", "standalone"] do
      let consumer := workspace / mode
      IO.FS.createDirAll consumer
      let toolchain := s!"leanprover/lean4:v{Lean.versionString}\n"
      IO.FS.writeFile (consumer / "lean-toolchain") toolchain
      IO.FS.writeFile (consumer / "Demo.lean") text
      let lakefile := "name = \"ordinary-project\"\n\n[[lean_lib]]\nname = \"Demo\"\n"
      if mode == "lake" then
        IO.FS.writeFile (consumer / "lakefile.toml") lakefile
        runLake consumer #["--keep-toolchain", "update"]
      -- Match the stock VS Code extension's server commands, including its folder argument.
      let (cmd, serverArgs) := if mode == "lake" then
        ("lake", #["serve", "--", consumer.toString])
      else
        ("lean", #["--server", consumer.toString])
      withServer consumer cmd (serverArgs ++ args) do
        let uri ← openDoc consumer "Demo.lean" text
        let mark := (← get).events.size
        let early ← tokens uri text
        sync uri
        if !early.any (·.spelling == "Tree") then
          -- Unlike module loading, startup loading must refresh an incomplete first result.
          waitEvent (fun
            | .request _ "workspace/semanticTokens/refresh" _ => true
            | _ => false) mark
        else
          expect early "Tree" "struct"
        expectDemo (← tokens uri text)
        edits consumer
      ensure ((← IO.FS.readFile (consumer / "Demo.lean")) == text) "Source file changed"
      ensure ((← IO.FS.readFile (consumer / "lean-toolchain")) == toolchain) "Toolchain changed"
      ensure (!(← (consumer / ".vscode").pathExists)) "Created project editor settings"
      if mode == "lake" then
        ensure ((← IO.FS.readFile (consumer / "lakefile.toml")) == lakefile) "Lakefile changed"
        let manifest ← IO.ofExcept <| Json.parse (← IO.FS.readFile (consumer / "lake-manifest.json"))
        let dependencies ← IO.ofExcept <| manifest.getObjValAs? (Array Json) "packages"
        ensure dependencies.isEmpty "Added a project dependency"
      IO.println s!"PASS direct VS Code user settings with {mode}, early requests, and unchanged project configuration"

/-- One global configuration follows project pins and explicit elan toolchain overrides. -/
def automaticActivation (root : System.FilePath)
    (versions : Array String := #[Lean.versionString]) : IO Unit := do
  let env : Array (String × Option String) :=
    #["ELAN_TOOLCHAIN", "LEAN_PATH", "LEAN_SRC_PATH", "LEAN_SYSROOT", "LAKE_HOME",
      "LEAN", "LAKE", "LEAN_AR", "LEAN_CC", "LEAN_GITHASH", "LAKE_OVERRIDE_LEAN",
      "LAKE_CACHE_DIR", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"].map (·, none)
  let text ← IO.FS.readFile (root / "examples/Consumer/Demo.lean")
  let sourcePin ← IO.FS.readFile (root / "lean-toolchain")
  IO.FS.withTempDir fun workspace => do
    -- Exercise paths with spaces and quotes without any existing build/cache.
    let source := workspace / "plugin's checkout"
    IO.FS.createDirAll source
    for name in #["lakefile.lean", "SemanticHighlighting.lean", "SemanticHighlighting", "tools", "LICENSE"] do
      copySources (root / name) (source / name)
    IO.FS.writeFile (source / "lean-toolchain") sourcePin
    let result ← IO.Process.output {
      cmd := "lake", args := #["run", "vscode-settings"], cwd := some source }
    ensure (result.exitCode == 0) s!"Automatic setup failed: {result.stdout}{result.stderr}"
    let settings ← IO.ofExcept <| Json.parse result.stdout
    let paths ← IO.ofExcept <| settings.getObjValAs? (Array String) "lean4.envPathExtensions"
    ensure (paths.size == 1) "Expected a single launcher directory"
    let bin := System.FilePath.mk paths[0]!
    let lean := bin / (if System.Platform.isWindows then "lean.exe" else "lean")
    let lake := bin / (if System.Platform.isWindows then "lake.exe" else "lake")
    for version in versions do
      let toolchain := s!"leanprover/lean4:v{version}"
      for mode in #["lake", "standalone"] do
        let consumer := workspace / s!"{version}-{mode}"
        IO.FS.createDirAll consumer
        -- The standalone launch deliberately overrides the checkout's default version.
        let pin := if mode == "lake" then s!"{toolchain}\n" else sourcePin
        IO.FS.writeFile (consumer / "lean-toolchain") pin
        IO.FS.writeFile (consumer / "Demo.lean") text
        let lakefile := "name = \"ordinary-project\"\n\n[[lean_lib]]\nname = \"Demo\"\n"
        if mode == "lake" then
          IO.FS.writeFile (consumer / "lakefile.toml") lakefile
          let update ← IO.Process.output {
            cmd := lake.toString, args := #["--keep-toolchain", "update"],
            cwd := some consumer, env }
          ensure (update.exitCode == 0) s!"Lake passthrough failed: {update.stdout}{update.stderr}"
        let plain ← IO.Process.output {
          cmd := lean.toString, args := #[s!"+{toolchain}", "--version"],
          cwd := some consumer, env }
        ensure (plain.exitCode == 0 && plain.stdout.startsWith s!"Lean (version {version},")
          s!"Lean passthrough selected the wrong version: {plain.stdout}{plain.stderr}"
        let (cmd, args) := if mode == "lake" then
          (lake, #["serve", "--", consumer.toString])
        else
          (lean, #[s!"+{toolchain}", "--server", consumer.toString])
        withServer consumer cmd.toString args (env := env) (timeoutSeconds := 180) do
          let uri ← openDoc consumer "Demo.lean" text
          let mark := (← get).events.size
          let early ← tokens uri text
          sync uri
          if !early.any (·.spelling == "Tree") then
            waitEvent (fun
              | .request _ "workspace/semanticTokens/refresh" _ => true
              | _ => false) mark
          else
            expect early "Tree" "struct"
          expectDemo (← tokens uri text)
          edits consumer
        ensure ((← IO.FS.readFile (consumer / "Demo.lean")) == text) "Source file changed"
        ensure ((← IO.FS.readFile (consumer / "lean-toolchain")) == pin) "Project toolchain changed"
        ensure (!(← (consumer / ".vscode").pathExists)) "Created project editor settings"
        if mode == "lake" then
          ensure ((← IO.FS.readFile (consumer / "lakefile.toml")) == lakefile) "Lakefile changed"
          let manifest ← IO.ofExcept <| Json.parse (← IO.FS.readFile (consumer / "lake-manifest.json"))
          let dependencies ← IO.ofExcept <| manifest.getObjValAs? (Array Json) "packages"
          ensure dependencies.isEmpty "Added a project dependency"
        IO.println s!"PASS automatic launcher on Lean {version} with {mode} and unchanged project files"
    ensure ((← IO.FS.readFile (source / "lean-toolchain")) == sourcePin) "Plugin checkout toolchain changed"
    let mut cachedVersions := #[]
    for entry in ← (source / ".lake/launcher/cache").readDir do
      if ← entry.path.isDir then
        let metadata ← IO.ofExcept <| Json.parse (← IO.FS.readFile (entry.path / "plugin.json"))
        cachedVersions := cachedVersions.push (← IO.ofExcept <| metadata.getObjValAs? String "version")
    ensure (cachedVersions.size == versions.size && versions.all cachedVersions.contains)
      s!"Expected one cached build per toolchain: {cachedVersions}"
    IO.println "PASS separate toolchain caches reused across server launches"
    if let some version := versions[0]? then
      let prepareArgs := #[s!"+leanprover/lean4:v{version}", "--run",
        (source / "tools/Setup.lean").toString, "prepare", source.toString]
      let prepare := IO.Process.output {
        cmd := lean.toString, args := prepareArgs, cwd := some source, env }
      let warm ← prepare
      ensure (warm.exitCode == 0 && warm.stderr.isEmpty) s!"Warm cache was not reused: {warm.stderr}"
      let oldLibrary := System.FilePath.mk (trimString warm.stdout)
      let oldBytes ← IO.FS.readBinFile oldLibrary
      let entry := source / "SemanticHighlighting.lean"
      let original ← IO.FS.readFile entry
      IO.FS.writeFile entry (original ++ "\n-- Exercise a new source revision.\n")
      let rebuilt ← prepare
      ensure (rebuilt.exitCode == 0 && rebuilt.stdout != warm.stdout)
        s!"Source update did not create a new plugin build: {rebuilt.stderr}"
      ensure ((← IO.FS.readBinFile oldLibrary) == oldBytes) "Replaced an existing toolchain build"
      IO.println "PASS source updates produce a new build without replacing cached libraries"
      IO.FS.writeFile entry (original ++ "\ninvalid_command_for_launcher_test\n")
      let consumer := workspace / "fallback"
      IO.FS.createDirAll consumer
      IO.FS.writeFile (consumer / "lean-toolchain") s!"leanprover/lean4:v{version}\n"
      IO.FS.writeFile (consumer / "Demo.lean") text
      IO.eprintln "Testing fallback with an intentionally invalid plugin; the following build error is expected."
      withServer consumer lean.toString #["--server", consumer.toString]
          (env := env) (timeoutSeconds := 180) do
        let uri ← openDoc consumer "Demo.lean" text
        sync uri
        let ts ← tokens uri text
        ensure (!ts.any (·.spelling == "Tree")) "Loaded a stale plugin after a build failure"
      IO.println "PASS build failure falls back to ordinary Lean without loading a stale plugin"

/-- Exercise both documented dependency configurations without a prebuilt native library. -/
def dependencyActivation (root : System.FilePath) : IO Unit :=
  IO.FS.withTempDir fun workspace => do
    let dependency := workspace / "plugin"
    IO.FS.createDirAll dependency
    for name in #["lakefile.lean", "SemanticHighlighting.lean", "SemanticHighlighting", "LICENSE"] do
      copySources (root / name) (dependency / name)
    -- A dependency's default pin must not force an older consumer to upgrade.
    IO.FS.writeFile (dependency / "lean-toolchain") "leanprover/lean4:v4.35.0\n"
    let toolchain := s!"leanprover/lean4:v{Lean.versionString}\n"
    let text ← IO.FS.readFile (root / "examples/Consumer/Demo.lean")
    ensure (!(← (libraryPath dependency).pathExists)) "Expected a clean dependency build"
    for format in #["lean", "toml"] do
      let consumer := workspace / format
      IO.FS.createDirAll consumer
      IO.FS.writeFile (consumer / "lean-toolchain") toolchain
      IO.FS.writeFile (consumer / "Demo.lean") text
      if format == "lean" then
        IO.FS.writeFile (consumer / "lakefile.lean") <|
          "import Lake\nopen Lake DSL\n\npackage consumer where\n" ++
          "  plugins := #[`@«semantic-highlighting»/SemanticHighlighting:shared]\n\n" ++
          "require «semantic-highlighting» from \"../plugin\"\n\n" ++
          "@[default_target]\nlean_lib Demo\n"
      else
        IO.FS.writeFile (consumer / "lakefile.toml") <|
          "name = \"consumer\"\ndefaultTargets = [\"Demo\"]\n" ++
          "plugins = [\"@semantic-highlighting/SemanticHighlighting:shared\"]\n\n" ++
          "[[require]]\nname = \"semantic-highlighting\"\npath = \"../plugin\"\n\n" ++
          "[[lean_lib]]\nname = \"Demo\"\n"
      runLake consumer #["--keep-toolchain", "update"]
      ensure ((← IO.FS.readFile (consumer / "lean-toolchain")) == toolchain)
        "Dependency changed the consumer's toolchain"
      withServer consumer "lake" #["serve"] (timeoutSeconds := 180) do
        let uri ← openDoc consumer "Demo.lean" text
        -- Lake loads module plugins while processing imports. A request already
        -- dispatched to the stock handler may finish with stock tokens and no refresh.
        -- Exercise that startup timing, then verify subsequent requests and an edit.
        let early ← tokens uri text
        ensure ((early.filter (·.spelling == "Tree")).all (·.kind == "struct"))
          "Incorrect structure token in the first full request"
        sync uri
        let ts ← tokens uri text
        expectDemo ts
        let ranged ← tokens uri text (some ⟨⟨16, 0⟩, ⟨29, 0⟩⟩)
        ensure (ranged == ts.filter (fun t => 16 <= t.line && t.line < 29))
          "Dependency full/range mismatch"
        let changed := text ++ "\n"
        send "textDocument/didChange" ({
          textDocument := ⟨uri, some 2⟩
          contentChanges := #[.fullChange changed] } : DidChangeTextDocumentParams)
        expectDemo (← tokens uri changed)
        sync uri 2
        edits consumer
      ensure (← (libraryPath dependency).pathExists) "Server did not build the plugin"
      runLake consumer #["build"]
      IO.println s!"PASS lakefile.{format} dependency activation, startup/edit requests, automatic build, and batch compilation"

end Tests

def main (args : List String) : IO Unit := do
  if let some expected ← IO.getEnv "SEMANTIC_HIGHLIGHTING_TEST_VERSION" then
    Tests.ensure (Lean.versionString == expected)
      s!"Expected Lean {expected}, but the test runner uses {Lean.versionString}"
  let root ← IO.currentDir
  if args.head? == some "--launcher-only" then
    let versions := if args.tail.isEmpty then #[Lean.versionString] else args.tail.toArray
    Tests.automaticActivation root versions
    return
  unless args.isEmpty do throw <| IO.userError "Usage: tests/Main.lean [--launcher-only VERSION ...]"
  let library := Tests.libraryPath root
  Tests.ensure (← library.pathExists) "Run lake build first"
  let (stockLegend, stockDocs, stockTime) ← Tests.withServer root "lean" #["--server"] do
    let docTokens ← Tests.docs root
    let time ← Tests.benchmark root
    return ((← get).legend, docTokens, time)
  Tests.withServer root "lean" #["--server", s!"--plugin={library}"] do
    Tests.ensure (toJson (← get).legend == toJson stockLegend) "Token legend changed"
    Tests.classification root
    Tests.dottedUniverses root
    Tests.edits root
    let docTokens ← Tests.docs root
    -- Elaborated Lean inside documentation receives the same enhanced classification.
    -- All markup outside these specific code spans must remain byte-for-byte equivalent.
    let isMarkup := fun (t : Tests.Token) =>
      !Tests.hasVersoTokens || (t.line != 11 && !(t.line == 14 && (t.column == 42 || t.column == 58)))
    Tests.ensure (docTokens.filter isMarkup == stockDocs.filter isMarkup)
      "Host documentation markup changed"
    if Tests.hasVersoTokens then
      Tests.ensure (((docTokens.filter (·.line == 11)).map fun t => (t.spelling, t.kind)) ==
        #[("def ", "string"), ("fromDoc", "function"), (" := 1", "string")])
        "Incorrect classification inside a documentation code block"
      Tests.expect docTokens "succ" "enumMember" (some 1)
      Tests.expect docTokens "type" "property" (some 1)
      Tests.ensure (((docTokens.filter (·.spelling == "k")).map (·.kind)) ==
        #["parameter", "variable"]) "Incorrect documentation local binder/use"
    IO.println "PASS unchanged token legend and documentation markup, enhanced embedded Lean"
    let time ← Tests.benchmark root
    IO.println s!"Warm full-request median, 300 declarations: stock {stockTime / 1000} µs; plugin {time / 1000} µs (5 samples each)"
    Tests.partialAndCancel root
  let consumer := root / "examples/Consumer"
  let update ← IO.Process.output {
    cmd := "lake", args := #["--keep-toolchain", "update"], cwd := some consumer }
  Tests.ensure (update.exitCode == 0) s!"Consumer configuration failed: {update.stderr}"
  Tests.withServer consumer "lake" #["serve"] do
    let text ← IO.FS.readFile (consumer / "Demo.lean")
    let uri ← Tests.openDoc consumer "Demo.lean" text
    Tests.sync uri
    Tests.expectDemo (← Tests.tokens uri text)
    IO.println "PASS lake serve activation in a separate project, without plugin imports"
  Tests.dependencyActivation root
  Tests.userSettingsActivation root
  Tests.automaticActivation root
