#!/usr/bin/env bash
# ============================================================================
#   NaleHut Panel — Animated Windows VM Stack Installer
#   Repo: https://github.com/stripathi02123-tech/NaleHut-Panel-1.0
#
#   What it does (all automatic):
#     1. Detects your distro + package manager (apt / dnf / pacman / zypper)
#     2. Installs the complete Win11-ready KVM/QEMU stack
#        (KVM, QEMU, libvirt, OVMF UEFI, swtpm TPM 2.0, VirtIO, guestfs)
#     3. Builds & installs the NaleHut Panel from source (or falls back to
#        the distro cockpit package) + cockpit-machines for the VM page
#     4. Enables libvirtd + cockpit.socket + default NAT network
#     5. Downloads the latest virtio-win drivers ISO (~700 MB)
#     6. Installs the separate VM tools (vm-create.sh, vm-list.sh, ...)
#
#   Usage:  sudo ./install.sh [options]
#   Options:
#     -y, --yes            unattended: accept all defaults
#     --skip-panel         do not build NaleHut, VM stack only
#     --panel-only         only build the panel, skip VM stack packages
#     --skip-virtio        do not download virtio-win ISO
#     --no-color           disable all colors/animations
#     --panel-dir DIR      build panel from DIR instead of auto-detect/clone
#     --repo-url URL       clone panel from URL (default: NaleHut-Panel-1.0)
#     --no-tools           do not copy VM tools to /usr/local/bin
#     -h, --help           show this help
# ============================================================================
set -Eeuo pipefail

NH_KIT_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ui.sh"

DEFAULT_REPO_URL="https://github.com/stripathi02123-tech/NaleHut-Panel-1.0.git"
CONF_DIR="/etc/nalehut"
CONF_FILE="$CONF_DIR/vm.conf"
ISO_DIR="/var/lib/libvirt/images"
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
VIRTIO_ISO="$ISO_DIR/virtio-win.iso"

ASSUME_YES=0
DO_PANEL=1
DO_STACK=1
DO_VIRTIO=1
DO_TOOLS=1
PANEL_DIR=""
REPO_URL="$DEFAULT_REPO_URL"

PM=""          # apt | dnf | pacman | zypper
DISTRO_ID="unknown"
DISTRO_PRETTY="unknown"
ACT_USER="${SUDO_USER:-$USER}"

# ---------------------------------------------------------------------------
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)        ASSUME_YES=1 ;;
            --skip-panel)    DO_PANEL=0 ;;
            --panel-only)    DO_STACK=0; DO_VIRTIO=0 ;;
            --skip-virtio)   DO_VIRTIO=0 ;;
            --no-color)      export NO_COLOR=1 ;;
            --no-tools)      DO_TOOLS=0 ;;
            --panel-dir)     PANEL_DIR="${2:?missing dir}"; shift ;;
            --repo-url)      REPO_URL="${2:?missing url}"; shift ;;
            -h|--help)       usage ;;
            *) die "unknown option: $1 (see --help)" ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
step_preflight() {
    step "Pre-flight checks"

    # root / sudo -----------------------------------------------------------
    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
        ok "Running as root"
    elif command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
        ok "Using sudo (user: $ACT_USER)"
        $SUDO -v || die "sudo authentication failed"
    else
        die "run as root or install sudo first"
    fi

    # architecture ----------------------------------------------------------
    case "$(uname -m)" in
        x86_64|aarch64) ok "Architecture: $(uname -m)" ;;
        *) warn "Unusual architecture $(uname -m) — Windows guests need x86_64" ;;
    esac

    # internet --------------------------------------------------------------
    if curl -fsI --max-time 8 https://github.com >/dev/null 2>&1; then
        ok "Internet connection: online"
    else
        warn "Internet check failed — package/ISO downloads may fail"
    fi

    # CPU virtualization ----------------------------------------------------
    local virt_flags
    virt_flags=$(grep -Ecm1 'vmx|svm' /proc/cpuinfo || true)
    if [ -e /dev/kvm ]; then
        ok "KVM device present: /dev/kvm"
    elif [ "$virt_flags" -ge 1 ] 2>/dev/null; then
        warn "CPU supports virtualization but /dev/kvm is missing (load kvm module or reboot)"
    else
        warn "No VT-x / AMD-V found — enable virtualization in BIOS/UEFI!"
    fi

    # disk space ------------------------------------------------------------
    local free_gb
    free_gb=$(df -BG --output=avail /var 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0)
    if [ "$free_gb" -ge 10 ] 2>/dev/null; then
        ok "Disk space: ${free_gb}G available on /var"
    else
        warn "Only ${free_gb}G free on /var — Windows VMs want 8-12G+ per guest"
    fi
}

