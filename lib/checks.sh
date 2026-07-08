#!/usr/bin/env bash
# =============================================================================
# lib/checks.sh - centralized feature dependency validation
#
# Design (see docs/PREREQUISITES.md):
#   Every feature entry point calls
#       require_feature <feature> <user|""> "<action label>"
#   BEFORE touching the system. Validation is strictly READ-ONLY; fixes run
#   only when the administrator explicitly picks them from the fix menu.
#   The user can always cancel back to the previous menu, the loop is
#   bounded, and nothing is partially applied without confirmation.
#
# Requirement record format (one array element per unmet requirement):
#       "severity|name|description|autofix|recommended action"
#   severity: blocking  - the action cannot run until resolved
#             warning   - the action can proceed, admin decides
#   autofix : an id understood by apply_dependency_fix(), or "-" if none.
#
# Logging: only requirement NAMES and feature labels are logged - never
# secrets, key material or OTP values.
# =============================================================================

REQ_FAILURES=()
REQ_FEATURE=""

req_reset() { REQ_FAILURES=(); }

req_fail() { # req_fail <severity> <name> <description> <autofix|-> <action>
    REQ_FAILURES+=("$1|$2|$3|$4|$5")
}

req_has_blocking() {
    local r
    for r in "${REQ_FAILURES[@]}"; do
        [[ "${r%%|*}" == "blocking" ]] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# Entry point used by every feature
# -----------------------------------------------------------------------------

require_feature() { # require_feature <feature> <user|""> "<action label>" ; 0 = proceed
    local feature="$1" user="$2" label="$3" guard=0 choice r sev name
    while (( guard++ < 15 )); do
        validate_feature_requirements "$feature" "$user"
        (( ${#REQ_FAILURES[@]} == 0 )) && return 0

        if (( guard == 1 )); then
            for r in "${REQ_FAILURES[@]}"; do
                IFS='|' read -r sev name _ <<< "$r"
                log_warn "${label} blocked: ${name} (${sev})"
            done
        fi

        # The info screen is shown OUTSIDE the command substitution below:
        # only the menu (whose fd-swap is capture-safe) runs inside $(...),
        # so no widget can ever end up drawn into a captured variable.
        show_missing_requirements_dialog "$label"
        choice="$(_requirements_fix_menu)" || {
            log_info "${label}: cancelled at requirements check"
            return 1
        }
        case "$choice" in
            proceed)
                log_info "${label}: administrator chose to proceed despite warnings"
                return 0 ;;
            back)
                log_info "${label}: cancelled at requirements check"
                return 1 ;;
            recheck)
                ;;   # loop re-validates
            *)
                apply_dependency_fix "$choice" "$user" || true ;;
        esac
    done
    ui_msg "Aborted" "Requirements were still not met after several attempts.
Returning to the previous menu."
    return 1
}

# -----------------------------------------------------------------------------
# Feature -> requirement mapping
# -----------------------------------------------------------------------------

validate_feature_requirements() { # validate_feature_requirements <feature> <user|"">
    local feature="$1" user="${2:-}"
    REQ_FEATURE="$feature"
    req_reset
    case "$feature" in
        yubikey_register)
            check_yubikey_requirements "register" "$user" ;;
        yubikey_test)
            check_yubikey_requirements "test" "" ;;
        mode_cert)
            ;;   # certificate-only mode has no extra prerequisites
        mode_password)
            check_password_auth_requirements ;;
        mode_password_totp)
            check_password_auth_requirements
            check_totp_requirements "mode" "" ;;
        mode_yubikey|mode_password_yubikey)
            check_password_auth_requirements
            check_yubikey_requirements "mode" "" ;;
        totp_generate)
            check_totp_requirements "generate" "$user" ;;
        user_add)
            check_certificate_requirements "" ;;
        profile)
            check_certificate_requirements "$user" ;;
        *)
            log_warn "validate_feature_requirements: unknown feature '${feature}'" ;;
    esac
}

