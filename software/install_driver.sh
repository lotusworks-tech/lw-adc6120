#!/bin/bash
# =============================================================================
# LotusWorks ADC6120 — Out-of-Tree Driver Installer
# Builds and installs:
#   1. tlv320adcx140 codec driver (patched for 2-channel ADC6120 variant)
# =============================================================================
set -euo pipefail
trap 'fail "Unexpected error on line $LINENO (exit code $?)"' ERR

# ---- Configurable ---------------------------------------------------------
# Auto-detect the kernel major.minor to select the matching stable branch.
KERNEL_VERSION=$(uname -r | grep -oP '^\d+\.\d+')
KERNEL_BRANCH="linux-${KERNEL_VERSION}.y"
DRIVER_SRC_BASE="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/sound/soc/codecs"
MODULE_NAME="snd-soc-tlv320adcx140"
OVERLAY_NAME="lw-adc6120"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/lw_adc_build"
PATCHES_DIR="${SCRIPT_DIR}/patches"
DTS_SRC="${SCRIPT_DIR}/${OVERLAY_NAME}.dts"
HAT_CTRL_SCRIPT="${SCRIPT_DIR}/lw_hat_ctrl.py"
HAT_CTRL_SERVICE="${SCRIPT_DIR}/lw-adc-hat-ctrl.service"
HAT_CTRL_INSTALL_DIR="/opt/lw-adc-hat"
HAT_CTRL_SERVICE_NAME="lw-adc-hat-ctrl"
ASOUND_CONF_SRC="${SCRIPT_DIR}/asound.conf"
ASOUND_CONF_DEST="/etc/alsa/conf.d/10-lw-adc6120.conf"
LW_RECORD_SRC="${SCRIPT_DIR}/lw-record"
LW_RECORD_DEST="/usr/local/bin/lw-record"
# ---------------------------------------------------------------------------

# ---- Colours & helpers -----------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }
step()  { echo -e "\n${BOLD}── Step $1: $2${NC}"; }

# ---- Uninstall path --------------------------------------------------------
do_uninstall() {
    echo -e "\n${BOLD}Uninstalling LotusWorks ADC driver…${NC}\n"

    local mod_path="/lib/modules/$(uname -r)/extra/${MODULE_NAME}.ko"

    if [ -f "$mod_path" ]; then
        info "Removing kernel module ${mod_path}"
        sudo rm -f "$mod_path"
        ok "Codec module removed."
    else
        warn "Codec module not found at ${mod_path} — nothing to remove."
    fi

    sudo depmod -a

    if [ -f "/etc/modules-load.d/${MODULE_NAME}.conf" ]; then
        info "Removing auto-load config"
        sudo rm -f "/etc/modules-load.d/${MODULE_NAME}.conf"
        ok "Auto-load config removed."
    fi

    # Remove device tree overlay
    local dtbo_path="/boot/firmware/overlays/${OVERLAY_NAME}.dtbo"
    if [ -f "$dtbo_path" ]; then
        info "Removing device tree overlay ${dtbo_path}"
        sudo rm -f "$dtbo_path"
        ok "Overlay removed."
    fi

    # Remove dtoverlay line from config.txt
    local config_txt="/boot/firmware/config.txt"
    if [ -f "$config_txt" ] && grep -q "^dtoverlay=${OVERLAY_NAME}" "$config_txt"; then
        info "Removing dtoverlay entry from ${config_txt}"
        sudo sed -i "/^dtoverlay=${OVERLAY_NAME}/d" "$config_txt"
        ok "config.txt entry removed."
    fi

    # Remove HAT control daemon
    if systemctl is-enabled "${HAT_CTRL_SERVICE_NAME}" &>/dev/null; then
        info "Stopping and disabling ${HAT_CTRL_SERVICE_NAME} service"
        sudo systemctl stop "${HAT_CTRL_SERVICE_NAME}" 2>/dev/null || true
        sudo systemctl disable "${HAT_CTRL_SERVICE_NAME}" 2>/dev/null || true
        ok "Service stopped and disabled."
    fi
    if [ -f "/etc/systemd/system/${HAT_CTRL_SERVICE_NAME}.service" ]; then
        sudo rm -f "/etc/systemd/system/${HAT_CTRL_SERVICE_NAME}.service"
        sudo systemctl daemon-reload
        ok "Service unit file removed."
    fi
    if [ -d "$HAT_CTRL_INSTALL_DIR" ]; then
        info "Removing HAT control daemon from ${HAT_CTRL_INSTALL_DIR}"
        sudo rm -rf "$HAT_CTRL_INSTALL_DIR"
        ok "HAT control daemon removed."
    fi

    # Remove channel swap service (legacy DSP_A workaround, no longer needed in I2S mode)
    if systemctl is-enabled "lw-adc-channel-swap" &>/dev/null; then
        info "Stopping and disabling lw-adc-channel-swap service"
        sudo systemctl stop "lw-adc-channel-swap" 2>/dev/null || true
        sudo systemctl disable "lw-adc-channel-swap" 2>/dev/null || true
        ok "Channel swap service stopped and disabled."
    fi
    if [ -f "/etc/systemd/system/lw-adc-channel-swap.service" ]; then
        sudo rm -f "/etc/systemd/system/lw-adc-channel-swap.service"
        sudo systemctl daemon-reload
        ok "Channel swap service unit file removed."
    fi

    # Remove ALSA config
    if [ -f "$ASOUND_CONF_DEST" ]; then
        info "Removing ${ASOUND_CONF_DEST}"
        rm -f "$ASOUND_CONF_DEST"
        ok "ALSA config removed."
    fi

    # Remove lw-record helper
    if [ -f "$LW_RECORD_DEST" ]; then
        info "Removing ${LW_RECORD_DEST}"
        rm -f "$LW_RECORD_DEST"
        ok "lw-record removed."
    fi

    if [ -d "$BUILD_DIR" ]; then
        info "Removing build directory ${BUILD_DIR}"
        rm -rf "$BUILD_DIR"
        ok "Build directory cleaned."
    fi

    echo ""
    ok "Uninstall complete.  Reboot to fully unload the driver."
    exit 0
}

