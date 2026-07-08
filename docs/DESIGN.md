# Design: relationship to angristan/openvpn-install

[`angristan/openvpn-install`](https://github.com/angristan/openvpn-install) is a single ~1300-line Bash script driven by sequential `read -rp` prompts. It is battle-tested and its *OpenVPN mechanics* are excellent; its *architecture* is what this project replaces.

## Reused conceptually (proven mechanics kept)

| Concept | Where it lives here |
|---|---|
| easy-rsa 3 PKI with ECDSA `prime256v1`, random server CN, `nopass` CA | `lib/certs.sh` |
| `tls-crypt` control-channel wrapping | `lib/certs.sh` / `lib/openvpn.sh` |
| Modern cipher profile (AES-GCM/ChaCha20, `TLS-ECDHE-ECDSA-…`, `dh none`, `tls-version-min 1.2`) | `write_server_conf` |
| `topology subnet`, `10.8.0.0/24`, `fd42:42:42:42::/112` for IPv6 | constants in `lib/common.sh` |
| NIC / local-IP / public-IP autodetection with manual override | `lib/os.sh` |
| DNS resolver menu incl. "system resolvers" with systemd-resolved handling | `_choose_dns` |
| CRL-based revocation, CRL world-readable for the privilege-dropped daemon | `lib/certs.sh` |
| Inline `.ovpn` generation (`<ca><cert><key><tls-crypt>`) from a client template | `lib/users.sh` |
| iptables rules applied by an own systemd oneshot unit (add/remove scripts) instead of touching distro persistence | `lib/firewall.sh` |
| `user nobody` privilege drop, sysctl drop-in for forwarding | `lib/openvpn.sh` |
| Headless-safe single-script distribution model (bash + coreutils only) | kept: bash, no runtime beyond packages it installs |

## Redesigned

| angristan | openvpn-manager | Why |
|---|---|---|
| One monolithic script | 12 modules under `lib/` (os / packages / ui / certs / users / auth / totp / yubikey / firewall / service / openvpn / common) | maintainability requirement |
| Sequential Q&A prompts | whiptail/dialog **menu TUI** (MC-style), confirmations default-No, status dashboards; plain-text fallback | usability requirement |
| No state between runs | `/etc/openvpn-manager/config.conf`, parsed against a key whitelist; **all generated files are rebuilt from this state** (no sed-patching of live configs) | idempotency, drift-free settings changes |
| Certificate-only auth | 5 auth modes: cert / +password / +password+TOTP / +YubiKey / +password+YubiKey, via `openvpn-plugin-auth-pam.so` + generated PAM stacks | core new feature |
| — | TOTP lifecycle (enroll/QR/reset/disable, mandatory-vs-optional policy) | new |
| — | YubiKey OTP lifecycle (API config, registration, online test, multi-key) | new |
| — | CN↔username enforcement (`auth-user-pass-verify`) | closes factor-mixing gap PAM alone leaves open |
| `echo`-based messages, no audit trail | `/var/log/openvpn-manager.log` operations log with an explicit no-secrets policy | ops requirement |
| Edits files in place | timestamped backups of every touched file, restore instructions in the UI | safety requirement |
| Firewall: iptables scripts (+ some firewalld) | backend auto-detection: **firewalld / ufw / iptables**, symmetric remove, marked ufw NAT blocks | don't break existing firewalls (ufw especially, as Ubuntu is a primary target) |
| Uninstall removes things directly | uninstall = final `0600` tar backup → stop/disable → reversal of exactly what was applied → optional package purge | reversibility requirement |
| Headless env-var automation (`AUTO_INSTALL`) | not carried over (interactivity was the goal) | listed as future work |

## Key implementation decisions

- **Bash + whiptail over Python**: the tool must run on a freshly provisioned minimal server *before* anything is installed; bash + newt are effectively always available or one package away, and the domain is 90 % orchestration of system commands.
- **Regenerate, don't patch**: `server.conf`, the client template, the PAM file and the CN-verify script are pure functions of the persisted config. Any settings/auth change rewrites them wholesale after a backup. This is what makes re-running and reconfiguring safe.
- **PAM as the single auth abstraction**: password (`pam_unix`), TOTP (`pam_google_authenticator`) and YubiKey (`pam_yubico`) all compose in one generated stack, gated by `pam_succeed_if … ingroup openvpn-users`. OpenVPN sees one plugin; the plugin's prompt-mapping string (`password PASSWORD verification OTP` / `yubikey OTP`) routes the two client-supplied values (auth-user-pass + static-challenge, SCRV1) to the right PAM module by prompt prefix.
- **System accounts as the user store**: gives hashed password storage (`/etc/shadow`), lockout/aging via standard tooling, and `pam_succeed_if` scoping for free — at the cost of accounts appearing in `/etc/passwd` (mitigated: `nologin`, no home, dedicated group, removed on revoke/uninstall).
