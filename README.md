# Yggr — the yaggr editor

> **Yggr is a test bed, not a product.** It proves two things before they reach
> anything that matters: editor features bound for kat800, and the machinery for
> shipping Odin software.
>
> **The editor.** kat800 has a built-in editor, and editor features are awkward
> to develop inside a terminal emulator: every change means rebuilding and
> driving the whole app to reach one pane. Yggr is that editor pulled out into a
> standalone GTK4 window, so a feature can be prototyped against a real buffer in
> seconds. LSP is the worked example — diagnostics, hover, completion and
> formatting are proven here first, then folded back into kat800.
>
> **The packaging.** Shipping Odin as a Flatpak means building the compiler
> inside a build sandbox, against whichever LLVM the SDK provides, with the
> language servers bundled and no host toolchain to lean on. Yggr is the smallest
> real application that exercises all of it, so the Flatpak manifest, the release
> workflow and the Odin SDK extension work are proven against a program someone
> actually runs rather than a contrived sample.
>
> Treat everything below as a proving ground. It is not a general-purpose editor,
> it is not competing with GNOME Text Editor or Builder, and nobody should be
> asked to adopt it. What works here graduates: editor features to kat800,
> packaging to the suite.

A small GTK4 / GtkSourceView 5 code editor written in **Odin**, with Language
Server Protocol support. Language servers are not spawned directly: Yggr shells
out to the **Foundry CLI** (`foundry lsp run <language>`) on the host, or to a
bundled registry of servers inside its Flatpak — the same client model as
Neovim's built-in `vim.lsp`.

App id `io.github.hyperquader.Yggr`; binary `yggr`.

## Features

- **Diagnostics** — severity squiggles + gutter marks (`textDocument/publishDiagnostics`)
- **Hover** — markdown docs rendered as Pango markup
- **Completion** — server proposals with `textEdit` application and trigger characters
- **Formatting** — whole-document `textDocument/formatting` on Ctrl+Shift+F
- **Save** — Ctrl+S writes the buffer to disk and sends `didSave`, which
  re-triggers diagnostics on check-on-save servers (e.g. OLS)

The LSP client core (`src/lsp/`) is pure Odin and imports no GTK, so it is
testable headless. The GTK layer (`src/ui/`) consumes it and paints results
onto GtkSourceView.

## Layout

```
src/lsp/            LSP client core — NO GTK, headless-testable
  transport.odin    subprocess spawn + shutdown; framing via vendor_ols
  client.odin       initialize/lifecycle, request correlation, doc versions
  protocol.odin     typed LSP message + capability structs
  encoding.odin     utf16 <-> utf8 line-offset conversion
  edits.odin        TextEdit ordering + pure-Odin apply (shared w/ formatting)
  registry.odin     server resolution: YGGR_LSP_CMD -> lsp-servers.conf -> foundry
  vendor_ols/       framing + JSON marshaller + uri, adapted from OLS (see THIRD_PARTY.md)
src/ui/             GTK main-thread layer
  editor.odin       window + GtkSourceView, client lifecycle, debounced didChange, Ctrl+Shift+F
  diagnostics.odin  publishDiagnostics -> tags + gutter marks
  providers.odin    hover + completion providers (markdown->Pango, proposal store)
  format.odin       formatting: reverse-order TextEdits, one undo group
  i18n.odin         gettext catalog lookup for the UI strings
  gtk_bindings.odin hand-rolled foreign decls (verified vs installed headers)
  shim.c            GObject ceremony: KatProvider (both interfaces) + KatProposal
src/main.odin       entry point -> ui.run
docs/               SPEC, ARCHITECTURE, DECISIONS, TOOLCHAIN, FLATPAK, SUPPLY-CHAIN
diags/              D2 sources + rendered SVGs
MoSCoW.md           scope + what's left
```

[`MoSCoW.md`](MoSCoW.md) is the honest list of what is left.

