---
title: "Software RAID on Ubuntu with mdadm"
date: 2026-10-03
authors:
  - name: neo7.dev
tags:
  - linux
  - storage
excludeSearch: false
summary: "Creating RAID 0, 1, 5, 6 and 10 arrays with mdadm, then the part that actually matters: saving the config, monitoring it, scrubbing it, and swapping a dead disk without losing the array."
# `coverText` renders in the card cover slot with the prompt glyph from
# params.command.prompt until there is a real cover image.
coverText: |
  mdadm --create
---

{{< lead >}}
Creating an array is one command. Everything that keeps it alive is the rest: write
the config and rebuild the initramfs or it will not assemble on reboot, enable mail
alerts or a failure is silent, scrub monthly, and rehearse a disk replacement before
you need one.
{{< /lead >}}

<!--more-->

RAID is uptime, not backup. A deleted file is deleted on every disk at once. What it
buys is staying online through a dead drive, and more throughput than one spindle.

## Before you create anything

Identify the disks and confirm they are the ones you think:

```shell
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,SERIAL
```

Install the tools, then wipe any old signature — a leftover superblock makes an array
assemble itself at boot under a name you did not choose:

```shell
sudo apt install mdadm
sudo wipefs -a /dev/sdb
sudo mdadm --zero-superblock /dev/sdb   # only if it was in a previous array
```

**Partition or whole disk?** Whole disks work. Partitions are better: create one
partition a few GB short of the disk, and a replacement drive that is nominally the
same size but a few sectors smaller still fits.

```shell
sudo parted /dev/sdb mklabel gpt
sudo parted -a optimal /dev/sdb mkpart primary 0% 100%
sudo parted /dev/sdb set 1 raid on
```

{{< callout type="error" >}}
`mdadm --create` destroys everything on every device listed. Check `lsblk` output
against the serial numbers, not against the letters — `/dev/sdX` names are assigned
in discovery order and can change between boots.
{{< /callout >}}

## The levels

| Level | Min disks | Usable    | Survives          | Cost                              |
| ----- | --------- | --------- | ----------------- | --------------------------------- |
| 0     | 2         | 100%      | nothing           | one disk dies, all data gone      |
| 1     | 2         | 50%       | n−1 disks         | writes go to every disk           |
| 5     | 3         | n−1 disks | 1 disk            | read-modify-write on small writes |
| 6     | 4         | n−2 disks | 2 disks           | two parity computations per write |
| 10    | 4         | 50%       | 1 per mirror pair | none worth naming                 |

Choosing, briefly: **6 over 5** on any array of large disks, because a rebuild reads
every sector of every remaining disk and that is exactly when a second drive fails.
**10 over 5/6** when the workload is random writes — no parity, no read-modify-write.
**1** for two disks. **0** only for scratch data you can regenerate.

## Creating each level

All of these take the same shape. `/dev/md0` is the array name, `--raid-devices` is
the count, and the device list follows.

**RAID 0** — striping, no redundancy:

```shell
sudo mdadm --create /dev/md0 --level=0 --raid-devices=2 /dev/sd[bc]1
```

**RAID 1** — mirror:

```shell
sudo mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/sd[bc]1
```

**RAID 5** — single parity, three disks minimum:

```shell
sudo mdadm --create /dev/md0 --level=5 --raid-devices=3 /dev/sd[bcd]1
```

**RAID 6** — double parity, four disks minimum:

```shell
sudo mdadm --create /dev/md0 --level=6 --raid-devices=4 /dev/sd[bcde]1
```

**RAID 10** — striped mirrors, four disks minimum:

```shell
sudo mdadm --create /dev/md0 --level=10 --raid-devices=4 /dev/sd[bcde]1
```

Two optional flags worth knowing:

- `--spare-devices=1` with an extra device appended. The spare sits idle and the
  array starts rebuilding onto it the moment a disk fails, without waiting for you.
- `--bitmap=internal` records which regions are dirty, so an unclean shutdown
  resyncs in seconds instead of rereading the whole array. Default on for larger
  arrays; set it explicitly and stop thinking about it.

mdadm's RAID 10 is its own implementation, not RAID 1+0 stacked. It accepts an odd
number of disks and takes a `--layout`: `n2` (near, the default) mirrors adjacent
copies, `f2` (far) places them half a disk apart and roughly doubles sequential read
speed at the cost of slower writes.

### Watch the initial sync

The array is usable immediately but is still building parity:

```shell
cat /proc/mdstat
```

```text
md0 : active raid6 sde1[3] sdd1[2] sdc1[1] sdb1[0]
      3906764800 blocks super 1.2 level 6, 512k chunk, algorithm 2 [4/4] [UUUU]
      [==>..................]  resync = 12.4% (242... ) finish=201.3min speed=161240K/sec
```

`[UUUU]` is one character per device: `U` up, `_` missing. That line is the fastest
health check there is.

## Filesystem, mount, and the two steps everyone forgets

```shell
sudo mkfs.ext4 /dev/md0
sudo mkdir -p /mnt/array
sudo mount /dev/md0 /mnt/array
blkid /dev/md0
```

Add it to `/etc/fstab` by UUID, with `nofail` so a degraded or missing array does not
drop the host into an emergency shell at boot:

```text
UUID=<from blkid>  /mnt/array  ext4  defaults,nofail,discard  0  0
```

Then the part that decides whether the array exists after a reboot:

```shell
sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf
sudo update-initramfs -u
```

{{< callout type="warning" >}}
Skip `update-initramfs -u` and the array assembles under a generated name like
`/dev/md127`, because the initramfs is still carrying the old config. The fstab
entry then points at a device that does not exist. This is the single most common
way an mdadm setup "breaks" on first reboot.
{{< /callout >}}

