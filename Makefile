# neo7.dev
#
# One server, one port. Hugo serves on 8043 - that is the only port the dev
# container forwards. Nothing serves `public/`; it is a build artifact, written
# by whichever of these ran last. `make prod` is the one that writes it the way
# CI does, so re-run that before trusting what is in there.
#

# Run `make` on its own for the annotated list. A `## comment` after a target
# name puts it there; a `##@ heading` starts a group.

.DEFAULT_GOAL := help

# bash rather than sh, with -e so a failing step in a multi-line recipe stops
# the recipe instead of carrying on into a bad state, and -o pipefail so a
# failure on the left of a pipe is not hidden by a zero exit on the right.
# -u is deliberately NOT set: several recipes read optional variables that are
# legitimately empty.
SHELL := /bin/bash
.SHELLFLAGS := -e -o pipefail -c

# ---------------------------------------------------------------- configuration

PORT ?= 8043

# The site's production base URL, used by `prod` and `preview`. Overridable:
# `make prod BASE_URL=https://staging.example.com/`. Keep the trailing slash -
# Hugo joins paths onto it directly. This must stay in step with `baseURL` in
# hugo.yaml and with the --baseURL in .github/workflows/pages.yml.
BASE_URL ?= https://neo7.dev/

# The GitHub account that owns this repository. `gh-auth` compares the
# authenticated login against it, because the host's gh is usually a different
# account and its failure message does not say so.
GH_OWNER ?= neo7dev

# Default base branch for pull requests.
BASE ?= main

# Opt-in destination pruning: `make build CLEAN=1`.
#
# --cleanDestinationDir deletes anything in public/ this build did not produce -
# renamed pages, stale fingerprinted CSS, whatever `make dev` left behind with
# its localhost baseURL. Off by default because it deletes files it did not
# create, so it should be a decision rather than a default.
#
# Different from --gc, which clears the resources/ cache and never touches the
# destination. `make clean` is stricter still: it removes both outright.
CLEAN ?= 0
CLEAN_DEST := $(if $(filter 1 true yes on,$(CLEAN)),--cleanDestinationDir,)

# Colours, but only when stdout is a TTY, so piped output and CI logs stay clean.
ifneq (,$(findstring xterm,$(TERM)))
  BOLD   := $(shell tput bold)
  DIM    := $(shell tput dim)
  RED    := $(shell tput setaf 1)
  GREEN  := $(shell tput setaf 2)
  YELLOW := $(shell tput setaf 3)
  BLUE   := $(shell tput setaf 4)
  RESET  := $(shell tput sgr0)
endif

# Message helpers. Used as `@$(SAY) "text"` rather than `$(call ...)` so that a
# comma inside a message is not parsed as another argument.
SAY  := printf "$(BLUE)==>$(RESET) $(BOLD)%s$(RESET)\n"
OK   := printf "$(GREEN)  ok$(RESET) %s\n"
WARN := printf "$(YELLOW)  !!$(RESET) %s\n"
ERR  := printf "$(RED)  xx$(RESET) %s\n"

# Interactive guard for anything that changes state on GitHub. $(1) is the
# question; keep it free of commas, which `call` would read as another argument.
# YES=1, YES=true and YES=yes bypass it and nothing else does, so a mistyped
# YES=maybe still asks. Without a terminal and without YES it aborts rather than
# blocking on a prompt nobody can answer.
define CONFIRM
	@if [ "$(YES)" = "1" ] || [ "$(YES)" = "true" ] || [ "$(YES)" = "yes" ]; then \
	  $(WARN) "confirmation bypassed - YES=$(YES)"; \
	else \
	  if [ ! -t 0 ]; then \
	    $(WARN) "no terminal to confirm on - pass YES=1 to proceed"; exit 1; \
	  fi; \
	  printf "$(YELLOW)  ??$(RESET) $(BOLD)%s$(RESET) $(DIM)[y/N]$(RESET) " "$(1)"; \
	  read -r reply; \
	  case "$$reply" in [yY]|[yY][eE][sS]) ;; *) $(WARN) "aborted"; exit 1 ;; esac; \
	fi
endef

# ----------------------------------------------------------------------- help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} \
		/^[a-zA-Z_-]+:.*?## / { printf "  $(GREEN)%-16s$(RESET) %s\n", $$1, $$2 } \
		/^##@/ { printf "\n$(BOLD)%s$(RESET)\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Develop

.PHONY: dev
dev: ## Serve on :8043 with live reload, drafts and future posts
	hugo server --disableFastRender -D -F --port $(PORT) --bind 0.0.0.0

