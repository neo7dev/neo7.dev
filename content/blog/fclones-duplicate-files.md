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

The thing that makes fclones usable on a disk you care about is that finding and
deleting are two separate commands. The search writes a report. You read it. Only then
does anything get removed.

## Install

{{< borderless-table >}}

| Where           | Command                                       |
| --------------- | --------------------------------------------- |
| Rust toolchain  | `cargo install fclones`                       |
| macOS           | `brew install fclones`                        |
| Debian / Ubuntu | `apt install fclones`                         |
| Anything else   | prebuilt binaries on the GitHub releases page |

{{< /borderless-table >}}

Check the package exists in your distribution before reaching for `cargo` — it arrived
in Debian and Ubuntu relatively recently.

```shell
fclones --version
```

## Two phases

```shell
fclones group ~/photos > dupes.txt   # read-only, writes a report
fclones remove < dupes.txt           # destructive, consumes the report
```

`group` never modifies anything. Everything that deletes, links or moves reads a report
on stdin. That means you can open the report, delete lines you want spared, and pipe the
edited file — the second command only acts on what it is given.

The report looks like this:

```text
# Report by fclones 0.34.0
# Timestamp: ...
2a4f1c90, 4823104 b (4.8 MB) * 3:
    /srv/source/img_0241.cr2
    /mnt/backup/2023/img_0241.cr2
    /mnt/scratch/import/img_0241.cr2
```

Hash, size, replica count, then one path per copy.

## Finding duplicates

```shell
fclones group /srv/source /mnt/backup > dupes.txt
```

Several roots is the normal case — that is how you find the same file in two places.

Narrowing the search:

{{< borderless-table >}}

| Flag                     | Does                                           |
| ------------------------ | ---------------------------------------------- |
| `-s, --min-size 1M`      | ignore anything smaller                        |
| `--max-size 2G`          | ignore anything larger                         |
| `--name '*.jpg'`         | match on file name glob                        |
| `--path '**/raw/**'`     | match on full path glob                        |
| `--exclude '**/.git/**'` | skip a subtree                                 |
| `-d, --depth 3`          | limit recursion                                |
| `-H, --hidden`           | include dotfiles                               |
| `--one-fs`               | do not cross filesystem boundaries             |
| `-f, --format json`      | machine-readable report (also `csv`, `fdupes`) |

{{< /borderless-table >}}

`--min-size` earns its place first. Most of the file count on a disk is tiny files whose
duplication saves nothing, and excluding them makes the run dramatically faster.

## Deleting, keeping the copy in the source directory

This is the whole point, and it is one flag:

```shell
fclones group /srv/source /mnt/scratch > dupes.txt
fclones remove --keep-path '/srv/source/**' --dry-run < dupes.txt
```

Read the output. Then run it for real:

```shell
fclones remove --keep-path '/srv/source/**' < dupes.txt
```

Every copy outside `/srv/source` goes; the one inside stays. `--drop-path` is the
inverse — name what to delete instead of what to protect.

{{< callout type="warning" >}}
`--keep-path` takes a glob against the **full path**, so run `group` with absolute
roots. A relative root produces relative paths in the report, your absolute pattern
matches nothing, and the protection you thought you had does not exist.
{{< /callout >}}

{{< callout type="error" >}}
`--dry-run` is not optional on a first run. A pattern that matches nothing in a group
protects nothing in that group. Read the dry-run output for the directory you meant to
keep before you let it delete anything.
{{< /callout >}}

## Choosing which copy survives

When no path rule applies, `--priority` decides:

{{< borderless-table >}}

| Value                     | Keeps               |
| ------------------------- | ------------------- |
| `newest` / `oldest`       | by creation time    |
| `most-recently-modified`  | by mtime            |
| `least-recently-modified` | by mtime            |
| `most-recently-accessed`  | by atime            |
| `least-nested`            | the shallowest path |
| `most-nested`             | the deepest path    |

{{< /borderless-table >}}

```shell
fclones remove --priority least-nested < dupes.txt
```

Rules stack: `--keep-path` first, then `--priority` to break ties among the rest.

## Instead of deleting

Same report, different verb:

```shell
fclones link < dupes.txt       # replace duplicates with hard links
fclones link --soft < dupes.txt  # symlinks instead
fclones dedupe < dupes.txt     # reflink/copy-on-write, on btrfs, XFS and APFS
fclones move /mnt/quarantine < dupes.txt
```

`dedupe` is the one to prefer where the filesystem supports it: the copies keep separate
inodes and separate metadata, but share the underlying blocks until one is written to.
Hard links do not — edit one and you have edited all of them.

`move` is the cautious option. Nothing is destroyed, the duplicates land somewhere you
can inspect, and you delete that directory when you are satisfied.

## Speed

```shell
fclones group --cache -t 8 --hash-fn blake3 /srv /mnt/backup > dupes.txt
```

- **`--cache`** stores hashes between runs. The second run over the same tree skips
  everything unchanged, which turns a repeat dedupe from minutes into seconds.
- **`-t, --threads`** — the default is tuned for SSDs. On spinning disks, more threads is
  usually slower, not faster.
- **`--hash-fn`** defaults to a fast non-cryptographic hash, which is the right default
  for finding duplicates. Matching is decided by that hash, so if you want a
  cryptographic guarantee against a crafted collision, ask for `blake3` or `sha256`.

fclones is cheap by design: it groups by size first, then by a prefix of each file, and
only hashes in full what survives both.

## Traps

- **Already-hardlinked files are not duplicates.** They share an inode, so there is
  nothing to reclaim and fclones does not report them.
- **The report goes stale.** It records paths and hashes at a moment in time. Regenerate
  it rather than reusing yesterday's against a tree that has moved on.
- **`remove` follows the report, not the disk.** If you edited the report, what you
  edited is what happens. That is the feature, and it is also the way to delete something
  you meant to keep.
- **Check `--rf-over` if the counts look wrong.** It sets how many replicas make a group
  interesting; the default finds anything appearing more than once, which is usually what
  you want and occasionally is not.

## Reference

The manual is thorough and worth reading once:

```shell
fclones group --help
fclones remove --help
```
