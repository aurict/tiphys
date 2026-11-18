# Security center

A read-only security audit of your machines, collected on one **monitoring server** (for example `atlas`) and shown
in the app as a score, a list of findings and a list of changes since the last state you accepted. Nothing is fixed
automatically and nothing is scanned from outside: the audit only reads what the host reports about itself.

It audits three kinds of machine:

- **This machine** (`self`): the agent runs the audit script itself, as the agent user or, optionally, as root through
  `sudo -n`.
- **A host without an agent** (`orion`): the monitoring server connects over SSH with a restricted audit key whose
  only possible command is the audit script.
- **Another agent** (`argo`, the PC): the monitoring server pulls that agent's raw report with a service token of the
  `security-report` scope.

Phase S-1 (this release) covers the status screen and score, the baseline and change detection, the host firewall
evaluation, the incident room link and the app screens. Container vulnerability scans, secret scans, traps, the black
box and attack detection (S-2 to S-5) come later.

API reference: [../agent/api.md#security](../agent/api.md#security). Configuration: feature flag `security`
(default off) and the [`security`](../agent/configuration.md#security) section. Setup of the three kinds of machine:
[setup guide](../setup-guide.md#security-center). Design of the restricted key:
[../security.md](../security.md#security-center-audit-key).

## What it does

- Collects a **report** from every audited machine on a timer (every 15 minutes by default), parses it and evaluates
  **findings** (each with a severity) and a **score** from 0 to 100.
- Keeps a **baseline** per machine: the first good report becomes the baseline silently; later differences (a new
  open port, a new user, a changed sudoers file, a new SSH key, ...) are listed as **changes** until you accept the
  current state as the new baseline.
- Evaluates the **host firewall** from `nft` (when the audit runs as root) to tell whether an open listener can really
  be reached from outside.
- Sends notifications: `security.change`, `security.accepted`, `security.unreachable` and `security.reachable`.
- Feeds the [incident room](incidents.md): a change opens a *security* incident, accepting the state closes it.
- Keeps the **last known state** when a machine can't be reached, and marks it stale.

There is **no automatic AI analysis** of security incidents (the incident room skips it for the `security` kind), and
the audit never changes anything on the audited machine.

## How the audit works

Every source returns the same thing: the text output of `helpers/audit.sh`, a POSIX shell script. The script prints
sections (`@@section NAME` followed by raw lines). The agent parses that text itself, so a remote host never sends
structured data the monitoring server would have to trust: it sends text, and the parser decides what it means.
Unknown lines are ignored; a report without its final `@@end` marker is rejected as truncated.

The script takes exactly one argument from a fixed list, `report` (ordinary) or `report-full` (adds the file scans).
Anything else exits with status 2 without running a command. It never writes anything, runs at the lowest CPU and I/O
priority, gives every command a time limit and caps every section's size.

### What it collects

| Section | Content |
| --- | --- |
| `meta` | host name, kernel, architecture, OS name, uptime, time, whether it ran as root, number of global IPv6 addresses |
| `listen` | listening TCP/UDP sockets (`ss`); process names only as root, or for your own processes |
| `nft` | the nftables ruleset as JSON (includes iptables-nft rules). **Root only.** |
| `sshd` | effective settings from `sshd -T` as root; otherwise the values read from `/etc/ssh/sshd_config` and its drop-ins |
| `users` | accounts with uid 0 or a login shell (name, uid, gid, shell) |
| `passwords` | per account only `empty` or `set` (locked accounts are not listed). **Root only.** |
| `groups` | members of `sudo`, `wheel`, `admin`, `docker`, `adm`, `lxd`, `libvirt` |
| `sudoers` | SHA-256 of `/etc/sudoers` and `/etc/sudoers.d/*`. **Root only.** |
| `authkeys` | `authorized_keys` fingerprints (bits, SHA-256 fingerprint, comment, type) of all users as root, of your own user otherwise |
| `cron` | SHA-256 of `/etc/crontab`, `/etc/cron.d/*` and user crontabs as root; the hash of your own crontab otherwise |
| `timers` | systemd timers (system; plus your user timers when not root) |
| `autostart` | SHA-256 of `~/.config/autostart/*.desktop` and user systemd units. **Not root:** it is a per-user section, so it is unavailable when the audit runs as root |
| `updates` | pending and security updates (`apt-get -s upgrade`), unattended-upgrades setting, age of the package lists, reboot required |
| `services` | active/enabled state of `auditd`, `apparmor`, `ufw`, `firewalld`, `nftables`, `fail2ban`, `ssh`, `sshd`, `unattended-upgrades` |
| `sysctl` | a fixed list of hardening values |
| `logins` | the last 20 logins (`last`, `wtmpdb`, or accepted SSH logins from the journal) |
| `docker` | running containers: image, privileged flag, network/PID mode, read-only root, user, added capabilities, mounts, published ports, compose project and service; and their images (id, tags, digests, size, created) |
| `suid`, `worldwritable` | **Full report only.** SUID/SGID files (root only) and world-writable files under `/etc`, `/usr`, `/opt` and `/var/lib` (at most 200) |
| `agentfiles` | added by the agent for the *local* source: the modes of the agent's config directory and files |

### What it never prints

No environment variables, no key material (only fingerprints and the key comment), no password hashes (only
`empty`/`set`), no contents of sudoers or cron files (only hashes), and for containers no environment, no command line
and no labels except the two compose ones. It does print names that you may consider private: user names, login source
addresses, container names and image names, mount source paths and published ports. A report stays on the monitoring
server (`security-state.json`, mode `0600`).

### Root and rootless

The audit runs as the agent user unless `security.self.sudo` is on (own machine) or the restricted SSH key is used
(the key's command is run through `sudo`). Without root, a section the script can't produce is marked
`@@unavailable`; the app lists such sections under *Sections not available*, and nothing is invented for them.

| Section / check | As root | Without root |
| --- | --- | --- |
| host firewall (`nft`) | read; listeners are judged as `open`/`filtered` | unavailable; `port.exposed` findings carry `firewall: unknown`, and the firewall check falls back to whether `ufw`, `firewalld` or `nftables` is active |
| `sshd` | effective values (`sshd -T`) | the config files; unset keys take OpenSSH's defaults, everything after the first `Match` is ignored |
| `passwords`, `sudoers`, `suid` | read | unavailable |
| process names of listeners | all | your own processes |
| `authkeys`, `cron` | all users | your own user |
| `autostart`, user timers | unavailable | your own |

When the privilege level of a machine changes (for example you turn `sudo` on), the next report starts a **new
baseline** silently, because a root report and a rootless report see different things.

## Score and findings

The score is `100 − Σ weights`, never below 0. Each finding has a severity and a weight:

| Severity | Weight |
| --- | --- |
| `critical` | 30 |
| `high` | 15 |
| `medium` | 6 |
| `low` | 2 |

A finding has a stable `id` (rule plus subject, e.g. `port.exposed:tcp/2222`), the `rule` (the app translates it) and
`params`. The host's **role** (`server` or `desktop`) changes a few rules.

| Rule | Severity | Raised when |
| --- | --- | --- |
| `port.exposed` | medium | A listener on a wildcard or public address (or a Docker port published on all or a public address) is not in the expected list and, when the firewall is known, is not filtered. One finding per protocol and port. |
| `ssh.passwordAuth` | high | `PasswordAuthentication` is `yes` (also when unset: the default) |
| `ssh.emptyPasswords` | critical | `PermitEmptyPasswords yes` |
| `ssh.rootLogin` | high / low | high for `yes`; low for any other value except `no` (including the default `prohibit-password`) |
| `ssh.kbdInteractive` | medium | keyboard-interactive authentication on together with `UsePAM yes` |
| `ssh.x11Forwarding` | low | `X11Forwarding yes` |
| `ssh.tcpForwarding` | low | `AllowTcpForwarding` is neither `no` nor `local` |
| `ssh.maxAuthTries` | low | `MaxAuthTries` above 4 (default 6) |
| `users.uid0` | critical | an account other than `root` has uid 0 |
| `users.emptyPassword` | critical | an account has an empty password (root audit only) |
| `updates.security` | medium | security updates pending |
| `updates.pending` | low | other updates pending (only when no security update is) |
| `updates.reboot` | low / medium | a reboot is required; medium from 7 days on |
| `updates.unattendedOff` | medium | automatic updates are off (servers only) |
| `updates.listsStale` | low | package lists older than 7 days |
| `firewall.none` | low (server) / medium (desktop) | exposed ports exist and no default-deny firewall: the nft ruleset (when readable) is not default-deny, or none of `ufw`, `firewalld`, `nftables` is active |
| `service.auditd` | low | `auditd` is installed but not active (servers only; a host without the package gets no finding) |
| `service.apparmor` | low | AppArmor is installed but not active (servers only; no finding when it isn't installed) |
| `sysctl.weak` | low | one or more of the hardening values is weak: `kernel.randomize_va_space`, `kernel.kptr_restrict`, `kernel.dmesg_restrict`, `kernel.yama.ptrace_scope`, `kernel.unprivileged_bpf_disabled`, `fs.protected_hardlinks`, `fs.protected_symlinks`, `fs.suid_dumpable`, `net.ipv4.tcp_syncookies`, `net.ipv4.conf.all.accept_redirects`, `net.ipv4.conf.all.accept_source_route` (`ip_forward` is not judged: Docker needs it) |
| `docker.privileged` | medium | a privileged container (per container) |
| `docker.socket` | medium | a container mounts `docker.sock` |
| `docker.hostPid` | medium | a container with the host PID namespace |
| `docker.hostNetwork` | low | a container on the host network |
| `files.worldWritable` | low | world-writable files found by the last full report (kept between full runs) |
| `files.agentPerms` | medium | the agent's config directory or one of its state files has group or other permission bits (local source and `security-report` pulls only) |

Always expected and never reported as exposed: `udp/41641` (Tailscale), `udp/68`, `udp/546` (DHCP) and `udp/5353`
(mDNS). Add your own with the host's **expected open ports** (`allowedPorts`, written `tcp/22`, `udp/53`). An expected
port raises no finding, but it still counts in the baseline (see below). Changing the role or the expected ports
re-evaluates the stored report at once, without a new check.

Exposure is judged from the machine's own point of view. A cloud security group or a router in front of the host is
not visible from inside.

## Baseline and changes

A snapshot keeps only what matters for "something changed that shouldn't have". A **change** is an item that was
added, removed or changed against the baseline; it stays listed (with the time it was first seen) until you accept
the state. Categories without data in one of the two reports (for example `passwords` without root) are skipped:
unknown is not "removed".

| Category | What is compared |
| --- | --- |
| `ports` | exposed `proto/port` (including expected ones, and Docker-published ports) |
| `users` | accounts with uid and shell |
| `passwords` | per account `empty`/`set` |
| `sudoers` | hashes of `/etc/sudoers` and `/etc/sudoers.d/*` |
| `authKeys` | SSH key fingerprints per user (value: the comment) |
| `cron` | hashes of cron files (or your crontab) |
| `timers` | systemd timers |
| `autostart` | hashes of autostart entries and user units (rootless only) |
| `sshd` | `port`, `listenaddress`, `permitrootlogin`, `passwordauthentication`, `kbdinteractiveauthentication`, `pubkeyauthentication`, `permitemptypasswords`, `allowusers`, `allowgroups`, `authorizedkeysfile`, `allowtcpforwarding`, `gatewayports`, `permittunnel` |
| `containers` | containers with risky flags: privileged, `docker.sock`, `pid=host`, `net=host`, added capabilities |
| `suid` | SUID/SGID files with mode and owner (from the daily full report, carried over until the next one) |
| `services` | active state of `auditd`, `apparmor`, `ufw`, `firewalld`, `nftables`, `fail2ban` |

Pending updates, logins and sysctl values are findings or information, not baseline items.

A new change is announced **once** (`security.change`). It is high priority when it includes an added or changed item
in `users`, `passwords`, `sudoers`, `authKeys`, `ports` or `sshd`; removals and the other categories are normal
priority. **Accept this state** (a confirmation in the app) makes the current report the new baseline, clears the
list and sends `security.accepted`.

## Notifications

| Key | When | Priority |
| --- | --- | --- |
| `security.change` | new changes against the baseline (params: host, count, categories, severity `warning`/`critical`) | high when critical, else default |
| `security.accepted` | you accepted the current state | low |
| `security.unreachable` | a machine that worked before has not produced a report for 6 hours (once) | default |
| `security.reachable` | the machine reports again after `security.unreachable` | low |

All four carry the link `tiphys://security/<host id>`. A machine that has never produced a report does not send
`security.unreachable`; the app shows the error code instead. Parameters are listed in the
[API reference](../agent/api.md#security).

## Incident room

`security.change` opens an incident of kind *security* for the machine (target: the machine's name), critical when the
change is critical, warning otherwise; further changes join the same incident. `security.accepted` is its closing
signal, so accepting the state clears it and it then resolves like any other incident. The incident offers a button
to open the security screen. It has **no actions** and no automatic AI analysis (the incident room skips the automatic analysis for the `security`
kind). `security.unreachable` and `security.reachable` are not incident signals.

## Schedules and limits

- A timer ticks every minute (first tick 30 seconds after the agent starts). A machine is checked when
  `security.intervalMinutes` (default 15, 5 to 1440) has passed since its last attempt, **one machine at a time**.
  A failed attempt also counts as an attempt.
- The first check of a machine, and then one **full report** per day (24 hours), include the SUID scan
  (`find / -xdev`, 120 s limit) and the world-writable scan. Ordinary reports skip both; the last SUID and
  world-writable lists are carried over (for the baseline, the finding and the report details) until the next full report. *Full check* in the app forces a full report.
- Time limits: 90 s for an ordinary report, 5 minutes for a full one (SSH and agent pulls get 20 s more). A report
  larger than 2 MiB is rejected.
- A machine is marked **stale** when it has had no successful report for more than 3 intervals; the app then shows
  the last known state with its age.
- At most 20 additional machines. *Check now* is limited to 6 per 10 minutes per device.
- One check per machine runs at a time; a second request joins the running one.
- State is kept in `security-state.json` next to `agent.json` (mode `0600`, written atomically). A corrupt file is
  set aside as `security-state.json.corrupt-<time>` and the next report starts a new baseline without notification.

## Limits of the evaluation

- **The firewall evaluation is conservative.** From the `nft` ruleset it asks one question for each wildcard or public
  listener: would a *new* connection from an arbitrary internet address, arriving on an external interface, be
  accepted by every `input` hook chain? Interfaces such as `lo`, `tailscale*`, `docker*`, `br-*`, `veth*`, `virbr*`,
  `cni*`, `flannel*`, `cali*` and `wg*` don't count as external. Rules limited to certain source addresses don't match
  "anyone". Where a rule contains something the evaluator doesn't understand, it assumes the worst: an accepting rule
  matches (the port counts as `open`), a dropping rule doesn't. iptables-nft rules (conntrack, `REJECT`) are
  understood for the usual patterns. `defaultDeny` means an arbitrary high port is filtered on IPv4.
- **Docker-published ports bypass `INPUT`.** Docker rewrites the destination before the input chains, so the
  evaluation doesn't judge them. A port published on all interfaces or a public address counts as exposed (unless
  you list it in the expected ports); published on loopback, a private or a Tailscale address it doesn't.
- **IPv6 is judged only on a machine with a global IPv6 address** (outside Tailscale and container interfaces). A
  wildcard IPv6 socket usually accepts IPv4 too, so it is judged for IPv4 either way.
- Without root there is no ruleset; see [Root and rootless](#root-and-rootless).
- The audit is a checklist of common weaknesses, not a vulnerability scanner or an intrusion detector. A clean score
  doesn't mean a machine is safe.

## In the app

*System › Security* (Turkish UI: *Sistem › Güvenlik*) appears once a connected agent has `security` on.

- **Overview**: every audited machine with its score, counts per severity, a chip with the number of changes, and
  *Last known state* when stale. The monitoring server's agent is the one that lists the machines.
- **Machine**: the score, *Check now* and *Full check*, the **changes** with *Accept this state*, the findings, and
  the details in tabs (ports, SSH, users, scheduled jobs, updates, containers, system), plus *Sections not
  available* for what the audit couldn't read.
- **Audit settings**: for *This machine* the role, the expected open ports and *Check with sudo*; under *Audited
  machines* add, edit or delete a machine (SSH address, user, port and key file, or an agent URL and its
  `security-report` token). The token is never shown again.

## Setup

See [Security center](../setup-guide.md#security-center) in the setup guide: enabling the feature, root-level audit
of the monitoring server itself, an SSH-only host, and another agent.