# --appendPort=false is required for the baseURL to stay clean; without it the
# server advertises the base URL with the port glued on. The cost is LiveReload:
# Hugo builds the injected websocket URL from the baseURL, so stripping the port
# leaves it empty and auto-refresh stops working. Acceptable here and not on
# `dev` - this target is for inspecting output, not for editing against.
# Blanking the GA4 ID keeps your own previews out of the analytics property.
# Hextra emits gtag.js on `hugo.IsProduction`, which this target deliberately
# sets - so without the override, browsing here is reported as real traffic.
# It is an override, not a different environment: everything else stays exactly
# as production, and the only difference in the output is the googletagmanager
# preconnect and the two gtag scripts. `prod` is left alone, because its whole
# job is to reproduce the CI build byte for byte.
.PHONY: preview
preview: ## Serve on :8043 as production: real baseURL, minified, no drafts, no analytics
	HUGO_SERVICES_GOOGLEANALYTICS_ID="" \
	  hugo server --environment production --minify \
	  --baseURL "$(BASE_URL)" --appendPort=false \
	  --port $(PORT) --bind 0.0.0.0

##@ Content

# These prompt for every field and write the file themselves rather than going
# through `hugo new`, because the blog front matter this site actually uses -
# authors, series, tags, coverText - is richer than archetypes/default.md and
# half of it is optional. An empty answer omits the key rather than leaving a
# blank one behind.
#
# Every prompt can be pre-answered from the command line, which also makes the
# targets usable without a terminal:
#
#   make new-blog TITLE="Rack cooling" TAGS="hardware,cooling" SERIES=Foundation
#
# SLUG defaults to a slugified TITLE. Nothing is overwritten: an existing file
# aborts the target.

.PHONY: new-blog
new-blog: ## Create a blog post, prompting for front matter: make new-blog [TITLE=...]
	@title="$(TITLE)"; \
	 if [ -z "$$title" ]; then \
	   if [ ! -t 0 ]; then $(ERR) "TITLE required when there is no terminal"; exit 1; fi; \
	   printf "  $(BOLD)Title$(RESET) $(DIM)(e.g. Rack cooling on a budget)$(RESET)\n  > "; \
	   read -r title; \
	 fi; \
	 if [ -z "$$title" ]; then $(ERR) "a title is required"; exit 1; fi; \
	 slug="$(SLUG)"; \
	 default_slug="$$(printf '%s' "$$title" | tr '[:upper:]' '[:lower:]' \
	   | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$$//')"; \
	 if [ -z "$$slug" ] && [ -t 0 ]; then \
	   printf "  $(BOLD)Slug$(RESET) $(DIM)[$$default_slug]$(RESET)\n  > "; read -r slug; \
	 fi; \
	 [ -n "$$slug" ] || slug="$$default_slug"; \
	 path="content/blog/$${slug%.md}.md"; \
	 if [ -e "$$path" ]; then $(ERR) "$$path already exists"; exit 1; fi; \
	 author="$(AUTHOR)"; \
	 if [ -z "$$author" ] && [ -t 0 ]; then \
	   printf "  $(BOLD)Author$(RESET) $(DIM)[neo7.dev]$(RESET)\n  > "; read -r author; \
	 fi; \
	 [ -n "$$author" ] || author="neo7.dev"; \
	 series="$(SERIES)"; \
	 if [ -z "$$series" ] && [ -t 0 ]; then \
	   printf "  $(BOLD)Series$(RESET) $(DIM)(blank for none - e.g. Foundation)$(RESET)\n  > "; \
	   read -r series; \
	 fi; \
	 tags="$(TAGS)"; \
	 if [ -z "$$tags" ] && [ -t 0 ]; then \
	   printf "  $(BOLD)Tags$(RESET) $(DIM)(comma separated - reuse existing spellings)$(RESET)\n  > "; \
	   read -r tags; \
	 fi; \
	 cover="$(COVER_TEXT)"; \
	 if [ -z "$$cover" ] && [ -t 0 ]; then \
	   printf "  $(BOLD)Cover text$(RESET) $(DIM)[$$slug]$(RESET)\n  > "; read -r cover; \
	 fi; \
	 [ -n "$$cover" ] || cover="$$(printf '%s' "$$slug" | tr '-' ' ')"; \
	 { \
	   echo '---'; \
	   printf 'title: "%s"\n' "$$title"; \
	   printf 'date: %s\n' "$$(date +%Y-%m-%d)"; \
	   echo 'draft: true'; \
	   echo 'authors:'; \
	   printf '  - name: %s\n' "$$author"; \
	   if [ -n "$$series" ]; then echo 'series:'; printf '  - %s\n' "$$series"; fi; \
	   if [ -n "$$tags" ]; then \
	     echo 'tags:'; \
	     printf '%s\n' "$$tags" | tr ',' '\n' \
	       | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$$//; /^$$/d; s/^/  - /'; \
	   fi; \
	   echo 'excludeSearch: false'; \
	   echo '# `coverText` renders in the card cover slot with the prompt glyph from'; \
	   echo '# params.command.prompt until there is a real cover image.'; \
	   echo 'coverText: |'; \
	   printf '  %s\n' "$$cover"; \
	   echo '---'; \
	   echo ''; \
	   echo 'The text above the marker below is the excerpt shown on the blog list.'; \
	   echo ''; \
	   echo '<!--more-->'; \
	   echo ''; \
	   echo '## First section'; \
	   echo ''; \
	 } > "$$path"; \
	 $(OK) "created $$path"; \
	 $(WARN) "draft: true - visible under make dev, excluded from make prod"

