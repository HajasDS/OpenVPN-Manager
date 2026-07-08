#!/usr/bin/env bash
# =============================================================================
# lib/os.sh - distribution detection, package-manager mapping, path discovery
# =============================================================================

OS_ID="" OS_LIKE="" OS_NAME="" OS_VERSION=""
PKG_MANAGER=""
NOGROUP="nogroup"
NOLOGIN_SHELL="/usr/sbin/nologin"
OS_SUPPORT="unsupported"   # primary | secondary | besteffort | unsupported

detect_os() {
    [[ -r /etc/os-release ]] || die "Cannot detect distribution: /etc/os-release not found."

    # Read only the fields we need; do not source the file blindly.
    OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
    OS_LIKE="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
    OS_NAME="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
    OS_VERSION="$(. /etc/os-release && printf '%s' "${VERSION_ID:-rolling}")"

    case "$OS_ID" in
        ubuntu)
            OS_SUPPORT="primary"
            version_ge "$OS_VERSION" "20.04" || OS_SUPPORT="besteffort"
            ;;
        debian|raspbian)
            OS_SUPPORT="primary"
            version_ge "$OS_VERSION" "11" || OS_SUPPORT="besteffort"
            ;;
        fedora)
            OS_SUPPORT="secondary"
            ;;
        centos|rocky|almalinux|rhel|ol)
            OS_SUPPORT="secondary"
            version_ge "${OS_VERSION%%.*}" "8" || OS_SUPPORT="besteffort"
            ;;
        arch|manjaro|endeavouros)
            OS_SUPPORT="secondary"
            ;;
        *)
            # Fall back on ID_LIKE for derivatives (Mint, Pop, etc.)
            case "$OS_LIKE" in
                *debian*|*ubuntu*)      OS_SUPPORT="besteffort" ;;
                *rhel*|*fedora*)        OS_SUPPORT="besteffort" ;;
                *arch*)                 OS_SUPPORT="besteffort" ;;
                *)                      OS_SUPPORT="unsupported" ;;
            esac
            ;;
    esac

    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
    else
        die "No supported package manager found (need apt, dnf, yum or pacman)."
    fi

    if getent group nogroup >/dev/null 2>&1; then
        NOGROUP="nogroup"
    else
        NOGROUP="nobody"
    fi

    NOLOGIN_SHELL="$(command -v nologin 2>/dev/null || printf '%s' /usr/sbin/nologin)"

    log_info "Detected OS: ${OS_NAME} (id=${OS_ID}, pkg=${PKG_MANAGER}, support=${OS_SUPPORT})"

    [[ "$OS_SUPPORT" != "unsupported" ]] || \
        die "Unsupported distribution: ${OS_NAME}. Supported: Ubuntu, Debian, Fedora, RHEL-family, Arch."
}

version_ge() { # version_ge A B -> true if A >= B (dotted numeric versions)
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

is_rhel_family() {
    case "$OS_ID" in
        centos|rocky|almalinux|rhel|ol) return 0 ;;
    esac
    [[ "$OS_LIKE" == *rhel* ]]
}

# --- Path discovery ----------------------------------------------------------

find_auth_pam_plugin() {
    # Locate openvpn-plugin-auth-pam.so; prints the path or fails.
    local c
    for c in \
        /usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so \
        /usr/lib/aarch64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so \
        /usr/lib64/openvpn/plugins/openvpn-plugin-auth-pam.so \
        /usr/lib/openvpn/plugins/openvpn-plugin-auth-pam.so \
        /usr/lib/openvpn/openvpn-plugin-auth-pam.so; do
        [[ -e "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    find /usr/lib /usr/lib64 -name 'openvpn-plugin-auth-pam.so' 2>/dev/null | head -n1 | grep .
}

find_pam_module() { # find_pam_module pam_google_authenticator.so
    local name="$1" d
    for d in /lib/security /lib64/security /usr/lib/security /usr/lib64/security \
             /lib/x86_64-linux-gnu/security /usr/lib/x86_64-linux-gnu/security \
             /usr/lib/aarch64-linux-gnu/security; do
        [[ -e "${d}/${name}" ]] && return 0
    done
    find /lib /usr/lib /usr/lib64 -name "$name" 2>/dev/null | head -n1 | grep -q .
}

find_easyrsa() {
    local c
    for c in /usr/share/easy-rsa/easyrsa /usr/share/easy-rsa/3/easyrsa; do
        [[ -e "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    command -v easyrsa 2>/dev/null
}

# --- Network discovery -------------------------------------------------------

detect_default_nic() {
    ip -4 route ls 2>/dev/null | awk '/^default/ {print $5; exit}'
}

detect_local_ipv4() {
    local nic="${1:-}"
    if [[ -n "$nic" ]]; then
        ip -4 addr show dev "$nic" scope global 2>/dev/null \
            | awk '/inet / {sub(/\/.*/,"",$2); print $2; exit}'
    else
        ip -4 addr show scope global 2>/dev/null \
            | awk '/inet / {sub(/\/.*/,"",$2); print $2; exit}'
    fi
}

detect_public_ipv4() {
    local ip
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ip="$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
        if is_valid_ipv4 "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

host_has_ipv6() {
    ip -6 addr show scope global 2>/dev/null | grep -q 'inet6' \
        && ip -6 route ls 2>/dev/null | grep -q '^default'
}