## Monitoring

**Mail on failure.** Set the destination in `/etc/mdadm/mdadm.conf` and make sure the
host can actually send mail:

```text
MAILADDR you@example.com
```

```shell
sudo systemctl enable --now mdmonitor.service
sudo mdadm --monitor --scan --test --oneshot   # sends a test message now
```

`--test` is not optional in practice. An array that reports failures to an address
nothing delivers to is an array with no monitoring.

**Status, two ways:**

```shell
cat /proc/mdstat                  # one line per array, fast
sudo mdadm --detail /dev/md0      # state, device roles, failed/spare counts
```

The field to read in `--detail` is `State`. `clean` is healthy; `clean, degraded`
means a device is gone and the array is running without redundancy; `clean,
degraded, recovering` means it is rebuilding.

## Checking health

**Scrub the array.** A monthly consistency check reads every block and compares it
against parity, which is how a bad sector gets found before a rebuild needs it.
Ubuntu installs a cron job for this; trigger one by hand with:

```shell
sudo /usr/share/mdadm/checkarray --cron --all --idle --quiet
```

Then read the result:

```shell
cat /sys/block/md0/md/mismatch_cnt
```

Non-zero on RAID 1 or 10 can be benign (swap and some workloads write to a mirror
without reading it back). Non-zero on RAID 5 or 6 means parity disagrees with data
and deserves investigation.

**Check the disks, not just the array.** mdadm reports a drive as failed once the
kernel gives up on it; SMART sees it coming:

```shell
sudo apt install smartmontools
sudo smartctl -a /dev/sdb
sudo smartctl -t short /dev/sdb
```

Watch `Reallocated_Sector_Ct`, `Current_Pending_Sector` and `Offline_Uncorrectable`.
A disk with a rising pending-sector count is the one to replace next, before it takes
the array degraded on its own schedule.

Enable `smartd` so those counters are checked without you remembering to.

## Replacing a failed disk

```shell
# 1. Mark it failed (skip if mdadm already did) and remove it
sudo mdadm --manage /dev/md0 --fail /dev/sdb1
sudo mdadm --manage /dev/md0 --remove /dev/sdb1

# 2. Note the serial of the disk to pull, so you pull the right one
sudo smartctl -i /dev/sdb | grep -i serial

# 3. Swap the hardware, then copy the partition table from a healthy member
sudo sgdisk --replicate=/dev/sdb /dev/sdc   # copy sdc's layout onto the new sdb
sudo sgdisk --randomize-guids /dev/sdb      # new disk needs its own GUIDs

# 4. Add it back
sudo mdadm --manage /dev/md0 --add /dev/sdb1

# 5. Watch the rebuild
watch cat /proc/mdstat
```

Notes that matter:

- **`--replicate` copies from healthy to new.** Reversing those arguments wipes the
  good disk. Read the command twice.
- **`--randomize-guids` is required.** Two disks with identical partition GUIDs
  confuse the kernel and anything that addresses disks by GUID.
- **The rebuild is the dangerous window.** The array has no redundancy left (RAID 5)
  or one layer (RAID 6) until it finishes, and it is hammering every remaining disk.
  Do not start a backup, a scrub, or a large copy at the same time.
- **Rebuild speed is throttled.** Raise the floor if the array is idle:

  ```shell
  echo 50000 | sudo tee /proc/sys/dev/raid/speed_limit_min
  ```

On an array with a hot spare, steps 1 and 4 happen by themselves — the spare is
already rebuilding before you have read the alert, and the physical swap just restocks
the spare.

### Replacing without going degraded

If the disk is failing but still readable, add the replacement first and let mdadm
copy onto it while the old disk is still a member:

```shell
sudo mdadm --manage /dev/md0 --add /dev/sdf1
sudo mdadm --manage /dev/md0 --replace /dev/sdb1 --with /dev/sdf1
```

The array never drops below full redundancy. This is always the better route when the
hardware gives you the chance.

## Growing an array

Adding a disk to RAID 5 or 6 reshapes it in place. It is slow, and it is the one
mdadm operation where an interruption without a backup file is hard to recover from:

```shell
sudo mdadm --manage /dev/md0 --add /dev/sdf1
sudo mdadm --grow /dev/md0 --raid-devices=5 --backup-file=/root/md0-reshape.bak
sudo resize2fs /dev/md0        # after the reshape completes
```

Keep the backup file on a disk that is **not** part of the array, and leave it in
place until `/proc/mdstat` shows the reshape finished.

## Traps

- **`/dev/sdX` is not stable.** Scripts and notes should use UUIDs or disk serials.
  mdadm itself tracks members by superblock, so the array survives renaming — your
  documentation does not.
- **Do not put `/boot` on RAID 5, 6 or 10.** GRUB can read a RAID 1 member as a plain
  filesystem. Use a small RAID 1 for `/boot` and the parity array for data.
- **`--assume-clean` skips the initial sync.** It makes creation instant and leaves
  parity undefined. Only correct for an array you are about to overwrite entirely.
- **An array removed from `mdadm.conf` still assembles**, from the superblocks, under
  an arbitrary name. Remove the config entry _and_ zero the superblocks when retiring
  an array.
- **Degraded is not failed.** An array running `clean, degraded` serves data normally
  and will keep doing so until the next disk goes. The only thing that tells you is
  the monitoring you set up above.

---

Reference: [How to Setup Software RAID with MDADM Command on Linux
Ubuntu](https://www.youtube.com/watch?v=O3Iq9hx8V7U) — Hetman Software.
