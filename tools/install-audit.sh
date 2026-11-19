#!/usr/bin/env bash
# Installs the read-only security audit on a host WITHOUT a Tiphys agent (PLAN.md §15):
#   - /usr/local/lib/tiphys/audit.sh (root:root 0755; the audit user cannot change it)
#   - system user tiphys-audit (password locked, not in the docker group)
#   - /etc/sudoers.d/tiphys-audit: only `sudo -n /usr/local/lib/tiphys/audit.sh` (checked with visudo)
#   - authorized_keys owned by root: restrict + from=<monitoring host IP> + forced command (the user can't edit it)
#   - /etc/ssh/sshd_config.d/05-tiphys-audit.conf: AllowUsers <existing users> tiphys-audit, only if AllowUsers is
#     in use; sshd -t must pass before a reload (reload keeps open sessions).
#
# Usage: tools/install-audit.sh <admin-ssh-target> <monitor-ip> <audit-pubkey-file> [admin-ssh-key]
#   admin-ssh-target  user@host with passwordless sudo (used once for the install)
#   monitor-ip        address the monitoring server connects from (its Tailscale IP)
#   audit-pubkey-file public half of the key the monitoring agent uses (ed25519)
# Remove: tools/install-audit.sh --uninstall <admin-ssh-target> [admin-ssh-key]
# Decoy file + auditd read watch (key tiphys_trap; the monitoring agent polls it with `traps`):
#   tools/install-audit.sh --trap <admin-ssh-target> <decoy-path> <content-file> [admin-ssh-key]
#   tools/install-audit.sh --untrap <admin-ssh-target> <decoy-path> [admin-ssh-key]   (removes the rule and the file)
# Optional env SSH_CONFIG=<file>: passed to ssh -F (tests).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--uninstall" ]; then
  TARGET=$2 KEY=${3:-}
  ssh ${SSH_CONFIG:+-F "$SSH_CONFIG"} -o BatchMode=yes ${KEY:+-i "$KEY"} "$TARGET" sudo -n bash -s <<'REMOTE'
set -euo pipefail
rm -f /etc/sudoers.d/tiphys-audit /etc/ssh/sshd_config.d/05-tiphys-audit.conf
sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd; }
id tiphys-audit >/dev/null 2>&1 && userdel -r tiphys-audit 2>/dev/null || true
rm -rf /var/lib/tiphys-audit /usr/local/lib/tiphys
echo "removed"
REMOTE
  exit 0
fi

if [ "${1:-}" = "--trap" ] || [ "${1:-}" = "--untrap" ]; then
  MODE=$1 TARGET=$2 DECOY=$3
  if [ "$MODE" = "--trap" ]; then CONTENT_B64=$(base64 -w0 "$4"); KEY=${5:-}; else CONTENT_B64=-; KEY=${4:-}; fi
  [[ $DECOY =~ ^/[A-Za-z0-9._/-]{1,200}$ && $DECOY != *..* ]] || { echo "decoy-path: absolute path of [A-Za-z0-9._/-] expected" >&2; exit 1; }
  ssh ${SSH_CONFIG:+-F "$SSH_CONFIG"} -o BatchMode=yes ${KEY:+-i "$KEY"} "$TARGET" sudo -n bash -s -- "$MODE" "$DECOY" "$CONTENT_B64" <<'REMOTE'
set -euo pipefail
MODE=$1 DECOY=$2 CONTENT_B64=$3
RULES=/etc/audit/rules.d/tiphys-trap.rules
command -v auditctl >/dev/null || { echo "auditd is not installed" >&2; exit 1; }
if [ "$MODE" = "--untrap" ]; then
  auditctl -W "$DECOY" -p r -k tiphys_trap 2>/dev/null || true
  [ -f "$RULES" ] && grep -vxF -- "-w $DECOY -p r -k tiphys_trap" "$RULES" > "$RULES.new" || true
  if [ -s "$RULES.new" ]; then mv -f "$RULES.new" "$RULES"; else rm -f "$RULES" "$RULES.new"; fi
  rm -f -- "$DECOY"
  echo "untrapped"
  exit 0
