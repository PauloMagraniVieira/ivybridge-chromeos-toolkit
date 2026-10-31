#!/usr/bin/env bash
# ==============================================================================
# ChromeOS Flex Enterprise Provisioning Suite for macOS (Intel / Apple Silicon)
# Cupertino / Google Labs Grade — Cryptographic SHA-1/MD5 + Dual-Mode USB Engine
#
# Supports:
#   - Mode A (Direct Raw Boot USB): For USB drives >= 10 GB (flashes 9.52 GB .bin
#     directly to /dev/rdiskN).
#   - Mode B (4 GB Dual-USB Bridge): For 4 GB - 8 GB USB drives (stages verified
#     1.37 GB official .bin.zip + automated zram/chroot SSD installer onto the
#     FAT32/ExFAT USB volume, paired with a Linux LTS Live USB).
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

WORKDIR="${HOME}/Downloads/cros_temp"
RECOVERY_JSON_URL="https://dl.google.com/dl/edgedl/chromeos/recovery/cloudready_recovery.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_INSTALLER_SRC="${SCRIPT_DIR}/install_flex_dell_ssd.sh"

print_header() {
    echo -e "${CYAN}${BOLD}======================================================================${NC}"
    echo -e "${CYAN}${BOLD}   ChromeOS Flex Enterprise Provisioner (Zero-Error / Cryptographic)  ${NC}"
    echo -e "${CYAN}${BOLD}======================================================================${NC}\n"
}

check_prerequisites() {
    if [[ "$OSTYPE" != "darwin"* ]]; then
        echo -e "${RED}[!] Error: This script must be run on macOS.${NC}" >&2
        exit 1
    fi

    for cmd in curl unzip diskutil shasum md5 python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}[!] Error: Required system tool '$cmd' not found.${NC}" >&2
            exit 1
        fi
    done
}

resolve_official_manifest() {
    mkdir -p "$WORKDIR"
    echo -e "${BLUE}[*] Querying official Google ChromeOS Flex STABLE recovery manifest...${NC}"
    local manifest_file="${WORKDIR}/cloudready_recovery.json"
    curl -fsSL "$RECOVERY_JSON_URL" -o "$manifest_file"

    eval "$(python3 - "$manifest_file" <<'PY'
import json, shlex, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
entry = next((x for x in data if x.get("channel") == "STABLE"), data[0])
for key in ("url", "file", "sha1", "md5", "version", "chrome_version"):
    print(f"MANIFEST_{key.upper()}={shlex.quote(str(entry.get(key, '')))}")
print(f"MANIFEST_ZIP_BYTES={int(entry['zipfilesize'])}")
print(f"MANIFEST_BIN_BYTES={int(entry['filesize'])}")
PY
)"

    echo -e "${GREEN}[+] Resolved Official Google Release:${NC}"
    echo -e "    Version        : ${BOLD}${MANIFEST_VERSION}${NC} (Chrome ${MANIFEST_CHROME_VERSION})"
    echo -e "    Zip Payload    : ${CYAN}$((MANIFEST_ZIP_BYTES / 1000000)) MB${NC} (${MANIFEST_ZIP_BYTES} bytes)"
    echo -e "    Raw .bin Image : ${CYAN}$((MANIFEST_BIN_BYTES / 1000000)) MB${NC} (${MANIFEST_BIN_BYTES} bytes)"
    echo -e "    Expected SHA-1 : ${CYAN}${MANIFEST_SHA1}${NC}"
}

