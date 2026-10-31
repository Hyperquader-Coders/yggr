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

# The desk's and CI's build runs on the Amber suite's GTK (amber-gtk4, from apt.amberlinux.org),
# never the distro's libgtk-4-1: the shim compiles against amber-gtk4-dev's headers, the program
# links its libgtk-4 and finds it at run time through its RUNPATH, and scripts/check-own-libs
# (house-rules', copied byte for byte: this repo's CI cannot read house-rules) fails a build or a
# test that loads GTK from anywhere else. The Flatpak builds against the GNOME runtime's GTK
# instead (flatpak/$(APPID).yaml), which is what it runs on.
GTK_BUNDLE_DIR := /usr/lib/amber-gtk4
GTK_PKG_CONFIG := PKG_CONFIG_PATH=$(GTK_BUNDLE_DIR)/pkgconfig pkg-config
CHECK_OWN_LIBS := scripts/check-own-libs --gtk $(GTK_BUNDLE_DIR)

# The suite's names, the same in every Odin repository: ODIN_FLAGS is what every odin command
# here takes, the vet (unused imports and variables, shadowing, `using` statements;
# -strict-style as the suite); ODIN_TEST_FLAGS adds what only a test run takes: a test that
# leaks or frees badly fails, rather than only warning, and the debug checks. There is no COLLECTIONS: the program imports no collection of its own. The vendored
# OLS package (src/lsp/vendor_ols) is type-checked but not vetted, which is what -vet-packages
# says: it is upstream's code, kept as upstream wrote it.
ODIN_FLAGS = -vet -vet-packages:main,gtkenv,lsp,markup,paths,ui -strict-style
ODIN_TEST_FLAGS = $(ODIN_FLAGS) -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -debug

# The system packages, one list for a desk and for CI: the Odin compiler (amber-odin, which
# brings clang) and odinfmt (amber-ols, for `make fmt` and `make check-fmt`), the compiler
# driver, the suite's GTK 4 (amber-gtk4 and its headers, amber-gtk4-dev) and GtkSourceView 5's
# headers `make build` links against, librsvg2-common for the SVG icons GTK draws when yggr
# runs, gettext for `make mo`, python3 for `make check-toolchain`, shellcheck for `make lint`,
# shfmt for `make fmt` and `make check-fmt`.
# amber-* come from apt.amberlinux.org: the README adds it at a desk; on the runner
# setup-amber-odin adds it and installs amber-odin and amber-ols itself, so init-packages finds
# them there. `make init-packages` installs the list; a package missing on the runner is added
# here, and the workflows name none.
DEPS := amber-odin amber-ols gcc pkg-config amber-gtk4 amber-gtk4-dev libgtksourceview-5-dev \
	librsvg2-common gettext python3 shellcheck shfmt
# What only the Flatpak builds need on the host: flatpak and flatpak-builder, git for the ols
# source flatpak-builder clones, librsvg2-common for the SVG icon check `flatpak build-export`
# runs. No elfutils or binutils: the manifest sets no-debuginfo and no strip option, and each
# module strips with the SDK's own strip. `make deps-flatpak` installs it, then the runtime,
# SDK and SDK extensions below; `make flatpak`, `make flatpak-repo` and the release workflow run
# it, `make setup` does not.
FLATPAK_DEPS := flatpak flatpak-builder git librsvg2-common
# The runtime and SDK at the manifest's runtime-version, and its SDK extensions at the
# freedesktop branch that runtime is built on, read from the manifest so the two cannot disagree.
# Each comes from Flathub, but the Odin extension, which flatpak.amberlinux.org publishes.
FLATPAK_RUNTIME_REFS = $(shell awk '/^(runtime|sdk):/ {n[$$1] = $$2} /^runtime-version:/ {v = $$2; gsub(/[\047"]/, "", v)} END {print n["runtime:"] "//" v, n["sdk:"] "//" v}' '$(FLATPAK_MANIFEST)')
FLATPAK_EXTENSIONS = $(shell awk '/^sdk-extensions:/ {on = 1; next} on && /^[a-z]/ {on = 0} on && /^[ \t]*- / {print $$2}' '$(FLATPAK_MANIFEST)')
FLATPAK_SDK_BASE := 26.08
FLATHUB := https://dl.flathub.org/repo/flathub.flatpakrepo
AMBERLINUX_FLATPAK := https://flatpak.amberlinux.org/amberlinux.flatpakrepo