See `docs/ARCHITECTURE.md` for the design and `diags/` for D2 diagrams of
the layering, threading model, and LSP lifecycle — plus the Flatpak bundle
anatomy and the OLS→compiler diagnostics chain (see Packaging below).

[`docs/SUPPLY-CHAIN.md`](docs/SUPPLY-CHAIN.md) answers the question the packaging
raises: **why four repositories exist to compile one editor.** A Flatpak build
sandbox reaches nothing on the host, so an Odin application has no compiler
unless one is built inside — which produced a patched compiler, an SDK extension
that builds it once, an archive to publish it from, and yggr consuming the lot.
It also says what retires each link: upstreaming the compiler patch, and Flathub.

## Build & run

Prerequisites: `odin` (dev nightly), `gtk4`, `gtksourceview-5` (≥ 5.10),
`gcc`, and the **`amber`** Odin collection (core-only path/fs utilities) as a
sibling checkout:

```sh
git clone https://github.com/Hyperquader-Coders/amber-lib ../amber-lib   # or set AMBER=/path
make check-toolchain
make test                # headless LSP core (no GTK / amber needed)
make build               # -> build/yggr  (compiles shim.c, links GTK + amber)
make install-lang        # once: install odin.lang so .odin highlights on the host
make run                 # opens demo/main.odin (default); or: make run FILE=<path>
```

`demo/main.odin` is the default example (Odin is the flagship language — the
Flatpak bundles the OLS server + `odin.lang`). It carries a deliberate type
error, so diagnostics appear on open without an edit. A Go sample lives at
`demo/main.go`.

Language servers are obtained via Foundry (`foundry lsp run <gtksourceview-lang-id>`).
For testing without Foundry, override the whole command line:

```sh
YGGR_LSP_CMD="python3 $(pwd)/scripts/fake_lsp.py" make run FILE=demo/main.odin
```

`scripts/fake_lsp.py` is a stdlib-only LSP server that answers
initialize/hover/completion/formatting and emits one canned diagnostic — used
by the headless tests and for driving the UI without a real server.

Environment overrides: `YGGR_LSP_CMD` (whole command line), `YGGR_FOUNDRY_BIN`
(path to `foundry`), `YGGR_LSP_TRACE=1` (dump every JSON-RPC frame to stderr).

## Packaging (Flatpak)

Yggr ships as a Flatpak (`io.github.hyperquader.Yggr`, GNOME 50 runtime) that
bundles its language servers **and a runnable Odin toolchain**, so LSP works
with zero host setup — and yggr doubles as a batteries-included Odin playground
for newcomers.

