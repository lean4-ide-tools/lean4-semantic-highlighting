# Semantic highlighting plugin for Lean

See the difference between types, functions, constructors, and proof hypotheses while reading Lean code. This plugin adds richer semantic highlighting to the standard Lean language server, using what Lean knows about each identifier.

Use your existing Lean toolchain and the official Lean editor extension. No patched compiler or imports in your Lean files are needed.

To enable highlighting across your VS Code projects, install the [companion extension](vscode/README.md). You can also enable it for a single project through Lake.

![Lean code in VS Code with Dark Modern-inspired semantic colors for types, structures, typeclasses, functions, constructors, fields, and local variables](docs/images/vscode-highlighting.png)

*VS Code with Lean 4.35.0 and the standard Lean extension. The showcase adds subtle semantic color variations to Dark Modern's palette. Open [Showcase.code-workspace](examples/Consumer/Showcase.code-workspace) to use the same theme and color rules. The complete example is [Demo.lean](examples/Consumer/Demo.lean).*

## What gets highlighted

The highlighting follows an identifier's meaning, including when its type is inferred:

- `Items`, defined with `def`, is recognized as a type family. Ordinary definitions such as `signals` remain functions.
- `Tree` is a structure and `Renderable` is a typeclass. Recursive references to `Tree` retain the same classification.
- Constructors such as `.cons`, `.go`, and `.stop` are distinguished from fields such as `tree.value`.
- Proposition families such as `NonemptyItems` are distinguished from datatypes. Proof hypotheses remain variables, including hypotheses quantified over propositions.
- Type parameters, term binders, and local uses have separate categories. `Type`, `Sort`, and `Prop` are highlighted independently of their universe levels.

Your editor's theme controls the colors. These are the semantic token names you can customize:

| Entity | Semantic token |
| --- | --- |
| `Type`, `Sort`, `Prop` | `class` |
| Local type parameters | `typeParameter` |
| Typeclasses | `interface` |
| Structures | `struct` |
| Propositions and proposition families | `enum` |
| Datatypes, type aliases, and type families | `type` |
| Constructors | `enumMember` |
| Projection fields and functions | `property` |
| Term definitions, theorems, axioms, and recursors | `function` |
| Local term binders | `parameter` |
| Local term uses and proof hypotheses | `variable` |

Highlighting updates as you edit. Lean code embedded in documentation receives these classifications when your Lean release supports it; other documentation highlighting follows that release's behavior.

## Build and try the example