.PHONY: new-doc
new-doc: ## Create a docs page, prompting for front matter: make new-doc [TITLE=...]
	@title="$(TITLE)"; \
	 if [ -z "$$title" ]; then \
	   if [ ! -t 0 ]; then $(ERR) "TITLE required when there is no terminal"; exit 1; fi; \
	   printf "  $(BOLD)Title$(RESET) $(DIM)(e.g. Proxmox setup)$(RESET)\n  > "; read -r title; \
	 fi; \
	 if [ -z "$$title" ]; then $(ERR) "a title is required"; exit 1; fi; \
	 slug="$(SLUG)"; \
	 default_slug="$$(printf '%s' "$$title" | tr '[:upper:]' '[:lower:]' \
	   | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$$//')"; \
	 if [ -z "$$slug" ] && [ -t 0 ]; then \
	   printf "  $(BOLD)Path under content/docs$(RESET) $(DIM)[$$default_slug]$(RESET)\n  > "; \
	   read -r slug; \
	 fi; \
	 [ -n "$$slug" ] || slug="$$default_slug"; \
	 path="content/docs/$${slug%.md}.md"; \
	 if [ -e "$$path" ]; then $(ERR) "$$path already exists"; exit 1; fi; \
	 weight="$(WEIGHT)"; \
	 if [ -z "$$weight" ] && [ -t 0 ]; then \
	   printf "  $(BOLD)Weight$(RESET) $(DIM)(blank to leave unordered - lower sorts first)$(RESET)\n  > "; \
	   read -r weight; \
	 fi; \
	 mkdir -p "$$(dirname "$$path")"; \
	 { \
	   echo '---'; \
	   printf 'title: "%s"\n' "$$title"; \
	   if [ -n "$$weight" ]; then printf 'weight: %s\n' "$$weight"; fi; \
	   echo '---'; \
	   echo ''; \
	   echo '## First section'; \
	   echo ''; \
	 } > "$$path"; \
	 $(OK) "created $$path"; \
	 if [ -z "$$weight" ]; then \
	   $(WARN) "no weight set - the sidebar will fall back to alphabetical order"; \
	 fi; \
	 case "$$slug" in */*) \
	   $(WARN) "new section: it needs a content/docs/$$(dirname "$$slug")/_index.md"; \
	   $(WARN) "a section with no _index.md loses its sidebar children" ;; \
	 esac

.PHONY: new-page
new-page: ## Create a bare page from archetypes/default.md: make new-page NAME=showcase/thing
	@if [ -z "$(NAME)" ]; then $(ERR) "NAME required, e.g. make new-page NAME=showcase/thing"; exit 1; fi
	@hugo new "content/$(patsubst %.md,%,$(NAME)).md"

##@ Build

.PHONY: build
build: ## Write public/ (add CLEAN=1 to prune files this build did not produce)
	hugo --gc --minify $(CLEAN_DEST)
	@$(MAKE) --no-print-directory check-unpublished

.PHONY: prod
prod: ## Write public/ as CI does, at $(BASE_URL) (add CLEAN=1 to prune)
	hugo --gc --minify $(CLEAN_DEST) --baseURL "$(BASE_URL)"
	@$(MAKE) --no-print-directory check-unpublished

.PHONY: check-unpublished
# Asserts what config/production/hugo.yaml is supposed to guarantee, rather than
# trusting it. The exclusion is config, and config gets edited by someone who does
# not know what it is for - while a published internal note cannot be unpublished,
# because the output repo is public and git history is forever.
#
# Greps the whole tree rather than only looking for public/internal/: a page can
# reach the flexsearch index, llms.txt or a feed without having a directory.
check-unpublished: ## Fail if anything from content/internal/ reached public/
	@$(SAY) "Checking nothing internal was published"
	@if [ ! -d public ]; then $(WARN) "no public/ yet - build first"; exit 0; fi
	@bad=0; \
	 if [ -e public/internal ]; then $(ERR) "public/internal/ exists"; bad=1; fi; \
	 for f in content/internal/*.md; do \
	   [ -e "$$f" ] || continue; \
	   case "$$f" in */_index.md) continue ;; esac; \
	   slug="$$(basename "$$f" .md)"; \
	   if grep -rqF "/internal/$$slug" public/ 2>/dev/null; then \
	     $(ERR) "$$slug is referenced somewhere in public/"; bad=1; \
	   fi; \
	 done; \
	 if [ $$bad -ne 0 ]; then \
	   $(WARN) "config/production/hugo.yaml must drop internal/** from the content mount"; \
	   exit 1; \
	 fi; \
	 $(OK) "no internal content in public/"

.PHONY: clean
clean: ## Remove build output
	rm -rf public resources .hugo_build.lock

##@ Assets

