# Diagrams

[d2](https://d2lang.com) sources with their rendered SVGs committed alongside, so the
diagrams are viewable without d2 installed. Re-render after editing a `.d2`:

```bash
make diags        # or: d2 diags/<name>.d2 diags/<name>.svg
```

**Design** (the editor itself):

| Source | Shows | Doc |
|---|---|---|
| [`architecture.d2`](architecture.d2) | `src/ui` (GTK) over `src/lsp` (headless core) over Foundry/server | ARCHITECTURE §1 |
| [`threading.d2`](threading.d2) | main vs reader thread and the `g_idle_add_full` marshal boundary | ARCHITECTURE §2 |
| [`lsp-lifecycle.d2`](lsp-lifecycle.d2) | spawn → initialize → didOpen → diagnostics → edit → features → shutdown | SPEC §4.1 |

**Packaging** (the Flatpak):

| Source | Shows | Doc |
|---|---|---|
| [`flatpak-bundle.d2`](flatpak-bundle.d2) | what lands in `/app` — bundled Odin toolchain, OLS + `builtin/`, marksman, runtime env; build-time vs runtime split | FLATPAK.md §6 |
| [`ols-diagnostics.d2`](ols-diagnostics.d2) | why OLS needs a runnable compiler: it shells out to `odin check` on `didSave` | FLATPAK.md §6 |
| [`supply-chain.d2`](supply-chain.d2) | why four repos exist to compile one editor — the fork's LLVM patch, the SDK extension, the archive, and yggr consuming it | SUPPLY-CHAIN.md |