BRANCH ?= main
REMOTE ?= origin
ROOT_COMMIT_MSG ?= Initial yggr

.PHONY: setup init-packages deps-flatpak init-modules init-workstation fmt check-fmt fmt-sh check-fmt-sh lint check test build run install-lang mo install uninstall check-test-tag \
        flatpak check-licences flatpak-run flatpak-remove flatpak-repo flatpak-repo-path \
        check-toolchain diags clean push force-push lint ci help check-no-agent-files

check-toolchain: ## print odin, GTK, foundry and python versions (the default)
	@$(ODIN) version
	@$(GTK_PKG_CONFIG) --modversion $(PKGS)
	@foundry --version 2>/dev/null || echo "foundry: NOT FOUND (soft, use YGGR_LSP_CMD)"
	@python3 --version

check: check-test-tag ## type-check and vet the program
	$(ODIN) check src $(ODIN_FLAGS)

# Acceptance criterion 1: passes with no GTK installed. odin test tracks every
# test's allocations, and ODIN_TEST_FAIL_ON_BAD_MEMORY has a leak or bad free fail the run;
# -debug adds the debug checks.
test: check-test-tag ## headless tests: LSP core, hover markup, paths, the GTK module path (no GTK needed)
	@mkdir -p $(BUILD_DIR)
	$(ODIN) test src/lsp $(ODIN_TEST_FLAGS) -keep-executable -out:$(BUILD_DIR)/lsp_test
	$(ODIN) test src/markup $(ODIN_TEST_FLAGS) -keep-executable -out:$(BUILD_DIR)/markup_test
	$(ODIN) test src/paths $(ODIN_TEST_FLAGS) -keep-executable -out:$(BUILD_DIR)/paths_test
	$(ODIN) test src/gtkenv $(ODIN_TEST_FLAGS) -keep-executable -out:$(BUILD_DIR)/gtkenv_test
	@$(CHECK_OWN_LIBS) $(BUILD_DIR)/lsp_test $(BUILD_DIR)/markup_test $(BUILD_DIR)/paths_test $(BUILD_DIR)/gtkenv_test

$(BUILD_DIR)/shim.o: src/ui/shim.c Makefile
	@mkdir -p $(BUILD_DIR)
	gcc -c $< -o $@ $$($(GTK_PKG_CONFIG) --cflags $(PKGS))

# Applies to every build, host and flatpak alike, so the flag belongs here rather
# than on a release target: Source_Code_Location otherwise carries the absolute
# path of every assert site. `filename` keeps basename, proc, line and column.
build: $(BUILD_DIR)/shim.o ## build build/yggr
	$(ODIN) build src $(ODIN_FLAGS) -source-code-locations:filename -out:$(BUILD_DIR)/yggr \
		-extra-linker-flags:"$(BUILD_DIR)/shim.o $$($(GTK_PKG_CONFIG) --libs $(PKGS)) -Wl,-rpath,$(GTK_BUNDLE_DIR)"
	@$(CHECK_OWN_LIBS) $(BUILD_DIR)/yggr

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
flatpak: deps-flatpak ## build and install the Flatpak for this user
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

flatpak-repo: deps-flatpak ## build the Flatpak into an ostree repo
	flatpak-builder --user --force-clean --disable-rofiles-fuse \
		--repo=$(REPO_DIR) $(FLATPAK_BUILDDIR) $(FLATPAK_MANIFEST)
	@$(MAKE) -s check-licences
	@echo "repo at $(CURDIR)/$(REPO_DIR)"

