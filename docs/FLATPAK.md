# FLATPAK.md — Agent Instructions: Packaging Phase (Phase 8)

Prerequisite: the editor builds and runs (`make build`, `make test` green).
This phase produces a flatpak of the editor — app id
`io.github.hyperquader.Yggr`, binary name `yggr` — bundling language servers
so LSP works with zero host setup.
Manifest: `flatpak/io.github.hyperquader.Yggr.yaml`. Bundled servers:
**OLS** (Odin, built from source at tag `dev-2026-06`, commit-pinned, using the
compiler the SDK extension supplies) and **marksman** (Markdown, `2026-02-08`, a
sha256-pinned prebuilt — the last blob, and a Flathub submission blocker; see
MoSCoW.md). Do not modify anything under `third_party/`.

**Diagrams** (`diags/`, D2 — regenerate with `d2 <file>.d2 <file>.svg`):
- `flatpak-bundle.d2` — anatomy of the installed `/app` image: the bundled Odin
  toolchain (compiler + `libLLVM` + `core`/`base`/`vendor`), OLS + its `builtin/`,
  marksman, the shared data, and the build-time-vs-runtime split.
- `ols-diagnostics.d2` — the load-bearing bit: OLS has no checker of its own, so
  it shells out to `odin check`, which is *why* a runnable compiler is bundled.

## §1 Toolchain

```sh
flatpak install --user flathub org.gnome.Platform//50 org.gnome.Sdk//50
flatpak search llvm   # confirm the llvm extension in the manifest still exists
flatpak install --user flathub org.freedesktop.Sdk.Extension.llvm22//25.08
# The Odin toolchain comes from our archive, not Flathub:
flatpak remote-add --if-not-exists --user amberlinux \
    https://flatpak.amberlinux.org/amberlinux.flatpakrepo
flatpak install --user amberlinux org.freedesktop.Sdk.Extension.odin
```
Verify whether the runtime already ships GtkSourceView (expected yes):
`flatpak run --command=pkg-config org.gnome.Sdk//50 --modversion gtksourceview-5`.
Only if absent/too old, add a gtksourceview git module before yggr.

## §2 Pinning duties (before first build)

1. The compiler is not built here. It arrives with
   `org.freedesktop.Sdk.Extension.odin` and is copied into `/app/opt/odin`;
   which Odin that is, is the extension's business — see SUPPLY-CHAIN.md.
2. **The ols tag tracks the compiler tag.** ols is built from source against the
   compiler this manifest builds, so a mismatch is a compile error, not a runtime
   surprise: ols `dev-2026-05` uses `Odin_OS_Type.Haiku`, which the compiler
   dropped before `dev-2026-07a`. Bump both together, and pin `commit:` beside
   the tag — `gh api repos/DanielGavin/ols/tags` lists them.
3. Confirm the marksman URL+sha256 still resolves. Never bump a version without
   recomputing sha256 (`curl -L <url> | sha256sum`).
4. **amber-lib source**: the yggr module fetches the `amber` Odin collection
   (`git` source, `dest: amber-lib`) and builds with
   `-collection:amber=amber-lib` (afs is used by `src/ui/editor.odin`). Pin
   its `commit:` — flathub requires a fixed ref; `branch: main` is fine for
   local iteration only.

## §3 Code change: server resolution (small, required)

Extend `resolve_server_argv` in `src/ui/editor.odin` to the three-step order:

1. `YGGR_LSP_CMD` env → split on spaces, use verbatim (unchanged).
2. Registry file: first of `$XDG_CONFIG_HOME/yggr/lsp-servers.conf` then
   `/app/share/yggr/lsp-servers.conf` (bundled). Format is
   `lang_id=command line` (see `flatpak/lsp-servers.conf`); ignore blank
   lines and `#` comments. On match, split value on spaces.
3. Fall back to `{"foundry","lsp","run",language_id}` iff `foundry` is on
   PATH; else soft failure (SPEC §5).

Also: when `gtk_source_buffer_get_language` returns NULL, fall back to an
extension map before giving up — at minimum `.odin→odin`, `.md→markdown`.
Add a headless test for the conf parser (comments, spaces, missing file).

## §4 Build & iterate

```sh
flatpak-builder --user --install --force-clean build-dir \
    flatpak/io.github.hyperquader.Yggr.yaml
flatpak run io.github.hyperquader.Yggr demo/main.odin
```
The yggr module builds from `type: dir, path: ..` — the repo itself; no
network needed for that module. flatpak-builder caches the odin-toolchain
module, so iteration on yggr sources is fast after the first build.

## §5 Acceptance criteria (Phase 8)

1. Build succeeds from a clean `--force-clean` run.
2. `flatpak run … demo/main.odin` shows Odin syntax highlighting (proves
   the bundled `odin.lang` is found) and OLS diagnostics ≤ 2 s on open —
   the file carries a deliberate type error — with `foundry` NOT installed
   on the host and no network at runtime.
3. Same for a `.md` file: marksman diagnostics/hover (e.g. broken
   wiki-link warning).
4. `flatpak run --command=sh io.github.hyperquader.Yggr -c 'ols --version; marksman --version'`
   both execute.
5. Closing the app leaves no server processes in the sandbox
   (`flatpak ps` empty for the app after exit).
