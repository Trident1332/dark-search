# Ask AI tools

Ask AI selects tools automatically when a question is submitted to a tool-capable model. Search can test the HTTP(S) tab already open in its own WebKit view, using structured snapshot, click, fill, select, press, scroll, wait, assertion, page JavaScript and same-origin HTTP checks. Native clicks and text keys use the current view; JavaScript and DOM operations explicitly report their execution mode. References expire on document changes. Native dialogs and other tabs are outside this interface. Page JavaScript does not require Inspector or network recording; raw network inspection remains an **Inspect page** option under Advanced.

Use the paperclip to attach a file or folder. A single regular file is copied into a private workspace (0700 directory, 0600 file, 500 MB maximum), without granting access to its original siblings. Attaching a folder grants read access to that folder. Copies are removed when detached or the conversation closes; original inputs remain unchanged. Paste an explicit public GitHub repository URL in the human question to select it automatically. Ambiguous links and page content cannot select a repository. Selections stay in memory and cannot be widened by model text.

**Details** shows readable activity summaries, with raw evidence available on expansion. Results have bounded, paged evidence IDs. Engine checks and tracing remain under Advanced; **Export report…** saves evidence only on an explicit native action.

## Free local engines and sources

| Integration | Role |
| --- | --- |
| REA 6.7.0 | Static application analysis and headless native analysis using installed Ghidra by default; existing Hopper remains an optional provider |
| Serena LSP | Semantic source navigation using free installed language servers; the paid JetBrains backend is excluded |
| Opengrep / Semgrep CE | Offline starter checks; the bundled small rule set is not a comprehensive security audit |
| ast-grep | Structured source search and rewrite previews that leave source files unchanged |
| Gitleaks | Redacted secret findings |
| Syft | Component inventory |
| Grype / OSV-Scanner | Vulnerability checks using an existing offline database |
| Frida | Short fixed function-entry traces after selecting an owned process; macOS/sandbox denial remains an error |
| mitmproxy / HAR reader | Saved capture inspection without replay, live capture, certificate-trust changes or system-proxy changes |
| Local documentation search | Bounded text search with source paths and line numbers |
| Public GitHub source | Explicitly selected public repository metadata/files/issues/PRs/releases/workflows through Search's current proxy route |

The model cannot choose executables, environment variables, sandbox rules, MCP registrations, or analysis roots. Executable discovery uses Search's private Tools folder, Homebrew and system locations. Discovery never installs software or falls back to paid providers. Local helpers have read-only access to the selected folder and write only to private scratch. They have no IP network access; narrowly scoped native Hopper IPC is documented below. Closing a conversation disposes its helpers and temporary files. Explicitly exported reports remain where the person saved them.

Public GitHub reads run in Search through the same proxy transport as Ask AI, without copying browser cookies or credentials. This connector does not authenticate to private repositories. An already-open private GitHub page can instead be inspected through explicitly enabled same-session browser tools.

## Installed development dependencies

The implementation used the existing Node 24.13.1, Ghidra 12.1.4, OpenJDK 26, Hopper, ast-grep and mitmproxy. Free additions are installed locally; no global agent/MCP configuration was changed.

- Homebrew: Gitleaks, Syft, Grype, OSV-Scanner, uv.
- Opengrep v1.33.1: official macOS arm64 release, verified SHA-256 `a17c1881bb40e3214266a7a291cf4f2ae3bc56c1715628b5712d2ec816bc3e2d` in `Search/Tools/bin`.
- Private npm package: `rea-agents@6.7.0` in `Search/Tools/rea`. The pin supports the existing Node runtime.
- Private Python environments: `serena-agent==2.1.0`, `jedi-language-server==0.47.0`, `frida-tools==14.11.0`, `frida==17.25.0`.
- Offline vulnerability database: `Search/Tools/Databases/grype`. Database maintenance is explicit; analysis never downloads updates. OSV can use an explicitly selected compatible offline cache.

The Tools folder is `~/Library/Application Support/Search/Tools`. Runtime libraries and managed databases have specific read grants. Missing dependencies, stale databases, unsupported operations and permission failures are reported explicitly.

## Provider and privacy boundaries

Activity and conversations remain in memory unless exported. A tools-specific cloud notice covers selected-file findings, saved network captures and raw live inspection values. Private/Tor tabs require a local provider. The bundled **On this Mac** text engine does not implement tool calling; choose a tool-capable local Ollama/LM Studio model or a configured provider. Inference charges are separate from these free integrations.

HTTP checks do not prove UI success. Zero scanner findings do not prove safety. Captured traffic, source indexes and inventories have coverage limits, and results should cite the evidence actually returned.

## Headless native analysis

Ghidra is the default native provider when its installed runtime is ready.
Search pins its installation and Java paths; model text cannot choose runtimes,
environment variables or paid providers. Headless Ghidra and optional Hopper
use separate MCP processes, scratch directories and sandbox profiles.

