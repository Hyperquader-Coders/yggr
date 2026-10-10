# Yggr — LSP editor (Odin + GTK4 + GtkSourceView 5). `make help` lists the targets.
# targets: no deb (yggr ships as a Flatpak only — docs/DECISIONS.md, Packaging)

ODIN      ?= odin
BUILD_DIR := build
PKGS      := gtk4 gtksourceview-5
# Amber LIB (core-only utilities) consumed as the `amber` Odin collection.
# Default demo file — Odin (the flagship: bundled OLS + odin.lang).
FILE      ?= demo/main.odin

APPID            := io.github.hyperquader.Yggr
FLATPAK_MANIFEST := flatpak/$(APPID).yaml
FLATPAK_BUILDDIR := build-flatpak
# Host install prefix — user-local by default (no sudo). Override for a system
# install: `sudo make install PREFIX=/usr`.
PREFIX ?= $(HOME)/.local
DESTDIR ?=
ICON_SIZES := 32 48 64 128 256 512

VERSION  := 0.1.0

BRANCH ?= main
REMOTE ?= origin
ROOT_COMMIT_MSG ?= Initial yggr

.PHONY: check test build run install-lang mo install uninstall check-test-tag \
        flatpak flatpak-run flatpak-remove flatpak-repo flatpak-repo-path \
        check-toolchain diags clean push force-push lint ci help check-no-agent-files

check-toolchain: ## print odin, GTK, foundry and python versions (the default)
	@$(ODIN) version
	@pkg-config --modversion $(PKGS)
	@foundry --version 2>/dev/null || echo "foundry: NOT FOUND (soft — use YGGR_LSP_CMD)"
	@python3 --version

# Type-check and vet the program. The vendored OLS package (src/lsp/vendor_ols) is
# type-checked but not vetted: it is upstream's code, kept as upstream wrote it.
check: check-test-tag ## type-check and vet the program
	$(ODIN) check src -vet -vet-packages:main,lsp,markup,paths,ui

# Acceptance criterion 1: passes with no GTK installed. odin test tracks every
# test's allocations, so a leak or bad free fails the run; -debug adds the
# debug checks.
test: check-test-tag ## headless tests: LSP core and hover markup (no GTK needed)
	@mkdir -p $(BUILD_DIR)
	$(ODIN) test src/lsp -debug -out:$(BUILD_DIR)/lsp_test
	$(ODIN) test src/markup -debug -out:$(BUILD_DIR)/markup_test
	$(ODIN) test src/paths -debug -out:$(BUILD_DIR)/paths_test

$(BUILD_DIR)/shim.o: src/ui/shim.c
	@mkdir -p $(BUILD_DIR)
	gcc -c $< -o $@ $$(pkg-config --cflags $(PKGS))

# Applies to every build, host and flatpak alike, so the flag belongs here rather
# than on a release target: Source_Code_Location otherwise carries the absolute
# path of every assert site. `filename` keeps basename, proc, line and column.
build: $(BUILD_DIR)/shim.o ## build build/yggr
	$(ODIN) build src -source-code-locations:filename -out:$(BUILD_DIR)/yggr \
		-extra-linker-flags:"$(BUILD_DIR)/shim.o $$(pkg-config --libs $(PKGS))"

run: build ## run yggr on FILE (default demo/main.odin)
	$(BUILD_DIR)/yggr $(FILE)

# Install the bundled Odin GtkSourceView spec for the current user so .odin
# files highlight + get language-id "odin" on the HOST (the Flatpak bundles it
# automatically). Run once: `make install-lang`.
install-lang: ## install odin.lang for this user's GtkSourceView
	@mkdir -p $(HOME)/.local/share/gtksourceview-5/language-specs
	install -m644 data/language-specs/odin.lang \
		$(HOME)/.local/share/gtksourceview-5/language-specs/odin.lang
	@echo "installed odin.lang -> $(HOME)/.local/share/gtksourceview-5/language-specs/"

# Compile gettext catalogs (po/*.po -> data/locale/<lang>/LC_MESSAGES/yggr.mo).
mo: ## compile the gettext catalogs
	@mkdir -p data/locale/de/LC_MESSAGES
	msgfmt --check po/de.po -o data/locale/de/LC_MESSAGES/yggr.mo