6. Desktop file and metainfo pass `desktop-file-validate` and
   `appstreamcli validate` (both available in the SDK).
7. The app shows its icon in the launcher / GNOME Software (the `.desktop`
   `Icon=io.github.hyperquader.Yggr` resolves to the installed hicolor icon).

## §7 Icons & branding

- Source artwork: `data/artwork/yggr.svg` (neon Yggdrasil tree in code
  brackets; author Andre Bremer).
- Shipped icons (named by app-id, installed by the manifest into
  `/app/share/icons/hicolor/…`):
  - `data/icons/hicolor/scalable/apps/io.github.hyperquader.Yggr.svg` — the
    colour app icon (librsvg renders SVG at any size; this alone satisfies
    GNOME/Mint and Flathub).
  - `data/icons/hicolor/symbolic/apps/io.github.hyperquader.Yggr-symbolic.svg`
    — monochrome variant for symbolic contexts.
  - PNG sizes (48–512) are rasterized best-effort at build time **iff**
    `rsvg-convert` is in the SDK; the SVG is authoritative.
- Regenerate/verify PNGs locally with `librsvg2-bin`:
  `rsvg-convert -w 256 -h 256 data/icons/hicolor/scalable/apps/io.github.hyperquader.Yggr.svg -o /tmp/yggr-256.png`.
- The icon `id`/filename MUST equal the app-id; keep them in lockstep if the
  app-id ever changes.

## §6 Known constraints & notes

- **No Foundry inside the flatpak.** Bundling Foundry means building its
  full stack (libdex, libpeas, template-glib) in the manifest; the
  registry file replaces it in-sandbox. On the host, Foundry remains the
  step-3 fallback. Revisit only if container-aware server execution is
  wanted inside the sandbox.
- **Bundled Odin toolchain + OLS diagnostics (working).** The flatpak ships a
  runnable Odin compiler so OLS (which diagnoses by shelling out to
  `odin check`) works in-sandbox — yggr doubles as a batteries-included Odin
  playground. What makes it work (all verified offscreen — a red squiggle on a
  deliberate type error):
  1. Keep the whole toolchain at `/app/opt/odin` (compiler + `core`/`base`/
     `vendor`); cleanup strips only cross-platform binaries (`*.dll`/`*.lib`/
     `*.dylib`/`*.a`). Odin refuses to start if `ODIN_ROOT` lacks the `vendor`
     collection, so vendor must stay.
  2. The `libLLVM` the compiler links (rpath `$ORIGIN` = `/app/opt/odin`)
     arrives with the extension, in the same directory — which is why copying
     that directory is enough and this manifest handles no libLLVM of its own.
     Symlink `/app/bin/odin`.
  3. `--env=ODIN_ROOT=/app/opt/odin` so OLS resolves `core:`/`base:`.
  4. Install OLS's `builtin/` **next to the ols binary** (`/app/bin/builtin`) —
     OLS logs `Failed to find the builtin folder at /app/bin/builtin` and can't
     analyze otherwise.
  5. yggr sends `workspaceFolders` in `initialize` and a `textDocument/didSave`
     after `didOpen` (OLS activates its project from workspaceFolders and only
     runs the checker on save) — see `src/lsp/client.odin`, `editor.odin`.
  Diagnostics refresh on open and on **Ctrl+S** (yggr writes the buffer then
  sends `didSave`, re-running `odin check`). True live-on-keystroke isn't
  possible with OLS (it's save-based, not incremental) — that's an OLS design
  choice, not a yggr limit; live-typing servers like gopls diagnose on
  `didChange` (which yggr already sends).
- **marksman** is a .NET-AOT native binary; if it aborts on ICU lookup in
  the sandbox, export `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` in a
  wrapper — expected unnecessary on the GNOME runtime.
- **aarch64:** add `only-arches` variants of the ols/marksman modules
  with the arm64 assets and their checksums; everything else is
  arch-neutral.
- **LLVM targets.** The llvm extension builds only
  `X86 AMDGPU ARM NVPTX WebAssembly` — NOT AArch64 or RISCV — and upstream Odin
  references their target-init symbols unconditionally, so the compiler will not
  link against it. That is handled once, in the extension, by a patched Odin that
  reads `llvm-config --targets-built`; nothing here needs a `sed` any more. See
  SUPPLY-CHAIN.md.
- **clang is still required.** The llvm extension stays in `sdk-extensions` even
  though the compiler is no longer built here: Odin links through `clang`, and
  the freedesktop SDK ships `gcc` but none.
- **App-icon SVG must be sniffable by the gdk-pixbuf SVG loader**, or the
  flatpak-builder finish step (`appstreamcli compose`) fails with
  `file-read-error` / `filters-but-no-output`. The loader detects SVGs by
  finding `<svg` within the first ~128 bytes, so keep the `<svg>` element
  right after the `<?xml?>` line — put attribution/licence in `<metadata>`,
  NOT a long leading XML comment (that pushes `<svg>` past the sniff window).
- **Filesystem access** is `--filesystem=host` for MVP pragmatism. Moving to
  portals, and replacing the last prebuilt blob (marksman) with a
  build-from-source module, are both Flathub submission prerequisites — tracked
  in [`../MoSCoW.md`](../MoSCoW.md).