# ---- Parse arguments -------------------------------------------------------
BUILD_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --uninstall)  do_uninstall ;;
        --build-only) BUILD_ONLY=true ;;
        *) fail "Unknown option: $arg\n       Usage: $0 [--build-only | --uninstall]" ;;
    esac
done

# ---- Banner ----------------------------------------------------------------
echo -e "${BOLD}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║   LotusWorks ADC6120 HAT — Driver Installer               ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ---- Pre-flight checks ----------------------------------------------------
step 1 "Pre-flight checks"

# Must be run on Linux
[[ "$(uname -s)" == "Linux" ]] || fail "This script must be run on Linux."

# Require root / sudo
if [[ $EUID -ne 0 ]]; then
    fail "Please run with sudo:  sudo bash $0"
fi

# Check basic network connectivity
if ! wget -q --spider https://git.kernel.org 2>/dev/null; then
    fail "Cannot reach git.kernel.org — please check your internet connection."
fi

ok "Pre-flight checks passed  (kernel $(uname -r))"

# ---- Install build dependencies -------------------------------------------
step 2 "Installing build dependencies"

info "Running apt-get update…"
apt-get update -qq || fail "apt-get update failed (exit code $?)."

info "Installing base build tools…"
apt-get install -y build-essential wget device-tree-compiler || \
    fail "apt-get install failed. Check the output above for details."

# Kernel headers: the package name varies across Raspberry Pi OS versions.
KERNEL_HEADERS="/lib/modules/$(uname -r)/build"
if [ ! -d "$KERNEL_HEADERS" ]; then
    info "Kernel headers not found — attempting to install…"
    HEADER_PKG=""
    for candidate in \
        "linux-headers-$(uname -r)" \
        "raspberrypi-kernel-headers" \
    ; do
        if apt-cache show "$candidate" > /dev/null 2>&1; then
            HEADER_PKG="$candidate"
            break
        fi
    done

    if [ -z "$HEADER_PKG" ]; then
        fail "Could not find a kernel-headers package for $(uname -r).\n" \
             "       Try:  sudo apt search linux-headers"
    fi

    info "Installing ${HEADER_PKG}…"
    apt-get install -y "$HEADER_PKG" || \
        fail "Failed to install ${HEADER_PKG}. Check the output above."
fi

if [ ! -d "$KERNEL_HEADERS" ]; then
    fail "Kernel headers still not found at ${KERNEL_HEADERS} after install."
fi
ok "Dependencies installed."
ok "Kernel headers present at ${KERNEL_HEADERS}"

# ---- Download driver source ------------------------------------------------
step 3 "Downloading driver source (branch ${KERNEL_BRANCH})"

mkdir -p "$BUILD_DIR"

