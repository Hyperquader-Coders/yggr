# yggr — decisions log

Why yggr is built the way it is, and what was deliberately not done. Each entry describes the
position that holds now: when one is superseded it is rewritten, not annotated. Keeping dead
positions around is for a project with released versions to answer for — this has none.

This is not a changelog — `git log` is that — and not a spec. The behaviour lives in
[`SPEC.md`](SPEC.md), the design in [`ARCHITECTURE.md`](ARCHITECTURE.md). When something ships
it leaves [`../MoSCoW.md`](../MoSCoW.md) and its reasoning arrives here.

---

## Architecture

- **`src/lsp` is headless: no GTK, no `amber` collection.** The LSP client is a plain Odin
  package that talks to a server over a pipe; only `src/ui` links GTK. This is what lets
  `make test` run with nothing but a compiler — no GTK, no amber-lib, no language server
  installed.

- **Callbacks fire on the reader thread; the UI layer marshals.** `client.odin` invokes
  its callbacks from the thread draining the server's stdout, so a UI callback may only
  package a payload and `g_idle_add` it. Touching a GTK object from the reader thread is the
  one way to break this design, so the constraint is stated at both call sites.

- **A missing language server is a soft failure.** Resolution is three-step —
  `YGGR_LSP_CMD`, then the `lsp-servers.conf` registry, then foundry (FLATPAK.md §3) — and
  when none is usable the editor still opens and edits. LSP is an enhancement, not a
  precondition for the editor working.

## Vendoring

- **OLS's framing and marshalling are vendored, not hand-written.** OLS is a production
  LSP implementation in Odin that compiles against the current compiler, so its reader,
  writer, header parsing and JSON marshaller replace the riskiest hand-written parts of the
  transport. MIT, commit-pinned, kept pristine under `third_party/ols/` and adapted under
  `src/lsp/vendor_ols/` — see [`../THIRD_PARTY.md`](../THIRD_PARTY.md).

- **`protocol.odin` and `encoding.odin` stay hand-written.** Upstream `server/types.odin`
  is server-oriented — full `ServerCapabilities`, semantic tokens, code actions — and its
  `common` dependencies pull in `core:odin/ast` and `tokenizer`, where the MVP needs six
  message families. The utf16↔utf8 conversion has a dedicated acceptance test (SPEC §6.3) and
  no AST dependency. Taking either from OLS would cost more than it saves.

## Toolchain

- **The compiler must be at least `dev-2026-07a`.** That is the core where `os2` merged into
  `core:os`, which yggr's `import os2 "core:os"` requires. Which Odin ships is the SDK
  extension's decision, not this repo's — see [`TOOLCHAIN.md`](TOOLCHAIN.md) and
  [`SUPPLY-CHAIN.md`](SUPPLY-CHAIN.md).

## Packaging

- **The Flatpak keeps the whole Odin toolchain at `/app/opt/odin`.** OLS produces
  diagnostics by shelling out to `odin check`, so a runnable compiler plus `core`, `base` and
  `vendor` must survive `cleanup:` — Odin validates that `ODIN_ROOT` has the `vendor`
  collection. Only cross-platform dead weight (`*.a`, `*.dll`, `*.lib`, `*.dylib`) is
  stripped. This is also what makes the bundle a usable Odin environment for newcomers.

- **The Flatpak forces `GTK_IM_MODULE=gtk-im-context-simple`.** The runtime's newer GTK4
  calls an IBus D-Bus method the host's older `ibus-daemon` lacks
  (`No such property PostProcessKeyEvent`), which spams warnings on every key event and
  crashes when the text context menu opens. Simple IM keeps dead keys, compose and the emoji
  picker; it drops full IBus/CJK input. Revisit if CJK input is needed.

- **yggr ships its own GtkSourceView language spec for Odin.** GtkSourceView has none, so
  `gtk_source_buffer_get_language()` returns NULL for `.odin` files and both highlighting and
  LSP language-id routing fail. `data/language-specs/odin.lang` covers keywords, comments,
  strings and numbers.

- **The Flatpak tracks amber-lib by `branch: main`, not a commit.** amber-lib is
  republished as a fresh root commit, which orphans any pin — and an orphaned pin fails only
  for a fresh clone, since locally the commit lingers as a dangling object and the build keeps
  working. Flathub requires a fixed ref, so a `commit:` is pinned at submission, once
  amber-lib stops being republished.

- **yggr ships as a Flatpak and nothing else.** It belongs to hyperquader.com, not to the
  Amber Linux suite: it is the editor test bed, not part of the desktop, and shipping it
  alongside the suite would imply support it does not have. One channel that bundles its own
  language servers and toolchain beats a host package that depends on Foundry being installed,
  so there is no deb — `make install` covers a local build, and the Flatpak is the artefact.

- **The compiler comes from an SDK extension, not from this manifest.** Building a compiler
  inside every Odin application is the wrong shape, and no Odin SDK extension existed, so one
  was made: `org.freedesktop.Sdk.Extension.odin`, published from `flatpak.amberlinux.org`.
  yggr declares it in `sdk-extensions` and copies `/usr/lib/sdk/odin` into `/app/opt/odin` —
  the extension is build-time only, and OLS needs the compiler at runtime.

  The extension builds Odin from `Hyperquader-Coders/Odin`, branch `llvm-target-guards`, for
  one patch. The freedesktop llvm extension provides X86, AMDGPU, ARM, NVPTX and WebAssembly —
  no AArch64, no RISCV — and Odin names each target's `LLVMInitialize*` symbols directly, while
  `src/llvm-c/Config/Targets.def` is vendored and lists every LLVM target regardless of what is
  linked. So the symbols are declared, the link fails over branches an x86_64 build can never
  take, and upstream Odin cannot be built against a partial-target LLVM at all. Deleting those
  lines with `sed` is the crude alternative, and it drops a target silently. The patch teaches
  `build_odin.sh` to read `llvm-config --targets-built` and guards each arm on
  `ODIN_LLVM_HAS_<TARGET>`. The fork is temporary: it goes back to `odin-lang/Odin` at a
  release tag once the patch is upstream.

  `llvm22` stays in `sdk-extensions` regardless of where the compiler comes from, because Odin
  links through `clang` and the freedesktop SDK ships none. The whole chain is in
  [`SUPPLY-CHAIN.md`](SUPPLY-CHAIN.md).

- **OLS is built from source, with the toolchain that ships in the bundle.** The `ols`
  module appends `/app/opt/odin` to PATH and sets `ODIN_ROOT`, so it compiles against the
  exact compiler the app will run rather than a prebuilt release archive — one less
  blob for Flathub review, and no chance of a server/compiler skew. Upstream's `build.sh` is
  deliberately not used: it stamps `VERSION` from `git rev-parse` plus today's date, so no two
  builds agree, and it passes **`-microarch:native`**, which targets the CPU doing the
  building. That is right for a local build and wrong for a redistributed one — a bundle built
  on a newer runner can emit instructions a user's CPU does not have, and it fails as SIGILL
  at run time, not at build time. The module passes upstream's other release flags verbatim.

- **A `v*` tag builds the bundle and attaches it to a GitHub release.** Until Flathub
  submission lands, `flatpak build-bundle` is the only way a user gets a downloadable file.
  The workflow installs the runtime, SDK and llvm extension with
  `flatpak-builder --install-deps-from=flathub`, reading the versions out of the manifest
  rather than repeating them in CI, so a runtime bump stays a one-file change. The bundle
  carries `--runtime-repo`, so a downloader without the GNOME runtime is pointed at Flathub
  instead of hitting an unresolved dependency.
