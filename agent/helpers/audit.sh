#!/bin/sh
# Tiphys read-only security audit (PLAN.md §15). Prints sections ("@@section NAME" + raw lines); the agent parses them.
#
# Runs in three ways:
#   - on a server without an agent, installed root-owned at /usr/local/lib/tiphys/audit.sh and started through a
#     restricted SSH key: command="sudo -n /usr/local/lib/tiphys/audit.sh \"$SSH_ORIGINAL_COMMAND\""
#   - on a server with an agent, through `sudo -n` (same file)
#   - from the agent's own helpers/ directory without root (PC): root-only checks are skipped and marked "unavailable".
#
# It never writes anything, never prints secrets (no environment, no key material: only fingerprints, hashes, counts
# and names) and accepts exactly one argument from a fixed list. Anything else exits 2 without running a command.
set -u
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH LC_ALL=C.UTF-8
VERSION=1

MODE=${1:-report}
case "$MODE" in
  ""|report) MODE=report ;;
  report-full) ;;
  *) echo "tiphys-audit: unsupported request" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "tiphys-audit: unsupported request" >&2; exit 2; }

ROOT=0
[ "$(id -u)" = 0 ] && ROOT=1
has() { command -v "$1" >/dev/null 2>&1; }
# Low priority: never compete with the production workload.
if has renice; then renice -n 19 -p $$ >/dev/null 2>&1 || true; fi
if has ionice; then ionice -c3 -p $$ >/dev/null 2>&1 || true; fi
# Every command gets a time limit; a section's output is capped so a runaway can't flood the agent.
t() { timeout -k 2 "$@"; }
cap() { head -c "${1:-65536}"; }
section() { printf '\n@@section %s\n' "$1"; }
unavailable() { echo "@@unavailable ${1:-root}"; }

printf '@@tiphys-audit %s %s\n' "$VERSION" "$MODE"

section meta
echo "hostname $(hostname 2>/dev/null)"
echo "kernel $(uname -r)"
echo "arch $(uname -m)"
[ -r /etc/os-release ] && (. /etc/os-release; echo "os ${PRETTY_NAME:-unknown}")
echo "uptime $(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
echo "root $ROOT"
echo "time $(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Global IPv6 addresses outside Tailscale/containers: without one, nothing is reachable over IPv6 from outside.
if has ip; then echo "ipv6Global $(ip -6 -o addr show scope global 2>/dev/null | grep -Evc ' (tailscale[0-9]*|docker[0-9]+|br-[^ ]*|veth[^ ]*) ')"; fi

section listen
# netid state recv send local peer [process]; -p shows other users' processes only as root.
if has ss; then
  if [ "$ROOT" = 1 ]; then t 10 ss -Htulnp 2>/dev/null | cap; else t 10 ss -Htuln 2>/dev/null | cap; fi
else unavailable ss; fi

section nft
# Host firewall (nftables, incl. iptables-nft) as JSON, one line; listing the ruleset needs root.
if [ "$ROOT" = 1 ] && has nft; then t 15 nft -j list ruleset 2>/dev/null | tr -d '\n' | cap 1048576; echo
else unavailable; fi

section sshd
if [ "$ROOT" = 1 ] && has sshd; then
  echo "@@mode effective"
  t 10 sshd -T 2>/dev/null | grep -Ei '^(port|listenaddress|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitemptypasswords|allowusers|allowgroups|denyusers|x11forwarding|allowtcpforwarding|allowagentforwarding|permittunnel|gatewayports|maxauthtries|logingracetime|usepam|authorizedkeysfile|clientaliveinterval) ' | cap 8192
else
  echo "@@mode config"
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [ -r "$f" ] || continue
    echo "@@file $f"
    grep -Eiv '^[[:space:]]*(#|$)' "$f" 2>/dev/null | cap 8192
  done
fi

section users
# name uid gid shell — only accounts that can log in or have uid 0.
awk -F: '$3 == 0 || ($7 !~ /(nologin|false|sync|shutdown|halt)$/) { print $1, $3, $4, $7 }' /etc/passwd 2>/dev/null | cap

section passwords
# Per account only "empty", "set" or "locked"; the hash itself is never printed.
if [ "$ROOT" = 1 ] && [ -r /etc/shadow ]; then
  awk -F: '{ s = ($2 == "") ? "empty" : (($2 ~ /^[!*]/) ? "locked" : "set"); if (s != "locked") print $1, s }' /etc/shadow | cap
else unavailable; fi

section groups
for g in sudo wheel admin docker adm lxd libvirt; do
  line=$(getent group "$g" 2>/dev/null) || continue
  echo "$g $(echo "$line" | cut -d: -f4)"
done

