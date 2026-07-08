# Testing strategy

Two layers: **static checks** that run anywhere (CI/dev laptop), and a **manual acceptance plan** on disposable VMs, because the tool's essence — package installs, PKI, PAM, firewalls, systemd — only manifests on a real system.

## 1. Static checks (every commit)

```bash
# Syntax check every module
bash -n openvpn-manager.sh lib/*.sh

# Lint (informational; SC1091 for sourced files is expected)
shellcheck -x openvpn-manager.sh lib/*.sh

# No CRLF line endings (would break on Linux)
grep -rlI $'\r' openvpn-manager.sh lib/ && echo "CRLF found!" || echo OK
```

## 2. Test matrix

Run the acceptance plan on at least:

| VM | Why |
|---|---|
| Ubuntu 22.04 / 24.04 (fresh) | primary target, ufw variant |
| Debian 12 (fresh) | primary target, no-firewall variant (raw iptables backend) |
| Rocky/Alma 9 | firewalld + EPEL + `nobody` group path |
| Ubuntu re-run | idempotency / upgrade behaviour |

Suggested harness: Vagrant/libvirt or cloud snapshots; snapshot before install so every scenario starts clean. A second VM (or your laptop) with an OpenVPN client ≥ 2.5 acts as the client.

## 3. Acceptance plan

Each step lists the action and the **pass criteria**.

### 3.1 Fresh installation

1. `sudo ./openvpn-manager.sh` → guided install, defaults, Cloudflare DNS.
   - ✅ finishes without error; `systemctl is-active openvpn-server@server` = `active`
   - ✅ `ss -lunp | grep 1194` shows OpenVPN listening
   - ✅ `sysctl net.ipv4.ip_forward` = 1
   - ✅ firewall backend matches the system (ufw active → ufw rules; else unit `openvpn-manager-iptables` active)
   - ✅ `/etc/openvpn-manager/config.conf` exists, mode `0600`
2. Reboot the VM.
   - ✅ service and firewall rules come back by themselves.

### 3.2 User lifecycle

1. Add user `alice` (no key passphrase).
   - ✅ `/etc/openvpn-manager/clients/alice.ovpn` exists, `0600`, contains `<ca>`, `<cert>`, `<key>`, `<tls-crypt>` blocks
2. Add user `bob` **with** key passphrase.
   - ✅ `grep ENCRYPTED /etc/openvpn/easy-rsa/pki/private/bob.key`
3. Invalid inputs: username `../evil`, `server_x`, `röt`, empty.
   - ✅ all rejected with a clear message, nothing created
4. List users. ✅ both appear with expiry dates.

### 3.3 Certificate-only connection

1. Copy `alice.ovpn` to the client machine; `openvpn --config alice.ovpn`.
   - ✅ `Initialization Sequence Completed`
   - ✅ client's public IP (`curl ifconfig.me`) = server IP; DNS resolves
   - ✅ server Service→status shows alice connected
2. IPv6 (if enabled): ✅ `curl -6 ifconfig.co` works from the client.

### 3.4 Revocation

1. Revoke `bob`. ✅ confirmation is default-No; after confirming, `bob.ovpn` gone, TOTP/YubiKey entries gone.
2. Try connecting with a *saved copy* of `bob.ovpn`.
   - ✅ connection rejected (CRL); server log shows verify failure.

### 3.5 Password authentication

1. Switch mode to *Certificate + password*; set password for `alice`; regenerate profiles.
   - ✅ `/etc/pam.d/openvpn` exists (`0600`) with `pam_succeed_if` + `pam_unix`
   - ✅ `alice.ovpn` now contains `auth-user-pass`
   - ✅ `getent shadow alice` shows a hash, account shell is `nologin`
2. Connect with correct username+password. ✅ success.
3. Wrong password → ✅ `AUTH_FAILED`. Username `carol` (no such user) → ✅ `AUTH_FAILED`.
4. Username `alice` + *bob's* certificate (recreate bob first) → ✅ `AUTH_FAILED` (CN match).
5. `ssh alice@server` with the VPN password → ✅ refused (nologin shell).

### 3.6 Password + TOTP

1. Switch mode to *password + TOTP*; enroll `alice` (scan QR in a TOTP app); regenerate profiles.
   - ✅ QR renders in terminal; `/etc/openvpn-manager/totp/alice` mode `0400`
   - ✅ `alice.ovpn` contains the `static-challenge` line
   - ✅ `grep -r <base32 secret> /var/log/` finds **nothing**
2. Connect: password + current 6-digit code. ✅ success.
3. Reuse the *same* code immediately. ✅ rejected (DISALLOW_REUSE).
4. Wrong/expired code. ✅ `AUTH_FAILED`.
5. Reset TOTP → old app entry fails, new one works.
6. Toggle per-user-optional (nullok), add user `dave` without TOTP → ✅ dave connects with password only; toggle back → ✅ dave rejected.

### 3.7 YubiKey OTP

1. Configure YubiCloud API key; *Validate a test OTP*. ✅ "Success".
2. Register alice's key. ✅ `authorized_yubikeys` contains `alice:<12-char id>`.
3. Switch mode to *Certificate + YubiKey OTP*; regenerate; connect with username + key touch. ✅ success.
4. Replay the same OTP (saved from a text editor touch). ✅ rejected.
5. Another (unregistered) YubiKey's OTP for alice. ✅ rejected.
6. Switch to *password + YubiKey* → ✅ both password and touch required.
7. Unregister the key → ✅ login fails; register again → works.

### 3.8 Service & config management

1. Restart from the Service menu. ✅ comes back active; clients auto-reconnect.
2. Change port 1194→1195. ✅ old firewall rule gone, new one present, server listens on 1195, regenerated profile connects.
3. Change DNS to Quad9. ✅ client resolver = 9.9.9.9 after reconnect.
4. Break `server.conf` on purpose (as the tool would after a bad change) → restart fails → ✅ journal shown automatically, backup exists under `backups/`.

### 3.9 Idempotent re-run

1. Run the script again on the configured server.
   - ✅ opens the management menu (no re-install prompt walk-through), status line correct.
2. Choose *Reinstall*. ✅ two default-No confirmations; after completion old profiles are invalid (new PKI) — expected and warned.

### 3.10 Uninstall

1. Main menu → Uninstall (accept package removal).
   - ✅ backup archive `/root/openvpn-manager-backup-*.tar.gz`, mode `0600`
   - ✅ service gone, unit gone, `/etc/openvpn` gone, PAM file gone
   - ✅ `getent group openvpn-users` empty; alice/dave accounts removed
   - ✅ firewall rules removed **and** pre-existing rules (e.g. the ufw SSH allow) untouched
   - ✅ `sysctl net.ipv4.ip_forward` back to 0 (unless set elsewhere)
2. Re-install afterwards. ✅ works on the same box.

## 4. Regression quick-list

After any code change, minimally re-run: 3.1(1), 3.2(1), 3.3, 3.5(2), 3.6(2), 3.10.