select_and_validate_target() {
    echo -e "\n${BLUE}[*] Scanning external physical USB devices...${NC}"
    local ext_list
    ext_list=$(diskutil list external physical 2>/dev/null || true)

    if [[ -z "$ext_list" ]]; then
        echo -e "${RED}[!] No external physical USB drives detected.${NC}" >&2
        exit 1
    fi

    echo "----------------------------------------------------------------------"
    echo "$ext_list"
    echo "----------------------------------------------------------------------"

    while true; do
        echo -ne "\n${YELLOW}${BOLD}Enter target USB identifier (e.g., disk3): ${NC}"
        read -r raw_input
        TARGET_DISK="${raw_input#/dev/}"

        if [[ "$TARGET_DISK" == "disk0" || "$TARGET_DISK" == "disk1" ]]; then
            echo -e "${RED}[!] BLOCKED: ${TARGET_DISK} is macOS internal storage!${NC}"
            continue
        fi

        if ! diskutil info "/dev/${TARGET_DISK}" >/dev/null 2>&1; then
            echo -e "${RED}[!] /dev/${TARGET_DISK} not found.${NC}"
            continue
        fi

        local info
        info=$(diskutil info "/dev/${TARGET_DISK}")

        if echo "$info" | grep -q "Internal:.*Yes"; then
            echo -e "${RED}[!] BLOCKED: /dev/${TARGET_DISK} is marked Internal.${NC}"
            continue
        fi

        if echo "$info" | grep -qiE "vp_USB|Time Machine"; then
            echo -e "${RED}[!] BLOCKED: /dev/${TARGET_DISK} contains a protected backup volume.${NC}"
            continue
        fi

        # Guard against overwriting the Linux LTS Live USB (disk with Linux Filesystem + EFI ESP)
        if diskutil list "/dev/${TARGET_DISK}" | grep -qi "Linux Filesystem"; then
            echo -e "${RED}[!] SAFETY GUARD: /dev/${TARGET_DISK} contains your Linux LTS Live Installer! Choose your other USB drive.${NC}"
            continue
        fi

        TARGET_DISK_BYTES=$(echo "$info" | awk -F'[()]' '/Disk Size:/ {gsub(/[^0-9]/, "", $2); print $2; exit}')
        if [[ -z "${TARGET_DISK_BYTES:-}" ]]; then
            TARGET_DISK_BYTES=0
        fi

        if (( TARGET_DISK_BYTES >= MANIFEST_BIN_BYTES )); then
            PROVISION_MODE="RAW_DD"
            echo -e "${GREEN}[+] Capacity Check: ${TARGET_DISK_BYTES} bytes >= ${MANIFEST_BIN_BYTES} bytes -> Mode: DIRECT RAW BOOTABLE USB${NC}"
        elif (( TARGET_DISK_BYTES >= MANIFEST_ZIP_BYTES + 200000000 )); then
            PROVISION_MODE="BRIDGE_4GB"
            echo -e "${YELLOW}[!] Physical Audit: /dev/${TARGET_DISK} is $((TARGET_DISK_BYTES / 1000000)) MB, while raw .bin is $((MANIFEST_BIN_BYTES / 1000000)) MB.${NC}"
            echo -e "${GREEN}[+] Auto-Engaging Enterprise Dual-USB Bridge Mode (transfers verified 1.37 GB .zip + automated SSD installer).${NC}"
        else
            echo -e "${RED}[!] /dev/${TARGET_DISK} ($((TARGET_DISK_BYTES / 1000000)) MB) is too small even for the 1.37 GB compressed archive.${NC}"
            continue
        fi

        echo -ne "${YELLOW}Type 'YES' to proceed with /dev/${TARGET_DISK} (${PROVISION_MODE}): ${NC}"
        read -r confirm
        if [[ "$confirm" == "YES" ]]; then
            break
        fi
    done
}

download_and_verify_zip() {
    ZIP_PATH="${WORKDIR}/chromeos_flex_${MANIFEST_VERSION}.bin.zip"
    echo -e "\n${BLUE}[*] Downloading official payload (resumable)...${NC}"
    curl -fL -C - --progress-bar "$MANIFEST_URL" -o "$ZIP_PATH"

    echo -e "${BLUE}[*] Verifying cryptographic hashes (SHA-1 & MD5)...${NC}"
    local actual_sha1 actual_md5 actual_bytes
    actual_bytes=$(stat -f %z "$ZIP_PATH")
    actual_sha1=$(shasum -a 1 "$ZIP_PATH" | awk '{print $1}')
    actual_md5=$(md5 -q "$ZIP_PATH")

    if [[ "$actual_bytes" != "$MANIFEST_ZIP_BYTES" ]]; then
        echo -e "${RED}[!] Byte-length mismatch: got ${actual_bytes}, expected ${MANIFEST_ZIP_BYTES}${NC}" >&2
        exit 1
    fi
    if [[ "$actual_sha1" != "$MANIFEST_SHA1" || "$actual_md5" != "$MANIFEST_MD5" ]]; then
        echo -e "${RED}[!] CRYPTOGRAPHIC CHECKSUM MISMATCH! Aborting.${NC}" >&2
        echo -e "    Expected SHA-1: ${MANIFEST_SHA1} | Got: ${actual_sha1}" >&2
        echo -e "    Expected MD5  : ${MANIFEST_MD5}  | Got: ${actual_md5}" >&2
        exit 1
    fi
    echo -e "${GREEN}[+] Cryptographic verification PASSED (SHA-1 & MD5 100% match).${NC}"
}

