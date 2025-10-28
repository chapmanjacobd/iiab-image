# README

```sh
./unpack.sh
Downloading from https://downloads.raspberrypi.org/raspios_lite_arm64_latest...
######################################################################### 100.0%
Extracting raspios_lite_arm64_latest.img.xz...
raspios_lite_arm64_latest.img.xz (1/1)
  100 %     475.8 MiB / 2,792.0 MiB = 0.170   701 MiB/s       0:03
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

To chroot into image: ./chroot.sh raspios_lite_arm64_latest.img.state
To repack, run: ./repack.sh raspios_lite_arm64_latest.img.state
==========================================
```

Make changes

```sh
./chroot.sh raspios_lite_arm64_latest.img.state
Loading state from raspios_lite_arm64_latest.img.state...
Mount point: ./mnt
Command: /bin/bash

Setting up chroot environment...
/proc already mounted
/sys already mounted
/dev already mounted
/dev/pts already mounted
Chroot environment ready

==========================================
Entering chroot environment...
==========================================

Detected ARM 64-bit architecture

Starting interactive shell...
Type 'exit' to return to host system

root@pakon:/# exit

==========================================
Exited chroot environment
==========================================
```

Build image

```