# Everything under assets/ and static/ reaches the site close to verbatim:
# static/ byte for byte, and assets/ as both Hugo's derivatives and - because
# Hextra's render-image hook publishes the source alongside them - the original
# file. Hugo's image pipeline drops metadata whenever it re-encodes, so the
# derivatives are always clean and the originals never are. That asymmetry is
# the hole these targets close, and it is why they read the source tree rather
# than public/.
#
# Two different jobs live here. `strip-meta` deletes metadata containers, which
# is mechanical and safe to automate. `check-leaks` reads text files, which have
# no container to delete - what leaks there is content, and a hit wants a person
# rather than a rewrite.
#
# Neither can be a build step. The publish is pages.yml running hugo directly
# and it never invokes make, so a strip wired into `prod` would not reach the
# live site - and `preview` is `hugo server`, which writes no public/ at all.
# They protect the site by being a required check instead: build-check.yml runs
# `check-assets` on every pull request.

# Which files go to which pass is decided by content, not by extension. `grep
# -I` classifies a file as binary the moment it sees a NUL, so the split is
# exactly the one that matters: text goes to the leak scan, which can read it,
# and everything else goes to exiftool, which knows the containers.
#
# Doing it by extension is what an earlier version did, and it meant a .heic
# off a phone or a .mov matched neither list, fell through to the leak scan,
# was skipped there for being binary, and was counted as clean without anything
# ever having looked at it. An unrecognised file now goes to the pass that can
# actually open it, and if exiftool cannot identify it either, check-meta says
# so and fails rather than passing it silently.
IS_TEXT = LC_ALL=C grep -qI . --

# Everything exiftool can tell us about a file, minus what is not metadata:
# ICC_Profile is a colour profile the strip deliberately keeps, System is the
# filename and mtime, Composite and ExifTool are derived rather than stored.
#
# What remains still holds structural tags - a PNG's BitDepth, a JPEG's
# ColorComponents, the cHRM chromaticities that survive a strip - so this is
# not on its own a list of things to object to. check-meta decides by asking
# whether a strip would change this output, which needs no such list and cannot
# drift out of step with what strip-meta actually removes.
META_READ = exiftool -q -q -s -G1 -all --ICC_Profile:all --System:all \
	--Composite:all --ExifTool:all --

# -overwrite_original rewrites in place rather than leaving an _original copy
# beside every file. --icc_profile:all excludes the colour profile from the
# wipe, because dropping an embedded profile changes how the image renders -
# a visible regression rather than a privacy win.
#
# It protects the ICC profile and nothing else. PNG gAMA and sRGB chunks are
# removed with everything else, and exiftool offers no exclusion that keeps
# them - measured, not assumed. In practice that is harmless: a PNG with no
# colour chunk is treated as sRGB, which is what a screenshot already is. It
# would matter for a PNG deliberately authored at some other gamma, and none
# of the assets here are.
#
# Neither flag touches pixel data: exiftool rewrites the container, so a
# stripped JPEG keeps byte-identical scan data instead of being re-encoded.
META_STRIP = exiftool -q -q -all= --icc_profile:all -overwrite_original --

# Shapes that have no business in a file copied off a real machine: home
# directories, addresses, RFC1918 hosts, key and token material, and the host
# account names as a backstop for an export that embeds them somewhere the
# other shapes miss.
#
# The address patterns are \b-anchored so that 210.0.0.5 is not read as the
# 10.0.0.5 inside it. A four-part version number that happens to start with 10
# still matches, which nothing short of understanding the file could fix -
# that is what .leakignore is for.
#
# content/ is deliberately NOT scanned. Its pages document commands, so
# /Users/you/VMs, you@personal.example and 192.168.1.50 are the subject matter
# rather than a leak - 32 such lines today, every one of them intentional.
LEAK_PATTERNS := /Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}\b|\b10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b|\b172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}\b|BEGIN [A-Z ]*PRIVATE KEY|ssh-(rsa|ed25519|dss) AAAA|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|\bsmit\b|\bchoksi\b

# The same shapes, written as placeholders. Matched against the extracted token
# rather than the whole line, so a real path on a line that also carries a
# placeholder is still caught - which is why each one allows for the `NN:` line
# number `grep -n -o` puts in front of it.
#
# noreply@ is tied to the domains it is expected at. Left open it would have
# waved through noreply@ at a real employer, which is a name and a workplace.
LEAK_ALLOW := ^[0-9]+:/Users/(you|user|username|me)$$|^[0-9]+:/home/(you|user|username|vscode|runner)$$|@([A-Za-z0-9.-]*\.)?example(\.(com|org|net))?$$|^[0-9]+:noreply@(users\.)?(github|noreply\.github)\.com$$

# exiftool is not in the base devcontainer image or on a fresh Mac, and the
# failure without it is a bare "command not found" from inside a loop.
define NEED_EXIFTOOL
	@command -v exiftool >/dev/null 2>&1 || { \
	  $(ERR) "exiftool not found"; \
	  printf "  %-14s %s\n" "" "macOS:  brew install exiftool"; \
	  printf "  %-14s %s\n" "" "Debian: sudo apt-get install -y libimage-exiftool-perl"; \
	  exit 1; \
	}
