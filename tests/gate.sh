#!/bin/sh
set -eu
K=$1
KO=$2
W=$3
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$W/root"
gcc -O2 -static -o "$W/root/init" "$HERE/gate.c"
install -m 0644 "$KO" "$W/root/sinty_scheduler.ko"
install -m 0755 "$(command -v mkfs.f2fs)" "$W/root/mkfs.f2fs"
ldd "$W/root/mkfs.f2fs" | awk '$(NF-1) ~ /^\// { print $(NF-1) } $1 ~ /^\// { print $1 }' | while read -r lib; do
	mkdir -p "$W/root$(dirname "$lib")"
	cp -L "$lib" "$W/root$lib"
done
mkdir -p "$W/root/proc" "$W/root/sys" "$W/root/dev" "$W/root/mnt" "$W/root/tmp"
python3 -I "$HERE/mkcpio.py" "$W/root" "$W/init.cpio"
rm -f "$W/disk.img"
fallocate -l 12G "$W/disk.img"
timeout "${GATE_TIMEOUT:-3600}" chrt -i 0 ionice -c3 nice -n 19 qemu-system-x86_64 -machine q35 -accel kvm -cpu host -smp 4 -m 6G \
	-kernel "$K" -initrd "$W/init.cpio" -append "console=ttyS0 panic=-1 rdinit=/init ${GATE_ARGS:-}" \
	-drive "file=$W/disk.img,if=none,id=d,format=raw,cache=${GATE_CACHE:-none},aio=threads,throttling.bps-write=${GATE_WRITE_BPS:-400000000}" \
	-device virtio-blk-pci,drive=d -nographic -no-reboot | tee "$W/gate.log" | grep --line-buffered -E "^GATE|^\[<|^[a-z_0-9]+ [0-9]+|BUG|Oops|panic|WARNING" || true
rm -f "$W/disk.img"
grep -q GATE_DONE "$W/gate.log"
python3 -I "$HERE/verdict.py" "$W/gate.log"