fi
[ -e "$DECOY" ] || [ -L "$DECOY" ] && { echo "decoy exists (or is a symlink), not overwritten" >&2; exit 1; }
# Every existing component of the path must belong to root or to the admin running this (already root-equivalent
# through sudo) and not be writable by group/others: otherwise another user who owns a directory on the way could
# swap in a symlink and make this root script write elsewhere.
p=$(dirname "$DECOY")
while :; do
  if [ -e "$p" ]; then
    [ -L "$p" ] && { echo "path component is a symlink: $p" >&2; exit 1; }
    owner=$(stat -c %u "$p")
    [ "$owner" = 0 ] || [ "$owner" = "${SUDO_UID:-0}" ] || { echo "path component owned by another user: $p" >&2; exit 1; }
    case "$(stat -c %A "$p")" in ?????w????|????????w?) echo "path component writable by group/others: $p" >&2; exit 1 ;; esac
  fi
  [ "$p" = / ] && break
  p=$(dirname "$p")
done
# Create missing directories only (an existing directory keeps its mode).
[ -d "$(dirname "$DECOY")" ] || install -d -m 0755 "$(dirname "$DECOY")"
umask 022
set -C   # O_EXCL: never through a symlink or onto an existing file
printf '%s' "$CONTENT_B64" | base64 -d > "$DECOY"
set +C
chown -h root:root "$DECOY"; chmod 0644 "$DECOY"
touch "$RULES"; chmod 0640 "$RULES"
grep -qxF -- "-w $DECOY -p r -k tiphys_trap" "$RULES" || echo "-w $DECOY -p r -k tiphys_trap" >> "$RULES"
# Immediate effect without reloading every rule; the rules.d file makes it permanent.
auditctl -l | grep -qF -- "-w $DECOY -p r -k tiphys_trap" || auditctl -w "$DECOY" -p r -k tiphys_trap
auditctl -l | grep -F tiphys_trap
echo "trapped"
REMOTE
  exit 0
fi

TARGET=$1 MONITOR_IP=$2 PUBKEY_FILE=$3 KEY=${4:-}
[[ $MONITOR_IP =~ ^[0-9a-fA-F.:]+$ ]] || { echo "monitor-ip: IP address expected" >&2; exit 1; }
PUBKEY=$(cat "$PUBKEY_FILE")
[[ $PUBKEY =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ [A-Za-z0-9@._-]*)?$ ]] || { echo "audit-pubkey-file: one ssh-ed25519 public key expected" >&2; exit 1; }
SSH=(ssh ${SSH_CONFIG:+-F "$SSH_CONFIG"} -o BatchMode=yes ${KEY:+-i "$KEY"} "$TARGET")

# The script travels as base64 so no quoting can change it; its hash is checked on the other side.
SCRIPT_B64=$(base64 -w0 agent/helpers/audit.sh)
SCRIPT_SHA=$(sha256sum agent/helpers/audit.sh | cut -d' ' -f1)
# ssh joins remote arguments with spaces, so anything with spaces travels base64-encoded.
PUBKEY_B64=$(printf '%s' "$PUBKEY" | base64 -w0)

"${SSH[@]}" sudo -n bash -s -- "$MONITOR_IP" "$SCRIPT_SHA" "$SCRIPT_B64" "$PUBKEY_B64" <<'REMOTE'
set -euo pipefail
umask 022
MONITOR_IP=$1 SCRIPT_SHA=$2 SCRIPT_B64=$3 PUBKEY=$(printf '%s' "$4" | base64 -d)
[[ $PUBKEY =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ [A-Za-z0-9@._-]*)?$ ]] || { echo "bad public key" >&2; exit 1; }
U=tiphys-audit HOME_DIR=/var/lib/tiphys-audit LIB=/usr/local/lib/tiphys

