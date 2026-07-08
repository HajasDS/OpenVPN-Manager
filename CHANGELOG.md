# Changelog

## 1.1.0 — 2026-07-08

### Fixed
- **Hang when enabling/registering YubiKey authentication without the global prerequisites in place.** Actions could start executing (package installs, dialogs after plain-terminal output) before their requirements existed, ending in a whiptail dialog waiting for input on a screen it never drew. All authentication workflows are now validation-first and every wait is bounded and cancellable.

### Added
- **Centralized dependency validation** (`lib/checks.sh`): every feature entry point (`auth mode switch`, `YubiKey register/test`, `TOTP generate`, `user add`, `profile regenerate`) calls `require_feature` *before* touching the system. Missing requirements are shown with severity (blocking/warning), the reason they are needed, and a menu of explicit fix actions (install package, configure Yubico API, register a key, generate a secret, fix permissions), plus *Proceed anyway* (warnings only), *Re-check*, and *Return to previous menu*. Structured records, bounded loop, no partial application without confirmation.
- **Config sanitization** (`config_sanitize`): all persisted values are re-validated on every start; corrupted/hand-edited values (port, protocol, auth mode, endpoint, Yubico ID/URL, firewall backend, plugin path) are reset to safe defaults and logged.
- **Partial-installation detection**: remnants of a failed/interrupted install are reported at startup and the Install action is labelled as a repair.
- **No-TTY guard**: with piped stdio or `TERM=dumb` the tool now uses plain prompts instead of whiptail (which would wait forever on an undrawable dialog).
- Documentation: `docs/PREREQUISITES.md` (dependency matrix + validation design), dependency-scenario test plan in `docs/TESTING.md`.

### Security
- Dependency-failure logging uses fixed requirement names only — no OTPs, secrets, API keys, or key material. New warning + one-tap fix for secret files with loose permissions.

## 1.0.1 — 2026-07-08

- Fixed invisible install progress: long-running steps (apt, easy-rsa, firewall, service start) now run on the plain terminal with live output and `[ OK ]`/`[FAIL]` markers (`ui_run`); whiptail `--infobox` quirk worked around via `TERM=ansi`.
- apt runs unmuted with `DPkg::Lock::Timeout=300` (visible, bounded waiting for `unattended-upgrades`).
- easy-rsa and package installs run with stdin closed — unexpected prompts fail loudly instead of hanging.
- Install-path fatal errors converted to error dialogs that return to the menu instead of killing the TUI; install completion shown as plain text with a clean TUI repaint afterwards.

## 1.0.0 — 2026-07-08

- Initial release: interactive whiptail/dialog TUI for installing and managing an OpenVPN server on Ubuntu/Debian (Fedora/RHEL-family and Arch best-effort); ECDSA P-256 PKI with tls-crypt; user lifecycle with `.ovpn` generation; auth modes: certificate / +password (PAM) / +password+TOTP / +YubiKey OTP / +password+YubiKey; firewalld/ufw/iptables backends; pre-change backups; operations log; safe uninstall.