# ---------------------------------------------------------------------------
# detect_distro [os_release_file]   (file arg makes it unit-testable)
detect_distro() {
    local f="${1:-/etc/os-release}"
    [ -r "$f" ] || die "cannot read $f — unknown operating system"
    # shellcheck disable=SC1090
    . "$f"

    DISTRO_ID="${ID:-unknown}"
    DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO_ID}"
    local id_like="${ID_LIKE:-}"
    local candidates="$DISTRO_ID $id_like"

    case "$candidates" in
        *debian*|*ubuntu*|*linuxmint*|*pop*|*kali*|*raspbian*)
            PM="apt" ;;
        *fedora*|*rhel*|*centos*|*rocky*|*alma*|*ol*|*amzn*|*cobalt*)
            PM="dnf"; command -v dnf >/dev/null 2>&1 || PM="yum" ;;
        *arch*|*manjaro*|*endeavouros*|*garuda*|*artix*)
            PM="pacman" ;;
        *opensuse*|*suse*|*sles*|*sled*)
            PM="zypper" ;;
        *)
            if   command -v apt-get >/dev/null 2>&1; then PM="apt"
            elif command -v dnf     >/dev/null 2>&1; then PM="dnf"
            elif command -v yum     >/dev/null 2>&1; then PM="yum"
            elif command -v pacman  >/dev/null 2>&1; then PM="pacman"
            elif command -v zypper  >/dev/null 2>&1; then PM="zypper"
            else die "unsupported distro: $DISTRO_PRETTY"
            fi ;;
    esac

    if [ "$PM" = "yum" ]; then PM="dnf"; fi
    ok "Detected: $DISTRO_PRETTY ($PM)"
}

# ---------------------------------------------------------------------------
# package lists --------------------------------------------------------------
pkg_list_stack_must() {
    case "$PM" in
        apt)    echo "qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients virtinst ovmf swtpm swtpm-tools dnsmasq-base curl wget ca-certificates" ;;
        dnf)    echo "qemu-kvm libvirt virt-install edk2-ovmf swtpm swtpm-tools curl wget ca-certificates" ;;
        pacman) echo "qemu-full libvirt virt-install edk2-ovmf swtpm dnsmasq curl wget" ;;
        zypper) echo "qemu-kvm libvirt virt-install ovmf swtpm swtpm-tools dnsmasq curl wget ca-certificates" ;;
    esac
}
pkg_list_stack_opt() {
    case "$PM" in
        apt)    echo "virt-manager bridge-utils libguestfs-tools virtiofsd cockpit-machines genisoimage netcat-openbsd" ;;
        dnf)    echo "virt-manager bridge-utils guestfs-tools virtiofsd cockpit-machines genisoimage" ;;
        pacman) echo "virt-manager bridge-utils guestfs-tools virtiofsd cockpit-machines openbsd-netcat" ;;
        zypper) echo "virt-manager bridge-utils guestfs-tools virtiofsd cockpit-machines genisoimage netcat-openbsd" ;;
    esac
}
pkg_list_panel_must() {
    case "$PM" in
        apt)    echo "build-essential autoconf automake libtool pkg-config gettext git python3 nodejs npm libglib2.0-dev libjson-glib-dev libgnutls28-dev libkrb5-dev libpam0g-dev libsystemd-dev" ;;
        dnf)    echo "gcc gcc-c++ make autoconf automake libtool pkgconf-pkg-config gettext git python3 nodejs npm glib2-devel json-glib-devel gnutls-devel krb5-devel pam-devel systemd-devel" ;;
        pacman) echo "base-devel autoconf automake libtool pkgconf gettext git python3 nodejs npm glib2 json-glib gnutls krb5 pam systemd" ;;
        zypper) echo "gcc gcc-c++ make autoconf automake libtool pkg-config gettext-tools git python3 nodejs-default npm glib2-devel libjson-glib-devel gnutls-devel krb5-devel pam-devel systemd-devel" ;;
    esac
}
pkg_list_fallback() {
    case "$PM" in
        apt)    echo "cockpit cockpit-machines" ;;
        dnf)    echo "cockpit cockpit-machines" ;;
        pacman) echo "cockpit cockpit-machines" ;;
        zypper) echo "cockpit cockpit-machines" ;;
    esac
}