provision_bridge_4gb() {
    local mount_point
    mount_point=$(diskutil info "/dev/${TARGET_DISK}s1" 2>/dev/null | awk -F': *' '/Mount Point:/ {print $2}' || true)
    if [[ -z "$mount_point" || ! -d "$mount_point" ]]; then
        echo -e "${BLUE}[*] Mounting /dev/${TARGET_DISK}s1...${NC}"
        diskutil mount "/dev/${TARGET_DISK}s1"
        mount_point=$(diskutil info "/dev/${TARGET_DISK}s1" | awk -F': *' '/Mount Point:/ {print $2}')
    fi

    local dest_zip="${mount_point}/chromeos_flex_recovery.bin.zip"
    echo -e "\n${BLUE}[*] Transferring verified 1.37 GB ChromeOS Flex payload to ${mount_point}...${NC}"
    rsync -ah --progress "$ZIP_PATH" "$dest_zip"

    if [[ -f "$LINUX_INSTALLER_SRC" ]]; then
        cp "$LINUX_INSTALLER_SRC" "${mount_point}/install_flex_dell_ssd.sh"
        chmod +x "${mount_point}/install_flex_dell_ssd.sh" || true
    fi

    cat > "${mount_point}/MANIFEST.env" <<EOF
CROS_VERSION="${MANIFEST_VERSION}"
CROS_CHROME_VERSION="${MANIFEST_CHROME_VERSION}"
CROS_ZIP_SHA1="${MANIFEST_SHA1}"
CROS_ZIP_MD5="${MANIFEST_MD5}"
CROS_ZIP_BYTES="${MANIFEST_ZIP_BYTES}"
CROS_BIN_BYTES="${MANIFEST_BIN_BYTES}"
CROS_BIN_NAME="${MANIFEST_FILE}"
EOF

    sync
    echo -e "${BLUE}[*] Performing Read-Back NAND Cryptographic Verification on ${dest_zip}...${NC}"
    local usb_sha1
    usb_sha1=$(shasum -a 1 "$dest_zip" | awk '{print $1}')
    if [[ "$usb_sha1" != "$MANIFEST_SHA1" ]]; then
        echo -e "${RED}[!] USB NAND READ-BACK FAILURE! Expected ${MANIFEST_SHA1}, read ${usb_sha1}.${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}[+] USB NAND Read-Back SHA-1 PASSED: ${usb_sha1}${NC}"

    echo -e "${BLUE}[*] Safely ejecting /dev/${TARGET_DISK}...${NC}"
    diskutil eject "/dev/${TARGET_DISK}"
    echo -e "\n${GREEN}${BOLD}=== 4 GB DUAL-USB BRIDGE PROVISIONING COMPLETE ===${NC}"
}

provision_raw_dd() {
    echo -e "\n${BLUE}[*] Requesting sudo authorization for raw block device /dev/r${TARGET_DISK}...${NC}"
    sudo -v

    echo -e "${BLUE}[*] Extracting ${MANIFEST_FILE}...${NC}"
    unzip -o "$ZIP_PATH" -d "$WORKDIR"
    local bin_path="${WORKDIR}/${MANIFEST_FILE}"
    local bin_bytes
    bin_bytes=$(stat -f %z "$bin_path")
    if [[ "$bin_bytes" != "$MANIFEST_BIN_BYTES" ]]; then
        echo -e "${RED}[!] Extracted .bin size mismatch (${bin_bytes} != ${MANIFEST_BIN_BYTES}).${NC}" >&2
        exit 1
    fi

    diskutil unmountDisk "/dev/${TARGET_DISK}"
    echo -e "${BLUE}[*] Flashing raw image to /dev/r${TARGET_DISK} (bs=4m)...${NC}"
    sudo dd if="$bin_path" of="/dev/r${TARGET_DISK}" bs=4m status=progress
    sync
    diskutil eject "/dev/${TARGET_DISK}"
    echo -e "\n${GREEN}${BOLD}=== STANDALONE BOOTABLE USB PROVISIONING COMPLETE ===${NC}"
}

main() {
    print_header
    check_prerequisites
    resolve_official_manifest
    select_and_validate_target
    download_and_verify_zip
    if [[ "$PROVISION_MODE" == "RAW_DD" ]]; then
        provision_raw_dd
    else
        provision_bridge_4gb
    fi
}

main "$@"