section sudoers
if [ "$ROOT" = 1 ]; then
  for f in /etc/sudoers /etc/sudoers.d/*; do [ -f "$f" ] && sha256sum "$f"; done | cap
else unavailable; fi

section authkeys
# user path fingerprint-line (ssh-keygen -l: bits, fingerprint, comment, type)
if [ "$ROOT" = 1 ]; then homes=$(awk -F: '{ print $1 ":" $6 }' /etc/passwd); else homes="$(id -un):$HOME"; fi
for e in $homes; do
  u=${e%%:*}; h=${e#*:}
  for f in "$h/.ssh/authorized_keys" "$h/.ssh/authorized_keys2"; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    t 10 ssh-keygen -lf "$f" 2>/dev/null | sed "s|^|$u $f |" | cap 16384
  done
done

section cron
if [ "$ROOT" = 1 ]; then
  for f in /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/* /var/spool/cron/*; do [ -f "$f" ] && sha256sum "$f"; done 2>/dev/null | cap
else
  c=$(crontab -l 2>/dev/null) && printf '%s' "$c" | sha256sum | sed 's|-$|crontab:'"$(id -un)"'|'
fi

section timers
t 10 systemctl list-timers --all --no-legend --no-pager 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\.timer$/) { print "system", $i, $(i+1); break } }' | cap
if [ "$ROOT" = 0 ]; then
  t 10 systemctl --user list-timers --all --no-legend --no-pager 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\.timer$/) { print "user", $i, $(i+1); break } }' | cap
fi

section autostart
if [ "$ROOT" = 0 ]; then
  for f in "$HOME"/.config/autostart/*.desktop "$HOME"/.config/systemd/user/*.service "$HOME"/.config/systemd/user/*.timer; do
    [ -f "$f" ] && sha256sum "$f"
  done | cap
else unavailable user; fi

section updates
if has apt-get; then
  out=$(t 60 apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null)
  echo "pending $(printf '%s\n' "$out" | grep -c '^Inst ')"
  echo "security $(printf '%s\n' "$out" | grep '^Inst ' | grep -ci 'securi')"
  if has apt-config; then
    echo "unattended $(apt-config dump 2>/dev/null | sed -n 's/^APT::Periodic::Unattended-Upgrade "\(.*\)";/\1/p' | tail -n1)"
  fi
  if [ -f /var/lib/apt/periodic/update-success-stamp ]; then
    echo "listsUpdated $(stat -c %Y /var/lib/apt/periodic/update-success-stamp)"
  elif [ -d /var/lib/apt/lists ]; then
    echo "listsUpdated $(stat -c %Y /var/lib/apt/lists)"
  fi
else
  echo "pending unknown"
fi
if [ -f /var/run/reboot-required ]; then echo "rebootRequired $(stat -c %Y /var/run/reboot-required)"; else echo "rebootRequired no"; fi

section services
for s in auditd apparmor ufw firewalld nftables fail2ban ssh sshd unattended-upgrades; do
  echo "$s $(t 5 systemctl is-active "$s" 2>/dev/null || true) $(t 5 systemctl is-enabled "$s" 2>/dev/null || true)"
done

section sysctl
for k in kernel.randomize_va_space kernel.kptr_restrict kernel.dmesg_restrict kernel.yama.ptrace_scope \
  kernel.unprivileged_bpf_disabled fs.protected_hardlinks fs.protected_symlinks fs.suid_dumpable \
  net.ipv4.tcp_syncookies net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.send_redirects \
  net.ipv4.conf.all.accept_source_route net.ipv4.conf.all.rp_filter net.ipv4.ip_forward; do
  v=$(sysctl -n "$k" 2>/dev/null) && echo "$k $v"
done

section logins
if has last; then t 10 last -n 20 -F -w 2>/dev/null | grep -Ev '^(reboot|wtmp|$)' | cap 16384
elif has wtmpdb; then t 10 wtmpdb last -n 20 -F -w 2>/dev/null | grep -Ev '^(reboot|wtmp|$)' | cap 16384
elif has journalctl; then
  # No wtmp reader (e.g. Ubuntu 26.04): accepted SSH logins from the journal, as "user ssh:method from time".
  t 20 journalctl -q --no-pager -o short-iso --since -7d -g 'Accepted (publickey|password|keyboard-interactive)' 2>/dev/null |
    sed -nE 's/^([^ ]+) [^ ]+ [^:]+: Accepted ([a-z/-]+) for ([^ ]+) from ([^ ]+) port .*/\3 ssh:\2 \4 \1/p' | tail -n 20 | cap 16384
else unavailable last; fi

section docker
if has docker && t 10 docker info >/dev/null 2>&1; then
  echo "@@version $(t 10 docker version --format '{{.Server.Version}}' 2>/dev/null)"
  ids=$(t 20 docker ps -q --no-trunc 2>/dev/null)
  if [ -n "$ids" ]; then
    # One line per container; no environment, no command line, no labels except the compose ones.
    # shellcheck disable=SC2086
    t 30 docker inspect --format 'c|{{.Name}}|{{.Config.Image}}|{{.Image}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.PidMode}}|{{.HostConfig.ReadonlyRootfs}}|{{.Config.User}}|{{range .HostConfig.CapAdd}}{{.}},{{end}}|{{range .Mounts}}{{.Source}}:{{.Destination}}:{{.RW}};{{end}}|{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}}:{{.HostPort}}->{{$p}};{{end}}{{end}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}' $ids 2>/dev/null | cap 131072
    imgs=$(t 30 docker inspect --format '{{.Image}}' $ids 2>/dev/null | sort -u)
    # shellcheck disable=SC2086
    [ -n "$imgs" ] && t 30 docker image inspect --format 'i|{{.Id}}|{{join .RepoTags ","}}|{{join .RepoDigests ","}}|{{.Size}}|{{.Created}}' $imgs 2>/dev/null | cap 131072
  fi
else
  unavailable docker
fi

if [ "$MODE" = report-full ]; then
  section suid
  if [ "$ROOT" = 1 ]; then
    t 120 find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%m %u %p\n' 2>/dev/null | sort | cap 65536
  else unavailable; fi

  section worldwritable
  # Files anyone may change under system directories; container image layers are not the host's files.
  t 120 find /etc /usr /opt /var/lib -xdev \( -path /var/lib/docker -o -path /var/lib/containerd -o -path /var/lib/containers \) -prune \
    -o -type f -perm -0002 -printf '%m %u %p\n' 2>/dev/null | sort | head -n 200 | cap 32768
fi

printf '\n@@end\n'
