# nspawn-loop

Inspired by [arm-runner-action](https://github.com/pguyot/arm-runner-action), [Build your own Container Runtime with chroot - Adam Gordon Bell](https://www.youtube.com/watch?v=89ESCBzM-3Q), [Systemd-Nspawn is Chroot on Steroids - Lennart Poettering](https://www.youtube.com/watch?v=s7LlUs5D9p4)
## Suggested workflow

1. `./mount.sh`

2. `./install_iiab.sh raspios_lite_arm64_latest.state https://raw.githubusercontent.com/iiab/iiab/master/vars/local_vars_small.yml`

3. (optional) `./chroot.sh raspios_lite_arm64_latest.state --boot`

4. (optional; to snapshot or resume work later) `./unmount.sh raspios_lite_arm64_latest.state --boot`

5. `./shrink.sh raspios_lite_arm64_latest.state`

As long as images are unmounted, feel free to make copies to treat as snapshots or different OS "flavours"

## ./mount.sh

Download latest raspios lite by default with a 5GB target size:

```sh
./mount.sh
Downloading from https://downloads.raspberrypi.org/raspios_lite_arm64_latest...
######################################################################### 100.0%
Extracting raspios_lite_arm64_latest.img.xz...
raspios_lite_arm64_latest.img.xz (1/1)
  100 %     475.8 MiB / 2,792.0 MiB = 0.170   701 MiB/s       0:03
Creating loopback device...
Created loopback device: /dev/loop0
...
```

Or for Debian with 22GB extra space:

```sh
./mount.sh https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.raw 22000
```

Or use local image:

```sh
./mount.sh raspios_lite_arm64_latest.img 22000
Partition numbers not explicity set. Attempting to auto-detect using parted on raspios_lite_arm64_latest.img...
Using boot partition
Using root partition 2
Using boot partition 1
Current image size: 2792MB
Target image size: 22000MB
Adding 19208MB to image...
4802+0 records in
4802+0 records out
20141047808 bytes (20 GB, 19 GiB) copied, 369.749 s, 54.5 MB/s
Created loopback device: /dev/loop8
Number  Start   End     Size    Type     File system  Flags
        32.3kB  8389kB  8356kB           Free Space
 1      8389kB  545MB   537MB   primary  fat32        lba
 2      545MB   2928MB  2382MB  primary  ext4
        2928MB  23.1GB  20.1GB           Free Space

Resizing partition to use available space
rootfs: 72636/145440 files (0.2% non-contiguous), 502525/581632 blocks
resize2fs 1.47.2 (1-Jan-2025)
Resizing the filesystem on /dev/loop8p2 to 5498880 (4k) blocks.
The filesystem on /dev/loop8p2 is now 5498880 (4k) blocks long.

Partition resize complete:
Number  Start   End     Size    Type     File system  Flags
        32.3kB  8389kB  8356kB           Free Space
 1      8389kB  545MB   537MB   primary  fat32        lba
 2      545MB   23.1GB  22.5GB  primary  ext4

/dev/loop8: msdos partitions 1 2
Root device: /dev/loop8p2
Boot device: /dev/loop8p1

Mount point: raspios_lite_arm64_latest
Root mounted at raspios_lite_arm64_latest
Boot mounted at raspios_lite_arm64_latest/boot
```

If auto-detection fails then use parted to identify the boot partition:

```sh
sudo parted raspios_lite_arm64_latest.img print
Model:  (file)
Disk /home/xk/iiab/github/iiab-image/raspios_lite_arm64_latest.img: 2928MB
Sector size (logical/physical): 512B/512B
Partition Table: msdos
Disk Flags:

Number  Start   End     Size    Type     File system  Flags
 1      8389kB  545MB   537MB   primary  fat32        lba
 2      545MB   2928MB  2382MB  primary  ext4
```

Then manually specify the target disk size, boot, and root partitions:

```sh
./mount.sh raspios_lite_arm64_latest.img 20000 1 2
```

## ./chroot.sh <STATE_FILE>

Make changes

```sh
./chroot.sh raspios_lite_arm64_latest.img.state
Loading state from raspios_lite_arm64_latest.img.state...
Mount point: ./mnt
Command: /bin/bash

Setting up ARM emulation environment...
Environment ready

Architecture: aarch64

==========================================
Entering container with systemd-nspawn...
==========================================

Starting interactive shell...
Type 'exit' or Ctrl+] three times to return to host system
```

## ./shrink.sh <STATE_FILE>

Export image

(You must ./mount.sh first to shrink)

```sh
./shrink.sh raspios_lite_arm64_latest.img.state
Loading state from raspios_lite_arm64_latest.img.state...
Loop device: /dev/loop0
Mount point: ./mnt
Image file: raspios_lite_arm64_latest.img
Cleaning up chroot environment...
Optimizing image...
Zero-filling unused blocks on boot filesystem...
Zero-filling unused blocks on root filesystem...
Unmounting filesystems...
Unmounting ./mnt/boot...
Successfully unmounted ./mnt/boot
Unmounting ./mnt...
Successfully unmounted ./mnt
Shrinking root filesystem to minimal size...
rootfs: 79905/145440 files (0.2% non-contiguous), 549585/581632 blocks
resize2fs 1.47.2 (1-Jan-2025)
The filesystem is already 581632 (4k) blocks long.  Nothing to do!

Root partition already at minimal size
Detaching loopback device...

==========================================
Image repacked successfully!
==========================================
Image file: raspios_lite_arm64_latest.img

To compress, run: xz -v -9 -T0 raspios_lite_arm64_latest.img
==========================================
```

---

## ./unmount.sh <STATE_FILE>

If you want to stop work or export later

```sh
./unmount.sh raspios_lite_arm64_latest.img.state
Loading state from raspios_lite_arm64_latest.img.state...
Loop device: /dev/loop0
Mount point: ./mnt

Cleaning up container environment...
Unmounting ./mnt/boot...
Successfully unmounted ./mnt/boot
Unmounting ./mnt...
Successfully unmounted ./mnt
Detaching loop device /dev/loop0...
Loop device detached
```

To manually unmount

```sh
sudo umount mnt/boot/
sudo umount mnt

losetup --list
sudo losetup --detach /dev/loopX
```

---

## Misc

For cross-arch install `qemu-user-static` on the host machine (but it is slow--it is better to build arm64 images on arm64, etc)

---

### Why not machinectl?

`machinectl` is really cool--when it works! I'm not sure why, but I often get errors like this:

```sh
sudo machinectl shell debian13
Failed to get shell PTY: Connection refused
```

`machinectl` feels like a buggy afterthought. In contrast, `systemd-nspawn` has been a lot more reliable for me:

```sh
sudo systemd-nspawn -M debian13 /bin/bash
sudo systemd-nspawn --quiet --boot --network-veth --machine=debian13
```

Maybe someday machinectl will work better and some of these scripts can be fully replaced by something more conventional:

```sh
sudo importctl pull-raw -Nm --verify=no https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.raw debian13
sudo systemd-firstboot --image=/var/lib/machines/debian13.raw --delete-root-password --force
sudo machinectl start debian13
sudo machinectl shell debian13
```
