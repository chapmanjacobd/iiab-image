# IIAB Image

Inspired by [arm-runner-action](https://github.com/pguyot/arm-runner-action)

Download latest raspios lite by default:

```sh
./unpack.sh
Downloading from https://downloads.raspberrypi.org/raspios_lite_arm64_latest...
######################################################################### 100.0%
Extracting raspios_lite_arm64_latest.img.xz...
raspios_lite_arm64_latest.img.xz (1/1)
  100 %     475.8 MiB / 2,792.0 MiB = 0.170   701 MiB/s       0:03
Creating loopback device...
Created loopback device: /dev/loop0
...
```

Or use local image:

```sh
./unpack.sh raspios_lite_arm64_latest.img
Using local file: raspios_lite_arm64_latest.img
Warning: File doesn't have .xz extension, assuming it's already extracted
Creating loopback device...
Created loopback device: /dev/loop0
/dev/loop0: msdos partitions 1 2
Root device: /dev/loop0p2
Boot device: /dev/loop0p1
Mount point: ./mnt
Mounting root filesystem...
Mounting boot filesystem...
Setting up QEMU for ARM emulation...

==========================================
Image unpacked successfully!
==========================================
Loop device: /dev/loop0
Mount point: ./mnt
State file: raspios_lite_arm64_latest.img.state

To enter container: ./chroot.sh raspios_lite_arm64_latest.img.state
To repack, run: ./repack.sh raspios_lite_arm64_latest.img.state
==========================================
```

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

Build image

```sh
./repack.sh raspios_lite_arm64_latest.img.state
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

To unmount (if you want to not repack)

```sh
./unmount.sh raspios_lite_arm64_latest.img.state
Loading state from raspios_lite_arm64_latest.img.state...
Loop device: /dev/loop0
Mount point: ./mnt

Cleaning up container environment...
Restoring resolv.conf...
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
