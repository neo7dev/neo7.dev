# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this repo is

Source for [neo7.dev](https://neo7.dev), a site of engineering notes: a Hugo site using
the [Hextra](https://github.com/homelabcentral/hextra) theme. This repo holds
**only source**. The rendered site lives in a separate repository.

See `README.md` for the human-facing overview; this file covers the conventions
and traps that are not obvious from reading the tree.

## Branching: never commit site changes straight to main

Pushing to `main` publishes to the live site. Treat `main` as the release
branch, not the working branch.

For any new article, doc page, layout change or config change:

1. Branch first — `git switch -c post/rack-cooling`, `docs/proxmox-setup`,
   `fix/hero-spacing`. Branch naming is loose; the branching is not.
2. Commit the work there.
3. Push the branch. The build check runs.
4. Open a PR (`gh pr create`) when it is ready to be public.
5. Merge the PR. That merge is the publish.

A local merge followed by `git push origin main` no longer works - the ruleset
rejects it. Merging through a PR is the only route in.

Pushing a feature branch is safe and does nothing to the live site:
`.github/workflows/pages.yml` triggers only on `push` to `main`. What a branch
push does trigger is `.github/workflows/build-check.yml`, which builds the site
with the same flags as the publish job and throws the output away.

`main` is protected by a ruleset: no direct pushes, no force-pushes, no
deletion, and a PR whose "Build site" check has passed. That check name is the
`name:` of the job in build-check.yml - renaming the job detaches the
requirement without any error, so change both together or neither.

On a pull request the check builds the _merge result_, not the branch tip, so a
branch that builds alone but conflicts semantically with current `main` still
fails.

Do not push to `main` without being asked. "Commit this" is not "publish this".

## How publishing works

Two repositories:

| Repository                  | Holds                | Branch |
| --------------------------- | -------------------- | ------ |
| `neo7dev/neo7.dev`          | source (this repo)   | `main` |
| `neo7dev/neo7dev.github.io` | rendered output only | `main` |

A push to `main` here runs `.github/workflows/pages.yml`, which builds with Hugo
and force-pushes `public/` to `main` of the `.github.io` repo via
`peaceiris/actions-gh-pages`. GitHub Pages serves that branch, and
`static/CNAME` maps it to the apex domain.

Consequences worth remembering:

- `force_orphan: true` — the published repo is rewritten to a single commit on
  every publish. It has no history and is not a place to put anything by hand.
- Auth is an SSH deploy key: private half in the `DEPLOY_KEY` secret here,
  public half a write-enabled deploy key on the `.github.io` repo. Not a PAT.
- `public/` is a build artifact. It is gitignored and must never be committed.
- The publish step cannot be rehearsed locally. `act` would run it for real.
  Verify with `make prod`, which reproduces the CI build command exactly.

## Commands

`make` on its own prints the annotated list, grouped. The ones worth knowing:

```shell
make dev        # authoring: live reload, drafts and future posts, :8043
make preview    # what ships: production env, minified, no drafts, :8043
make prod       # write public/ exactly as CI does
make clean      # remove public/, resources/, .hugo_build.lock
make theme-update  # bump Hextra to the latest tagged release
npm run format  # prettier, including Go templates
```

`make dev` for writing, `make preview` for checking what ships — drafts and
`hugo.IsProduction`-gated features (analytics, among others) behave differently
between them.

### Creating content

```shell
make new-blog   # prompts for title, slug, author, series, tags, cover text
make new-doc    # prompts for title, path, weight
make new-page NAME=showcase/thing   # bare page from archetypes/default.md
```

`new-blog` and `new-doc` write the front matter this site actually uses rather
than `archetypes/default.md`'s four lines, so prefer them over `hugo new` for
those two sections. Every prompt can be pre-answered, which also makes them
usable without a terminal:

```shell
make new-blog TITLE="Rack cooling" TAGS="hardware,cooling" SERIES=Foundation
```

An empty answer omits the key rather than leaving a blank one, and neither
target overwrites an existing file.

### Pull requests and CI

These run `gh`, so they need the dev container — the host's `gh` is
authenticated as a different account and is not a collaborator here.

```shell
make gh-auth    # is gh authenticated, and as whom
make git-auth   # git identity, ssh-agent, origin reachability
make pr TITLE="..."         # open a PR for the current branch
make pr-checks              # watch the Build site gate
make gh-runs BRANCH=main    # Actions runs for any branch, checked out or not
```

`BRANCH=` works on `gh-runs`, `gh-watch` and `gh-rerun`, defaulting to the
current branch; `gh-runs` also takes `STATUS=` and `LIMIT=`. Everything that
changes state on GitHub prompts first and defaults to no — `YES=1` bypasses.

`make gh-dispatch` triggers `pages.yml` by hand. That is the publish, so it is
guarded hardest of all.

## The theme is a Hugo Module

Nothing from the theme is vendored. Hugo resolves
`github.com/homelabcentral/hextra` from `go.mod` into its module cache. There is
no `themes/` directory and no submodule.

To read theme source, `hugo mod vendor` writes it to `_vendor/` — but **delete
it afterwards**. `_vendor/` is gitignored, and while it exists Hugo builds from
it and ignores `go.mod` entirely, silently pinning the theme and making
`make theme-update` a no-op.

Editing a local checkout of the theme changes nothing here until it is tagged
and released.

## Content conventions

New posts go in `content/blog/`, docs in `content/docs/`. `archetypes/default.md`
sets `draft: true`; `hugo new content/blog/slug.md` uses it.

Blog front matter follows `content/blog/welcome.md`: `title`, `date`,
`authors`, optional `series` and `tags`, and `coverText` as a stand-in until
there is a real cover image.

`enableGitInfo: true` means `.Lastmod` comes from the last commit touching the
file, not from front matter. Do not add a `lastmod` key to work around a date
looking wrong — commit properly instead.

### content/internal/ is never published

A third section alongside `docs/` and `blog/`, blog-shaped via `cascade: type: blog`,
for notes worth keeping and not publishing: setup records, runbooks, anything
naming real hosts or paths.

`config/production/hugo.yaml` drops `internal/**` from the content mount, so a
production build does not read those files at all — nothing can reach the rendered
output, the flexsearch index, `llms.txt`, the feeds or the sitemap. This is why it
is a mount exclusion rather than `draft: true`: `--buildDrafts` publishes a draft,
while no flag publishes an unmounted file.

`hugo server` defaults to the development environment and `hugo` to production, so
`make dev` shows the section and `make prod`, `make preview` and CI cannot. The
navbar entry lives in `config/development/hugo.yaml` for the same reason; menus
merge by identifier, so it adds one item without restating the others.

`make check-unpublished` asserts it, and runs from `build`, `prod`, the PR gate and
— before the publish step — `pages.yml`. Do not take it out to make a build pass:
a published internal note cannot be unpublished, because the output repo is public
and its history is permanent.

Put a new internal note in `content/internal/`. Nothing else is needed; the
cascade gives it blog front matter semantics.

## The Hextra skill

The theme repo ships an agent skill covering authoring against Hextra -
shortcodes and their `{{< >}}` vs `{{% %}}` notation, front matter, `hugo.yaml`
params, the blog and docs sections, and icon names. It is generated from the
theme's own shortcode templates, so it describes the version of the theme that
produced it rather than a hand-written approximation.

It is not installed by default. Install it as a plugin, which works on any
machine and inside the dev container:

```shell
/plugin marketplace add homelabcentral/hextra
/plugin install hextra@hextra
```

Pin it to the theme version this site actually uses - the plugin is versioned
alongside the theme, so an upgrade here should be followed by reinstalling the
plugin.

If you are working from a local checkout of the theme and want the unreleased
skill, point the marketplace at the path instead:

```shell
/plugin marketplace add ~/Code/hextra
```

A path-based install only resolves on a machine that has that checkout; inside
the dev container only this repository is mounted, so use the GitHub form there.

Prefer the skill over guessing shortcode syntax. The notation split is the most
common source of broken pages: `details`, `include`, `steps`, `ltr` and `rtl`
take `{{% %}}`, everything else takes `{{< >}}`.

## Editor snippets

`.vscode/hextra.code-snippets` holds 115 snippets for the theme's shortcodes
(markdown scope) and config blocks (yaml scope) - `hxcallout`, `hxcards`,
`hxtabs`, `hxsteps` and so on. They are copied verbatim from the theme repo at
`~/Code/hextra/.vscode/`, so re-syncing is a plain `cp` and a `diff` tells you
whether it is stale.

Prefer them over hand-writing shortcode markup: they get the nesting and the
delimiters right, which is where the four-space trap below bites.

## Traps

**Four-space indentation inside shortcodes.** Several Hextra shortcodes render
their inner content through `markdownify`. Four leading spaces is a Markdown
indented code block, so indenting shortcode contents "for readability" renders
the raw HTML as literal text on the page. Keep inner content flush left.

**`enableGitInfo` hard-fails without a repo.** Not a warning, not a fallback to
file mtime — the build aborts with `failed to load Git data`. Hence
`fetch-depth: 0` in CI; a shallow clone yields wrong dates.

**Three places hold the base URL** and must stay in step: `baseURL` in
`hugo.yaml`, `BASE_URL` in the `Makefile`, and `--baseURL` in
`.github/workflows/pages.yml`. It is hardcoded in CI deliberately — the site is
served from the apex domain, not the `<user>.github.io` path the target repo
would imply.

**Images.** Files under `assets/` go through Hugo's pipeline and can be resized
and converted; files under `static/` are copied verbatim. The blog rail avatar
resolves via `resources.Get`, so its path is relative to `assets/`. The home
hero image is a plain `src` and must live in `static/`, pre-sized — no
processing happens.

**Assets carry their export metadata.** `static/` is copied byte for byte, and
Hextra publishes an image's original alongside Hugo's derivatives — so whatever
an image or PDF was exported with is published with it. The home hero used to
ship the Canva account, brand and document IDs it was made under. Assets are
committed already stripped: after adding any asset, run `make strip-meta`.
`make check-assets` is what the PR gate runs.

The two passes split on content rather than extension — `grep -I` decides, so
text goes to the leak scan and everything else to exiftool. That matters: an
extension list left a `.heic` or a `.mov` in neither bucket, and it was counted
clean without anything opening it. A file exiftool cannot identify now fails
the check rather than passing it. And "carries metadata" means "a strip would
change this file", asked by stripping a copy and diffing — not a list of
forbidden tags, because a list drifts out of step with what the strip removes
and silently caps it.

That text scan deliberately skips `content/`. Its pages document commands, so
`/Users/you/VMs` and `192.168.1.50` are the subject matter rather than a leak.
Record an accepted hit in `.leakignore` with a reason rather than widening
`LEAK_PATTERNS` in the Makefile.

**Git identity.** This repo is owned by a different GitHub account than the host
default. `user.name` and `user.email` are set repo-locally, and `origin` uses
the `github.com-neo7` SSH alias so pushes authenticate as the right
account. Do not "fix" the remote to `git@github.com:` — that silently selects
the wrong key.

## Dev container

Compose-based, in `.devcontainer/`. Two things it does that are easy to break:

- Mounts exactly one SSH key, not the host's `~/.ssh`. `${HOME}/.ssh/`
  `${NEO7DEV_SSH_KEY:-neo7_github}` and its `.pub` are bound
  read-only to `~/.ssh/id_container`, and `.devcontainer/ssh-config` — named by
  `IdentityFile` with `IdentitiesOnly yes` — is symlinked over `~/.ssh/config`
  by `postCreateCommand`. The forwarded agent still does the signing; this only
  narrows which identity is offered, and mounting the whole of `~/.ssh` is what
  dragged every other one in. `~/.ssh` itself is a named volume so
  `known_hosts` survives a rebuild. Long syntax, not a mount _string_: a
  string's `readonly` flag is silently dropped on the compose code path, and
  these are real private keys. The host no longer needs
  `IgnoreUnknown UseKeychain` — its config is never parsed here.
- Reads `GH_TOKEN` from `NEO7DEV_GH_TOKEN` on the host, exported from
  `~/.zshrc` behind a `VSCODE_RESOLVING_ENVIRONMENT` guard. The rename keeps the
  host's own `gh` credentials untouched.

If `GH_TOKEN` is empty in the container, the usual cause is VS Code's cached
shell environment, which is resolved once per app session. Quit VS Code fully
and relaunch — Reload Window and Rebuild Container both reuse the cache.

### Run `git` and `gh` inside the container, from anywhere

Both are authenticated in there and neither is on the host: the host's `gh` is
signed in as a different account with `pull` and nothing else, and
`NEO7DEV_GH_TOKEN` is only exported into VS Code's resolved environment,
so a plain host shell has no way to become the right account. Opening a PR from
the host therefore does not fail cleanly — `gh pr create` offers to fork instead.

Being outside VS Code is not a reason to fall back to the host. The container
is a normal Docker container and `docker exec` reaches it from any shell.

**Check whether it is already up, and if it is, just use it.** Do not rebuild
it, do not reopen VS Code, do not ask whether to use it, and do not offer the
host or a browser link as an alternative:

```shell
docker ps --format '{{.Names}}\t{{.Status}}'
docker exec neo7dev-dev-1 bash -lc 'cd /workspaces/neo7.dev && gh pr create --base main --fill'
```

The name comes from the compose project, so it tracks the directory name —
read it from `docker ps` rather than assuming. Only if nothing is running does
starting it become the question: `docker compose -f
.devcontainer/docker-compose.yml up -d`, or reopening the folder in VS Code.

Three things that bite inside `docker exec`:

- **SSH does not work.** The forwarded agent belongs to the VS Code session, so
  `docker exec` has no `SSH_AUTH_SOCK` and `git push` fails with
  `Permission denied (publickey)` despite the mounted key. Push over HTTPS with
  the `gh` credential helper instead:
  `git -c credential.helper='!gh auth git-credential' push https://github.com/neo7dev/neo7.dev.git HEAD:refs/heads/<branch>`
- `/tmp` is not writable as the container user. A `--body-file` or any other
  scratch file goes under `$HOME` or the repo, and a heredoc redirected to
  `/tmp` fails with `Permission denied` — which `gh` will happily treat as an
  empty body and open the PR anyway.
- `bash -lc` is what loads the profile that puts `GH_TOKEN` in scope. Without
  the login shell, `gh` is unauthenticated.

Never echo `GH_TOKEN`, `NEO7DEV_GH_TOKEN` or `gh auth token` to the
terminal to check them. `gh auth status` reports the account and the source
without revealing the value.

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:

- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec
