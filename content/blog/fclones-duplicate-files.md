---
title: "Finding and removing duplicate files with fclones"
date: 2026-10-03T22:30:00+05:30
authors:
  - name: neo7.dev
tags:
  - linux
  - storage
excludeSearch: false
summary: "fclones splits deduplication into a read-only search and a separate destructive pass, which is what makes it safe to point at a disk you care about. Finding duplicates, keeping the copy in the directory you choose, and the flags that decide which copy survives."
# `coverText` renders in the card cover slot with the prompt glyph from
# params.command.prompt until there is a real cover image.
coverText: |
  fclones group
---

{{< lead >}}
Find duplicate files, then delete the copies while keeping the ones in a directory you
name.
{{< /lead >}}

<!--more-->

What makes fclones usable on a disk you care about is that finding and deleting are two
separate commands. The search writes a report. You read it. Only then does anything get
removed.

## Install

{{< borderless-table >}}

| Where          | Command                           |
| -------------- | --------------------------------- |
| Linux          | `snap install fclones`            |
| macOS or Linux | `brew install fclones`            |
| Rust toolchain | `cargo install fclones`           |
| Anything else  | binaries attached to the releases |

{{< /borderless-table >}}

Third-party packages exist for Arch, Alpine and NixOS. There is no Debian or Ubuntu
package — use snap or cargo.

```shell
fclones --version
eval "$(fclones complete bash)"   # completions, if you want them
```

## Two phases

```shell
fclones group ~/photos > dupes.txt   # read-only, writes a report
fclones remove < dupes.txt           # destructive, consumes the report
```

`group` modifies nothing. Every destructive verb reads a report on stdin. So you can
open the report, delete the lines you want spared, and pipe the edited file — the second
command acts only on what it is given. Piping straight through works too:

```shell
fclones group . | fclones link
```

The report:

```text
# Report by fclones 0.35.0
# Timestamp: 2026-10-03 22:14:08.112 +0530
# Command: fclones group /srv/source /mnt/scratch
# Found 2 file groups
# 9.6 MB (9.6 MB) in 2 redundant files can be removed
7d6ebf613bf94dfd976d169ff6ae02c3, 4823104 B (4.8 MB) * 2:
/srv/source/img_0241.cr2
/mnt/scratch/import/img_0241.cr2
```

Hash, size, replica count, then one path per line.

## Finding duplicates

```shell
fclones group /srv/source /mnt/backup > dupes.txt
```

Several roots is the normal case — that is how you find the same file in two places.

{{< borderless-table >}}

| Flag                     | Does                                            |
| ------------------------ | ----------------------------------------------- |
| `-s 100M`                | ignore anything smaller                         |
| `--name '*.jpg' '*.png'` | match on file name glob                         |
| `--path '/home/**'`      | match on full path glob                         |
| `--exclude '/proc/**'`   | skip a subtree                                  |
| `--depth 1`              | limit recursion                                 |
| `--hidden --no-ignore`   | include dotfiles and ignored files              |
| `-L`                     | follow symbolic links                           |
| `--isolate`              | match across roots, not within one              |
| `--unique`               | invert: files with no duplicate                 |
| `--rf-under 3`           | under-replicated files                          |
| `--rf-over 3`            | files appearing more than three times           |
| `--stdin`                | take the file list from stdin, e.g. from `find` |

{{< /borderless-table >}}

{{< callout type="warning" >}}
By default fclones **skips hidden files and anything matching `.gitignore` or
`.fdignore`**. If a file you expected is missing from the report, that is usually why.
`--hidden --no-ignore` turns both off.
{{< /callout >}}

`--isolate` is the one worth knowing for the case below: it finds files that exist in
both trees without treating two copies inside the same tree as duplicates.

## Keeping the copy in the source directory

```shell
fclones group /srv/source /mnt/scratch > dupes.txt
fclones remove --keep-path '/srv/source/**' --dry-run < dupes.txt
```

Read the output. Then run it for real, without `--dry-run`.

Four flags select files, and they are symmetrical:

{{< borderless-table >}}

| Flag                          | Means                         |
| ----------------------------- | ----------------------------- |
| `--path '/trash/**'`          | only remove files under here  |
| `--name '*.jpg'`              | only remove files named this  |
| `--keep-path '/important/**'` | never remove files under here |
| `--keep-name '*.mov'`         | never remove files named this |

{{< /borderless-table >}}

{{< callout type="error" >}}
The globs match the **full path**, so run `group` with absolute roots. A relative root
produces relative paths in the report, your absolute pattern matches nothing, and the
protection you thought you had does not exist. `--dry-run` is how you find that out
before it costs you.
{{< /callout >}}

`--dry-run` prints the exact shell commands it would run. The progress log goes to
stderr, so `2>/dev/null` leaves just the commands:

```shell
fclones remove --keep-path '/srv/source/**' --dry-run < dupes.txt 2>/dev/null
```

## Which copies go

Default: fclones keeps the files at the **start** of each group in the report and
removes the ones at the end. The report order is therefore the policy, which is why
editing the report works.

`--priority` changes that order, and it names what gets **removed**:

```shell
fclones remove --priority newest < dupes.txt   # remove the newest replicas
fclones remove --priority oldest < dupes.txt   # remove the oldest replicas
```

`fclones remove --help` lists the rest.

To keep more than one copy, `-n` sets how many survive per group:

```shell
fclones remove -n 2 < dupes.txt   # leave two replicas
```

## Instead of deleting

Same report, different verb:

```shell
fclones link < dupes.txt            # hard links
fclones link -s < dupes.txt         # symbolic links (also --soft)
fclones dedupe < dupes.txt          # reflink, on btrfs, XFS and APFS
fclones move /mnt/quarantine < dupes.txt
```

`dedupe` is the one to prefer where the filesystem supports it: copies keep separate
inodes and separate metadata but share blocks until one is written to. Hard links do not
— edit one and you have edited all of them.

`move` destroys nothing. The duplicates land somewhere you can inspect, and you delete
that directory once you are satisfied.

## Speed

```shell
fclones group --cache /srv /mnt/backup > dupes.txt
```

`--cache` persists each hash with the file's size and mtime. Subsequent runs over the
same tree skip everything unchanged, and an interrupted run resumes cheaply. On a large
dataset it is the single flag worth adding.

The hashing ladder is why it is fast without the cache: group by size, drop unique
sizes, drop same-inode entries, hash a block from the start, hash a block from the end,
and only then hash the whole file — pruning groups at every step.

{{< borderless-table >}}

| `--hash-fn`         | Width   | Cryptographic |
| ------------------- | ------- | ------------- |
| `metro` _(default)_ | 128-bit | no            |
| `xxhash3`           | 128-bit | no            |
| `blake3`            | 256-bit | yes           |
| `sha256` / `sha512` | 256/512 | yes           |

{{< /borderless-table >}}

{{< callout type="info" >}}
fclones never compares files byte for byte. Matching is decided by the hash, which is
why every option is at least 128 bits wide. The default is fine unless your threat model
includes someone deliberately crafting a collision.
{{< /callout >}}

## Traps

- **Hard-linked and symlinked files are not duplicates.** They already share data, so
  there is nothing to reclaim. `--match-links` changes that, and combining it with
  `--symbolic-links` is how you end up with a directory of orphan links.
- **The report goes stale.** It records paths and hashes at a moment in time. Regenerate
  it rather than reusing yesterday's against a tree that has moved on.
- **`remove` follows the report, not the disk.** If you edited the report, what you
  edited is what happens. That is the feature, and also the way to delete something you
  meant to keep.
- **Quote your globs.** An unquoted `--name *.jpg` is expanded by the shell before
  fclones sees it.

## Reference

[pkolaczk/fclones](https://github.com/pkolaczk/fclones). The README covers link
handling, `--transform` for preprocessing files before matching, and the cache
internals.

```shell
fclones group --help
fclones remove --help
```