It is also the first consumer of the
[Odin SDK extension](https://github.com/Hyperquader-Coders/odin-sdk-extension):
the build adds the `amberlinux` flatpak remote and declares the extension in
`sdk-extensions`, exactly as any third party would. That is deliberate — an
extension nobody consumes is untested, and yggr is the smallest real application
that exercises the whole path.

What lands in the image:

- **Bundled Odin toolchain** at `/app/opt/odin` — the `odin` binary, its
  `libLLVM`, and the full `core`/`base`/`vendor` collections (`ODIN_ROOT` points
  here). Copied in from
  [`org.freedesktop.Sdk.Extension.odin`](https://github.com/Hyperquader-Coders/odin-sdk-extension),
  which yggr installs from `flatpak.amberlinux.org` at build time rather than
  compiling a compiler itself. The extension is build-time only, so the copy is
  what survives into the image — see [`docs/SUPPLY-CHAIN.md`](docs/SUPPLY-CHAIN.md).
- **OLS** (Odin LSP) + `odinfmt` at `/app/bin`, with OLS's `builtin/` docs
  folder placed beside the binary. OLS has no type checker of its own — it
  **shells out to `odin check`** — which is the whole reason the compiler is
  bundled. Diagnostics refresh on open and on **Ctrl+S** (check-on-save).
- **marksman** (Markdown LSP), and a `lsp-servers.conf` registry that replaces
  Foundry inside the sandbox (three-step server resolution: `YGGR_LSP_CMD` →
  registry → `foundry`).
- German UI catalog, hicolor icons, `.desktop` + metainfo. Input uses GTK's
  simple IM module (`GTK_IM_MODULE=gtk-im-context-simple`) to sidestep a
  host-IBus/runtime D-Bus skew on Ubuntu 24.04 / Mint 22.

```sh
make flatpak          # flatpak-builder --user --install --force-clean
make flatpak-run      # flatpak run … demo/main.odin
make flatpak-remove
make repo             # build into an ostree repo an archive can pull from
make flatpak-repo     # answer with that repo's path — the contract
                      # amberlinux-flatpak's `make add-suite` calls
```

### Installing

yggr publishes on the `stable` branch of the suite's flatpak archive:

```sh
flatpak remote-add --if-not-exists --user amberlinux \
    https://flatpak.amberlinux.org/amberlinux.flatpakrepo
flatpak install --user amberlinux io.github.hyperquader.Yggr
flatpak run io.github.hyperquader.Yggr <file>
```

A `v*` tag also builds the bundle in CI and attaches it to a GitHub release,
for a machine that should not add a remote:

```sh
flatpak install --user ./yggr-<tag>-x86_64.flatpak
```

The GNOME 50 runtime is pulled from Flathub if it is not already present. Servers
and toolchain are inside the bundle, so there is no host setup.

See `docs/FLATPAK.md` for the packaging spec and `diags/flatpak-bundle.d2`
+ `diags/ols-diagnostics.d2` for the bundle anatomy and the OLS→compiler
diagnostics chain.

## Vendored / referenced code

- **`third_party/ols/` + `src/lsp/vendor_ols/`** — framing, JSON marshalling
  and URI helpers adapted from [OLS](https://github.com/DanielGavin/ols) (MIT).
  See `THIRD_PARTY.md`. Do not edit `third_party/`.
- **`amber` collection** — [amber-lib](https://github.com/Hyperquader-Coders/amber-lib),
  Go-shaped core-only utilities (`afs` for lexical path/URI handling).

Design cross-checks (reference reading, not dependencies): GNOME Builder's
`libide-lsp` (LSP client patterns), GNOME Text Editor and the GtkSourceView 5
source (GTK4/GSV5 provider APIs), and the `odin-gtk` bindings.

## Scope

Scope is whatever proves the next thing, on either track. Anything already proven
graduates — editor features to kat800, packaging to the suite — which is why the
out-of-scope list stays long. Yggr does not owe anyone a complete editor.

**Editor.** The surface is diagnostics, hover, completion and formatting for any
language Foundry can serve. The `src/lsp/` split serves the graduation: it
imports no GTK, so the client core lifts into kat800 without dragging Yggr's
window along.

**Packaging.** What gets proven here is everything between source and an
installable file: building the Odin compiler inside a build sandbox against the
SDK's LLVM, building the language servers from source against that compiler,
bundling a toolchain that OLS can shell out to, and a tagged release that
produces a downloadable bundle. The manifest is documented in
`docs/FLATPAK.md`; the compiler patch it depends on lives in the Odin fork and
is described in [`docs/DECISIONS.md`](docs/DECISIONS.md).

What is out of scope and what is still open both live in
[`MoSCoW.md`](MoSCoW.md), so there is one list to keep honest.

## License

Yggr is licensed **GPL-3.0-or-later** (see `LICENSE`); the application icon
(`data/icons/…`, `data/artwork/`) is covered by the same license.
Copyright © 2026 Andre Bremer &lt;hyperquader@gmail.com&gt;, https://hyperquader.com.
Vendored/consumed third-party code keeps its own licenses (OLS — MIT, `THIRD_PARTY.md`;
the `amber` collection — see amber-lib).
