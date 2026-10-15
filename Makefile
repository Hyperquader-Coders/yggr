# Yggr, the LSP editor (Odin + GTK4 + GtkSourceView 5). `make help` lists the targets.
# targets: no deb (yggr ships as a Flatpak only; see docs/DECISIONS.md, Packaging)

ODIN      ?= odin
BUILD_DIR := build
PKGS      := gtk4 gtksourceview-5
# Amber LIB (core-only utilities) consumed as the `amber` Odin collection.
# Default demo file: Odin (the flagship: bundled OLS + odin.lang).
FILE      ?= demo/main.odin

APPID            := com.hyperquader.Yggr
FLATPAK_MANIFEST := flatpak/$(APPID).yaml
FLATPAK_BUILDDIR := build-flatpak
# Host install prefix: user-local by default (no sudo). Override for a system
# install: `sudo make install PREFIX=/usr`.
PREFIX ?= $(HOME)/.local
DESTDIR ?=
ICON_SIZES := 32 48 64 128 256 512

VERSION  := 0.1.0

# The suite's names, the same in every Odin repository: ODIN_FLAGS is what every odin command
# here takes, the vet (unused imports and variables, shadowing, `using` statements;
# -strict-style as the suite); ODIN_TEST_FLAGS adds what only a test run takes: a test that
# leaks or frees badly fails, rather than only warning, and the debug checks. There is no COLLECTIONS: the program imports no collection of its own. The vendored
# OLS package (src/lsp/vendor_ols) is type-checked but not vetted, which is what -vet-packages
# says: it is upstream's code, kept as upstream wrote it.
ODIN_FLAGS = -vet -vet-packages:main,lsp,markup,paths,ui -strict-style
ODIN_TEST_FLAGS = $(ODIN_FLAGS) -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -debug

# The system packages, one list for a desk and for CI: the compiler driver and GTK 4 and
# GtkSourceView 5 headers `make build` links against, gettext for `make mo`, python3 for
# `make check-toolchain`, shellcheck for `make lint`, and what the Flatpak builds need on the
# host (flatpak-builder, elfutils for its strip step, librsvg2-common for the SVG icon check
# `flatpak build-export` runs). `make deps` installs it; a package missing on the runner is
# added here, and the workflows name none.
DEPS := gcc pkg-config libgtk-4-dev libgtksourceview-5-dev gettext python3 shellcheck \
	flatpak flatpak-builder elfutils librsvg2-common

BRANCH ?= main
REMOTE ?= origin
ROOT_COMMIT_MSG ?= Initial yggr

.PHONY: deps fmt check-fmt lint check test build run install-lang mo install uninstall check-test-tag \
        flatpak check-licences flatpak-run flatpak-remove flatpak-repo flatpak-repo-path \
        check-toolchain diags clean push force-push lint ci help check-no-agent-files

check-toolchain: ## print odin, GTK, foundry and python versions (the default)
	@$(ODIN) version
	@pkg-config --modversion $(PKGS)
	@foundry --version 2>/dev/null || echo "foundry: NOT FOUND (soft, use YGGR_LSP_CMD)"
	@python3 --version

check: check-test-tag ## type-check and vet the program
	$(ODIN) check src $(ODIN_FLAGS)

# Acceptance criterion 1: passes with no GTK installed. odin test tracks every
# test's allocations, and ODIN_TEST_FAIL_ON_BAD_MEMORY has a leak or bad free fail the run;
# -debug adds the debug checks.
test: check-test-tag ## headless tests: LSP core and hover markup (no GTK needed)
	@mkdir -p $(BUILD_DIR)
	$(ODIN) test src/lsp $(ODIN_TEST_FLAGS) -out:$(BUILD_DIR)/lsp_test
	$(ODIN) test src/markup $(ODIN_TEST_FLAGS) -out:$(BUILD_DIR)/markup_test
	$(ODIN) test src/paths $(ODIN_TEST_FLAGS) -out:$(BUILD_DIR)/paths_test

$(BUILD_DIR)/shim.o: src/ui/shim.c
	@mkdir -p $(BUILD_DIR)
	gcc -c $< -o $@ $$(pkg-config --cflags $(PKGS))

# Applies to every build, host and flatpak alike, so the flag belongs here rather
# than on a release target: Source_Code_Location otherwise carries the absolute
# path of every assert site. `filename` keeps basename, proc, line and column.
build: $(BUILD_DIR)/shim.o ## build build/yggr
	$(ODIN) build src $(ODIN_FLAGS) -source-code-locations:filename -out:$(BUILD_DIR)/yggr \
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

# ---- host install (no flatpak): desktop integration under $(PREFIX) --------
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
	@$(MAKE) -s check-licences