# -----------------------------------------------------------------------------
# Requirement checks (READ-ONLY - they must never change system state)
# -----------------------------------------------------------------------------

check_password_auth_requirements() {
    # Shared base of every PAM-backed mode (password, TOTP, YubiKey).
    local p
    if p="$(find_auth_pam_plugin)"; then
        PLUGIN_PATH="$p"
    else
        req_fail blocking "OpenVPN PAM plugin (openvpn-plugin-auth-pam.so)" \
            "Routes VPN logins to PAM; no password/TOTP/YubiKey mode can work without it." \
            "-" "Reinstall the openvpn package - the plugin ships with it."
    fi
    _check_secret_perms
}

check_totp_requirements() { # check_totp_requirements <context: mode|generate> <user|"">
    local context="$1" user="${2:-}"

    find_pam_module pam_google_authenticator.so || req_fail blocking \
        "TOTP PAM module (pam_google_authenticator)" \
        "Verifies the 6-digit TOTP codes during PAM authentication." \
        "install_totp_pam" "Install the libpam-google-authenticator package."

    case "$context" in
        generate)
            _check_user_exists "$user"
            ;;
        mode)
            # Enabling mandatory TOTP with zero enrolled users locks everyone out.
            if [[ "$TOTP_NULLOK" != "yes" ]] \
                    && [[ -n "$(cert_list_valid_clients 2>/dev/null)" ]] \
                    && ! ls "$OVM_TOTP_DIR"/* >/dev/null 2>&1; then
                req_fail warning "TOTP enrollment" \
                    "No user has a TOTP secret yet and TOTP is mandatory - every login would fail until users enroll." \
                    "generate_totp" "Generate a TOTP secret for at least one user, or enable the per-user-optional policy."
            fi
            ;;
    esac
    _check_secret_perms
}

check_yubikey_requirements() { # check_yubikey_requirements <context: register|test|mode> <user|"">
    local context="$1" user="${2:-}"

    if [[ "$context" != "test" ]]; then
        find_pam_module pam_yubico.so || req_fail blocking \
            "YubiKey PAM module (pam_yubico)" \
            "Validates YubiKey one-time codes during PAM authentication." \
            "install_yubico_pam" "Install the libpam-yubico package."
    fi

    case "$context" in
        register)
            _check_yubico_api warning
            _check_user_exists "$user"
            if [[ "$AUTH_MODE" != "yubikey" && "$AUTH_MODE" != "password_yubikey" ]]; then
                req_fail warning "Global YubiKey authentication" \
                    "Server auth mode is '$(auth_mode_label)'; a registered key is stored but NOT requested at login until a YubiKey mode is enabled." \
                    "-" "Register keys first, then enable a YubiKey mode under Authentication -> Change mode."
            fi
            ;;
        test)
            _check_yubico_api blocking
            command -v curl >/dev/null 2>&1 || req_fail blocking \
                "curl" "Needed to reach the OTP validation service over HTTPS." \
                "-" "Install the curl package."
            ;;
        mode)
            _check_yubico_api blocking
            if ! grep -q ':' "$OVM_YUBI_AUTHFILE" 2>/dev/null; then
                req_fail warning "Registered YubiKeys" \
                    "No user has a registered YubiKey - enabling this mode would lock every user out." \
                    "register_yubikey" "Register at least one user's YubiKey first."
            fi
            ;;
    esac
    _check_secret_perms
}

check_certificate_requirements() { # check_certificate_requirements <user|"">
    local user="${1:-}"

    [[ -x "${EASYRSA_DIR}/easyrsa" ]] || req_fail blocking \
        "easy-rsa PKI tool" \
        "Issues and revokes all VPN certificates." \
        "-" "Run Reinstall from the main menu (or install the easy-rsa package and re-run installation)."

    [[ -f "${PKI_DIR}/ca.crt" ]] || req_fail blocking \
        "CA certificate (${PKI_DIR}/ca.crt)" \
        "Every client profile embeds the CA; without it no profile can be built." \
        "-" "The PKI is missing/broken - run Reinstall from the main menu."

    [[ -f "${PKI_DIR}/index.txt" ]] || req_fail blocking \
        "PKI index (${PKI_DIR}/index.txt)" \
        "Tracks issued/revoked certificates; required for user management." \
        "-" "The PKI is missing/broken - run Reinstall from the main menu."

    [[ -s "${OVPN_SERVER_DIR}/tls-crypt.key" ]] || req_fail blocking \
        "tls-crypt key (${OVPN_SERVER_DIR}/tls-crypt.key)" \
        "Embedded in every client profile; clients cannot connect without it." \
        "-" "The server keys are missing - run Reinstall from the main menu."

    if [[ -n "$user" ]]; then
        [[ -f "${PKI_DIR}/issued/${user}.crt" && -f "${PKI_DIR}/private/${user}.key" ]] \
            || req_fail blocking "Certificate/key of user '${user}'" \
                "The user's certificate and private key are needed to build the .ovpn profile." \
                "-" "Revoke the remnants of this user and create the user again."
    fi
}

# --- shared low-level checks ---------------------------------------------------

_check_user_exists() {
    local u="$1"
    if [[ -z "$u" ]] || ! cert_exists "$u"; then
        req_fail blocking "VPN user '${u:-?}'" \
            "The target user must exist as a valid (non-revoked) VPN user." \
            "-" "Create the user first: User management -> Add a new VPN user."
    fi
}

_check_yubico_api() { # _check_yubico_api <severity>
    local sev="$1"
    if [[ -n "$YUBICO_URL" ]]; then
        is_valid_url "$YUBICO_URL" && return 0
        req_fail "$sev" "Self-hosted validation server URL" \
            "The configured URL is not a valid http(s) address." \
            "configure_yubico_api" "Reconfigure the validation service."
        return 0
    fi
    if [[ -n "$YUBICO_ID" || -n "$YUBICO_KEY" ]]; then
        if is_valid_yubico_client_id "${YUBICO_ID:-}" && [[ -n "$YUBICO_KEY" ]]; then
            return 0
        fi
        req_fail "$sev" "YubiCloud API credentials" \
            "Client ID and secret key must both be set to validate OTPs against YubiCloud." \
            "configure_yubico_api" "Reconfigure the YubiCloud API credentials."
        return 0
    fi
    req_fail "$sev" "YubiKey validation service" \
        "YubiKey OTPs change on every touch and must be verified online (YubiCloud or self-hosted); without a service no OTP can be checked." \
        "configure_yubico_api" "Configure YubiCloud API credentials or a self-hosted verify URL."
}

_check_secret_perms() {
    local bad="" f mode
    for f in "$PAM_FILE" "$OVM_CONFIG_FILE" "$OVM_YUBI_AUTHFILE"; do
        [[ -e "$f" ]] || continue
        mode="$(stat -c '%a' "$f" 2>/dev/null)"
        case "$mode" in 600|400) ;; *) bad+=" ${f}(${mode})" ;; esac
    done
    for f in "$OVM_TOTP_DIR"/*; do
        [[ -f "$f" ]] || continue
        mode="$(stat -c '%a' "$f" 2>/dev/null)"
        case "$mode" in 600|400) ;; *) bad+=" ${f}(${mode})" ;; esac
    done
    [[ -z "$bad" ]] && return 0
    req_fail warning "Secret file permissions" \
        "These files may contain credentials and must be root-only:${bad}" \
        "fix_permissions" "Tighten permissions to 0600/0400."
}

# -----------------------------------------------------------------------------
# UI: show what is missing, why, and how it can be fixed
# -----------------------------------------------------------------------------

show_missing_requirements_dialog() { # show_missing_requirements_dialog "<label>"
    local label="$1" r sev name desc fix act text
    text="Requested action:
  ${label}

Requirements not met:
"
    for r in "${REQ_FAILURES[@]}"; do
        IFS='|' read -r sev name desc fix act <<< "$r"
        text+="
  [${sev^^}] ${name}
      Why:  ${desc}
      Next: ${act}
      Automatic fix available: $( [[ "$fix" != "-" ]] && echo yes || echo no )
"
    done
    if req_has_blocking; then
        text+=$'\nBLOCKING items must be resolved before this action can run.'
    else
        text+=$'\nOnly warnings were found - you may proceed anyway.'
    fi
    ui_show_text "Missing requirements" "$text"
}

_requirements_fix_menu() { # prints the chosen action id; rc=1 on cancel
    local r sev name desc fix act id seen
    local -a fix_ids=() items=()
    for r in "${REQ_FAILURES[@]}"; do
        IFS='|' read -r sev name desc fix act <<< "$r"
        [[ "$fix" == "-" ]] && continue
        seen="no"
        for id in "${fix_ids[@]}"; do [[ "$id" == "$fix" ]] && seen="yes"; done
        [[ "$seen" == "no" ]] && fix_ids+=("$fix")
    done
    for id in "${fix_ids[@]}"; do
        items+=("$id" "$(_fix_label "$id")")
    done
    req_has_blocking || items+=("proceed" "Proceed anyway (warnings only)")
    items+=("recheck" "Re-check requirements")
    items+=("back"    "Return to previous menu")

    ui_menu "Missing requirements" "How do you want to continue?" "${items[@]}"
}

_fix_label() {
    case "$1" in
        install_yubico_pam)   echo "Install the YubiKey PAM module now" ;;
        install_totp_pam)     echo "Install the TOTP PAM module now" ;;
        configure_yubico_api) echo "Configure the YubiKey validation service now" ;;
        register_yubikey)     echo "Register a YubiKey for a user now" ;;
        generate_totp)        echo "Generate a TOTP secret for a user now" ;;
        fix_permissions)      echo "Tighten secret file permissions now" ;;
        *)                    echo "$1" ;;
    esac
}

# -----------------------------------------------------------------------------
# Fix actions (each one is explicit, confirmed, logged, and returns to the
# validation loop afterwards - never applied implicitly)
# -----------------------------------------------------------------------------

apply_dependency_fix() { # apply_dependency_fix <id> <user|"">
    local id="$1" user="${2:-}" rc=0
    log_info "Dependency fix selected: ${id}"
    case "$id" in
        install_yubico_pam)
            ui_run "Install YubiKey PAM module (pam_yubico)" pkg_install_yubico; rc=$?
            ui_pause; ui_resume_tui ;;
        install_totp_pam)
            ui_run "Install TOTP PAM module (pam_google_authenticator)" pkg_install_totp; rc=$?
            ui_pause; ui_resume_tui ;;
        configure_yubico_api)
            yubikey_configure_api; rc=$? ;;
        register_yubikey)
            _yubi_pick_user "Register YubiKey" yubikey_register; rc=$? ;;
        generate_totp)
            _totp_pick_user "Enable TOTP" totp_generate; rc=$? ;;
        fix_permissions)
            _fix_secret_perms; rc=$? ;;
        *)
            log_warn "Unknown dependency fix id: ${id}"; rc=1 ;;
    esac
    return "$rc"
}

_fix_secret_perms() {
    local f
    for f in "$PAM_FILE" "$OVM_CONFIG_FILE" "$OVM_YUBI_AUTHFILE"; do
        [[ -e "$f" ]] && { chmod 600 "$f"; chown root:root "$f" 2>/dev/null; }
    done
    for f in "$OVM_TOTP_DIR"/*; do
        [[ -f "$f" ]] && { chmod 400 "$f"; chown root:root "$f" 2>/dev/null; }
    done
    log_info "Secret file permissions tightened (0600/0400)"
    ui_msg "Permissions" "Secret file permissions have been tightened."
    return 0
}