endef

# Collect the file list up front rather than piping find into the loop. A
# process substitution hands its exit status to nobody, so a find that failed -
# or one run after assets/ was renamed - used to read as a successful scan of
# nothing, and the target reported "0 file(s) clean" and passed. An empty list
# is now a failure in its own right.
define ASSET_FILES
	files=$$(find assets static -type f | sort) || { \
	  $(ERR) "find failed over assets/ static/"; exit 1; \
	}; \
	if [ -z "$$files" ]; then \
	  $(ERR) "no files found under assets/ static/ - wrong directory, or a rename"; \
	  exit 1; \
	fi
endef

# Whether a file is dirty is defined as "would a strip change it", asked by
# stripping a copy and diffing the metadata. That is the whole reason there is
# no list of forbidden tags: a list is a second opinion that drifts, and this
# one cannot - check-meta objects to exactly what strip-meta removes, on every
# format exiftool handles rather than the handful someone thought to enumerate.
#
# The earlier version did keep such a list, and a JPEG COM segment reading
# "exported by Jane Doe /Users/jane/Desktop" was not on it. check-meta passed
# the file, and strip-meta skipped it for being clean - so the list capped the
# fixer as well as the check, and `-all=` never ran on a file it would have
# cleaned in full.
define META_DIFF
	if ! exiftool -q -s3 -FileType -- "$$f" >/dev/null 2>&1 || \
	   [ -z "$$(exiftool -q -q -s3 -FileType -- "$$f" 2>/dev/null)" ]; then \
	  unknown=$$((unknown + 1)); \
	  $(ERR) "$$f"; \
	  printf '       %s\n' "exiftool cannot identify this format - nothing checked it"; \
	  continue; \
	fi; \
	tmp=$$(mktemp "$${TMPDIR:-/tmp}/meta.XXXXXX"); \
	cp "$$f" "$$tmp"; \
	$(META_STRIP) "$$tmp" 2>/dev/null || true; \
	removed=$$(diff <($(META_READ) "$$f" 2>/dev/null) \
	                <($(META_READ) "$$tmp" 2>/dev/null) \
	           | sed -n 's/^< //p'); \
	rm -f "$$tmp"
endef

.PHONY: strip-meta
strip-meta: ## Strip metadata from every non-text file under assets/ and static/
	$(NEED_EXIFTOOL)
	@$(SAY) "Stripping asset metadata"
	@$(ASSET_FILES); \
	 found=0; changed=0; unknown=0; \
	 while IFS= read -r f; do \
	   if $(IS_TEXT) "$$f" 2>/dev/null; then continue; fi; \
	   found=$$((found + 1)); \
	   $(META_DIFF); \
	   [ -n "$$removed" ] || continue; \
	   $(META_STRIP) "$$f"; \
	   changed=$$((changed + 1)); \
	   $(OK) "$$f - removed $$(printf '%s\n' "$$removed" | wc -l | tr -d ' ') tag(s)"; \
	 done <<< "$$files"; \
	 if [ "$$unknown" != "0" ]; then \
	   $(WARN) "$$unknown file(s) exiftool could not identify - left untouched"; \
	 fi; \
	 if [ "$$changed" = "0" ]; then \
	   $(OK) "$$found file(s) scanned - already clean"; \
	 else \
	   $(WARN) "$$changed of $$found file(s) rewritten - review and commit them"; \
	 fi

.PHONY: check-meta
check-meta: ## Fail if a strip would change any non-text file under assets/ or static/
	$(NEED_EXIFTOOL)
	@$(SAY) "Checking asset metadata"
	@$(ASSET_FILES); \
	 found=0; dirty=0; unknown=0; \
	 while IFS= read -r f; do \
	   if $(IS_TEXT) "$$f" 2>/dev/null; then continue; fi; \
	   found=$$((found + 1)); \
	   $(META_DIFF); \
	   [ -n "$$removed" ] || continue; \
	   dirty=$$((dirty + 1)); \
	   $(ERR) "$$f"; \
	   printf '%s\n' "$$removed" | sed 's/^/       /'; \
	 done <<< "$$files"; \
	 if [ "$$dirty" != "0" ] || [ "$$unknown" != "0" ]; then \
	   [ "$$dirty" = "0" ] || $(WARN) "$$dirty file(s) carry metadata - run make strip-meta"; \
	   [ "$$unknown" = "0" ] || $(WARN) "$$unknown file(s) could not be identified - check them by hand"; \
	   exit 1; \
	 fi; \
	 $(OK) "$$found file(s) clean"

