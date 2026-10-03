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
RAID on Ubuntu with mdadm.
{{< /lead >}}

<!--more-->

RAID is uptime, not backup. A deleted file is deleted on every disk at once. What it
buys is staying online through a dead drive, and more throughput than one spindle.

Software RAID on Ubuntu is handled by mdadm. It supports RAID 0, 1, 5, 6 and 10.

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

## Prerequisites

1. Ubuntu 22.04 LTS or higher.
2. Two or more drives you can erase, enough for the level you picked above.

## Setting up the array

{{% steps %}}

### Get a `sudo -s` session

Since we will be running multiple commands as sudo, it is better to run this entire
thing in a single sudo session. Every command below assumes you are root from here on.

```shell
sudo -s
```

### Install mdadm

```shell
apt install mdadm
```

### Check if the drives show up

Identify the disks and confirm they are the ones you think:

```shell
cat /proc/partitions
```

Or, with sizes, models and serials:

```shell
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,SERIAL
```

Note down the drives you want to use for RAID, such as `/dev/sdb` and `/dev/sdc`.

{{< callout type="error" >}}
`mdadm --create` destroys everything on every device listed. Check `lsblk` output
against the serial numbers, not against the letters — `/dev/sdX` names are assigned
in discovery order and can change between boots.
{{< /callout >}}

### Partition the disks

Use `fdisk` to partition the drives:

```shell
fdisk /dev/sdb
```

Then, at its prompt:

1. `p` to view the existing partitions.
2. `n` to create a new partition.
3. `p` to select the primary partition type.
4. `1` for the partition number.
5. Leave the rest of the settings as defaults.
6. _Do you want to remove the signature?_ — select `Yes`.
7. `p` again to view the partition that was created.
8. `w` to write the changes.

Repeat the same process for all the drives. After that is done, run `partprobe`. On
Ubuntu it is not strictly necessary, but do it anyway.

```shell
partprobe
```

Check the partitions appeared, with either of the commands from the previous step.

### Create the array

All of these take the same shape. `/dev/md0` is the array name, `--raid-devices` is
the count, and the device list follows.

**RAID 0** — striping, no redundancy:

```shell
mdadm --create /dev/md0 -a yes --level=0 --raid-devices=2 /dev/sd[bc]1
```

**RAID 1** — mirror:

```shell
mdadm --create /dev/md0 -a yes --level=1 --raid-devices=2 /dev/sd[bc]1
```

**RAID 5** — single parity, three disks minimum:

```shell
mdadm --create /dev/md0 -a yes --level=5 --raid-devices=3 /dev/sd[bcd]1
```

**RAID 6** — double parity, four disks minimum:

```shell
mdadm --create /dev/md0 -a yes --level=6 --raid-devices=4 /dev/sd[bcde]1
```

**RAID 10** — striped mirrors, four disks minimum:

```shell
mdadm --create /dev/md0 -a yes --level=10 --raid-devices=4 /dev/sd[bcde]1
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

### Format the array

Format the array in ext4:

```shell
mkfs.ext4 /dev/md0
```

{{< callout type="info" >}}
This might take a while. It is independent of the resync above — you do not need to
wait for `/proc/mdstat` to reach 100% before formatting or using the array.
{{< /callout >}}

### Get the UUID with `blkid`

`/dev/md0` is not a name worth trusting in `/etc/fstab` — mount by UUID instead. The
array does not need to be mounted for this; `blkid` reads the filesystem superblock
directly.

```shell
blkid /dev/md0
```

```text
/dev/md0: UUID="9d4e1f27-6b3a-4c58-b0d2-7a1e5c93f480" BLOCK_SIZE="4096" TYPE="ext4"
```

{{< callout type="warning" >}}
Use the UUID that `blkid` prints — that is the **filesystem** UUID. `mdadm --detail`
prints a different UUID, which identifies the **array**. Putting the array UUID in
`fstab` gives you a mount that silently never happens.
{{< /callout >}}

### Mount it through `/etc/fstab`

Create the mount point, then append one line to `/etc/fstab` using the UUID from the
previous step:

```shell
mkdir -p /mnt/array
```

```text
UUID=9d4e1f27-6b3a-4c58-b0d2-7a1e5c93f480  /mnt/array  ext4  defaults,nofail,discard  0  0
```

`nofail` is the important option: without it, a degraded or missing array drops the
host into an emergency shell at boot instead of booting without that mount.

Mount it from that entry rather than by hand, so the first mount is the same one the
next boot will perform:

```shell
systemctl daemon-reload
mount -a
findmnt /mnt/array
```

If `mount -a` is silent and `findmnt` shows the mount, the entry is correct. An error
here is one you can fix at a prompt; the same error at boot is one you fix from a
rescue console.

### Save the array config and rebuild the initramfs

```shell
mdadm --detail --scan | tee -a /etc/mdadm/mdadm.conf
update-initramfs -u
```

{{< callout type="warning" >}}
Skip `update-initramfs -u` and the array assembles under a generated name like
`/dev/md127`, because the initramfs is still carrying the old config. The fstab
entry then points at a device that does not exist. This is the single most common
way an mdadm setup "breaks" on first reboot.
{{< /callout >}}

{{% /steps %}}

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

**Status, two ways.** One line per array, and the fastest check there is:

```shell
cat /proc/mdstat
```

State, device roles, and failed and spare counts for a single array:

```shell
sudo mdadm --detail /dev/md0
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