pm_refresh() {
    case "$PM" in
        apt)    run_bar "Refreshing package metadata" $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -y ;;
        dnf)    run_bar "Refreshing package metadata" $SUDO dnf -q makecache --refresh ;;
        pacman) run_bar "Refreshing package metadata" $SUDO pacman -Sy --noconfirm ;;
        zypper) run_bar "Refreshing package metadata" $SUDO zypper --non-interactive refresh ;;
    esac
}

pm_install() {           # pm_install "label" "pkg pkg pkg" [allow-fail]
    local label="$1" pkgs="$2" mode="${3:-must}"
    [ -z "$pkgs" ] && return 0
    if ! run_bar "$label" $SUDO env DEBIAN_FRONTEND=noninteractive \
            bash -c "case '$PM' in
                apt)    apt-get install -y $pkgs ;;
                dnf)    dnf install -y -q $pkgs ;;
                pacman) pacman -S --noconfirm --needed $pkgs ;;
                zypper) zypper --non-interactive install --force-resolution $pkgs ;;
            esac"; then
        [ "$mode" = "opt" ] && warn "optional group skipped: $label"
        return 0
    fi
    return 0
}

pkg_exists() {
    case "$PM" in
        apt)    apt-cache show "$1" >/dev/null 2>&1 ;;
        dnf)    dnf -q list available "$1" >/dev/null 2>&1 ;;
        pacman) pacman -Si "$1" >/dev/null 2>&1 ;;
        zypper) zypper -q --non-interactive search -s "$1" 2>/dev/null | grep -q '\[package\]' ;;
    esac
}

step_vm_stack() {
    step "Virtualization stack  ·  KVM + QEMU + libvirt (Windows 11 ready)"
    local must opt p
    must=$(pkg_list_stack_must)
    run_bar "Installing core stack ($(echo $must | wc -w) packages)" \
        $SUDO env DEBIAN_FRONTEND=noninteractive \
        bash -c "case '$PM' in
            apt)    apt-get install -y $must ;;
            dnf)    dnf install -y -q $must ;;
            pacman) pacman -S --noconfirm --needed $must ;;
            zypper) zypper --non-interactive install --force-resolution $must ;;
        esac"

    for p in $(pkg_list_stack_opt); do
        if pkg_exists "$p"; then
            run_spinner "Installing $p" $SUDO env DEBIAN_FRONTEND=noninteractive \
                bash -c "case '$PM' in
                    apt)    apt-get install -y $p ;;
                    dnf)    dnf install -y -q $p ;;
                    pacman) pacman -S --noconfirm --needed $p ;;
                    zypper) zypper --non-interactive install --force-resolution $p ;;
                esac" && ok "$p" || warn "$p failed to install (non-fatal)"
        else
            skip "$p (not in repos — skipped)"
        fi
    done
}

# ---------------------------------------------------------------------------
node_major() { node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 || echo 0; }