# The licence texts the bundle ships, under /app/share/licenses/<component>/: yggr's own and
# those of the code compiled into it, then each program it carries (the Odin compiler with the
# utf8proc code compiled into it, libLLVM, OLS and odinfmt, marksman). Both flatpak builds run
# this on the tree they made.
LICENCES := yggr/LICENSE yggr/THIRD_PARTY.md yggr/amber-json-LICENSE yggr/odin-core-json-LICENSE \
	odin/LICENSE utf8proc/LICENSE.md llvm/LICENSE.TXT ols/LICENSE marksman/LICENSE

check-licences: ## fail when the built Flatpak tree lacks a licence text
	@missing=0; \
	for f in $(LICENCES); do \
		test -s "$(FLATPAK_BUILDDIR)/files/share/licenses/$$f" || { echo "missing licence: /app/share/licenses/$$f"; missing=1; }; \
	done; \
	test $$missing = 0 && echo "licences OK: $(words $(LICENCES)) texts"

flatpak-run: ## run the installed Flatpak on FILE
	flatpak run $(APPID) $(FILE)

# The sibling contract amberlinux-flatpak's `make add-suite` calls, mirroring
# odin-sdk-extension and the apt archive's `make deb-path`: answer with the
# ostree repo this build produced, so the archive never hardcodes another
# repo's output layout. `make flatpak` installs; `repo` builds into a repo an
# archive can pull from. Needs the odin SDK extension installed: the manifest
# declares it in sdk-extensions.
REPO_DIR := repo

flatpak-repo-path: ## print the path of the ostree repo 'make flatpak-repo' built
	@test -d $(REPO_DIR) || { \
		echo "no repo at $(CURDIR)/$(REPO_DIR); run 'make flatpak-repo' first" >&2; \
		exit 2; }
	@echo "$(CURDIR)/$(REPO_DIR)"

flatpak-repo: ## build the Flatpak into an ostree repo
	flatpak-builder --user --force-clean --disable-rofiles-fuse \
		--repo=$(REPO_DIR) $(FLATPAK_BUILDDIR) $(FLATPAK_MANIFEST)
	@$(MAKE) -s check-licences
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
# checked here, because a squashed history shows no file being added: a stray
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
			echo "$$p exists and is not gitignored, so 'git add -A' would publish it"; \
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
	else echo "shellcheck not installed, skipping (apt install shellcheck)"; fi

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

# odinfmt comes with amber-ols; its settings are odinfmt.json, a copy of amber-house's. odin-fmt
# formats until the output settles, and refuses a file whose comments odinfmt would damage.
# third_party/ is other repositories' code, vendored as it was taken.
ODINFMT ?= odinfmt
ODIN_FMT ?= ../amber-house/scripts/odin-fmt
ODIN_SOURCES = git ls-files --cached --others --exclude-standard '*.odin' ':!third_party'
fmt: ## format the Odin code in place
	@$(ODIN_SOURCES) | ODINFMT=$(ODINFMT) $(ODIN_FMT)

check-fmt: ## fail when an Odin file is not as make fmt leaves it
	@if ! command -v $(ODINFMT) >/dev/null; then if [ "$$GITHUB_ACTIONS" = true ]; then echo "odinfmt is not installed on this runner; the workflow asks for it (ols: true)"; exit 1; fi; echo "odinfmt not installed, skipping (apt install amber-ols)"; exit 0; fi; \
	bad=0; \
	for f in $$($(ODIN_SOURCES)); do \
		$(ODINFMT) -stdin < "$$f" | cmp -s - "$$f" || { echo "not formatted: $$f"; bad=1; }; \
	done; \
	if [ $$bad = 1 ]; then echo "fix: make fmt"; exit 1; fi; \
	echo "odinfmt OK"

lint: check-fmt

# `make deps` installs DEPS, the list above, asking apt only for what dpkg does not report as
# installed. CI runs `sudo apt-get update && make deps APT_FLAGS=-y`; at a desk apt asks before
# it installs.
APT_FLAGS ?=

deps: ## install the system dependencies (sudo apt)
	@missing=$$(for p in $(DEPS); do \
		dpkg-query -W -f='$${db:Status-Status}' "$$p" 2>/dev/null | grep -qx installed || echo "$$p"; \
	done); \
	if [ -z "$$missing" ]; then echo "deps: all $(words $(DEPS)) packages present"; \
	else sudo apt-get install $(APT_FLAGS) --no-install-recommends $$missing; fi

# The one command after a fresh clone, the same in every repository: `deps` first, which CI
# calls on its own; this checkout needs nothing else.
.PHONY: init
init: deps ## everything a fresh clone needs: deps