Install Lean with elan and, for VS Code, the standard Lean 4 extension. The [Lean installation guide](https://lean-lang.org/install/) covers both. Download or clone this repository, then open a terminal in its root directory.

The example defaults to **Lean 4.35.0**. Using the plugin in another project does not require upgrading that project's toolchain; see [Supported Lean versions](#supported-lean-versions).

```sh
lake build
lake test
```

`lake build` builds the plugin. `lake test` checks it against real Lean language servers, including fresh projects using both Lakefile formats.

To open the example with the screenshot's theme and semantic colors:

```sh
code examples/Consumer/Showcase.code-workspace
```

Open `Demo.lean` in that workspace and wait for Lean to finish checking it. The example already has the plugin enabled. Its workspace settings select Dark Modern and add related shades for different semantic categories without changing your global VS Code settings.

You can also use **File > Open Workspace from File** to open `Showcase.code-workspace`. To try the example with your existing theme instead, open the `examples/Consumer` folder directly.

## VS Code companion extension

The extension works with the official Lean 4 extension on Windows, macOS, and Linux. See the [installation instructions and color settings](vscode/README.md).

To build the VSIX from this checkout, run the following commands from the repository root with Node.js 22 or newer.

```sh
cd vscode
npm ci
npm run package
```

In VS Code, run **Extensions: Install from VSIX…** and select the `.vsix` file in `vscode/`.

## Use it in VS Code without changing a project

You can enable the plugin globally in VS Code User Settings. This works with ordinary Lake projects and standalone Lean files, including files from dependencies. The launcher automatically builds or reuses the plugin for the toolchain selected by elan, so you can switch projects and Lean versions with the same configuration.

The automatic launcher requires **elan and an installed Lean toolchain** on Windows, macOS, or Linux. The same Lean sources are used by the companion extension. For a setup without elan, use [direct server arguments](#direct-server-arguments) below.

From the plugin repository, run:

```sh
lake run vscode-settings
```

The command compiles the Lean launcher locally and prints a JSON object containing `lean4.envPathExtensions` and `editor.semanticHighlighting.enabled`. It does not edit your VS Code configuration.

1. With the standard Lean 4 extension installed, run **Preferences: Open User Settings (JSON)** from the Command Palette.
2. Merge the printed settings. If you already have `lean4.envPathExtensions`, put the generated directory first in that array.
3. Run **Developer: Reload Window**, then open your existing project or Lean file.

The extension's existing [`lean4.envPathExtensions` setting](https://github.com/leanprover/vscode-lean4/blob/master/vscode-lean4/package.json) makes its normal `lake serve` and `lean --server` commands use the launchers. Other commands, including ordinary builds, pass through to elan.

The first server launch for a toolchain may take a little longer while the plugin builds. Later launches reuse that build. Updating the plugin's sources creates a new cached build; existing builds remain available to running servers. You do not need to change the plugin repository's `lean-toolchain` to match each project. The plugin loads before the server starts handling requests, which also avoids the first-open refresh limitation of the Lake dependency setup below.

If the plugin cannot build with a toolchain, the launcher reports the error in Lean's output and starts the ordinary Lean server. That project remains usable with its usual highlighting.

Keep the plugin checkout at the same location after generating the settings. If you move it, run the command again. Builds are cached under `.lake/launcher/cache` in the plugin checkout; deleting that cache makes future launches rebuild them. For SSH, WSL, or containers, generate the settings on the remote host and use that environment's Remote settings.

To disable it, remove the launcher directory from `lean4.envPathExtensions` and reload the window. Use one activation method at a time: disable the launcher when a project already enables this plugin through Lake.

### Direct server arguments

For an installation without the automatic launcher, build with the **exact Lean toolchain** your server uses and run:

```sh
lake run vscode-settings --direct
```

Merge the generated `lean4.serverArgs` and `editor.semanticHighlighting.enabled` into VS Code User Settings, then reload the window. This method supplies a fixed library path: update or remove that argument when changing toolchains. A mismatched library can prevent the server from starting. See [Supported Lean versions](#supported-lean-versions) for building a matching version.

## Enable it through a project dependency

Add the plugin as a Lake dependency and enable its named build target. Lake builds it with your project's Lean toolchain and finds the correct library for your operating system automatically.

In the examples below, `/path/to/semantic-highlighting` is a placeholder for wherever you cloned this repository. Replace it with your actual checkout path; no folder name or directory layout is required. You can also use a normal Git dependency pinned to a commit or tag; the `plugins` setting stays the same.

### Projects with `lakefile.lean`

Add `plugins` to your existing `package` declaration and add the dependency:

```lean
import Lake
open Lake DSL

package myProject where
  plugins := #[`@«semantic-highlighting»/SemanticHighlighting:shared]

require «semantic-highlighting» from "/path/to/semantic-highlighting"
```

Keep your existing package name, library declarations, and other settings. If you already have a `plugins` array, append this target to it.

### Projects with `lakefile.toml`

Put `plugins` at the top level, before any `[table]` or `[[array-of-tables]]` sections, and add a dependency section:

```toml
name = "my-project"
plugins = ["@semantic-highlighting/SemanticHighlighting:shared"]

[[require]]
name = "semantic-highlighting"
path = "/path/to/semantic-highlighting"
```

Keep your existing library and executable sections. Append to any existing `plugins` array.

### Finish setup and open the editor

From your project's root directory, run:

```sh
lake --keep-toolchain update
lake build @semantic-highlighting/SemanticHighlighting:shared
```

`--keep-toolchain` preserves your project's selected Lean version when updating dependencies. The build command prepares the plugin explicitly; Lake also builds it on demand when you open a Lean file or build your project.

Open your project's root folder in VS Code. If it is already open, run **Developer: Reload Window** from the Command Palette so the server starts with the new configuration. Then open a Lean file and let it finish checking.

No per-file imports are needed. Other editors that launch your project's server through `lake serve` use the same configuration. The setting applies to your package's files; dependencies keep their own highlighting configuration.

Use one activation method per project.

On first opening a file, a request sent before the plugin loads can retain Lean's default colors. If that happens, make a small edit, such as inserting and removing a space. Subsequent highlighting requests use the plugin.

To disable the plugin, remove its target from `plugins` and reload the editor window. You can also remove the dependency if you no longer need it.

## Supported Lean versions

The test matrix covers the following stable releases.

**4.24.0, 4.25.0, 4.25.1, 4.25.2, 4.26.0, 4.28.0, 4.34.1, 4.35.0, and 4.36.0.**

The VS Code extension is incompatible with Lean 4.7.0, 4.17.0, and 4.20.0. Other unlisted releases and nightlies may work, depending on their Lean language-server APIs. Run `lean --version` in your project folder to check the active toolchain.

The automatic launcher and Lake dependency setup both build the plugin using your project's exact Lean version and platform. Source compatibility across releases does not mean one native library can be loaded by all of them; these setups manage the separate builds for you.

With the launcher, opening a project using another toolchain automatically selects its build. With the dependency setup, you can prepare the build explicitly after switching toolchains, then reload your editor:

```sh
lake build @semantic-highlighting/SemanticHighlighting:shared
```

Prefer a separate Git dependency checkout in each project when working with multiple Lean versions. Sharing one local source checkout also shares its build directory, so different projects may rebuild the same artifacts.

To build and test the plugin repository itself with another project's toolchain, run these commands from the plugin repository, replacing `/path/to/your-project`:

```sh
cp /path/to/your-project/lean-toolchain lean-toolchain
cp lean-toolchain examples/Consumer/lean-toolchain
lake clean
lake build
lake test
```

Copying the toolchain to the consumer example keeps the example and integration tests on the same version. You can also edit both files directly; for example, their complete contents could be `leanprover/lean4:v4.28.0`.

With SSH, WSL, or containers, add the dependency in the remote project so Lake builds it where the Lean server runs.

## Choose your colors

The plugin provides categories; your theme decides how they look. The [example workspace](examples/Consumer/Showcase.code-workspace) keeps Dark Modern's teal for types, yellow for functions, blue for constructors, and light blue for variables. Nearby shades distinguish the other categories: structures lean greener, typeclasses lean toward cyan, and proposition families use a softer teal. Fields and parameters use variations of the same light blue.

To reproduce the screenshot's colors in your own project, select Dark Modern and copy the complete `editor.semanticTokenColorCustomizations` setting from the example workspace into your project's `.vscode/settings.json`. The theme alone does not include these variations. For a smaller customization, merge just a few of its rules:

```json
{
  "editor.semanticHighlighting.enabled": true,
  "editor.semanticTokenColorCustomizations": {
    "rules": {
      "struct:lean4": "#6ACD9B",
      "interface:lean4": "#68C5D0",
      "enumMember:lean4": "#4FC1FF"
    }
  }
}
```

The `:lean4` suffix limits each color rule to Lean. Use the names in the token table to customize other categories. VS Code's [semantic highlighting guide](https://code.visualstudio.com/api/language-extensions/semantic-highlight-guide#theming) explains the available styling options.

## Run the tests

From the plugin repository:

```sh
lake test
```

This builds the plugin and runs the test suite, entirely written in Lean. It checks identifier categories, Unicode positions, highlighting after edits, full-file and range requests, partial results, refreshes, cancellation, and documentation. It also checks both Lakefile formats and direct server arguments. Launcher tests cover ordinary projects and standalone files, elan overrides, paths with spaces and quotes, cache reuse, source updates, and fallback after build failures. Project sources, configuration, dependencies, and toolchain pins stay unchanged. No running editor is required.

The suite prints `PASS` lines and exits with a nonzero status on failure. It also reports a small request-latency comparison; the timings depend on your machine.

To test several releases, install them with elan and select them explicitly:

```sh
elan toolchain install leanprover/lean4:v4.24.0
elan toolchain install leanprover/lean4:v4.35.0
lake run test-matrix 4.24.0 4.35.0
```

To test all listed releases, install each of those toolchains and run the matrix.

```sh
lake run test-matrix
```

The matrix builds and tests a clean copy for each release. It leaves your working copy and its toolchain selection unchanged.

To check switching toolchains with a single global launcher configuration:

```sh
lake env lean --run tests/Main.lean --launcher-only 4.24.0 4.35.0
```

For the VS Code extension tests, run `npm ci`, `npm test`, and `npm run test:integration` from `vscode/`. The integration test opens a temporary project in an isolated VS Code profile with the official Lean extension. On headless Linux, run it under Xvfb. To reuse local installations, set `VSCODE_EXECUTABLE_PATH` to the editor executable and `LEAN4_EXTENSION_PATH` to the official extension directory.

## Troubleshooting

- **Colors look unchanged:** wait for Lean to finish checking and make a small edit to refresh highlighting. Enable `editor.semanticHighlighting.enabled` and try the showcase workspace. Your usual theme may use identical colors for different categories.
- **Lake cannot find or build the plugin:** check the dependency's source path, run `lake --keep-toolchain update`, then run `lake build @semantic-highlighting/SemanticHighlighting:shared` from your project to see the build error.
- **The automatic launcher uses ordinary highlighting:** check Lean's output for a build error. Confirm the launcher directory is first in `lean4.envPathExtensions`, then reload the window.
- **VS Code stops starting Lean with direct server arguments:** check that the configured plugin build matches the project's exact toolchain. Remove its `lean4.serverArgs` argument to disable it, or regenerate the settings from a matching build. Also check that the project does not already load another copy through Lake.
- **The plugin works in the example but not in your project:** check the project's `plugins` setting, then reload the editor window. A custom server launcher should use `lake serve`. Files belonging to another dependency use that dependency's settings.
- **Highlighting conflicts with another plugin:** try loading only this highlighting plugin to identify the conflict.

## License

[MIT](LICENSE).
