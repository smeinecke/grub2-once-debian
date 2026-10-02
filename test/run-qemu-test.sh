#!/usr/bin/env bash
#
# Integration test for grub-once: builds a bootable disk image
# containing GRUB, the grub-once script and a minimal initramfs, then
# boots it under QEMU three times and asserts that
#   * grub-once --list enumerates the fixture grub.cfg correctly
#   * `grub-once 1` boots the oneshot entry exactly once
#   * the following boot falls back to the default entry
#
# Requirements: qemu-system-x86_64, grub-efi-amd64-bin (grub-mkimage
# + x86_64-efi modules), ovmf, grub2-common (grub-editenv),
# busybox-static, dosfstools (mkfs.vfat), mtools, fdisk (sfdisk), cpio, perl.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRUB_ONCE="${GRUB_ONCE:-$ROOT/grub-once}"   # override to test other revisions
WORK="$(mktemp -d "$ROOT/.itest.XXXXXX")"
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT

log()  { printf '==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "missing required tool: $1"; }

for t in qemu-system-x86_64 grub-mkimage grub-editenv sfdisk mkfs.vfat \
         mcopy cpio dpkg-deb; do need "$t"; done
need /usr/bin/busybox
[ -d /usr/lib/grub/x86_64-efi ] || fail "x86_64-efi grub modules missing (install grub-efi-amd64-bin)"

OVMF=
for f in /usr/share/qemu/OVMF.fd /usr/share/OVMF/OVMF_CODE_4M.fd \
         /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    [ -r "$f" ] && OVMF="$f" && break
done
if [ -z "$OVMF" ]; then
    log "OVMF not installed; downloading package"
    (cd "$WORK" && apt-get download ovmf >/dev/null 2>&1) || true
    deb="$(echo "$WORK"/ovmf_*.deb 2>/dev/null)"
    [ -f "$deb" ] && dpkg-deb -x "$deb" "$WORK/ovmf"
    OVMF="$(echo "$WORK"/ovmf/usr/share/OVMF/OVMF_CODE*.fd "$WORK"/ovmf/usr/share/ovmf/OVMF*.fd 2>/dev/null | awk '{print $1}')"
fi
[ -r "$OVMF" ] || fail "no OVMF firmware found (install ovmf)"
log "firmware: $OVMF"

# ---------------------------------------------------------------- kernel
KVER="${KVER:-$(uname -r)}"
VMLINUZ="/boot/vmlinuz-$KVER"
if [ ! -r "$VMLINUZ" ]; then
    pkg="$(dpkg-query -S "$VMLINUZ" 2>/dev/null | cut -d: -f1 || true)"
    pkg="${pkg:-linux-image-$KVER}"
    log "vmlinuz not readable; downloading $pkg"
    (cd "$WORK" && apt-get download "$pkg" >/dev/null 2>&1)
    deb="$(echo "$WORK"/"$pkg"_*.deb)"
    [ -f "$deb" ] || fail "cannot obtain kernel image ($pkg)"
    dpkg-deb -x "$deb" "$WORK/kx"
    VMLINUZ="$WORK/kx/boot/vmlinuz-$KVER"
    [ -f "$VMLINUZ" ] || VMLINUZ="$(echo "$WORK"/kx/boot/vmlinuz-*)"
fi
[ -r "$VMLINUZ" ] || fail "no usable kernel image found"
log "kernel: $VMLINUZ"

# -------------------------------------------------------------- initramfs
IR="$WORK/initrd"
mkdir -p "$IR"/{bin,sbin,proc,sys,dev,boot,tmp} \
         "$IR"/lib/x86_64-linux-gnu "$IR"/lib64 \
         "$IR"/usr/{bin,sbin} "$IR"/usr/share/grub \
         "$IR"/usr/lib/x86_64-linux-gnu/perl-base \
         "$IR"/lib/modules "$IR"/var/lib/misc

# stub systemctl: logs invocations to the serial console so the test can
# assert the correct unit name is enabled; is-enabled reports "not enabled"
cat > "$IR/usr/bin/systemctl" <<'EOF'
#!/bin/busybox sh
# callers may redirect stdout — write straight to the console device
echo "### SYSTEMCTL $*" > /dev/console
case "$*" in *is-enabled*) exit 1 ;; esac
exit 0
EOF
chmod 755 "$IR/usr/bin/systemctl"