# -o extracts the offending token rather than the whole line, which keeps the
# allow list matching what was actually found instead of whatever else shares
# the line. Accepted hits belong in .leakignore, one regex per line, with a
# comment saying why - loosening LEAK_PATTERNS instead hides the next one.
.PHONY: check-leaks
check-leaks: ## Fail if a text file under assets/ or static/ names a real path, host or key
	@$(SAY) "Scanning assets for identifying content"
	@$(ASSET_FILES); \
	 found=0; hits=0; \
	 ign=$$(grep -vE '^[[:space:]]*(#|$$)' .leakignore 2>/dev/null | paste -sd'|' - || true); \
	 while IFS= read -r f; do \
	   $(IS_TEXT) "$$f" 2>/dev/null || continue; \
	   found=$$((found + 1)); \
	   out=$$(grep -nIoE '$(LEAK_PATTERNS)' -- "$$f" 2>/dev/null | grep -vE '$(LEAK_ALLOW)' || true); \
	   if [ -n "$$out" ] && [ -n "$$ign" ]; then \
	     out=$$(printf '%s\n' "$$out" | grep -vE "$$ign" || true); \
	   fi; \
	   [ -n "$$out" ] || continue; \
	   hits=$$((hits + 1)); \
	   $(ERR) "$$f"; \
	   printf '%s\n' "$$out" | sed 's/^/       line /'; \
	 done <<< "$$files"; \
	 if [ "$$hits" != "0" ]; then \
	   $(WARN) "$$hits file(s) name something real - fix them, or record the"; \
	   $(WARN) "exception in .leakignore with a reason"; \
	   exit 1; \
	 fi; \
	 $(OK) "$$found file(s) clean"

.PHONY: check-assets
check-assets: check-meta check-leaks ## Both asset checks - what the PR gate runs

##@ Theme

# Reads the pinned version out of go.mod by scanning fields rather than a
# fixed column, so it works with both the single-line `require` form and a
# `require (...)` block. `hugo mod get -u` itself only speaks up when it
# changes something - a no-op upgrade is silent, which reads the same as a
# failure. Comparing before and after makes "already current" explicit.
THEME := github.com/homelabcentral/hextra
theme_version = $(shell awk '{for (i = 1; i <= NF; i++) if ($$i == "$(THEME)") print $$(i + 1)}' go.mod)

.PHONY: theme-update
theme-update: ## Bump Hextra to the latest tagged release
	@before='$(theme_version)'; \
	hugo mod get -u $(THEME); \
	after=$$(awk '{for (i = 1; i <= NF; i++) if ($$i == "$(THEME)") print $$(i + 1)}' go.mod); \
	if [ "$$before" = "$$after" ]; then \
	  echo "Hextra already at $$after - no newer tagged release."; \
	else \
	  echo "Hextra updated: $$before => $$after"; \
	fi
	@echo "Pin a specific version instead with:"
	@echo "  hugo mod get $(THEME)@vX.Y.Z"

##@ GitHub

# Pull requests, driven by `gh` from inside the dev container.
#
# main is protected by a ruleset: no direct pushes, no force-pushes, and a PR
# whose "Build site" check has passed. Merging that PR is the publish, so these
# targets are the only route a change takes to the live site.
#
# Nothing here reads, echoes, masks or length-checks GH_TOKEN. Presence is
# tested with [ -n ] and identity is asked of GitHub, which answers with a
# login. `gh auth status` is silenced because it renders a masked token, and a
# masked token is still a disclosure.

.PHONY: gh-auth
gh-auth: ## Check gh is authenticated as the account that owns this repository
	@$(SAY) "gh authentication"
	@if ! command -v gh >/dev/null 2>&1; then \
	  printf "  %-14s $(RED)%s$(RESET)\n" "gh" "not installed"; \
	  $(WARN) "these targets run inside the dev container - reopen the repo in it"; exit 1; fi
	@printf "  %-14s %s\n" "gh" "$$(gh --version | head -1)"
	@if [ -z "$${GH_TOKEN:-}" ]; then \
	  printf "  %-14s $(YELLOW)%s$(RESET)\n" "GH_TOKEN" "unset or empty"; \
	  printf "  %-14s %s\n" "" "the container reads it from NEO7DEV_GH_TOKEN on the host"; \
	  printf "  %-14s %s\n" "" "exported from the VSCODE_RESOLVING_ENVIRONMENT guard in ~/.zshrc"; \
	  printf "  %-14s %s\n" "" "if that export exists: quit VS Code fully and relaunch - Reload"; \
	  printf "  %-14s %s\n" "" "Window and Rebuild Container both reuse the cached shell env"; \
	else \
	  printf "  %-14s $(GREEN)%s$(RESET)\n" "GH_TOKEN" "present"; \
	fi
	@login=""; \
	 if out="$$(gh api user --jq .login 2>/dev/null)"; then login="$$(printf '%s' "$$out" | head -1)"; fi; \
	 case "$$login" in *[!A-Za-z0-9-]*) login="" ;; esac; \
	 if [ -z "$$login" ]; then \
	   printf "  %-14s $(RED)%s$(RESET)\n" "identity" "not authenticated"; \
	   if [ -n "$${GH_TOKEN:-}" ]; then \
	     $(WARN) "GH_TOKEN is set but GitHub rejected it - expired or revoked"; \
	     $(WARN) "after rotating it the container still holds the old value until"; \
	     $(WARN) "VS Code is fully quit and relaunched"; \
	   else \
	     $(WARN) "no credential at all - see GH_TOKEN above"; \
	   fi; \
	   exit 1; \
	 elif [ "$$login" != "$(GH_OWNER)" ]; then \
	   printf "  %-14s $(RED)%s$(RESET)\n" "identity" "$$login"; \
	   $(WARN) "this repository belongs to $(GH_OWNER) - $$login is not a collaborator"; \
	   $(WARN) "gh pr create would fail with 'must be a collaborator'"; \
	   $(WARN) "run make inside the dev container - the host gh is a different account"; \
	   exit 1; \
	 else \
	   printf "  %-14s $(GREEN)%s$(RESET)\n" "identity" "$$login"; \
	 fi
	@$(OK) "gh can write to $(GH_OWNER)"

