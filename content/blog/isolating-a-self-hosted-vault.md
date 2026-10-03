---
title: "Keeping a password vault off the rest of the network"
date: 2026-10-03
authors:
  - name: neo7.dev
tags:
  - docker
  - security
  - self-hosting
excludeSearch: false
summary: "A self-hosted password manager is the one service whose compromise costs you everything else. That argues for giving it its own network, its own ingress, and no path to the stack it shares a host with."
# `coverText` renders in the card cover slot with the prompt glyph from
# params.command.prompt until there is a real cover image.
coverText: |
  vault --isolate
---

{{< lead >}}
Give the password vault its own bridge network, sized for the number of containers on
it rather than assumed, reach it through an outbound tunnel instead of the reverse
proxy the rest of the stack shares, pin the image, and test the restore.
{{< /lead >}}

<!--more-->

Most self-hosted services fail cheaply. A media indexer or a dashboard gets
compromised and you rebuild it. A password vault is different: it holds the
credentials to everything else, so its blast radius is not the host it runs on —
it is every account you have.

That asymmetry justifies treating it differently from the rest of the stack,
even on a host where everything else shares one reverse proxy and one bridge
network.

## Three things to separate

**Its network.** The shared bridge network that a reverse proxy uses to reach a
dozen containers is a flat segment. Any container on it can open a connection to
any other. The vault does not need to talk to the dashboard, the download client
or the monitoring stack, and none of them need to talk to it.

**Its ingress.** Everything else can sit behind the shared proxy. The vault is
the one service where you would rather not have the proxy as a shared dependency
at all — a misconfigured router rule on a busy proxy is one typo away from
exposing something that should not be exposed.

**Its upgrade path.** Automatic image updates are reasonable for services where
a broken update means an hour of downtime. For the vault, pin and update
deliberately.

## A network sized for what is on it

Create a dedicated bridge network with an explicit subnet, so the containers get
stable addresses and the segment is documented rather than whatever Docker's
address pool handed out:

```shell
docker network create \
  --driver=bridge \
  --subnet=10.123.0.0/29 \
  --gateway=10.123.0.1 \
  --ipv6=false \
  vault
```

{{< callout type="error" >}}
Count the addresses before you pick the prefix. A `/30` is four addresses:
network, gateway, **one** usable host, broadcast. It does not hold two
containers, let alone three — and the failure is an unhelpful address-allocation
error at `up` time rather than anything that names the real problem. A `/29`
gives eight addresses and five usable hosts. Size for what you will run, then
add one.
{{< /callout >}}

Pick a range that does not overlap your LAN or Docker's default pools. A
collision here produces routing that works until the one day it does not.

Attach the service with a fixed address:

```yaml
services:
  vault:
    image: vaultwarden/server:1.32.7
    container_name: vault
    restart: always
    user: "${UID}:${GID}"
    networks:
      vault:
        ipv4_address: 10.123.0.2
    security_opt:
      - no-new-privileges:true
      - apparmor:docker-default
    volumes:
      - ${DIR_VAULT_DATA}:/data
    env_file:
      - stack.env
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 1G
        reservations:
          cpus: "1"
          memory: 512M

networks:
  vault:
    external: true
```

What each of those is doing:

- **`user:`** runs the process as an unprivileged account that owns the data
  directory and nothing else on the host. Supply the real UID and GID through the
  environment rather than hard-coding them; they differ per host.
- **`no-new-privileges`** stops the process gaining privileges through a setuid
  binary. It costs nothing and closes the most common escalation route.
- **`apparmor:docker-default`** is the profile the runtime applies anyway. Stating
  it makes the intent explicit and makes its absence visible in review.
- **No `ports:` key.** Nothing is published to the host. The only way in is the
  one described below.
- **Resource limits** so that a runaway process cannot starve the rest of the
  host. A vault is not a demanding workload; cap it well below what the machine
  has.

## Ingress without an open port

The alternative to port-forwarding or a shared reverse proxy is an outbound
tunnel: a lightweight client on the isolated network dials out to a provider and
serves the vault through that connection. Nothing listens on the host's public
interface and the router keeps no forwarded ports.

```yaml
services:
  tunnel:
    image: cloudflare/cloudflared:2024.12.2
    container_name: vault-tunnel
    restart: unless-stopped
    user: "${UID}:${GID}"
    command: tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}
    networks:
      vault:
        ipv4_address: 10.123.0.3
    security_opt:
      - no-new-privileges:true
      - apparmor:docker-default
    env_file:
      - stack.env
    deploy:
      resources:
        limits:
          cpus: "1"
          memory: 256M

networks:
  vault:
    external: true
```

The tunnel's route points at `http://10.123.0.2:80` — an address that only exists
inside that one network. Two containers, one segment, and no path from either to
the rest of the stack.

{{< callout type="warning" >}}
Be clear about what this buys. The isolated network protects the rest of your
stack from the vault and the vault from the rest of the stack. The tunnel does
not protect the vault from the internet — it publishes it, through a third
party that terminates TLS. If that is not the trade you want, put an
authentication layer in front of the tunnel's hostname, or skip public exposure
entirely and reach the vault over a VPN instead.
{{< /callout >}}

The tunnel token is a credential that grants the ability to publish traffic as
your hostname. It belongs in the environment file, that file belongs to the same
unprivileged user, and it is mode `0600`.

## Not everything belongs on this network

The temptation, having built an isolated segment, is to move other
security-adjacent services onto it. Resist it for two reasons.

The obvious one: each additional container is another thing that can reach the
vault. A segment with five services on it is a flat network again, just a smaller
one.

The less obvious one: some services do not work there at all. A network scanner
or discovery tool needs to see broadcast traffic on the real LAN, and an isolated
bridge network is exactly the thing that prevents it. Put one on this segment and
it will start cleanly, report nothing, and look like a configuration problem for
an afternoon. Those services need host networking or a macvlan interface — which
is the opposite of isolation, and a good argument for keeping them on a different
host entirely.

## The service configuration that matters

Network isolation does not help if the application is configured to let anyone
in.

- **Close registration.** `SIGNUPS_ALLOWED=false` once your accounts exist.
  Leave invitations on if you need to add people, off otherwise.
- **Hash the admin token.** Vaultwarden accepts an Argon2 hash in place of a
  plaintext `ADMIN_TOKEN`, generated by its own CLI. A plaintext token sits in an
  environment file and in `docker inspect` output. Better still: leave the admin
  interface disabled entirely and enable it only when you need it.
- **Raise the KDF iterations.** The client-side key derivation is what protects
  the vault if the encrypted blob is ever taken. Current guidance for PBKDF2 is
  600,000 iterations and rising; set it above the default and verify what your
  clients actually negotiated.
- **Configure SMTP.** Not a convenience — it is how two-factor codes and security
  alerts reach you.
- **Enable write-ahead logging** on the SQLite database. It improves concurrent
  access and reduces the window in which a crash corrupts the file.

## Pin the image, and back up the data

Automatic container updates are a reasonable default for most of a homelab. For
this one, pin the tag to a specific version and update when you have read the
release notes — a vault that silently updates itself into a broken state locks
you out of everything, at the exact moment you cannot look up a password to fix
it.

Back up the data directory on a schedule, encrypt the backup, and store a copy
somewhere that is not the host. Then **restore it somewhere else and log in**.
A password vault backup you have never tested is a password vault backup you do
not have, and the day you find out is the worst possible day to find out.