flatpak-remove: ## uninstall the Flatpak and remove its build tree
	-flatpak uninstall --user -y $(APPID)
	rm -rf $(FLATPAK_BUILDDIR) .flatpak-builder

diags: ## render diags/*.d2 to SVG
	@for f in diags/*.d2; do d2 "$$f" "$${f%.d2}.svg"; done

ci: init-modules lint check-no-agent-files check test build ## everything a push must pass

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
	other_wt="$$(git worktree list --porcelain | awk -v b="branch refs/heads/$(BRANCH)" '/^worktree /{w=substr($$0, 10)} $$0 == b {print w}')"; \
	if [ -n "$$other_wt" ] && [ "$$other_wt" != "$$(git rev-parse --show-toplevel)" ]; then \
		git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 || true; \
		git checkout -q --detach; git branch -D "$$tmp_branch" >/dev/null; \
		echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."; \
		echo "$(BRANCH) is checked out in $$other_wt; once it is clean: git -C $$other_wt fetch && git -C $$other_wt reset --keep $(REMOTE)/$(BRANCH)"; \
	else \
		git branch -M "$$tmp_branch" "$(BRANCH)"; \
		git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null 2>&1 || { git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 && git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null; } || echo "warning: could not set upstream"; \
		echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."; \
	fi

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

# odinfmt comes with amber-ols; its settings are odinfmt.json, a copy of house-rules'. odin-fmt
# formats until the output settles, and refuses a file whose comments odinfmt would damage.
# third_party/ is other repositories' code, vendored as it was taken.
# house-rules holds odin-fmt, in the folder HOUSE_ROOT names (mise sets it on a development
# machine). It is private, so a clone outside the house and the public runner go without it:
# there `make fmt` runs odinfmt itself, each file until a pass changes nothing, which leaves it
# as `make check-fmt` wants it, but without odin-fmt's guard against comments odinfmt moves.
HOUSE ?= $(HOUSE_ROOT)/house-rules
ODINFMT ?= odinfmt
ODIN_FMT ?= $(HOUSE)/scripts/odin-fmt
ODIN_SOURCES = git ls-files --cached --others --exclude-standard '*.odin' ':!third_party'
fmt: ## format the Odin code in place
	@if [ -x '$(ODIN_FMT)' ]; then $(ODIN_SOURCES) | ODINFMT=$(ODINFMT) $(ODIN_FMT); exit $$?; fi; \
	echo "fmt: no odin-fmt at $(ODIN_FMT), so $(ODINFMT) alone (comments it moves are not checked)"; \
	tmp=$$(mktemp) || exit 1; trap 'rm -f "$$tmp"' EXIT; bad=0; \
	for f in $$($(ODIN_SOURCES)); do \
		n=0; \
		while :; do \
			$(ODINFMT) -stdin < "$$f" > "$$tmp" || { echo "odinfmt failed: $$f"; bad=1; break; }; \
			cmp -s "$$tmp" "$$f" && break; \
			n=$$((n + 1)); [ $$n -le 5 ] || { echo "odinfmt's output still changes: $$f"; bad=1; break; }; \
			cat "$$tmp" > "$$f"; \
		done; \
	done; \
	exit $$bad

check-fmt: ## fail when an Odin file is not as make fmt leaves it
	@if ! command -v $(ODINFMT) >/dev/null; then if [ "$$GITHUB_ACTIONS" = true ]; then echo "odinfmt is not installed on this runner; the workflow asks for it (ols: true)"; exit 1; fi; echo "odinfmt not installed, skipping (apt install amber-ols)"; exit 0; fi; \
	bad=0; \
	for f in $$($(ODIN_SOURCES)); do \
		$(ODINFMT) -stdin < "$$f" | cmp -s - "$$f" || { echo "not formatted: $$f"; bad=1; }; \
	done; \
	if [ $$bad = 1 ]; then echo "fix: make fmt"; exit 1; fi; \
	echo "odinfmt OK"

lint: check-fmt

# Shell scripts are laid out by shfmt (sudo apt install shfmt), with tabs: every tracked file
# that is a shell script by its name or its first line, but third_party/, which is vendored. As in
# house-rules. It needs nothing from house-rules, so a clone outside the house formats the same.
# apt's shfmt, the one a CI runner has, before any other on the PATH: versions differ in layout.
SHFMT ?= $(firstword $(wildcard /usr/bin/shfmt) shfmt)
SHFMT_FLAGS = -i 0
SH_SOURCES = git ls-files -z --cached --others --exclude-standard -- . ':!third_party' | grep -zv '/$$' | xargs -0 -r $(SHFMT) -f
fmt-sh: ## lay the shell scripts out in place
	@$(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -w

check-fmt-sh: ## fail when a shell script is not as make fmt-sh leaves it
	@if ! command -v $(SHFMT) >/dev/null; then \
		if [ "$$GITHUB_ACTIONS" = true ]; then echo "shfmt is not installed on this runner; the workflow installs it (init-packages)"; exit 1; fi; \
		echo "shfmt not installed, skipping (sudo apt install shfmt)"; exit 0; \
	fi; \
	bad=$$($(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -l 2>&1) || true; \
	if [ -n "$$bad" ]; then echo "not formatted:"; echo "$$bad"; echo "fix: make fmt"; exit 1; fi; \
	echo "shfmt OK"

fmt: fmt-sh
check-fmt: check-fmt-sh

# `make init-packages` installs DEPS, the list above, asking apt only for what dpkg does not
# report as installed. CI runs `sudo apt-get update && make init-packages APT_FLAGS=-y`; at a
# desk apt asks before it installs.
APT_FLAGS ?=

# $(call apt-install,list): install what of the list dpkg does not report as installed.
apt-install = @missing=$$(for p in $(1); do \
		dpkg-query -W -f='$${db:Status-Status}' "$$p" 2>/dev/null | grep -qx installed || echo "$$p"; \
	done); \
	if [ -z "$$missing" ]; then echo "$@: all $(words $(1)) packages present"; \
	else sudo apt-get install $(APT_FLAGS) --no-install-recommends $$missing; fi

init-packages: ## install the system packages (sudo apt)
	$(call apt-install,$(DEPS))

# FLATPAK_DEPS as init-packages installs DEPS, then each runtime and extension no installation
# has yet, for this user, adding its remote first.
deps-flatpak: ## install what the Flatpak builds need: the host's tools (sudo apt), then the runtime, SDK and extensions for this user
	$(call apt-install,$(FLATPAK_DEPS))
	@for ref in $(FLATPAK_RUNTIME_REFS) $(addsuffix //$(FLATPAK_SDK_BASE),$(FLATPAK_EXTENSIONS)); do \
		if flatpak info "$$ref" >/dev/null 2>&1; then echo "$@: have $$ref"; continue; fi; \
		case $$ref in \
		org.freedesktop.Sdk.Extension.odin//*) remote=amberlinux url=$(AMBERLINUX_FLATPAK) ;; \
		*) remote=flathub url=$(FLATHUB) ;; \
		esac; \
		flatpak remote-add --user --if-not-exists "$$remote" "$$url" || exit 1; \
		flatpak install --user --noninteractive "$$remote" "$$ref" || exit 1; \
	done

# No language packages: the program imports no collection, and third_party/ is vendored. `ci`
# depends on it all the same, as in every repository.
init-modules: ## install the language packages from the lock: none here

init-workstation: check-toolchain ## set up a desk: the toolchain report

# The one command after a fresh clone, the same in every repository.
setup: init-packages init-modules init-workstation ## everything a fresh clone needs: packages (sudo apt), the toolchain report
