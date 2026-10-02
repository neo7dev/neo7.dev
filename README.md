# neo7.dev

[![Deploy](https://github.com/neo7dev/neo7.dev/actions/workflows/pages.yml/badge.svg?branch=main)](https://github.com/neo7dev/neo7.dev/actions/workflows/pages.yml)
[![Build check](https://github.com/neo7dev/neo7.dev/actions/workflows/build-check.yml/badge.svg)](https://github.com/neo7dev/neo7.dev/actions/workflows/build-check.yml)

Hugo site for [neo7.dev](https://neo7.dev), built with the
[Hextra](https://github.com/homelabcentral/hextra) theme and deployed to GitHub
Pages from `neo7dev/neo7dev.github.io`.

## The theme is a Hugo Module

Nothing from the theme is vendored into this repo. There is no `themes/`
directory and no submodule. Hugo resolves the theme from the Go module proxy
into its own module cache, and the version in use is one line in `go.mod`:

```
require github.com/homelabcentral/hextra v0.17.2
```

Upgrade deliberately:

```shell
hugo mod get -u github.com/homelabcentral/hextra          # latest release
hugo mod get github.com/homelabcentral/hextra@v0.17.2     # a specific version
```

Editing a local checkout of the theme has no effect on this site until that
change is tagged and released.

## Requirements

Hugo **extended** 0.146.0 or newer, and Go — Hugo shells out to it to resolve
modules. The dev container supplies both.

## Dev container

Open the folder in VS Code and "Reopen in Container". It is compose-based with a
single service:

- `dev` — the workspace container (Go base image, Hugo 0.166.0 extended,
  Node 24, git, `gh`)

No Docker socket and no `act` inside the container: nothing here builds or runs
containers, and mounting the host socket would be root-equivalent access to the
host daemon for no gain. `act` stays a host tool — `.actrc` configures it, and
`act -ln` syntax-checks `.github/workflows/pages.yml` with no daemon running.

Hugo serves on **:8043**, the only forwarded port. There is no second static
file server: `make preview` runs Hugo itself in production mode when you want to
see the minified, draft-free output.

The host `~/.ssh` is **not** mounted. One key is bound read-only to a fixed path,
`~/.ssh/id_container` — `$NEO7DEV_SSH_KEY`, defaulting to
`neo7_github` — and `.devcontainer/ssh-config` is symlinked to
`~/.ssh/config` and names that one identity with `IdentitiesOnly yes`. Which key
a container uses is a property of the container, not of the host it runs on.

The key is never unlocked here: it is passphrase-protected, the passphrase is in
the macOS Keychain, and VS Code forwards the host ssh-agent to do the signing.
So `docker exec`, which gets no forwarded agent, cannot push.

`gh` reads `GH_TOKEN`, populated from `NEO7DEV_GH_TOKEN` on the host. That export
lives in the dotfiles host file, gated so only VS Code's resolved environment ever
holds it; the token itself is stored with `make secret-set NAME=gh-token-neo7dev`
and `make secrets` reports whether it is present.

The rename matters — `gh` prefers `GH_TOKEN` over its stored credentials, so
exporting it under that name on the host would re-authenticate every host
terminal as this account.

It is a fine-grained PAT scoped to this repository alone, with:

| Permission    | Level        | For                                                   |
| ------------- | ------------ | ----------------------------------------------------- |
| Metadata      | read         | mandatory on every fine-grained token                 |
| Contents      | read & write | `git push` over HTTPS, reading branches               |
| Pull requests | read & write | `make pr`, `pr-list`, `pr-view`, `pr-close`           |
| Actions       | read & write | `make gh-runs`, `gh-watch`, `gh-rerun`, `gh-dispatch` |
| Workflows     | read & write | pushing any commit that edits `.github/workflows/`    |

`Workflows` is not optional here, because this repo has workflows: GitHub refuses
a workflow-file change from a token without it, and reports a generic push
rejection that names nothing.

The published repo needs no token at all — the Action pushes to it with
`DEPLOY_KEY`, not with a PAT.

Deliberately **not** on this token: `Secrets: write` and `Administration: write`.
They are only needed to create the `DEPLOY_KEY` secret or the ruleset through the
API rather than the settings pages, which is a one-time job. `Administration` is
the whole settings surface — rename, transfer, visibility, collaborators, delete
the repository — and this token lives in a shell environment to open pull
requests. For the API route, make a separate token with a short expiry and delete
it afterwards.

## Commands

```shell
make dev      # :8043 live reload, drafts, internal section, future posts
make preview  # :8043 exactly what ships — production env, minified, no drafts
make prod     # verify CI's build succeeds; writes nothing
make build    # write public/ as CI does (prunes; CLEAN=0 to keep stale files)
make clean    # remove public/ and resources/
make help     # everything else
```

Three of those four write nothing. `dev` and `preview` serve from memory
(`--renderToMemory`), and `prod` is an in-memory build that answers "would CI's
build succeed" and exits non-zero if not. **`build` is the only target that touches
`public/`**, and it prunes by default, so what is on disk is always what one build
produced rather than the union of several.

That matters because `hugo server` overlays its in-memory render on the real
`publishDir`: before this, a page left in `public/` by one target was served by
another that had never rendered it, which made `make preview` show content the
production build correctly excluded.

## Deployment

`.github/workflows/pages.yml` builds on every push to `main` and force-pushes
`public/` to `neo7dev/neo7dev.github.io`. The custom domain comes from
`static/CNAME`, which Hugo copies verbatim into `public/` — it has to live there
because `force_orphan` rewrites the published branch on every publish, discarding
anything added to it by hand or by the Pages UI.

### First-time setup

Auth is an SSH deploy key: public half on the published repo, private half as a
secret here. One pair, used only by the Action. Do these in order.

**1. Generate the key.** No passphrase — CI cannot type one. A new pair, not a
reused one: GitHub rejects the same public key as a deploy key on a second repo.

```shell
ssh-keygen -t ed25519 -N '' -C 'neo7.dev pages deploy' -f ~/.ssh/tmp-deploy
```

**2. Public half → published repo.** Copy it, then add it on github.com:

```shell
pbcopy < ~/.ssh/tmp-deploy.pub
```

- https://github.com/neo7dev/neo7dev.github.io/settings/keys → **Add deploy key**
- Title: `neo7.dev pages publish`
- Key: paste
- **Tick "Allow write access"** — without it the publish fails looking like an
  auth error rather than a permissions one
- **Add key**

**3. Private half → secret here.** Copy it, then add it on github.com:

```shell
pbcopy < ~/.ssh/tmp-deploy
```

- https://github.com/neo7dev/neo7.dev/settings/secrets/actions/new
- Name: `DEPLOY_KEY` — exact; that is what `pages.yml` reads
- Secret: paste whole, including the `-----BEGIN/END OPENSSH PRIVATE KEY-----`
  lines and the trailing newline. A truncated key fails unhelpfully.
- **Add secret**

Note the two go in _different_ repositories. Swapping them is the usual mistake.

**4. Delete the local copies.** Both halves are now where they belong.

```shell
rm -f ~/.ssh/tmp-deploy ~/.ssh/tmp-deploy.pub
pbcopy < /dev/null
```

Nothing local reads either half again. A secret cannot be read back, so confirm
steps 2 and 3 landed before deleting — otherwise the only fix is a new pair.

**5. Push.** This is the first publish, and it creates `main` on the published
repo. `force_orphan` works on an empty repository.

```shell
git push -u origin main
make gh-watch
```

**6. Point Pages at the branch** — only possible now that it exists:

- https://github.com/neo7dev/neo7dev.github.io/settings/pages
- Source: **Deploy from a branch** → `main` / `/ (root)`

**7. DNS for `neo7.dev`.** Four A records, then enforce HTTPS once the
certificate issues:

```
@      A      185.199.108.153
@      A      185.199.109.153
@      A      185.199.110.153
@      A      185.199.111.153
www    CNAME  neo7dev.github.io
```

Rotating the key later means repeating 1–4 with a new pair and removing the old
deploy key.

### Branch protection

`main` is the release branch: a push to it publishes. It is protected by a
ruleset - `.github/ruleset.json` is the live configuration, kept here so it is
reviewable rather than only clickable.

What it enforces: no direct pushes, no force-pushes, no deletion, and a pull
request whose **Build site** check has passed. Squash is the only permitted merge
method, so `main` stays one commit per change.

To set it up on github.com:

https://github.com/neo7dev/neo7.dev/settings/rules -> **New ruleset** ->
**New branch ruleset**

- Name: `main`
- Enforcement status: **Active**
- Bypass list: **leave empty** - otherwise it does not apply to you, and you are
  the only one who would push
- Target branches: Add target -> **Include default branch**
- Rules: **Restrict deletions**, **Block force pushes**, **Require a pull request
  before merging** (approvals `0`, allowed merge methods **Squash** only), and
  **Require status checks to pass** -> `Build site`

Or, with a token carrying `Administration: write`:

```shell
gh api -X POST repos/neo7dev/neo7.dev/rulesets --input .github/ruleset.json
```

Three things that bite, in order:

- **Create the ruleset after the first push to `main`.** The require-PR rule
  rejects the push that creates the branch.
- **The required check is the job name, `Build site`** - `jobs.build.name` in
  `build-check.yml`, not the workflow's own `name:` of `Build check`. Renaming the
  job detaches the requirement silently, with no error, so change both or neither.
- **`Build site` only appears in the picker once it has reported.** Pushing `main`
  does not do it: `build-check.yml` is `branches-ignore: [main]` plus
  `pull_request`, so the first main push runs the publish workflow instead. Push
  any branch once, then add the check. Creating the ruleset without that one rule
  and adding it afterwards is fine - the other three protect `main` immediately.

On a pull request the check builds the **merge result**, not the branch tip, so a
branch that builds alone but conflicts semantically with current `main` still
fails.

Also under Settings -> Pull Requests: leave **Allow squash merging** on, untick
**Allow merge commits** and **Allow rebase merging**, and tick **Automatically
delete head branches**. The ruleset already refuses the other two methods; this
removes the buttons that would be rejected.
