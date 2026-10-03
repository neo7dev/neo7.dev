---
title: "Setting Up This Site"
date: 2026-10-02T17:30:00+05:30
draft: true
authors:
  - name: neo7.dev
tags:
  - hugo
  - devcontainer
  - github-actions
  - meta
excludeSearch: false
summary: "A Hugo site in a dev container, published to GitHub Pages by an Action. Three credentials, two repositories, and the order the steps have to happen in."
coverText: |
  hugo devcontainer deploy
---

## The shape of it

**Two repositories.** One holds source, one holds rendered HTML. An Action builds
the first and force-pushes `public/` into the second, which Pages serves.

**Three credentials**, and confusing them is the main way this goes wrong. They
authenticate different actors:

| Credential       | Lives                                                                              | Authenticates                             |
| ---------------- | ---------------------------------------------------------------------------------- | ----------------------------------------- |
| Your SSH key     | your machine; public half on your GitHub account                                   | **you**, pushing from the container       |
| Deploy key       | public half on the published repo; private half as `DEPLOY_KEY` on the source repo | **the Action**, pushing built output      |
| Fine-grained PAT | OS keychain, exported into the container as `GH_TOKEN`                             | **`gh`**, for API calls like opening a PR |

Git over SSH and the GitHub API authenticate separately. The SSH key cannot open
a pull request; the PAT cannot sign a push. You need both.

**One dev container**, which declares the toolchain and exactly one SSH identity
rather than inheriting whatever the host has.

Everything below is in order. Several steps are impossible before an earlier one
has run.

## 1. Two repositories, both empty

- `<user>/<site>` — source
- `<user>/<user>.github.io` — rendered output, **must be public** for Pages

No README, no `.gitignore`. Anything in them gets overwritten or fought with.

## 2. Your SSH key, and a host alias for it

Skip the key if the account you push as is already your machine's default. If it
is a _second_ GitHub account — the usual case for a side project — it needs its
own key and its own `Host` alias:

```shell
ssh-keygen -t ed25519 -C '<account>@github.com <site>' -f ~/.ssh/<account>_<site>
```

Give it a passphrase. On macOS, `ssh-add --apple-use-keychain` stores that
passphrase so you type it once ever.

Add the public half at **github.com → Settings → SSH and GPG keys**, signed in as
that account.

Then, in `~/.ssh/config`:

```sshconfig
Host github.com-<account>
  HostName github.com
  User git
  IdentityFile ~/.ssh/<account>_<site>
  IdentitiesOnly yes
```

`IdentitiesOnly yes` is the load-bearing line. Without it ssh offers every key the
agent holds and GitHub accepts the first that maps to _any_ account — so a push
to this repo authenticates as your other account and fails on permissions,
looking like a broken key.

Never claim the bare `Host github.com` for a second account. ssh keeps the
**first** `IdentityFile` across all matching blocks, so two accounts both claiming
it means one silently wins everywhere. Clone with the alias:

```shell
git clone git@github.com-<account>:<user>/<site>.git
```

## 3. Scaffold the site

```shell
hugo new site <site> --format yaml
cd <site> && git init -b main
hugo mod init github.com/<user>/<user>.github.io
hugo mod get github.com/<owner>/hextra
```

The theme is a Hugo Module — no `themes/` directory, no submodule. In `hugo.yaml`:

```yaml
baseURL: "https://<domain>/"
enableGitInfo: true
module:
  hugoVersion:
    extended: true
    min: "0.146.0"
  imports:
    - path: github.com/<owner>/hextra
```

Hugo shells out to `go` to resolve that import, so Go must be installed even
though nothing is compiled.

`enableGitInfo` drives "last updated" from the last commit touching each file. It
**hard-fails** without a repository — `failed to load Git data`, not a warning —
which is why CI checks out with full history.

The custom domain:

```shell
echo '<domain>' > static/CNAME
```

In `static/`, not set through the Pages UI. The publish step uses `force_orphan`,
which rewrites the published branch every time and discards anything the UI wrote
there. From `static/` Hugo re-copies it on every build.

## 4. The dev container

Three files. `.devcontainer/devcontainer.json` declares the toolchain:

```json
{
  "name": "<site>",
  "dockerComposeFile": "docker-compose.yml",
  "service": "dev",
  "workspaceFolder": "/workspaces/<site>",
  "features": {
    "ghcr.io/devcontainers/features/hugo:1": {
      "extended": true,
      "version": "0.166.0"
    },
    "ghcr.io/devcontainers/features/node:1": { "version": "24" },
    "ghcr.io/devcontainers/features/git:1": {},
    "ghcr.io/devcontainers/features/github-cli:1": {}
  },
  "postCreateCommand": "sudo chown \"$(id -u):$(id -g)\" /home/vscode/.ssh && sudo chmod 700 /home/vscode/.ssh && ln -sfn \"${containerWorkspaceFolder}/.devcontainer/ssh-config\" /home/vscode/.ssh/config",
  "forwardPorts": [8043]
}
```

`.devcontainer/docker-compose.yml` mounts one key and one token:

```yaml
name: <site>
services:
  dev:
    image: mcr.microsoft.com/devcontainers/go:1
    user: vscode
    environment:
      - GH_TOKEN=${SITE_GH_TOKEN:-}
    volumes:
      - ..:/workspaces/<site>:cached
      - ssh_home:/home/vscode/.ssh
      - type: bind
        source: ${HOME}/.ssh/<account>_<site>
        target: /home/vscode/.ssh/id_container
        read_only: true
      - type: bind
        source: ${HOME}/.ssh/<account>_<site>.pub
        target: /home/vscode/.ssh/id_container.pub
        read_only: true
    command: sleep infinity
volumes:
  ssh_home:
```

`.devcontainer/ssh-config`, symlinked over `~/.ssh/config` by
`postCreateCommand`:

```sshconfig
Host github.com github.com-<account>
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_container
  IdentitiesOnly yes
```

Four decisions worth keeping:

- **The host's `~/.ssh` is not mounted.** Only one key, at a fixed path. Mounting
  the whole directory drags every identity in and the forwarded agent offers them
  all. Which key a container uses is a property of the container.
- **Long mount syntax, not a string.** The devcontainers CLI re-emits compose
  mounts through a converter with no `readonly` field, so `read_only` in a mount
  _string_ is silently dropped. These are real private keys.
- **`~/.ssh` is a named volume** so `known_hosts` survives a rebuild. Docker
  creates it root-owned, hence the `chown` in `postCreateCommand` — without it ssh
  cannot write `known_hosts` and re-asks to trust github.com on every connection.
- **The key is never unlocked in the container.** It stays passphrase-protected;
  VS Code forwards the host ssh-agent and the agent signs. A consequence:
  `docker exec` gets no forwarded agent and cannot push.

## 5. The PAT, and where to keep it

A fine-grained token, scoped to the source repo only: Metadata read; Contents,
Pull requests, Actions, Workflows all read & write. `Workflows` because the repo
contains workflow files and GitHub refuses a workflow-file change without it,
reporting a push rejection that names nothing.

Do **not** add `Secrets: write` or `Administration: write`. Those are only for
doing step 6 and step 9 through the API instead of the settings pages, and
`Administration` carries rename, transfer, visibility and deletion with it.

Store it in the OS keychain, not a `.env`:

```shell
security add-generic-password -a "$USER" -s gh-token-<site> -w
```

Then export it **only** into VS Code's resolved environment, in `~/.zshrc`:

```shell
if [[ -n $VSCODE_RESOLVING_ENVIRONMENT ]]; then
  export SITE_GH_TOKEN="$(security find-generic-password -a "$USER" -s gh-token-<site> -w 2>/dev/null)"
fi
```

The rename from `GH_TOKEN` to `SITE_GH_TOKEN` on the host is the point: `gh`
prefers `GH_TOKEN` over its stored credentials, so exporting it under that name
would re-authenticate every host terminal as this account. Compose renames it back
on the way in, so only the container sees `GH_TOKEN`.

{{< callout type="info" >}}
VS Code resolves that shell once per app session. After adding the export, fully
quit and relaunch — Reload Window and Rebuild Container both reuse the cache.
{{< /callout >}}

## 6. The deploy key

