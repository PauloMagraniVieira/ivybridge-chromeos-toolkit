#!/usr/bin/env bash
# ==============================================================================
# Full ChromeOS + Google Play Store (Brunch r150 + Official Google rammus ARC++)
# Automated ZRAM + UEFI NVRAM Provisioning Script for Dell Inspiron 7520
# ==============================================================================

set -euo pipefail

MAC_SERVER="${MAC_SERVER:-http://192.168.15.14:8000}"
EXPECTED_RAMMUS_SHA1="87ff73f66f0ff678279136e5d9cc359f9796af29"
TARGET_SSD="${TARGET_SSD:-/dev/sda}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq cgpt pv efibootmgr

swapoff -a 2>/dev/null || true
umount -lf "${TARGET_SSD}"* 2>/dev/null || true
umount -lf /mnt/brunch_ram 2>/dev/null || true

modprobe zram
zramctl --reset /dev/zram0 2>/dev/null || true
ZRAM_DEV=$(zramctl --find --size 14G --algorithm zstd 2>/dev/null || zramctl --find --size 14G)
mkfs.ext4 -q -m 0 -O sparse_super2 "$ZRAM_DEV"
mkdir -p /mnt/brunch_ram
mount -o discard "$ZRAM_DEV" /mnt/brunch_ram
cd /mnt/brunch_ram

curl --http1.1 -fSL "${MAC_SERVER}/brunch_r150.tar.gz" | tar -zxf -
curl --http1.1 -fSL "${MAC_SERVER}/rammus_r150.bin.zip" -o rammus.zip

ACTUAL_SHA1=$(sha1sum rammus.zip | awk '{print $1}')
if [[ "$ACTUAL_SHA1" != "$EXPECTED_RAMMUS_SHA1" ]]; then
    echo "SHA-1 mismatch: got $ACTUAL_SHA1, expected $EXPECTED_RAMMUS_SHA1" >&2
    exit 1
fi

python3 - <<'PY'
import os, zipfile
with zipfile.ZipFile("rammus.zip", "r") as zf:
    member = next(n for n in zf.namelist() if n.endswith(".bin"))
    total = zf.getinfo(member).file_size
    chunk_sz = 4 * 1024 * 1024
    with zf.open(member, "r") as src, open("rammus.bin", "wb") as dst:
        while True:
            buf = src.read(chunk_sz)
            if not buf:
                break
            if buf.count(0) == len(buf):
                dst.seek(len(buf), os.SEEK_CUR)
            else:
                dst.write(buf)
        dst.truncate(total)
PY
rm -f rammus.zip

wipefs -a "$TARGET_SSD" 2>/dev/null || true
echo "yes" | bash /mnt/brunch_ram/chromeos-install.sh -src /mnt/brunch_ram/rammus.bin -dst "$TARGET_SSD"
partprobe "$TARGET_SSD" 2>/dev/null || true
sleep 2

for bnum in $(efibootmgr | awk '/ChromiumOS|ChromeOS/ {gsub(/^Boot/, "", $1); gsub(/\*/, "", $1); print $1}'); do
    efibootmgr -b "$bnum" -B 2>/dev/null || true
done
efibootmgr -c -d "$TARGET_SSD" -p 12 -L "ChromeOS" -l '\efi\boot\bootx64.efi'
sync
blockdev --flushbufs "$TARGET_SSD"
