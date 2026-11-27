import Lean

namespace Matrix

def releases : List String :=
  ["4.24.0", "4.25.0", "4.25.1", "4.25.2", "4.26.0", "4.28.0", "4.34.1", "4.35.0", "4.36.0"]

def isRelease (version : String) : Bool :=
  let parts := version.splitOn "."
  parts.length == 3 && parts.all fun part =>
    !part.isEmpty && part.toList.all Char.isDigit

partial def copyTree (source target : System.FilePath) : IO Unit := do
  if ← source.isDir then
    IO.FS.createDirAll target
    for entry in ← source.readDir do
      unless entry.fileName == ".lake" do
        copyTree entry.path (target / entry.fileName)
  else
    IO.FS.writeBinFile target (← IO.FS.readBinFile source)

def testRelease (root : System.FilePath) (version : String) : IO UInt32 :=
  IO.FS.withTempDir fun target => do
    -- Copy only package inputs: every release starts without generated artifacts.
    for name in #[
      "lakefile.lean", "SemanticHighlighting.lean", "SemanticHighlighting",
      "tests", "tools", "examples", "README.md", "LICENSE"
    ] do copyTree (root / name) (target / name)
    let toolchain := s!"leanprover/lean4:v{version}"
    for path in #[target / "lean-toolchain", target / "examples/Consumer/lean-toolchain"] do
      IO.FS.writeFile path s!"{toolchain}\n"
    IO.println s!"Testing Lean {version}"
    (← IO.getStdout).flush
    let proc ← IO.Process.spawn {
      cmd := "elan", args := #["run", toolchain, "lake", "test"], cwd := some target
      -- Do not inherit paths configured by the outer `lake env` invocation.
      env := #[
        ("ELAN_TOOLCHAIN", some toolchain), ("LEAN_PATH", none),
        ("LEAN_SRC_PATH", none), ("LEAN_SYSROOT", none), ("LAKE_HOME", none),
        ("LEAN", none), ("LAKE", none), ("LEAN_AR", none), ("LEAN_CC", none),
        ("LEAN_GITHASH", none), ("LAKE_OVERRIDE_LEAN", none), ("LAKE_CACHE_DIR", none),
        ("LD_LIBRARY_PATH", none), ("DYLD_LIBRARY_PATH", none),
        ("SEMANTIC_HIGHLIGHTING_TEST_VERSION", some version)
      ]
    }
    let code ← proc.wait
    IO.println s!"Lean {version}: {if code == 0 then "PASS" else "FAIL"}"
    return code

end Matrix

def main (args : List String) : IO UInt32 := do
  let versions := if args.isEmpty then Matrix.releases else args
  for version in versions do
    unless Matrix.isRelease version do
      throw <| IO.userError s!"Expected a stable release such as 4.35.0, got: {version}"
  let root ← IO.currentDir
  let mut failed : List String := []
  for version in versions do
    if (← Matrix.testRelease root version) != 0 then
      failed := failed ++ [version]
  if failed.isEmpty then
    IO.println s!"All {versions.length} stable releases passed."
    return 0
  IO.eprintln s!"Failed releases: {String.intercalate ", " failed}"
  return 1