install -m755 /usr/bin/busybox           "$IR/bin/busybox"
install -m755 "$ROOT/test/init"          "$IR/init"
install -m755 "$GRUB_ONCE"               "$IR/usr/sbin/grub-once"
install -m755 /usr/bin/perl              "$IR/usr/bin/perl"
install -m755 /usr/bin/grub-editenv      "$IR/usr/bin/grub-editenv"
install -m755 /usr/sbin/grub-probe       "$IR/usr/sbin/grub-probe"
install -m755 /usr/sbin/grub-reboot      "$IR/usr/sbin/grub-reboot"
install -m644 /usr/share/grub/grub-mkconfig_lib "$IR/usr/share/grub/"

# core perl modules (strict.pm et al. live in perl-base)
cp -a /usr/lib/x86_64-linux-gnu/perl-base/. "$IR/usr/lib/x86_64-linux-gnu/perl-base/"

# shared libraries needed by the copied binaries
ldd /usr/bin/perl /usr/bin/grub-editenv /usr/sbin/grub-probe |
    awk '{ for (i=1; i<=NF; i++) if ($i ~ /^\// && $i ~ /\.so/) print $i }' | sort -u |
    while read -r lib; do install -D -m644 "$lib" "$IR$lib"; done
install -D -m755 /lib64/ld-linux-x86-64.so.2 "$IR/lib64/ld-linux-x86-64.so.2"

# kernel modules for the drivers we rely on (skip builtins)
modlist() {
    local m
    for m in vfat nls_cp437 nls_iso8859-1 virtio_blk virtio_pci sd_mod ata_piix; do
        modprobe --show-depends "$m" 2>/dev/null |
            awk '/^insmod/ { print $2 }'
    done | awk '!seen[$0]++'
}
: > "$IR/lib/modules/modlist"
while read -r mod; do
    base="$(basename "$mod")"
    case "$base" in
        *.ko)     cp "$mod" "$IR/lib/modules/$base" ;;
        *.ko.zst) need zstd; zstd -q -d -c "$mod" > "$IR/lib/modules/${base%.zst}"; base="${base%.zst}" ;;
        *.ko.xz)  need xz;    xz   -q -d -c "$mod" > "$IR/lib/modules/${base%.xz}";  base="${base%.xz}" ;;
        *.ko.gz)  need gzip;  gzip -q -d -c "$mod" > "$IR/lib/modules/${base%.gz}";  base="${base%.gz}" ;;
    esac
    echo "${base%.ko}" >> "$IR/lib/modules/modlist"
done < <(modlist)

(cd "$IR" && find . | cpio -o -H newc 2>/dev/null | gzip -9) > "$WORK/initrd.img"
log "initramfs: $(du -h "$WORK/initrd.img" | cut -f1)"

# ------------------------------------------------------------ disk image
# GPT with a single EFI system partition (FAT32) that doubles as /boot:
# its fs root holds grub/, vmlinuz, initrd.img and EFI/BOOT/BOOTX64.EFI —
# mounted at /boot in the guest. No boot-sector embedding needed.
ST="$WORK/stage"
mkdir -p "$ST/grub" "$ST/EFI/BOOT"
cp "$VMLINUZ"                    "$ST/vmlinuz"
cp "$WORK/initrd.img"            "$ST/initrd.img"
cp "$ROOT/test/grub.cfg"         "$ST/grub/grub.cfg"
grub-editenv "$ST/grub/grubenv" create
# GRUB loads modules (linux, test, serial, ...) from $prefix/x86_64-efi —
# same layout as grub-install produces
cp -a /usr/lib/grub/x86_64-efi   "$ST/grub/"