# 1. Script (root-owned; written to a temp file, hash checked, then moved).
install -d -o root -g root -m 0755 "$LIB"
tmp=$(mktemp "$LIB/.audit.XXXXXX")
printf '%s' "$SCRIPT_B64" | base64 -d > "$tmp"
[ "$(sha256sum "$tmp" | cut -d' ' -f1)" = "$SCRIPT_SHA" ] || { rm -f "$tmp"; echo "hash mismatch" >&2; exit 1; }
chown root:root "$tmp"; chmod 0755 "$tmp"; mv -f "$tmp" "$LIB/audit.sh"

# 2. User: system account, no usable password ("*", not "!": sshd treats "!" as a locked account), /bin/sh (sshd runs the forced command through it), no extra groups.
if ! id "$U" >/dev/null 2>&1; then
  useradd --system --home-dir "$HOME_DIR" --no-create-home --shell /bin/sh --user-group "$U"
fi
usermod -p '*' "$U"
for g in $(id -nG "$U"); do [ "$g" = "$U" ] || gpasswd -d "$U" "$g" >/dev/null; done

# 3. Key: directory and file owned by root, so the account cannot add keys or change the restrictions.
install -d -o root -g root -m 0755 "$HOME_DIR" "$HOME_DIR/.ssh"
printf 'restrict,from="%s",command="sudo -n /usr/local/lib/tiphys/audit.sh \\"$SSH_ORIGINAL_COMMAND\\"" %s\n' "$MONITOR_IP" "$PUBKEY" > "$HOME_DIR/.ssh/authorized_keys.new"
chown root:root "$HOME_DIR/.ssh/authorized_keys.new"; chmod 0644 "$HOME_DIR/.ssh/authorized_keys.new"
mv -f "$HOME_DIR/.ssh/authorized_keys.new" "$HOME_DIR/.ssh/authorized_keys"

# 4. sudoers: exactly one command (env_reset is the default; no Defaults lines, which sudo-rs may not know).
cat > /etc/sudoers.d/.tiphys-audit.new <<EOF
# Tiphys security audit (read-only). Managed by tools/install-audit.sh.
$U ALL=(root) NOPASSWD: $LIB/audit.sh
EOF
chmod 0440 /etc/sudoers.d/.tiphys-audit.new
visudo -cqf /etc/sudoers.d/.tiphys-audit.new || { rm -f /etc/sudoers.d/.tiphys-audit.new; echo "visudo check failed" >&2; exit 1; }
mv -f /etc/sudoers.d/.tiphys-audit.new /etc/sudoers.d/tiphys-audit

# 5. sshd: if AllowUsers is in force, add the audit user next to the current list (AllowUsers lines accumulate).
#    The drop-in sorts before the existing ones; no Match block (a drop-in Match would swallow the main config).
CONF=/etc/ssh/sshd_config.d/05-tiphys-audit.conf
current=$(sshd -T 2>/dev/null | awk 'tolower($1)=="allowusers"{ $1=""; print }' | xargs || true)
if [ -n "$current" ] && ! printf '%s\n' $current | grep -qx "$U"; then
  printf '# Tiphys security audit. Managed by tools/install-audit.sh.\nAllowUsers %s\n' "$U" > "$CONF"
  chmod 0644 "$CONF"
fi
if ! sshd -t; then
  rm -f "$CONF"; echo "sshd -t failed; drop-in removed" >&2; exit 1
fi
systemctl reload ssh 2>/dev/null || systemctl reload sshd
echo "allowusers: $(sshd -T 2>/dev/null | awk 'tolower($1)=="allowusers"{ $1=""; print }' | xargs)"
echo "installed $(sha256sum "$LIB/audit.sh" | cut -d' ' -f1)"
REMOTE
