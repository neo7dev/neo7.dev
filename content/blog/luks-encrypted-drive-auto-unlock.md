---
title: "Encrypting a disk with LUKS, and unlocking it on boot"
date: 2026-10-03T21:20:00+05:30
authors:
  - name: neo7.dev
tags:
  - linux
  - storage
  - security
excludeSearch: false
summary: "Setting up a LUKS volume with a passphrase, adding a key file so it unlocks without one, wiring crypttab and fstab so it mounts at boot, and the key management that decides whether you ever get the data back."
# `coverText` renders in the card cover slot with the prompt glyph from
# params.command.prompt until there is a real cover image.
coverText: |
  cryptsetup luksFormat
---

{{< lead >}}
Disk encryption with LUKS: passphrase, key file, and automatic unlock at boot.
{{< /lead >}}

<!--more-->

LUKS encrypts a block device at rest. Pull the disk out of the machine and it is
noise. Leave the machine running and the data is as readable as any other mount —
encryption protects the disk, not the host.

That distinction decides the whole design. A passphrase typed at boot protects a
stolen laptop. A key file on the same machine protects a disk pulled from a server,
and nothing else. Both are legitimate; pick knowingly.

## Prerequisites

1. Ubuntu 22.04 LTS or higher, or any distribution with `cryptsetup` 2.x.
2. A disk or partition you can erase.

## Setting up the encrypted volume

{{% steps %}}

### Get a `sudo -s` session

Everything below assumes you are root.

```shell
sudo -s
```

### Install cryptsetup

```shell
apt install cryptsetup
```

### Identify the device

```shell
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,SERIAL
```

{{< callout type="error" >}}
`luksFormat` destroys everything on the device. Confirm the target against its serial
number, not against the `/dev/sdX` letter — those are assigned in discovery order and
change between boots.
{{< /callout >}}

### Format it as a LUKS volume

```shell
cryptsetup luksFormat --type luks2 /dev/sdb1
```

It asks for confirmation — `YES`, in capitals, not `y` — and then for a passphrase,
twice. That passphrase goes into key slot 0.

{{< callout type="info" >}}
LUKS2 is the default on current distributions and is the right choice for a data
volume: larger header, metadata redundancy, and Argon2id key derivation, which is
memory-hard and therefore much more expensive to attack than LUKS1's PBKDF2. Use
`--type luks1` only for a volume that GRUB has to read directly.
{{< /callout >}}

### Open it

Unlocking maps a decrypted device under `/dev/mapper/`. The name is yours to pick:

```shell
cryptsetup open /dev/sdb1 cryptdata
ls -l /dev/mapper/cryptdata
```

From here on, `/dev/mapper/cryptdata` is the device you treat as a disk.
`/dev/sdb1` is the encrypted container and is never formatted or mounted directly.

### Create the filesystem

On the mapper device, not on the partition:

```shell
mkfs.ext4 /dev/mapper/cryptdata
```

### Get both UUIDs with `blkid`

A LUKS volume has two UUIDs, and the next two config files want one each:

```shell
blkid /dev/sdb1
blkid /dev/mapper/cryptdata
```

```text
/dev/sdb1: UUID="3f1c9a7e-24b8-4d06-9e5f-c81a2b7d6034" TYPE="crypto_LUKS"
/dev/mapper/cryptdata: UUID="b7e24d91-0c3a-45f8-a16d-9d2e7f4c5801" TYPE="ext4"
```

{{< callout type="warning" >}}
The `crypto_LUKS` UUID identifies the **container** and belongs in `/etc/crypttab`.
The `ext4` UUID identifies the **filesystem inside it** and belongs in `/etc/fstab`.
Swapping them produces a volume that unlocks but never mounts, or a boot that hangs
waiting for a device that will never appear.
{{< /callout >}}

### Add it to `/etc/crypttab`

Four fields: mapper name, source device, key file, options. `none` in the key field
means "prompt for the passphrase":

```text
cryptdata  UUID=3f1c9a7e-24b8-4d06-9e5f-c81a2b7d6034  none  luks,discard,nofail
```

`nofail` keeps a missing or unopenable volume from blocking the boot. On a headless
machine it is the difference between a degraded boot and no boot at all.

### Add it to `/etc/fstab`

Mount the mapper device, by the filesystem UUID:

```shell
mkdir -p /mnt/secure
```

```text
UUID=b7e24d91-0c3a-45f8-a16d-9d2e7f4c5801  /mnt/secure  ext4  defaults,nofail  0  2
```

### Test it without rebooting

Close the volume, then let systemd reopen it the way boot will:

```shell
umount /mnt/secure 2>/dev/null
cryptsetup close cryptdata
systemctl daemon-reload
systemctl start systemd-cryptsetup@cryptdata.service
mount -a
findmnt /mnt/secure
```

With `none` as the key file, that service prompts for the passphrase. If it unlocks
and `findmnt` shows the mount, both files are correct.

{{% /steps %}}

## Unlocking with a key file

A passphrase at every boot is correct for a laptop and impractical for a server that
reboots unattended. A key file is a second credential in its own key slot: the volume
still accepts the passphrase, and now also accepts a file.

{{% steps %}}

### Generate the key

Random bytes, not a password. 4 KiB is conventional:

```shell
mkdir -p /etc/luks
chmod 0700 /etc/luks
dd if=/dev/urandom of=/etc/luks/cryptdata.key bs=512 count=8
chmod 0400 /etc/luks/cryptdata.key
chown root:root /etc/luks/cryptdata.key
```

### Add it to a key slot

This asks for an existing passphrase, because adding a credential requires proving
you already hold one:

```shell
cryptsetup luksAddKey /dev/sdb1 /etc/luks/cryptdata.key
```

Confirm it landed:

```shell
cryptsetup luksDump /dev/sdb1 | grep -A2 Keyslots
```

LUKS2 has 32 key slots. Each holds an independent credential, any one of which opens
the volume.

### Point crypttab at it

Replace `none` with the path:

```text
cryptdata  UUID=3f1c9a7e-24b8-4d06-9e5f-c81a2b7d6034  /etc/luks/cryptdata.key  luks,discard,nofail
```

### Test it, again

```shell
umount /mnt/secure
cryptsetup close cryptdata
systemctl daemon-reload
systemctl start systemd-cryptsetup@cryptdata.service
mount -a
findmnt /mnt/secure
```

No prompt this time. Reboot once to confirm, while you still remember what you
changed.

{{% /steps %}}

{{< callout type="warning" >}}
Be honest about what this buys. A key file on an unencrypted root filesystem means
anyone who takes the whole machine takes the key with it. The volume is still
protected against a disk pulled from the chassis, a disk sent for RMA, and a disk
resold — which is most of what disk encryption is for on a server, and none of what
it is for on a laptop.
{{< /callout >}}

## Unlocking from the TPM instead

On hardware with a TPM 2.0, `systemd-cryptenroll` seals a key to the platform state
rather than storing it in a file. The disk unlocks on this machine, and does not
unlock in another:

```shell
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/sdb1
```

Then set the crypttab option and drop the key file field back to `none`:

```text
cryptdata  UUID=3f1c9a7e-24b8-4d06-9e5f-c81a2b7d6034  none  luks,discard,nofail,tpm2-device=auto
```

{{< callout type="warning" >}}
PCR 7 covers Secure Boot state. Changing the boot configuration — enrolling keys,
switching bootloaders, some firmware updates — changes the measurement and the TPM
stops releasing the key. Keep the passphrase slot populated, because that is what
you will be unlocking with the day it happens.
{{< /callout >}}

## Managing keys

```shell
cryptsetup luksDump /dev/sdb1                    # which slots are populated
cryptsetup luksChangeKey /dev/sdb1               # replace one credential
cryptsetup luksAddKey /dev/sdb1                  # add a passphrase to a free slot
cryptsetup luksKillSlot /dev/sdb1 1              # destroy slot 1
```

Two rules that matter more than the commands:

- **Keep at least two slots populated.** A passphrase you can type, plus whatever
  automated credential the machine uses. Removing the last recoverable one is
  unrecoverable.
- **Changing a passphrase does not re-encrypt anything.** Every slot wraps the same
  master key, and the data is encrypted under that. A rotated passphrase stops the
  old passphrase working; it does nothing about a master key that has leaked. For
  that you need `cryptsetup reencrypt`, which rewrites the volume.

## Back up the header

The LUKS header holds the key slots and the wrapped master key. Corrupt it and the
data is gone — not difficult to recover, gone, in the same sense that random bytes
are gone.

```shell
cryptsetup luksHeaderBackup /dev/sdb1 \
  --header-backup-file /root/cryptdata-header.img
```

Restoring it:

```shell
cryptsetup luksHeaderRestore /dev/sdb1 \
  --header-backup-file /root/cryptdata-header.img
```

{{< callout type="error" >}}
The header backup is a file that opens the volume with any passphrase that was valid
when the backup was taken. Store it like a key, off the machine, encrypted. And note
the corollary: restoring an old header resurrects a passphrase you thought you had
removed.
{{< /callout >}}

## Traps

- **Format the mapper, mount the mapper.** `mkfs` on `/dev/sdb1` after `luksFormat`
  destroys the header and the volume with it.
- **`nofail` in both files.** Without it, an unopenable volume stops the boot at a
  prompt that a headless machine cannot answer.
- **`update-initramfs -u` only when the volume is needed early.** A data volume that
  systemd opens after the root filesystem is mounted does not need it. A LUKS root
  filesystem does, and so does any volume whose key file must live in the initramfs —
  which also means that key file gets copied into an image on an unencrypted `/boot`.
- **`discard` leaks a little.** Passing TRIM through to the underlying SSD tells an
  observer which blocks are unused, and therefore roughly how full the volume is.
  Usually an acceptable trade for SSD lifetime; a deliberate choice either way.
- **Test the reboot while the change is fresh.** Every failure mode here surfaces at
  boot, which is the least convenient moment to debug a config file you edited a week
  ago.