step_panel() {
    step "NaleHut Panel build  ·  from source"

    if [ "$ASSUME_YES" -eq 0 ]; then
        if ! ask_yesno "Build & install the NaleHut Panel from source?" "Y"; then
            skip "panel build skipped by user"
            DO_PANEL=0
            return 0
        fi
    fi

    # --- locate / fetch source ------------------------------------------
    if [ -z "$PANEL_DIR" ]; then
        if [ -f "$SCRIPT_DIR/Makefile.am" ] && [ -f "$SCRIPT_DIR/configure.ac" ]; then
            PANEL_DIR="$SCRIPT_DIR"
            info "Using panel sources next to install.sh: $PANEL_DIR"
        else
            PANEL_DIR="$PWD/NaleHut-Panel"
            info "Panel sources not found — cloning from GitHub"
            run_bar "Cloning $REPO_URL" \
                git clone --depth 50 "$REPO_URL" "$PANEL_DIR"
        fi
    fi
    [ -f "$PANEL_DIR/configure.ac" ] || die "no configure.ac in $PANEL_DIR"

    # --- build dependencies ----------------------------------------------
    local pmust
    pmust=$(pkg_list_panel_must)
    pm_refresh
    run_bar "Installing build toolchain ($(echo $pmust | wc -w) packages)" \
        $SUDO env DEBIAN_FRONTEND=noninteractive \
        bash -c "case '$PM' in
            apt)    apt-get install -y $pmust ;;
            dnf)    dnf install -y -q $pmust ;;
            pacman) pacman -S --noconfirm --needed $pmust ;;
            zypper) zypper --non-interactive install --force-resolution $pmust ;;
        esac"

    # --- node >= 16 required by the web build ------------------------------
    local nmajor
    nmajor=$(node_major)
    [ -z "$nmajor" ] && nmajor=0
    if [ "$nmajor" -lt 16 ]; then
        warn "Node.js v$nmajor is too old (need >= 16) for the web asset build"
        if [ "$PM" = "apt" ] && { [ "$ASSUME_YES" -eq 1 ] || ask_yesno "Install Node.js 20 from NodeSource?" "Y"; }; then
            run_bar "Adding NodeSource repo (Node 20)" \
                bash -c "curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO -E bash -"
            run_bar "Installing Node.js 20" \
                $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
        else
            warn "continuing with old node — build may fail; distro cockpit fallback will kick in"
        fi
    else
        ok "Node.js $(node -v) detected"
    fi

    # --- version.m4 (git tag independent) ----------------------------------
    (
        cd "$PANEL_DIR"
        if ! git describe --tags --abbrev=0 >/dev/null 2>&1; then
            printf 'm4_define(VERSION_NUMBER, [1.0])\n' > version.m4
            info "no git tags found — pinning panel version to 1.0"
            run_bar "autoreconf (generating configure)" \
                autoreconf -i --warnings obsolete
            run_bar "configure --prefix=/usr" \
                ./configure --prefix=/usr
        else
            run_bar "autogen + configure" \
                ./autogen.sh --prefix=/usr
        fi
    ) || { warn "source build failed"; fallback_distro_cockpit; return 0; }

    # --- compile ------------------------------------------------------------
    (
        cd "$PANEL_DIR"
        run_bar "make -j$(nproc)  (this can take 5-15 minutes)" \
            make -j"$(nproc)"
        run_bar "make install (system-wide)" \
            $SUDO make install
    ) || { warn "source build failed"; fallback_distro_cockpit; return 0; }

    ok "NaleHut Panel built and installed from source"
}

fallback_distro_cockpit() {
    warn "Falling back to distro cockpit packages so you still get a panel"
    local fb
    fb=$(pkg_list_fallback)
    pm_install "Installing distro cockpit + cockpit-machines" "$fb" must
}

# ---------------------------------------------------------------------------
start_default_net() {
    $SUDO virsh net-start default >/dev/null 2>&1 || true
    $SUDO virsh net-autostart default >/dev/null 2>&1 || true
    $SUDO virsh net-info default >/dev/null 2>&1
}

add_user_groups() {
    local g
    for g in libvirt kvm; do
        getent group "$g" >/dev/null 2>&1 || continue
        $SUDO usermod -aG "$g" "$ACT_USER" 2>/dev/null || true
    done
}