# ---- host install (no flatpak) — desktop integration under $(PREFIX) --------
install: build mo ## install under PREFIX (default ~/.local)
	install -Dm755 $(BUILD_DIR)/yggr $(DESTDIR)$(PREFIX)/bin/yggr
	install -Dm644 data/$(APPID).desktop $(DESTDIR)$(PREFIX)/share/applications/$(APPID).desktop
	install -Dm644 data/$(APPID).metainfo.xml $(DESTDIR)$(PREFIX)/share/metainfo/$(APPID).metainfo.xml
	install -Dm644 data/language-specs/odin.lang $(DESTDIR)$(PREFIX)/share/gtksourceview-5/language-specs/odin.lang
	install -Dm644 data/locale/de/LC_MESSAGES/yggr.mo $(DESTDIR)$(PREFIX)/share/locale/de/LC_MESSAGES/yggr.mo
	install -Dm644 data/icons/hicolor/scalable/apps/$(APPID).svg $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/$(APPID).svg
	install -Dm644 data/icons/hicolor/symbolic/apps/$(APPID)-symbolic.svg $(DESTDIR)$(PREFIX)/share/icons/hicolor/symbolic/apps/$(APPID)-symbolic.svg
	@for s in $(ICON_SIZES); do install -Dm644 data/icons/hicolor/$${s}x$${s}/apps/$(APPID).png $(DESTDIR)$(PREFIX)/share/icons/hicolor/$${s}x$${s}/apps/$(APPID).png; done
	-gtk-update-icon-cache -qtf $(DESTDIR)$(PREFIX)/share/icons/hicolor 2>/dev/null || true
	-update-desktop-database $(DESTDIR)$(PREFIX)/share/applications 2>/dev/null || true
	@echo "installed to $(PREFIX). Odin/German highlighting + locale come from there;"
	@echo "for LSP set YGGR_LSP_CMD or install foundry (host has no bundled servers)."

uninstall: ## remove what install put under PREFIX
	rm -f $(DESTDIR)$(PREFIX)/bin/yggr
	rm -f $(DESTDIR)$(PREFIX)/share/applications/$(APPID).desktop
	rm -f $(DESTDIR)$(PREFIX)/share/metainfo/$(APPID).metainfo.xml
	rm -f $(DESTDIR)$(PREFIX)/share/gtksourceview-5/language-specs/odin.lang
	rm -f $(DESTDIR)$(PREFIX)/share/locale/de/LC_MESSAGES/yggr.mo
	rm -f $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/$(APPID).svg
	rm -f $(DESTDIR)$(PREFIX)/share/icons/hicolor/symbolic/apps/$(APPID)-symbolic.svg
	@for s in $(ICON_SIZES); do rm -f $(DESTDIR)$(PREFIX)/share/icons/hicolor/$${s}x$${s}/apps/$(APPID).png; done

# ---- flatpak (bundles the language servers; docs/FLATPAK.md) ----------------
flatpak: ## build and install the Flatpak for this user
	flatpak-builder --user --install --force-clean $(FLATPAK_BUILDDIR) $(FLATPAK_MANIFEST)

flatpak-run: ## run the installed Flatpak on FILE
	flatpak run $(APPID) $(FILE)

# The sibling contract amberlinux-flatpak's `make add-suite` calls, mirroring
# odin-sdk-extension and the apt archive's `make deb-path`: answer with the
# ostree repo this build produced, so the archive never hardcodes another
# repo's output layout. `make flatpak` installs; `repo` builds into a repo an
# archive can pull from. Needs the odin SDK extension installed — the manifest
# declares it in sdk-extensions.
REPO_DIR := repo

flatpak-repo-path: ## print the path of the ostree repo 'make flatpak-repo' built
	@test -d $(REPO_DIR) || { \
		echo "no repo at $(CURDIR)/$(REPO_DIR) — run 'make flatpak-repo' first" >&2; \
		exit 2; }
	@echo "$(CURDIR)/$(REPO_DIR)"

flatpak-repo: ## build the Flatpak into an ostree repo
	flatpak-builder --user --force-clean --disable-rofiles-fuse \
		--repo=$(REPO_DIR) $(FLATPAK_BUILDDIR) $(FLATPAK_MANIFEST)
	@echo "repo at $(CURDIR)/$(REPO_DIR)"

