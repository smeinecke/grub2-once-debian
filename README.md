# grub2-once (Debian Version)
grub2 source code from openSUSE https://build.opensuse.org/package/show/Base:System/grub2

Tool to set the default boot entry for the next boot only. Migrated from opensuse grub2 package.

## Testing

`test/run-qemu-test.sh` runs an end-to-end check under QEMU. It builds a
bootable disk image — real GRUB embedded in the MBR plus a minimal
initramfs containing the script and the grub tools — boots it, runs
`grub-once` inside the guest, reboots and asserts on the serial console
that the selected entry booted exactly once and the default was restored.

Requirements: `qemu-system-x86_64`, `grub-pc-bin`, `grub2-common`,
`busybox-static`, `e2fsprogs`, `fdisk`, `cpio`, `perl`. KVM is used when
available; otherwise it falls back to TCG emulation.

    ./test/run-qemu-test.sh

The same test runs in CI via `.github/workflows/test.yml`.