SRC_URL="${DRIVER_SRC_BASE}/tlv320adcx140"
for ext in c h; do
    dest="${BUILD_DIR}/tlv320adcx140.${ext}"
    info "Fetching tlv320adcx140.${ext} …"
    wget -q "${SRC_URL}.${ext}?h=${KERNEL_BRANCH}" -O "$dest" || \
        fail "Failed to download tlv320adcx140.${ext}"
    [ -s "$dest" ] || fail "Downloaded tlv320adcx140.${ext} is empty."
done
ok "Source files downloaded."

# ---- Apply codec patches ---------------------------------------------------
if [ -d "$PATCHES_DIR" ] && compgen -G "${PATCHES_DIR}/0*.patch" > /dev/null; then
    step 3.5 "Applying codec patches from ${PATCHES_DIR}"
    for p in "${PATCHES_DIR}"/0*.patch; do
        info "Applying $(basename "$p") …"
        patch -p1 -d "$BUILD_DIR" < "$p" || fail "Failed to apply $(basename "$p")"
    done
    ok "Codec patches applied."
fi

# ---- Create codec Makefile -------------------------------------------------
step 4 "Generating codec Makefile"

cat > "${BUILD_DIR}/Makefile" <<'MAKEFILE'
obj-m += snd-soc-tlv320adcx140.o
snd-soc-tlv320adcx140-objs := tlv320adcx140.o

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
MAKEFILE

ok "Codec Makefile created."

# ---- Build the codec module ------------------------------------------------
step 5 "Compiling codec kernel module"

make -C "$BUILD_DIR" clean > /dev/null 2>&1 || true
make -C "$BUILD_DIR" 2>&1

KO_FILE="${BUILD_DIR}/${MODULE_NAME}.ko"
[ -f "$KO_FILE" ] || fail "Build produced no .ko file — codec compilation failed."
ok "Codec module built:  ${KO_FILE}"

if $BUILD_ONLY; then
    # ---- Compile overlay (build-only) ------------------------------------------
    step 6 "Compiling device tree overlay"

    [ -f "$DTS_SRC" ] || fail "Overlay source not found: ${DTS_SRC}"
    DTBO_FILE="${BUILD_DIR}/${OVERLAY_NAME}.dtbo"
    dtc -@ -I dts -O dtb -o "$DTBO_FILE" "$DTS_SRC" 2>&1 || \
        fail "Failed to compile device tree overlay."
    ok "Overlay built: ${DTBO_FILE}"

    # ---- Build-only done --------------------------------------------------------
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Build completed successfully!${NC}"
    echo ""
    echo -e "  Codec module:  ${CYAN}${KO_FILE}${NC}"
    echo -e "  Overlay:       ${CYAN}${DTBO_FILE}${NC}"
    echo -e "  Kernel:        $(uname -r)"
    echo ""
    echo -e "  To load manually:"
    echo -e "    ${CYAN}sudo insmod ${KO_FILE}${NC}"
    echo -e "    ${CYAN}sudo dtoverlay ${DTBO_FILE}${NC}"
    echo -e "  To unload:"
    echo -e "    ${CYAN}sudo rmmod ${MODULE_NAME}${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
