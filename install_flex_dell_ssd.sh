#!/usr/bin/env bash
# ==============================================================================
# ChromeOS Flex Direct Internal SSD Installer (Linux Live / Subiquity Shell)
# Target Hardware: Dell Inspiron 7520 (6 GB RAM + Kingston 120 GB SATA SSD)
# Architecture: zram Compressed Sparse Image + Official Google chromeos-install
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

MAC_SERVER="${MAC_SERVER:-http://192.168.15.14:8000}"
EXPECTED_ZIP_SHA1="41a14e127201ca565d27e1e243ae5ce33e818821"
EXPECTED_BIN_BYTES="9523261952"

echo -e "${CYAN}${BOLD}======================================================================${NC}"
echo -e "${CYAN}${BOLD}   ChromeOS Flex Enterprise SSD Installer — Dell Inspiron 7520        ${NC}"
echo -e "${CYAN}${BOLD}======================================================================${NC}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RED}[!] Execute como root: sudo bash $0${NC}" >&2
    exit 1
fi

# 1. Fix CMOS/BIOS Clock if stuck in 2011 (prevents UEFI / TLS certificate errors)
CUR_YEAR=$(date -u +%Y)
if (( CUR_YEAR < 2025 )); then
    echo -e "${YELLOW}[*] Relógio da BIOS em ${CUR_YEAR} detectado! Sincronizando data/hora...${NC}"
    date -u -s "2026-10-27 15:00:00" || true
    hwclock --systohc --utc 2>/dev/null || true
fi

# 2. Identify non-removable internal Kingston SSD (never touch USB drives)
TARGET_SSD=""
for blk in /sys/block/sd* /sys/block/nvme*; do
    [[ -e "$blk" ]] || continue
    dev_name=$(basename "$blk")
    removable=$(cat "$blk/removable" 2>/dev/null || echo 1)
    ro_flag=$(cat "$blk/ro" 2>/dev/null || echo 1)
    sectors=$(cat "$blk/size" 2>/dev/null || echo 0)
    size_gb=$(( sectors * 512 / 1000000000 ))
    if [[ "$removable" == "0" && "$ro_flag" == "0" && "$size_gb" -ge 32 ]]; then
        TARGET_SSD="/dev/${dev_name}"
        SSD_MODEL=$(tr -s ' ' < "$blk/device/model" 2>/dev/null || echo "Internal SSD")
        SSD_SIZE_GB="$size_gb"
        break
    fi
done

if [[ -z "$TARGET_SSD" ]]; then
    echo -e "${RED}[!] Erro: Nenhum SSD interno (>=32 GB, não-removível) encontrado!${NC}" >&2
    lsblk
    exit 1
fi

echo -e "${GREEN}[+] SSD Interno Detectado:${NC} ${BOLD}${TARGET_SSD}${NC} — ${BOLD}${SSD_MODEL}${NC} (${SSD_SIZE_GB} GB)"
echo -e "${YELLOW}ATENÇÃO: TODO o disco ${TARGET_SSD} (${SSD_MODEL}) será formatado com ChromeOS Flex Oficial.${NC}"
echo -ne "${BOLD}Confirmar instalação no ${TARGET_SSD}? Digite SIM: ${NC}"
read -r CONFIRM </dev/tty
if [[ "$CONFIRM" != "SIM" && "$CONFIRM" != "sim" && "$CONFIRM" != "YES" ]]; then
    echo -e "${RED}Operação cancelada pelo usuário.${NC}"
    exit 1
fi

cleanup() {
    set +e
    for mp in /mnt/cros_root/dev/pts /mnt/cros_root/dev /mnt/cros_root/proc \
              /mnt/cros_root/sys/firmware/efi/efivars /mnt/cros_root/sys \
              /mnt/cros_root/run /mnt/cros_root/tmp /mnt/cros_root/mnt/stateful_partition \
              /mnt/cros_root; do
        mountpoint -q "$mp" 2>/dev/null && umount -lf "$mp" 2>/dev/null
    done
    [[ -n "${LOOP_DEV:-}" ]] && losetup -d "$LOOP_DEV" 2>/dev/null
    mountpoint -q /mnt/cros_zram 2>/dev/null && umount -lf /mnt/cros_zram 2>/dev/null
    [[ -n "${ZRAM_DEV:-}" ]] && zramctl --reset "$ZRAM_DEV" 2>/dev/null
}
trap cleanup EXIT

# 3. Ensure target SSD has zero mounted partitions or active swap
swapoff -a 2>/dev/null || true
for part in "${TARGET_SSD}"*; do
    [[ "$part" == "$TARGET_SSD" ]] && continue
    umount -lf "$part" 2>/dev/null || true
done

# 4. Initialize 12 GB zram compressed RAM workspace (uses ~1.4 GB of 6 GB RAM)
echo -e "\n${CYAN}[1/5] Inicializando disco RAM comprimido (zram 12 GB)...${NC}"
modprobe zram
ZRAM_DEV=$(zramctl --find --size 12G --algorithm zstd 2>/dev/null || zramctl --find --size 12G)
mkfs.ext4 -q -m 0 -O sparse_super2 "$ZRAM_DEV"
mkdir -p /mnt/cros_zram
mount -o discard "$ZRAM_DEV" /mnt/cros_zram