The Action needs to push to the published repo. That is a third credential, with
no passphrase, because CI cannot type one:

```shell
ssh-keygen -t ed25519 -N '' -C '<site> pages deploy' -f ~/.ssh/tmp-deploy
```

A fresh pair. GitHub rejects the same public key as a deploy key on a second
repository, so one cannot be shared between sites.

Public half → **published** repo, Settings → Deploy keys → Add deploy key, and
**tick Allow write access**:

```shell
pbcopy < ~/.ssh/tmp-deploy.pub
```

Private half → **source** repo, Settings → Secrets and variables → Actions → New
repository secret, named `DEPLOY_KEY` exactly:

```shell
pbcopy < ~/.ssh/tmp-deploy
```

Paste it whole, including the `BEGIN`/`END` lines and the trailing newline.

Then delete both local copies and clear the clipboard:

```shell
rm -f ~/.ssh/tmp-deploy ~/.ssh/tmp-deploy.pub
pbcopy < /dev/null
```

{{< callout type="warning" >}}
The halves go in different repositories, and a secret cannot be read back to
check. Confirm both landed before deleting, or the only fix is a new pair.
{{< /callout >}}

## 7. The two workflows

`.github/workflows/pages.yml` — builds and publishes, on pushes to `main`:

```yaml
on:
  push:
    branches: ["main"]
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0 # enableGitInfo needs real history
      - uses: actions/setup-go@v7
      - run: hugo --gc --minify --baseURL "https://<domain>/"
      - uses: peaceiris/actions-gh-pages@v4
        with:
          deploy_key: ${{ secrets.DEPLOY_KEY }}
          external_repository: <user>/<user>.github.io
          publish_branch: main
          publish_dir: ./public
          enable_jekyll: false
          force_orphan: true
```

`enable_jekyll: false` writes `.nojekyll`. Without it Pages runs the output
through Jekyll, which silently drops every path starting with an underscore.

`.github/workflows/build-check.yml` — same build, output discarded:

```yaml
on:
  pull_request:
    branches: ["main"]
  push:
    branches-ignore: ["main"]
jobs:
  build:
    name: Build site
```

Remember `jobs.build.name`. That string, not the workflow's own `name:`, is what
step 9 requires.

## 8. First push, then Pages and DNS

```shell
git remote add origin git@github.com-<account>:<user>/<site>.git
git add -A && git commit -m "Initial commit"
git push -u origin main
```

That is also the first publish. `force_orphan` works on an empty repository, so it
creates `main` on the published side — which is what the next step needs to exist:

Published repo → Settings → Pages → Source **Deploy from a branch** → `main` /
`/ (root)`.

DNS for the apex domain:

```
@      A      185.199.108.153
@      A      185.199.109.153
@      A      185.199.110.153
@      A      185.199.111.153
www    CNAME  <user>.github.io
```

Enforce HTTPS once the certificate issues.

## 9. Protect main

A push to `main` publishes, so `main` is a release branch. Source repo → Settings
→ Rules → New ruleset → New branch ruleset:

- Enforcement **Active**, bypass list **empty** — otherwise it does not apply to
  you, and you are the only one who would push
- Target: **Include default branch**
- **Restrict deletions**, **Block force pushes**
- **Require a pull request before merging** — approvals `0`, allowed merge methods
  **Squash** only
- **Require status checks to pass** → `Build site`

Three traps, in the order you hit them:

- Create the ruleset **after** step 8. The require-PR rule rejects the push that
  creates the branch.
- `Build site` is the **job** name. Renaming the job detaches the requirement
  silently, with no error.
- `Build site` is not selectable until it has reported once, and pushing `main`
  never runs it — `build-check.yml` ignores that branch. Push any other branch
  once, then add the check. Creating the ruleset without that one rule and adding
  it later is fine.

## 10. Last, because they need the site to exist

Analytics and comments both want IDs that cannot be generated beforehand: a GA4
measurement ID, and giscus `repoId` / `categoryId` against the published repo.
Blank giscus IDs render the widget and then fail in the browser, so leave comments
off until the IDs are real.

From here every change is a branch and a squashed PR. The merge is the publish.
