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

## Commands

```shell
make dev      # :8043 live reload, drafts and future posts included
make preview  # :8043 production mode — minified, no drafts
make prod     # write public/ exactly as CI does
make clean    # remove build output
make help     # everything else
```

`public/` is a build artifact — nothing serves it locally. Every target above
writes it, so whatever ran last is what is in there; run `make prod` before
trusting it to match what CI produces.

## Deployment

`.github/workflows/pages.yml` builds on every push to `main` and publishes to
GitHub Pages. The custom domain comes from `static/CNAME`, which Hugo copies
verbatim into `public/`.