.PHONY: git-auth
git-auth: ## Check git identity and that origin is reachable for pushing
	@$(SAY) "git authentication"
	@printf "  %-14s %s\n" "user.name" "$$(git config user.name || echo '(unset)')"
	@printf "  %-14s %s\n" "user.email" "$$(git config user.email || echo '(unset)')"
	@if [ -z "$$(git config user.name)" ] || [ -z "$$(git config user.email)" ]; then \
	  $(WARN) "this repo is owned by a different account than the host default -"; \
	  $(WARN) "set them repo-locally rather than relying on the global config"; \
	fi
	@url="$$(git remote get-url origin 2>/dev/null || true)"; \
	 if [ -z "$$url" ]; then printf "  %-14s $(RED)%s$(RESET)\n" "origin" "no remote"; exit 1; fi; \
	 printf "  %-14s %s\n" "origin" "$$url"; \
	 case "$$url" in \
	   git@github.com-neo7:*) ;; \
	   git@github.com:*) $(WARN) "plain github.com selects the host's default key - this repo" ; \
	                     $(WARN) "needs the github.com-neo7 ssh alias" ;; \
	 esac
	@if [ -n "$${SSH_AUTH_SOCK:-}" ] && [ -S "$${SSH_AUTH_SOCK:-}" ]; then \
	   printf "  %-14s $(GREEN)%s$(RESET)\n" "ssh-agent" "forwarded"; \
	 else \
	   printf "  %-14s $(YELLOW)%s$(RESET)\n" "ssh-agent" "not forwarded"; \
	   printf "  %-14s %s\n" "" "VS Code forwards it to terminals it opens; a plain"; \
	   printf "  %-14s %s\n" "" "'docker exec' does not - push from a VS Code terminal"; \
	 fi
# Reachability and emptiness are separate questions. `ls-remote --exit-code` exits 2
# when no refs MATCH, so on a repository that exists but has no commits yet it is
# indistinguishable from an auth failure - which reported "origin unreachable" on a
# correctly configured new repo, sending you to debug an agent that was fine.
	@refs=$$(git ls-remote --heads origin 2>/dev/null); rc=$$?; \
	 if [ $$rc -ne 0 ]; then \
	   printf "  %-14s $(RED)%s$(RESET)\n" "push access" "origin unreachable"; \
	   $(WARN) "the host keys are mounted read-only and the agent does the signing"; \
	   $(WARN) "so this usually means the agent is missing rather than a bad key"; \
	   $(WARN) "check in a VS Code terminal: ssh-add -l"; \
	   exit 1; \
	 elif [ -z "$$refs" ]; then \
	   printf "  %-14s $(GREEN)%s$(RESET)\n" "push access" "origin reachable (no branches yet)"; \
	   $(OK) "git can reach origin; it has no commits, so nothing to compare against"; \
	 else \
	   printf "  %-14s $(GREEN)%s$(RESET)\n" "push access" "origin reachable"; \
	   $(OK) "git can push to origin"; \
	 fi