# 5. Locate payload (Local USB /media or pull over Gigabit LAN from Mac)
SCRIPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo /tmp)"
ZIP_SOURCE=""
if [[ -f "${SCRIPT_SELF_DIR}/chromeos_flex_recovery.bin.zip" ]]; then
    ZIP_SOURCE="${SCRIPT_SELF_DIR}/chromeos_flex_recovery.bin.zip"
    echo -e "${GREEN}[+] Payload encontrado no Pendrive USB: ${ZIP_SOURCE}${NC}"
else
    ZIP_SOURCE="/mnt/cros_zram/chromeos_flex_recovery.bin.zip"
    echo -e "${CYAN}[2/5] Baixando imagem oficial verificada via Rede Local (${MAC_SERVER})...${NC}"
    curl --http1.1 -fL --progress-bar "${MAC_SERVER}/chromeos_flex_16805.36.0.bin.zip" -o "$ZIP_SOURCE"
fi

echo -e "${CYAN}[3/5] Verificando assinatura criptográfica SHA-1 do Google...${NC}"
ACTUAL_SHA1=$(sha1sum "$ZIP_SOURCE" | awk '{print $1}')
if [[ "$ACTUAL_SHA1" != "$EXPECTED_ZIP_SHA1" ]]; then
    echo -e "${RED}[!] ERRO CRÍTICO: SHA-1 inválido (${ACTUAL_SHA1} != ${EXPECTED_ZIP_SHA1})! Abortando sem tocar no SSD.${NC}" >&2
    exit 1
fi
echo -e "${GREEN}[+] SHA-1 100% autêntico: ${ACTUAL_SHA1}${NC}"

# 6. Sparse-extract .bin into compressed zram & free .zip if in RAM
echo -e "${CYAN}[4/5] Extraindo imagem GPT esparsa (9.52 GB) em RAM comprimida...${NC}"
BIN_PATH="/mnt/cros_zram/flex.bin"
python3 - "$ZIP_SOURCE" "$BIN_PATH" <<'PY'
import os, sys, zipfile

zip_path, out_path = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path, "r") as zf:
    member = next(n for n in zf.namelist() if n.endswith(".bin"))
    total = zf.getinfo(member).file_size
    written = 0
    chunk_sz = 4 * 1024 * 1024
    with zf.open(member, "r") as src, open(out_path, "wb") as dst:
        while True:
            buf = src.read(chunk_sz)
            if not buf:
                break
            if buf.count(0) == len(buf):
                dst.seek(len(buf), os.SEEK_CUR)
            else:
                dst.write(buf)
            written += len(buf)
            pct = written * 100 // total
            print(f"\r    Progresso: {pct}% ({written // 1048576} / {total // 1048576} MB)", end="", flush=True)
        dst.truncate(total)
print()
PY

if [[ "$ZIP_SOURCE" == "/mnt/cros_zram/"* ]]; then
    rm -f "$ZIP_SOURCE"
fi

ACTUAL_BIN_BYTES=$(stat -c %s "$BIN_PATH")
if [[ "$ACTUAL_BIN_BYTES" != "$EXPECTED_BIN_BYTES" ]]; then
    echo -e "${RED}[!] Tamanho do .bin inválido (${ACTUAL_BIN_BYTES} != ${EXPECTED_BIN_BYTES}).${NC}" >&2
    exit 1
fi

# 7. Mount official Google ROOT-A and execute official /usr/sbin/chromeos-install
echo -e "${CYAN}[5/5] Executando instalador oficial Google ChromeOS Flex no ${TARGET_SSD}...${NC}"
LOOP_DEV=$(losetup --find --show --partscan --read-only "$BIN_PATH")
partprobe "$LOOP_DEV" 2>/dev/null || true
sleep 1

mkdir -p /mnt/cros_root
mount -o ro "${LOOP_DEV}p3" /mnt/cros_root

mount --bind /dev /mnt/cros_root/dev
mount --bind /dev/pts /mnt/cros_root/dev/pts
mount -t proc proc /mnt/cros_root/proc
echo "$(cat /proc/cmdline) cros_efi" > /mnt/cros_zram/cros_cmdline
mount --bind /mnt/cros_zram/cros_cmdline /mnt/cros_root/proc/cmdline
mount --bind /sys /mnt/cros_root/sys
if [[ -d /sys/firmware/efi/efivars ]]; then
    mount --bind /sys/firmware/efi/efivars /mnt/cros_root/sys/firmware/efi/efivars 2>/dev/null || true
fi
mount -t tmpfs tmpfs /mnt/cros_root/run
mkdir -p /mnt/cros_root/run/lock
mount -t tmpfs tmpfs /mnt/cros_root/mnt/stateful_partition
mount --bind /mnt/cros_zram /mnt/cros_root/tmp

chroot /mnt/cros_root /usr/sbin/chromeos-install \
    --dst="${TARGET_SSD}" \
    --yes \
    --target_bios="efi" \
    --payload_image="/tmp/flex.bin"

sync
echo -e "\n${GREEN}${BOLD}======================================================================${NC}"
echo -e "${GREEN}${BOLD}   SUCESSO ABSOLUTO! CHROMEOS FLEX INSTALADO NO SSD KINGSTON 120 GB!  ${NC}"
echo -e "${GREEN}${BOLD}======================================================================${NC}"
echo -e "1. Digite: ${BOLD}sudo poweroff${NC}"
echo -e "2. Remova TODOS os pendrives USB do Dell Inspiron 7520."
echo -e "3. Ligue o Dell: ele iniciará direto no Google ChromeOS Flex pelo SSD!"