else
    # ---- Install the module ----------------------------------------------------
    step 6 "Installing kernel module"

    INSTALL_DIR="/lib/modules/$(uname -r)/extra"
    mkdir -p "$INSTALL_DIR"
    cp "$KO_FILE" "$INSTALL_DIR/"
    depmod -a

    ok "Module installed to ${INSTALL_DIR}/"

    # ---- Auto-load on boot -----------------------------------------------------
    step 7 "Configuring auto-load on boot"

    LOAD_CONF="/etc/modules-load.d/${MODULE_NAME}.conf"
    if [ ! -f "$LOAD_CONF" ]; then
        printf '%s\n' "$MODULE_NAME" > "$LOAD_CONF"
        ok "Created ${LOAD_CONF}"
    else
        ok "Auto-load config already exists — skipping."
    fi

    # ---- Install device tree overlay -------------------------------------------
    step 8 "Installing device tree overlay"

    [ -f "$DTS_SRC" ] || fail "Overlay source not found: ${DTS_SRC}"
    DTBO_FILE="${BUILD_DIR}/${OVERLAY_NAME}.dtbo"
    dtc -@ -I dts -O dtb -o "$DTBO_FILE" "$DTS_SRC" 2>&1 || \
        fail "Failed to compile device tree overlay."
    ok "Overlay compiled."

    OVERLAY_DIR="/boot/firmware/overlays"
    if [ ! -d "$OVERLAY_DIR" ]; then
        # Fallback for older Raspberry Pi OS layout
        OVERLAY_DIR="/boot/overlays"
    fi
    cp "$DTBO_FILE" "$OVERLAY_DIR/"
    ok "Overlay installed to ${OVERLAY_DIR}/${OVERLAY_NAME}.dtbo"

    # Add dtoverlay line to config.txt (idempotent)
    CONFIG_TXT="/boot/firmware/config.txt"
    if [ ! -f "$CONFIG_TXT" ]; then
        CONFIG_TXT="/boot/config.txt"
    fi
    if ! grep -q "^dtoverlay=${OVERLAY_NAME}" "$CONFIG_TXT" 2>/dev/null; then
        echo "dtoverlay=${OVERLAY_NAME}" >> "$CONFIG_TXT"
        ok "Added dtoverlay=${OVERLAY_NAME} to ${CONFIG_TXT}"
    else
        ok "dtoverlay entry already present in ${CONFIG_TXT} — skipping."
    fi

    # ---- Install HAT control daemon -------------------------------------------
    step 9 "Installing HAT control daemon (encoders + LEDs)"

    if [ -f "$HAT_CTRL_SCRIPT" ]; then
        # Ensure gpiod Python bindings are available
        info "Checking Python gpiod bindings…"
        if ! python3 -c "import gpiod" 2>/dev/null; then
            info "Installing python3-libgpiod…"
            apt-get install -y python3-libgpiod || \
                warn "Could not install python3-libgpiod — install manually."
        fi
        ok "Python gpiod bindings available."

        # Copy daemon script
        mkdir -p "$HAT_CTRL_INSTALL_DIR"
        cp "$HAT_CTRL_SCRIPT" "$HAT_CTRL_INSTALL_DIR/"
        chmod +x "${HAT_CTRL_INSTALL_DIR}/lw_hat_ctrl.py"
        ok "Daemon script installed to ${HAT_CTRL_INSTALL_DIR}/"

        # Install systemd service
        if [ -f "$HAT_CTRL_SERVICE" ]; then
            cp "$HAT_CTRL_SERVICE" /etc/systemd/system/
            systemctl daemon-reload
            systemctl enable "${HAT_CTRL_SERVICE_NAME}"
            ok "Systemd service enabled: ${HAT_CTRL_SERVICE_NAME}"
        else
            warn "Service file not found at ${HAT_CTRL_SERVICE} — skipping."
        fi
    else
        warn "HAT control script not found at ${HAT_CTRL_SCRIPT} — skipping."
    fi

    # ---- Install ALSA config --------------------------------------------------
    step 10 "Installing ALSA configuration"

    if [ -f "$ASOUND_CONF_SRC" ]; then
        mkdir -p /etc/alsa/conf.d
        cp "$ASOUND_CONF_SRC" "$ASOUND_CONF_DEST"
        ok "ALSA config installed to ${ASOUND_CONF_DEST}"
    else
        warn "asound.conf not found at ${ASOUND_CONF_SRC} — skipping."
    fi

    # ---- Install lw-record helper ----------------------------------------------
    step 11 "Installing lw-record recording helper"

    if [ -f "$LW_RECORD_SRC" ]; then
        cp "$LW_RECORD_SRC" "$LW_RECORD_DEST"
        chmod +x "$LW_RECORD_DEST"
        ok "lw-record installed to ${LW_RECORD_DEST}"
    else
        warn "lw-record not found at ${LW_RECORD_SRC} — skipping."
    fi

    # ---- Done -------------------------------------------------------------------
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Installation complete!${NC}"
    echo ""
    echo -e "  Codec module:  ${CYAN}${MODULE_NAME}${NC}"
    echo -e "  Overlay:       ${CYAN}${OVERLAY_NAME}${NC}"
    echo -e "  HAT Ctrl:      ${CYAN}${HAT_CTRL_SERVICE_NAME}${NC}"
    echo -e "  Recorder:      ${CYAN}${LW_RECORD_DEST}${NC}"
    echo -e "  Kernel:        $(uname -r)"
    echo -e "  I2C Addr:      0x4E  (per LotusWorks ADC6120 HAT design)"
    echo ""
    echo -e "  ${YELLOW}Please reboot to load the driver and overlay.${NC}"
    echo -e "  After reboot, verify with:"
    echo -e "    ${CYAN}arecord -l${NC}"
    echo -e "    ${CYAN}dmesg | grep -i tlv320${NC}"
    echo -e "    ${CYAN}systemctl status ${HAT_CTRL_SERVICE_NAME}${NC}"
    echo -e "    ${CYAN}lw-record -h${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
fi