step_services() {
    step "Services  ·  libvirtd, network, cockpit.socket"

    run_spinner "Enabling libvirtd" \
        $SUDO systemctl enable --now libvirtd.service || warn "libvirtd enable failed"
    $SUDO systemctl enable --now virtlogd.socket >/dev/null 2>&1 || true

    if run_spinner "Starting default NAT network" start_default_net; then
        ok "default network: active + autostart"
    else
        warn "default network not available (check libvirtd logs)"
    fi

    run_spinner "Adding $ACT_USER to libvirt + kvm groups" add_user_groups
    ok "$ACT_USER is now in libvirt/kvm (log out+in to apply)"

    run_spinner "Enabling cockpit.socket" \
        $SUDO systemctl enable --now cockpit.socket || warn "cockpit.socket failed"
    ok "Panel listening on https://$(hostname -I 2>/dev/null | awk '{print $1}'):9090"
}

# ---------------------------------------------------------------------------
step_virtio() {
    [ "$DO_VIRTIO" -eq 1 ] || { skip "virtio-win download skipped"; return 0; }
    step "virtio-win drivers ISO  ·  required during Windows setup"

    if [ "$ASSUME_YES" -eq 0 ] && [ "$DO_STACK" -eq 1 ]; then
        ask_yesno "Download virtio-win stable ISO (~700 MB) now?" "Y" || { DO_VIRTIO=0; skip "skipped by user"; return 0; }
    fi

    $SUDO mkdir -p "$ISO_DIR"
    if [ -s "$VIRTIO_ISO" ]; then
        ok "virtio-win ISO already present: $VIRTIO_ISO"
        return 0
    fi
    info "Fetching from fedorapeople.org (stable channel)"
    if run_bar "Downloading virtio-win.iso" \
        $SUDO curl -fL --retry 3 --retry-delay 2 -o "$VIRTIO_ISO" "$VIRTIO_URL"; then
        local sz
        sz=$(du -h "$VIRTIO_ISO" | cut -f1)
        ok "virtio-win.iso saved ($sz) -> $VIRTIO_ISO"
    else
        warn "download failed — rerun later:  tools/vm-download.sh"
    fi
}

# ---------------------------------------------------------------------------
verify_stack() {
    step "Verification"
    local vpass=0 vwarn=0

    if [ -e /dev/kvm ]; then ok "/dev/kvm"; else fail "/dev/kvm missing (BIOS VT-x/AMD-V?)"; vwarn=$((vwarn+1)); fi

    if command -v virsh >/dev/null 2>&1 && virsh -c qemu:///system version >/dev/null 2>&1; then
        ok "libvirt $(virsh -c qemu:///system version | sed -n '1s/.*libvirt \([0-9.]*\).*/\1/p')"
    else
        warn "virsh not reachable via qemu:///system (group membership needs re-login)"
        vwarn=$((vwarn+1))
    fi

    local ov=""
    for f in /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/edk2-ovmf/x64/OVMF_CODE.secboot.fd /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd \
             /usr/share/qemu/ovmf/OVMF_CODE.secboot.fd /usr/share/qemu/OVMF_CODE.fd; do
        [ -f "$f" ] && ov="$f" && break
    done
    if [ -n "$ov" ]; then ok "UEFI firmware (OVMF): $ov"
    else warn "OVMF firmware not found — UEFI VMs unavailable"; vwarn=$((vwarn+1)); fi

    if command -v swtpm >/dev/null 2>&1; then ok "swtpm (TPM 2.0): $(swtpm --version 2>/dev/null | head -n1 | awk '{print $3}')"
    else warn "swtpm missing — Windows 11 TPM check would fail"; vwarn=$((vwarn+1)); fi

    if [ -s "$VIRTIO_ISO" ]; then ok "virtio-win ISO: $VIRTIO_ISO"
    else skip "virtio-win ISO not downloaded yet"; fi

    if systemctl is-active --quiet cockpit.socket; then
        ok "cockpit.socket: active  ->  https://$(hostname -I 2>/dev/null | awk '{print $1}'):9090"
    else
        warn "cockpit.socket not active"
        vwarn=$((vwarn+1))
    fi

    if rpm -q cockpit-machines >/dev/null 2>&1 || dpkg -s cockpit-machines >/dev/null 2>&1 \
       || pacman -Qi cockpit-machines >/dev/null 2>&1; then
        ok "cockpit-machines: 'Virtual Machines' page enabled in NaleHut"
    else
        skip "cockpit-machines not found (VM page hidden — VM tools still work)"
    fi

    printf '\n'
    if [ "$vwarn" -eq 0 ]; then
        ok "All checks passed — your host is Windows-VM ready!"
    else
        warn "$vwarn warning(s) — review the lines above (usually needs a reboot / re-login)"
    fi
}