flatpak-remove: ## uninstall the Flatpak and remove its build tree
	-flatpak uninstall --user -y $(APPID)
	rm -rf $(FLATPAK_BUILDDIR) .flatpak-builder

diags: ## render diags/*.d2 to SVG
	@for f in diags/*.d2; do d2 "$$f" "$${f%.d2}.svg"; done

ci: check test lint check-no-agent-files ## everything a push must pass

clean: ## remove build/, build-flatpak/ and repo/
	rm -rf $(BUILD_DIR) $(FLATPAK_BUILDDIR) $(REPO_DIR)

push: ## push main to origin
	git push "$(REMOTE)" "$(BRANCH)"

# Rewrite the whole tree as one signed root commit and force-push it. The suite's
# repos carry no history until the first official release.
# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added — a stray
# path simply appears in the root commit as though it always belonged.
check-no-agent-files: ## refuse agent files that are tracked or not ignored
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored — 'git add -A' would publish it"; \
			echo "fix: add $$p to .gitignore"; \
			exit 2; \
		fi; \
	done
	@echo "no agent files staged for publication"

force-push: test check-no-agent-files ## rewrite history as one signed root commit and force-push
	@test -z "$$(git status --porcelain)" || { \
		echo "Working tree is dirty. Commit, stash, or revert changes first."; \
		exit 2; \
	}
	@set -e; \
	orig_branch="$$(git branch --show-current)"; \
	test -n "$$orig_branch" || { echo "force-push: detached HEAD, check out a branch first"; exit 1; }; \
	tmp_branch="root-squash-$$(date +%s)"; \
	step="starting"; ok=0; \
	trap 'if [ "$$ok" != 1 ]; then echo "force-push FAILED while: $$step. Local history is intact on $$orig_branch; $(REMOTE)/$(BRANCH) was not replaced." >&2; git checkout -f "$$orig_branch" >/dev/null 2>&1 || true; git branch -D "$$tmp_branch" >/dev/null 2>&1 || true; exit 1; fi' EXIT; \
	step="creating the orphan branch"; git checkout --orphan "$$tmp_branch"; \
	step="staging the tree"; git add -A; \
	step="signing the root commit"; git commit -S -m "$(ROOT_COMMIT_MSG)"; \
	step="pushing to $(REMOTE)/$(BRANCH) (refused or unreachable)"; git push --force "$(REMOTE)" "$$tmp_branch:$(BRANCH)"; \
	step="verifying $(REMOTE)/$(BRANCH) equals the new commit"; \
	remote_sha="$$(git ls-remote "$(REMOTE)" "refs/heads/$(BRANCH)" | cut -f1)"; \
	test -n "$$remote_sha" && test "$$remote_sha" = "$$(git rev-parse HEAD)"; \
	ok=1; \
	git branch -M "$$tmp_branch" "$(BRANCH)"; \
	git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null 2>&1 || { git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 && git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null; } || echo "warning: could not set upstream"; \
	echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."

lint: ## shellcheck any shell scripts
	@if command -v shellcheck >/dev/null; then \
		git ls-files | while read -r f; do \
			case "$$f" in *.sh|*.bash) echo "$$f";; \
			*) head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh' && echo "$$f";; esac; \
		done | xargs -r shellcheck --severity=warning && echo "shellcheck OK"; \
	else echo "shellcheck not installed — skipping (apt install shellcheck)"; fi

# `odin build` compiles a package's _test.odin files like any other file unless they
# start with #+test, so a test's imports and @(init) procs would ship in every program
# that imports the package. Files under tests/ are test programs and suites that no
# program imports.
check-test-tag:
	@bad=$$(git ls-files --cached --others --exclude-standard '*_test.odin' | grep -Ev '(^|/)tests/' | xargs -r grep -L '^#+test' || true); \
	if [ -n "$$bad" ]; then \
		echo "test files without #+test, which odin build compiles into programs:"; \
		printf '  %s\n' $$bad; \
		exit 2; \
	fi

help: ## this list
	@awk 'BEGIN {FS = ":.*## "} \
	    /^##@ / {printf "\n%s\n", substr($$0, 5)} \
	    /^[a-z][a-z0-9-]*:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