The Ghidra lane grants no Mach services or AppleEvents. IP access and
LaunchServices launches stay denied. Its only network permission is Unix IPC
inside that session's private scratch directory. JVM home, temporary files,
preferences and analysis projects also stay there. Only the selected source
and fixed Ghidra/Java runtime roots are readable. Cancellation stops owned
Node/Java processes, preserving unrelated Java sessions.

Real fixtures verify Mach-O import, procedure inventory and decompilation,
provider provenance, unchanged input, kernel network/file denials and cleanup.
Native evidence identifies Ghidra, rather than claiming Hopper produced it.

## Isolated Hopper adapter

`HopperOfflineLauncher.swift` replaces the normal vendor launch path for this
integration. The vendor `hopper` utility uses AppleScript and LaunchServices to
find or reuse a global GUI application. That application's network and file
access would not be confined by a sandbox around the utility.

Search instead:

1. Validates the host-selected workspace, private scratch directory, target,
   bridge script, Hopper bundle identifier, and native executable.
2. Spawns the original Hopper executable directly. The helper and Hopper inherit
   one fixed analysis sandbox that denies IP networking, AppleEvent sending,
   and LaunchServices launches. macOS rejects applying a nested sandbox here.
3. Keeps the child unreaped and verifies its executable and process identity.
4. Connects only to Search's private `hopper-events.sock` in this scratch
   directory. The fixed, bounded request includes the target, bridge, loader
   enum and child process start identity. The host independently authenticates
   the kernel-reported helper peer, pinned helper code, ownership chain, target
   and trusted REA bridge before sending anything.
5. The trusted Search host requests ordinary macOS Automation permission and
   addresses only the verified owned Hopper PID, using the documented
   `Hopp/OpEx`, `EXPY`, `STAN` and `OPTS` event parameters. No AppleScript or
   client-supplied event/script text is evaluated by Search.
6. Waits for the child; cancellation terminates the owned process group. A
   250 ms watchdog checks the original supervisor PID, user, and process start
   identity; supervisor death/reparenting stops only the owned child even when
   no cancellation signal is delivered.

Only Search has Automation permission; the helper and parser cannot reuse it
against another Hopper application. Unix sockets are restricted to private
scratch. Only the selected workspace is readable as analysis input; writes stay
in scratch. No license file or Hopper binary is changed.
The installed Hopper edition's normal limits remain in effect, including demo
session and export restrictions.

`build.sh` packages and signs the fixed helper in `Contents/Helpers` before
signing Search. Search declares Automation use; macOS consent is still required.
An authorization failure is a failure, never evidence that analysis succeeded.
There is no unsandboxed or global vendor-launcher fallback. Unsupported loader
options and database workflows fail explicitly.

## REA 6.7.0 private runtime patch

The adapter also needs three narrow changes to the MIT-licensed REA runtime:

- Hopper lease sockets use the host's private `TMPDIR`.
- Isolated Hopper bridge sockets use that same private directory.
- The fixed Search helper has a child-owned process lifetime so close/cancel
  cleans up the GUI process instead of treating it as a reused application.

The CLI and MCP bundles contain copies of these modules, so all six source and
bundle files are checked and patched together. Review without writing:

```sh
python3 Integrations/AskAI/patch_rea_runtime.py
```

Apply only to Search's private installation:

```sh
python3 Integrations/AskAI/patch_rea_runtime.py --apply
```

The script requires exactly `rea-agents@6.7.0` beneath
`~/Library/Application Support/Search/Tools/rea`, refuses redirected source
paths, preserves original files in private backups, and writes
`.search-patches/manifest.json`. The manifest identifies
`search-private-hopper-isolation-2` and includes SHA-256 for every patched file.
AIREA verifies the marker and file digests before enabling native analysis. A
matching package version alone does not establish that this adapter is present.
The runtime's MIT license and notices remain unchanged. Global agent/MCP
configuration and global npm installations are not edited.

A short, exclusively created scratch path is necessary: macOS Unix socket
addresses have a small fixed limit. Do not move the socket root back to shared
`/tmp`, replace it with a public listener, or allow all localhost traffic.

## Verification

Runtime patch regressions use disposable package fixtures. The helper lifecycle
fixtures compile the production helper, exercise the single-sandbox authenticated
relay with a synthetic native engine, verify inherited file/network denials and
host-denial cleanup, and kill only a synthetic supervisor PID to verify that the
orphaned helper reaps its own child:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s Integrations/AskAI -p 'test_*.py' -v
```

Browser tools have separate real WebKit fixtures in
`Tests/SearchTests/AIBrowserToolsTests.swift`, including existing HttpOnly session
reuse, trusted input, stale references, cancellation, and explicit assertions.
Successful HTTP status does not establish successful UI behavior.

Native verification requires an actual successful analysis through the signed
Search application after macOS grants Search access to Hopper. Compilation,
MCP discovery, a valid code signature, and launching Hopper's `--help` do not
establish native analysis. Preserve that distinction in release notes and test
reports, including when Automation is denied or the installed Hopper edition
cannot provide a requested operation.