# ---------------------------------------------------------------------------
write_config() {
    $SUDO mkdir -p "$CONF_DIR"
    $SUDO tee "$CONF_FILE" >/dev/null <<EOF
# NaleHut VM Kit — shared config (written by install.sh v$NH_KIT_VERSION)
ISO_DIR=$ISO_DIR
VIRTIO_ISO=$VIRTIO_ISO
VIRTIO_URL=$VIRTIO_URL
PANEL_REPO=$REPO_URL
KIT_VERSION=$NH_KIT_VERSION
EOF
    ok "Config written: $CONF_FILE"
}

install_tools() {
    [ "$DO_TOOLS" -eq 1 ] || { skip "tools not copied (--no-tools)"; return 0; }
    step "VM tools  ·  separate scripts"
    local t
    for t in "$SCRIPT_DIR"/tools/vm-*.sh; do
        [ -f "$t" ] || continue
        run_spinner "Installing $(basename "$t")" \
            $SUDO install -m 0755 "$t" "/usr/local/bin/$(basename "$t")"
        ok "$(basename "$t")"
    done
    $SUDO mkdir -p /usr/local/lib
    $SUDO install -m 0644 "$SCRIPT_DIR/lib/ui.sh" /usr/local/lib/ui.sh
    $SUDO install -m 0644 "$SCRIPT_DIR/lib/vm-common.sh" /usr/local/lib/vm-common.sh
    ok "Shared libs -> /usr/local/lib/{ui.sh,vm-common.sh}"
}

# ---------------------------------------------------------------------------
summary() {
    step "All done — NaleHut is Windows-VM ready"
    printf '\n'
    info "${B}Open the panel:${R}      https://$(hostname -I 2>/dev/null | awk '{print $1}'):9090"
    info "${B}Create a Windows VM:${R}  sudo vm-create.sh          ${GRAY}(or tools/vm-create.sh)${R}"
    info "${B}List / manage VMs:${R}    vm-list.sh · vm-start.sh · vm-stop.sh · vm-delete.sh"
    info "${B}Download drivers:${R}     vm-download.sh  (virtio-win ISO)"
    printf '\n'
    warn "Group membership changed? Run:  ${B}newgrp libvirt${R}  or log out/in once."
    printf '\n'
    hr
    type_print "  ${BTEAL}Happy virtualizing! — NaleHut VM Kit v$NH_KIT_VERSION${R}" 6
    printf '\n'
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    ui_init
    export NH_KIT_VERSION

    trap 'printf "\n  %s✘ unexpected error at line %s%s — see messages above\n" "${BRED:-}" "${LINENO:-}" "${R:-}" >&2' ERR

    banner "Windows VM stack + panel installer  ·  auto-detects your distro"

    step_preflight
    step "Distro detection"
    detect_distro

    if [ "$DO_STACK" -eq 1 ]; then step_vm_stack; fi
    if [ "$DO_PANEL" -eq 1 ]; then step_panel; fi
    if [ "$DO_STACK" -eq 1 ]; then step_services; fi
    step_virtio
    if [ "$DO_STACK" -eq 1 ]; then verify_stack; fi
    write_config
    install_tools
    summary
}

# only run when executed directly (allows `source install.sh` for testing)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