.PHONY: pr
pr: gh-auth ## Open a PR for the current branch: make pr TITLE="..." [BODY_FILE=f] [DRAFT=1] [YES=1]
	@if [ -z "$(TITLE)" ]; then \
	  $(ERR) 'TITLE required, e.g. make pr TITLE="post: rack cooling"'; exit 1; fi
	@branch="$$(git rev-parse --abbrev-ref HEAD)"; \
	 if [ "$$branch" = "$(BASE)" ]; then \
	   $(ERR) "on $(BASE) - branch first, then open the PR"; exit 1; fi; \
	 if ! git rev-parse --verify --quiet "refs/remotes/origin/$$branch" >/dev/null; then \
	   $(ERR) "$$branch has never been pushed - git push -u origin $$branch"; exit 1; fi; \
	 ahead="$$(git rev-list --count "refs/remotes/origin/$$branch..HEAD")"; \
	 if [ "$$ahead" != "0" ]; then \
	   $(ERR) "$$ahead local commit(s) not on origin - push before opening the PR"; exit 1; fi; \
	 if [ -n "$$(gh pr list --head "$$branch" --state open --json number --jq '.[].number')" ]; then \
	   $(ERR) "a PR is already open for $$branch - push to it instead"; exit 1; fi
	$(call CONFIRM,Open a pull request from $$(git rev-parse --abbrev-ref HEAD) into $(BASE)?)
	@$(SAY) "Opening the pull request"
	@gh pr create --base "$(BASE)" --head "$$(git rev-parse --abbrev-ref HEAD)" \
	  --title "$(TITLE)" \
	  $(if $(BODY_FILE),--body-file "$(BODY_FILE)",$(if $(BODY),--body "$(BODY)",--fill)) \
	  $(if $(DRAFT),--draft,)
	@$(OK) "opened - make pr-checks to watch the Build site gate"

.PHONY: pr-close
pr-close: gh-auth ## Close a PR without merging: make pr-close [PR=3] [DELETE_BRANCH=1] [YES=1]
	@num="$(PR)"; [ -n "$$num" ] || num="$$(gh pr view --json number --jq .number 2>/dev/null)"; \
	 if [ -z "$$num" ]; then $(ERR) "no open PR for this branch - pass PR=<number>"; exit 1; fi; \
	 $(SAY) "$$(gh pr view "$$num" --json number,title,headRefName \
	   --jq '"#\(.number) \(.title)  [\(.headRefName)]"')"
	$(call CONFIRM,Close this pull request without merging?)
	@num="$(PR)"; [ -n "$$num" ] || num="$$(gh pr view --json number --jq .number)"; \
	 gh pr close "$$num" $(if $(DELETE_BRANCH),--delete-branch,); \
	 $(OK) "closed #$$num"

.PHONY: pr-list
pr-list: gh-auth ## List open pull requests
	@gh pr list --state open

.PHONY: pr-view
pr-view: gh-auth ## Show a PR: make pr-view [PR=3]
	@gh pr view $(PR)

.PHONY: pr-checks
pr-checks: gh-auth ## Watch a PR's checks to completion: make pr-checks [PR=3]
	@gh pr checks $(PR) --watch

##@ Remote CI (GitHub Actions)

# Two workflows. build-check.yml is the gate: it runs on every pull_request
# against main and on every push to a branch that is not main, building the
# merge result rather than the branch tip. pages.yml runs on a push to main and
# is the publish.
#
# BRANCH defaults to the checked-out branch and takes any ref name, so main's
# runs are visible without checking main out. STATUS filters by gh's own run
# states - queued, in_progress, completed, failure, success - and LIMIT sets how
# many rows `gh-runs` prints.
GH_BRANCH = $(if $(BRANCH),$(BRANCH),$$(git rev-parse --abbrev-ref HEAD))
GH_LATEST = gh run list --branch "$(GH_BRANCH)" --limit 1 --json databaseId --jq '.[0].databaseId'

.PHONY: gh-runs
gh-runs: gh-auth ## List recent Actions runs: make gh-runs [BRANCH=main] [STATUS=in_progress] [LIMIT=10]
	@gh run list --branch "$(GH_BRANCH)" --limit $(if $(LIMIT),$(LIMIT),10) \
	  $(if $(STATUS),--status "$(STATUS)",)

.PHONY: gh-watch
gh-watch: gh-auth ## Watch the latest Actions run: make gh-watch [BRANCH=main]
	@id="$$($(GH_LATEST))"; \
	 if [ -z "$$id" ]; then $(ERR) "no runs for $(GH_BRANCH) yet"; exit 1; fi; \
	 gh run watch "$$id"

.PHONY: gh-rerun
gh-rerun: gh-auth ## Re-run failed jobs of the latest run: make gh-rerun [BRANCH=main] [YES=1]
	@id="$$($(GH_LATEST))"; \
	 if [ -z "$$id" ]; then $(ERR) "no runs for $(GH_BRANCH) yet"; exit 1; fi; \
	 $(SAY) "latest run on $(GH_BRANCH): $$id"
	$(call CONFIRM,Re-run the failed jobs of that run?)
	@gh run rerun "$$($(GH_LATEST))" --failed
	@$(OK) "re-run queued - make gh-watch to follow it"

.PHONY: gh-dispatch
gh-dispatch: gh-auth ## Trigger pages.yml by hand: make gh-dispatch [REF=main] [YES=1]
	@$(WARN) "pages.yml is the publish - it force-pushes public/ to the .github.io repo"
	@$(WARN) "and that repo is rewritten to a single commit on every publish"
	$(call CONFIRM,Really publish $(if $(REF),$(REF),main) to the live site?)
	@gh workflow run pages.yml --ref "$(if $(REF),$(REF),main)"
	@$(OK) "dispatched - make gh-watch BRANCH=$(if $(REF),$(REF),main) to follow it"