# self-contained grub image for removable-media boot
grub-mkimage -O x86_64-efi -o "$ST/EFI/BOOT/BOOTX64.EFI" -p '(hd0,gpt1)/grub' \
    part_gpt fat normal linux configfile search serial

truncate -s 60M "$WORK/part1.img"
mkfs.vfat "$WORK/part1.img" >/dev/null
mcopy -i "$WORK/part1.img" -s "$ST"/* ::

truncate -s 64M "$WORK/disk.img"
printf 'label: gpt\nstart=2048, type=U\n' | sfdisk -q "$WORK/disk.img"
dd if="$WORK/part1.img" of="$WORK/disk.img" bs=512 seek=2048 conv=notrunc status=none

# -------------------------------------------------------------------- run
ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm
TIMEOUT="$(command -v timeout >/dev/null && echo timeout || echo /usr/bin/timeout)"
# sysbox containers shadow coreutils timeout with /usr/local/sbin/timeout
[ -x /usr/bin/timeout ] && TIMEOUT=/usr/bin/timeout
log "booting image under QEMU ($ACCEL)"
"$TIMEOUT" 240 qemu-system-x86_64 \
    -machine pc -accel "$ACCEL" -m 512 -smp 1 -net none \
    -bios "$OVMF" \
    -drive file="$WORK/disk.img",format=raw,if=virtio \
    -display none -serial file:"$WORK/console.log" \
    || rc=$?

CONSOLE="$WORK/console.log"
[ -s "$CONSOLE" ] || fail "no console output captured"
cp "$CONSOLE" "$ROOT/console.log"   # keep for inspection/debug

# ----------------------------------------------------------------- assert
assert_grep() { grep -q -- "$1" "$CONSOLE" || fail "$2"; }

list=$(awk '/### LIST-BEGIN/,/### LIST-END/' "$CONSOLE")
printf '%s\n' "$list" | grep -q 'default system'                 || fail "--list missing 'default system'"
printf '%s\n' "$list" | grep -q 'advanced options>oneshot target' || fail "--list missing submenu entry"
printf '%s\n' "$list" | grep -q 'nested-dead-branch'   && fail "--list shows entry inside dead if-branch"
printf '%s\n' "$list" | grep -q 'dead-branch'          && fail "--list shows entry inside dead if-branch"
printf '%s\n' "$list" | grep -q 'indented-comment'     && fail "--list shows commented-out entry"

assert_grep '### SELECT-OK'                                 "grub-once 1 failed"
assert_grep 'next_entry=advanced options>oneshot target'    "next_entry not written to grubenv"
assert_grep '### SYSTEMCTL .*grub-once'                     "cleanup service not enabled"
assert_grep '### SYSTEMCTL --no-reload enable grub-once'    "cleanup service enable call missing"
! grep -q 'grub2-once' "$CONSOLE" || fail "stale unit name grub2-once used"

# stage 0: default boot, stage 1: oneshot entry, stage 2: back to default
assert_grep '### STAGE=2' "third boot never happened"
awk '/### STAGE=1/{s=1} /### STAGE=2/{s=0} s && /### CMDLINE/ && /grub_once_marker=1/{ok=1} END{exit !ok}' "$CONSOLE" \
    || fail "oneshot entry did not boot on second boot"
awk '/### STAGE=0/{s=1} /### STAGE=1/{s=0} s && /### CMDLINE/ && /grub_once_marker=1/{ok=1} END{exit ok}' "$CONSOLE" \
    || fail "first boot unexpectedly used the oneshot entry"
awk '/### STAGE=2/{s=1} s && /### CMDLINE/ && /grub_once_marker=1/{bad=1} END{exit bad}' "$CONSOLE" \
    || fail "oneshot entry still active on third boot (next_entry not cleared)"

assert_grep '### DONE' "guest did not reach final stage"

log "PASS - all assertions held"
log "console log: $ROOT/console.log"
