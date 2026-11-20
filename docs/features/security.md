# Security center

A read-only security audit of your machines, collected on one **monitoring server** (for example `atlas`) and shown
in the app as a score, a list of findings and a list of changes since the last state you accepted. Nothing is fixed
automatically: the audit only reads what the host reports about itself. You can hand findings to a Claude session that
fixes them over SSH ([Fixing findings with Claude](#fixing-findings-with-claude)), but only when you start it. On top of it the monitoring server can run
heavier checks (container vulnerability and secret scans, an outside view of what the internet can reach, attack
detection from Cloudflare), plant traps, keep a tamper-evident record of what was done through the agents, and lock
everything when a phone is lost. Those are described from [Container vulnerability scan](#container-vulnerability-scan)
on; every one of them is off until you turn it on.

It audits three kinds of machine:

- **This machine** (`self`): the agent runs the audit script itself, as the agent user or, optionally, as root through
  `sudo -n`.
- **A host without an agent** (`orion`): the monitoring server connects over SSH with a restricted audit key whose
  only possible command is the audit script.
- **Another agent** (`argo`, the PC): the monitoring server pulls that agent's raw report with a service token of the
  `security-report` scope.

The features come in phases. **S-1** is the audit itself: status and score, the baseline and change detection, the
host firewall evaluation, the incident room link and the app screens. **S-2** adds the vulnerability and secret scans,
**S-3** traps and alerts to the owner's Telegram, **S-4** the black box and the lost-phone lockdown, **S-5** the
outside view and attack detection. The agent side of S-2 to S-5 is complete; the app screens for them are still being
added, and you can always drive these features through the [API](../agent/api.md#security) (`curl`, examples in the
[setup guide](../setup-guide.md#security-center)).

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
- Optionally (S-2 to S-5, each switched on separately): scans container images for vulnerabilities and repositories,
  logs and local code for secrets; plants decoys that raise an alarm when touched; keeps a hash-chained black box of
  what was done through the agents; locks everything with a recovery code; checks from outside what the internet
  can reach; and spots scanners and attackers in Cloudflare's analytics.
- Feeds the [incident room](incidents.md): a change opens a *security* incident, accepting the state closes it.
- Keeps the **last known state** when a machine can't be reached, and marks it stale.

There is **no automatic AI analysis** of security incidents (the incident room skips it for the `security` kind), and
the audit never changes anything on the audited machine. The later features change nothing on a host either, with
four explicit exceptions that you start yourself: `tools/install-audit.sh --trap` on an SSH host (decoy file and audit
rule), a decoy file the agent creates on its own machine, the lockdown (which revokes access on the agents), and a
[Claude security fix session](#fixing-findings-with-claude), which you start from the findings you selected and whose
permission mode you choose. The audit itself stays read-only in that case too: it only runs again afterwards to check
the result.

## How the audit works

Every source returns the same thing: the text output of `helpers/audit.sh`, a POSIX shell script. The script prints
sections (`@@section NAME` followed by raw lines). The agent parses that text itself, so a remote host never sends
structured data the monitoring server would have to trust: it sends text, and the parser decides what it means.
Unknown lines are ignored; a report without its final `@@end` marker is rejected as truncated, and so is a report in
which the same section header appears twice (something other than the script wrote it, for example a crafted file
name; see below).

The script takes exactly one argument from a fixed list: `report` (ordinary), `report-full` (adds the file scans),
`traps` (recent auditd events of the decoy-file watch, see [Traps](#traps)) and `image-save sha256:<64 hex>` (one
image of a running container as a tar stream, see [Container vulnerability scan](#container-vulnerability-scan)).
Anything else exits with status 2 without running a command. It never writes anything (`image-save` only reads through
`docker save`), runs at the lowest CPU and I/O priority, gives every command a time limit and caps every section's
size. The script's `VERSION` is 3 (version 1 had only the two reports; 2 added `traps` and `image-save`; 3 closed the
file-name injection and narrowed the login and trap sources, see below). A host audited over SSH needs the current
script (run `tools/install-audit.sh` again) before `traps` and `image-save` work there and to get the fixes of version 3.

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
| `logins` | the last 20 logins (`last`, `wtmpdb`, or, where neither exists, accepted SSH logins from the journal; only messages written by `sshd`, matched with `_COMM`, because any user can write an "Accepted …" line to the journal with `logger`) |
| `docker` | running containers: image, privileged flag, network/PID mode, read-only root, user, added capabilities, mounts, published ports, compose project and service; and their images (id, tags, digests, size, created) |
| `suid`, `worldwritable` | **Full report only.** SUID/SGID files (root only) and world-writable files under `/etc`, `/usr`, `/opt` and `/var/lib` (at most 200). `find` prints the names NUL-separated and the script then replaces any newline inside a name with `?`, so a crafted file name can never start a line of its own (and so never a fake `@@section`). |
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
| `sshd` | effective values (`sshd -T`) | the config files; unset keys take OpenSSH's defaults; the lines of a `Match` block are ignored up to the end of the file the block is in (as sshd does), so settings in a later drop-in still count |
| `passwords`, `sudoers`, `suid` | read | unavailable |
| process names of listeners | all | your own processes |
| `authkeys`, `cron` | all users | your own user |
| `autostart`, user timers | unavailable | your own |

When the privilege level of a machine changes (for example you turn `sudo` on) and no changes are waiting for
acceptance, the next report starts a **new baseline** silently, because a root report and a rootless report see
different things. If changes **are** pending, the flip must not wash them away: it is listed as a change of its own
(`services`, item `audit.root`, announced as a `security.change` of critical severity), the old baseline stays, and
you accept the state as usual.

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
unknown is not "removed". The same goes for a category that one report could not read (Docker restarting, a failed
command): the changes already listed for it are **kept**, not dropped, until a report reads it again.

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

The later phases add these keys (all on the monitoring server's agent; parameters and links in the
[API reference](../agent/api.md#notifications-s-2-to-s-5)):

| Key | When | Priority |
| --- | --- | --- |
| `security.vulns` | a scanned image has critical vulnerabilities for the first time or more than before | default |
| `security.secretFound` | a secret scan found something new | high |
| `security.trap` | a decoy was touched (or you sent the test alarm) | high |
| `security.exposure` | the outside view found a new open port, a leaking path or a critical problem | high |
| `security.attack` | an IP behaved like a scanner or attacker at Cloudflare (once per IP, zone and day) | default |
| `blackbox.broken` | the black box chain failed its verification (once until it verifies again) | high |
| `security.lockdown` | a lockdown ran on this agent (recovery code, or another agent's fan-out) | high |

Of these, `security.trap`, `security.secretFound`, `blackbox.broken`, `security.lockdown` and a `security.change` with
severity `critical` are also sent to the owner's Telegram (see [Alerts](#alerts-to-the-owners-telegram)).

## Incident room

`security.change` opens an incident of kind *security* for the machine (target: the machine's name), critical when the
change is critical, warning otherwise; further changes join the same incident. `security.accepted` is its closing
signal, so accepting the state clears it and it then resolves like any other incident. The incident offers a button
to open the security screen. It has **no actions** and no automatic AI analysis (the incident room skips the automatic analysis for the `security`
kind). `security.unreachable` and `security.reachable` are not incident signals.

## Container vulnerability scan

*Phase S-2. Off until `security.scanners.trivy` is on. Needs Docker on the monitoring server.*

The monitoring server scans the images of the **running containers** of every audited machine with
[Trivy](https://trivy.dev), for known vulnerabilities in installed packages. The list of images comes from the
machines' latest reports (this machine, SSH hosts, other agents); an image used on several machines, or by several
containers, is scanned once (by image id). An image that no container runs any more drops off the list.

- **Trivy runs in a container pinned by digest** (`aquasec/trivy@sha256:…`, version 0.76.2) with a 2 GB memory limit,
  2 CPUs, a read-only root file system, `no-new-privileges` and a 4 GB `tmpfs` for `/tmp`. Its vulnerability database
  lives in the Docker volume `tiphys-trivy-cache`; the container downloads and refreshes the database itself, so it
  has network access. Only vulnerabilities (no secret or misconfiguration scanners) of severity `CRITICAL` and `HIGH`
  are looked at. Nothing is pulled by hand: Docker fetches the Trivy image the first time it is needed.
- **Where the image comes from**, in this order:
  1. **Remote, by digest.** Trivy fetches `repo@sha256:<digest>` from the registry (using a digest from the image's
     `RepoDigests`, for the host's CPU architecture). It never uses a tag, so an image of the same name that lives
     somewhere else cannot be scanned by mistake. Nothing is pulled into Docker. **Only known registries are
     contacted**: `docker.io`, `ghcr.io`, `gcr.io`, `quay.io`, `registry.k8s.io`, `public.ecr.aws`,
     `mcr.microsoft.com`, `registry.gitlab.com`, `lscr.io` and `codeberg.org`, plus any registry you gave credentials
     for (`registryAuth`). An audited host's report is data from another machine; without this rule a crafted image
     name could make the monitoring server fetch from an arbitrary address (a cloud metadata address, say). An
     image from any other registry has no remote step and falls through to the next source.
  2. **Local `docker save`**, for an image on the monitoring server itself that no registry has (or that needs
     credentials you did not give). The tar goes to a private temporary directory, is scanned with `trivy --input` and
     deleted afterwards. Limits: 3 GB and 30 minutes. A full disk fails that one save (`saveFailed`); it does not
     stop the agent.
  3. **`image-save` over the restricted SSH key**, for such an image on an SSH-audited host. This puts load on that
     host's Docker daemon, so: **only at night** (the night window, even when you start the scan by hand: the image
     stays `pending` with `error: "nightOnly"`), **at most 2 saves per night** (counted per night, so a window that
     crosses midnight such as `[22, 6]` is one night, not two; a failed
     attempt counts too; the rest wait with `error: "saveLimit"`), **at most 3 GB** (the audit script checks the size
     on the host and exits with 4; the agent also cuts the stream at 3 GB), 30 minutes at most, and only for an image
     that a running container on that host uses (the script checks that again on the host). An image on another
     agent has no save route: without a registry it is `notAvailable`.
  A registry answer "not found" or "unauthorized" continues with the next source; any other Trivy failure on the
  remote step ends the attempt as `failed`.
- **Registry credentials** (`security.scanners.registryAuth`, up to 10 entries `{registry, username, token}`, for
  private images such as `ghcr.io` with a read-only token) are matched by the registry name of the digest reference
  (`docker.io` when there is none). They reach Trivy only through the **environment of the `docker` child process**
  (`TRIVY_USERNAME`, `TRIVY_PASSWORD`, handed into the container with `-e NAME`), never on a command line, so they
  don't show in a process list. They are never returned by the API (`hasToken` only).
- **Java DB is off by default** (`security.scanners.javaDb`). Trivy needs a separate database of about 1 GB to look
  inside Java archives. While it is off, the agent starts Trivy with `--skip-java-db-update` and skips every `*.jar`,
  `*.war` and `*.ear` file. That means **vulnerabilities in Java libraries inside those archives are not reported**:
  an image that is mostly a Java application can show "clean" while it isn't. Operating-system packages and the other
  language ecosystems (Python, Node, Go, …) are still scanned. Turn it on if you run such images; the first scan then
  downloads the database.
- **Result.** Per image: status, source (`remote`/`local`/`ssh`), scan time, OS, the counts of critical, high and
  fixable findings, and the list of findings with only `id`, package, installed version, fixed version, severity,
  title and target (at most 300 per image, critical first, fixable first; `truncated` says more existed). No file
  content is kept. Statuses: `ok`; `pending` (not scanned yet, or waiting for the night or the save limit);
  `needsCredentials` (`error` is the registry name); `notAvailable` (`error: "noSource"`: no digest, no local copy and no
  save route; or `"notFound"`); `failed` (`error` such as `badOutput`, `scanFailed`, `saveFailed`, `imageTooLarge`,
  `knownHostsMissing`, `agent.security.timeout`).
- **Notification** `security.vulns` (priority default): only when an image has at least one *critical* finding and it
  is the first scan or the critical count went up. High findings alone don't notify.
- **Schedule.** The monitoring server checks every 10 minutes whether it is inside the **night window**
  (`security.scanners.nightHours`, local hours, default `[2, 6]`, written `[from, to]`; `[22, 6]` wraps over midnight;
  `[0, 24]` means always). Inside it, due images are scanned one at a time: never scanned or pending first, then
  images last scanned **more than 7 days** ago; a failed scan is retried after 24 hours. *Scan now* (`POST
  /v1/security/vulns/scan`) scans the due images at once, outside the window too (except SSH saves, above), or one
  image if you name it (refused with `agent.security.scanBusy` while the batch is running: one Trivy at a time).

State: `security-vulns.json` next to `agent.json` (mode `0600`; a corrupt file is set aside with a `.corrupt-<time>`
suffix).

## Secret scan

*Phase S-2. GitHub and Loki need `security.scanners.gitleaks` on and Docker; the local scan needs only
`security.scanners.localRoots`.*

Looks for credentials that ended up where they shouldn't be. A **finding never contains the secret**: gitleaks runs
with `--redact`, the agent drops its `Secret` and `Match` fields before anything is stored, and a finding keeps only
*where* (repository, file, line, commit; or log host, stream and time) and *which rule*. The secret itself is still
where it was: dismissing a finding doesn't remove it, rotating the secret does.

gitleaks runs in a container pinned by digest (v8.30.1) with **no network**, a read-only root file system, 1 GB of
memory, 1 CPU and the data mounted read-only.

- **GitHub** (`security.scanners.github`: `owners` (up to 20) and an optional `token`). Every non-fork repository of
  those owners (at most 200) is cloned as a bare repository into a temporary directory (the whole history is scanned)
  and removed afterwards. **Without a token only the owners' public repositories** are seen. With a **fine-grained
  token that has `contents: read`** the owners' private repositories are included too. Only the listed owners are
  scanned, even if the token can see more. The token goes to GitHub's API as a bearer header for the repository list,
  and to `git` **only through its process environment** (an `http.extraheader` set with `GIT_CONFIG_*` variables):
  it is not in the URL, not in a command line and not in the clone's own configuration. The default branch's head is
  read first with `git ls-remote`; **a repository is rescanned only when its head moved** (a repository whose clone or
  scan failed is retried next time and shows its `error`: `cloneFailed` or `scanFailed`). Only the default branch's
  history is looked at, not a branch you push to later.
- **Loki** (`security.scanners.loki`: `{container, port?}` of a Loki container on this machine, whose IP is looked up
  each time, or `{url}`). For every value of the `host` label, the **last 24 hours** of its logs (at most 50 000
  lines or 32 MiB per host) are piped through `gitleaks stdin`. A finding keeps the host, the stream label
  (container or unit) and the log time. Every run looks at the same 24 hours again, but a log line has a stable
  identity, so it is reported once. Loki's answer is read with a size limit (64 MiB), GitHub's (8 MiB) too. Logs that contain secrets are a common leak (a request dump, a debug line): the
  fix is in the application, not here.
- **Local repositories** (`security.scanners.localRoots`: paths inside `allowedRoots`, up to 20). Any agent can do
  this, for example the PC (`argo`) scans its own code. A root is a git repository, or a folder whose direct
  subfolders are (at most 100 repositories). Only **git-tracked** files up to 512 KiB, up to 20 000 per repository,
  that are text, are read (a tracked symlink is not followed: it may point outside the repository), and **nothing leaves the machine but the location**. Two kinds of findings: a **tracked
  `.env` file** (`.env` or `.env.*`, except `.example`, `.sample`, `.template` and `.dist`; rule `env-file-tracked`),
  and lines that match the agent's own redaction patterns for well-known key formats (private key blocks, JWTs, AWS,
  GitHub, Stripe, Slack and Google keys, API keys, Tiphys tokens; rule = the pattern's name). The generic
  `password = …` pattern is deliberately not used here: it would flag every `password = form.password`. This is not
  gitleaks and doesn't read history; it is a quick check of the working tree.
- **Findings and dismissing.** The finding's id is a hash of source, location and rule, so the same finding doesn't
  come back or notify twice. For local findings the location is the file and the occurrence number of the rule in
  it, not the line, so lines added above a finding move it (its line is updated) without making it a new one. *Dismiss* marks it as accepted (still listed, below the open ones) and can be undone.
- **Notification** `security.secretFound` (priority high; also to the owner's Telegram): one per run, for all new
  findings of all sources (params: how many, which sources, up to three locations).
- **Schedule.** At night (the night window as above), when the last run is more than 20 hours old. *Scan now* (`POST
  /v1/security/secrets/scan`) runs it at once. `lastRun` per source is `null` or the error code, so a failing source
  (a missing token, Loki unreachable) is visible.

State: `security-secrets.json` (mode `0600`).

## Traps

*Phase S-3. Nothing is on until you create it.*

A trap is something no legitimate user touches, so **any** touch is an alarm: the notice `security.trap` (priority
high, critical for the [owner's Telegram](#alerts-to-the-owners-telegram) as well). There are four kinds. All of them
belong to the agent that created them: a trap on `atlas` is watched by `atlas`'s agent.

**Decoy token.** `POST /v1/security/traps/tokens {name}` returns a `tps_…` token **once**. The agent keeps only its
hash (up to 20 tokens). Plant it where an intruder would look (a notes page, a backup `.env`). It opens nothing:
whoever presents it gets the **same `401`** as for any unknown token, so the response doesn't reveal the trap (a decoy
passed in the `?token=` query, or without any `Authorization` header, is recognised too). Internally the server hands every rejected token to the trap service; if it is a decoy, the alarm goes
off, at most **once a minute per decoy** (params: the decoy's name, the client address the agent saw, the request path).

**Decoy file.** `POST /v1/security/traps/files {path, kind}` creates a file the agent then watches (up to 20):

- `kind: "env"`: a fake `.env` backup with a made-up database URL (using the **first decoy database user** if there is
  one, otherwise `app_backup`), a made-up AWS key pair, and a **decoy token** created for this file. `kind: "sshkey"`:
  a freshly generated private key that opens nothing.
- It is created with mode `0600`, **never overwrites** an existing file (`agent.security.trapExists`) and must lie
  **inside `allowedRoots`**. The limit of 20 files and 20 decoy tokens is checked **before** anything is written
  (`agent.security.tooManyTraps`), so a refused request leaves no stray file or token behind.
- **How reads are detected.** Node can't watch for reads, so the agent uses the **access time**: it sets the file's
  atime one minute before its mtime ("armed"). With the default `relatime` mount option the kernel updates the atime on
  the first read after that. Every **30 seconds** the agent looks at the atime; if it moved, the alarm goes off and the
  file is armed again. Several reads inside 30 seconds make one alarm. After an agent restart the file is armed again, so
  reads while the agent was down are not seen.
- **`noatime` mounts can't work.** The agent reads `/proc/mounts` when it arms the file; on a `noatime` file system the
  trap's status is `noatime` ("ineffective") and nothing will ever trigger it. Move the decoy to another file system.
- **Backup tools, indexers, antivirus and recursive searches read files too** and will trigger the trap. Put the
  decoy where such tools don't go, or exclude it, or accept the alarm as noise to look at.
- If the file is missing the alarm `fileMissing` goes off **once** (also when the agent starts and finds it already
  gone), then stays quiet until the file is back. A file that comes back (restored from a backup, say) is armed again
  **without an alarm**. Removing a trap in the app (`DELETE`) only stops
  the watching; the file stays on disk, delete it yourself. Don't commit a decoy: the secret scan will flag it.

**Decoy files on SSH-audited hosts (auditd).** For a host without an agent, where the agent can't `stat` anything:
a read watch of the Linux audit system on a decoy file. This changes the audited host, so it is a separate, explicit
step with the installer (needs admin login with `sudo` and `auditd` installed on that host):

```bash
tools/install-audit.sh --trap admin@orion.my-tailnet.ts.net /srv/backup/.env.bak decoy-content.txt [admin-key]
tools/install-audit.sh --untrap admin@orion.my-tailnet.ts.net /srv/backup/.env.bak [admin-key]   # rule and file
```

`--trap` writes the file you supply (root-owned, mode `0644`). It **refuses** when the path already exists or is a
symlink (the file is created with `O_EXCL`, never through a link), and when any existing directory on the way is a
symlink, is owned by a user other than root or the admin who runs the installer through `sudo`, or is writable by group
or others: otherwise another user who owns a directory on the path could swap in a symlink and make the root script
write somewhere else. Missing directories are created (mode `0755`); an existing directory **keeps its mode**. It
adds
`-w <path> -p r -k tiphys_trap` to `/etc/audit/rules.d/tiphys-trap.rules` and loads it at once. Then switch `traps` on
for that host (`PATCH /v1/security/hosts/orion {"traps": true}`). Every **30 seconds** the agent sends the `traps`
request through the restricted key; the script returns the recent `ausearch -k tiphys_trap --start recent` events as
CSV: **the last 10 minutes, the newest 500 if there are more**. An event is identified by its audit time and serial and
announced once, **including the first poll after an agent start** (an event from the last 10 minutes is news, not
history). **One alarm per host and poll**, however many events it found: it carries the newest event (who read it, user
ids; with which program; the object; the time) and a `count`, so a flood of reads is one notification, not a hundred.
The script needs root and `ausearch`. A host where that is missing answers `unavailable` (exit 3): the agent no longer
skips it silently, it records the state per host and shows it as `auditHosts[].status` (`ok`, `unavailable`, `error`,
or `pending` before the first poll) in `GET /v1/security/traps`, so a wrong setup is visible. Still test it by reading
the decoy yourself.

**Decoy database users.** `PUT /v1/security/traps/db-users {users}` (up to 10 names, `[a-z_][a-z0-9_]{2,62}`). The
users exist **nowhere**; they appear only in decoy files, so a login attempt with one means someone found and used a
decoy file. Nothing is installed on the database host: the agent asks **Loki** (setting `security.scanners.loki`)
every 2 minutes for log lines of any host that say a login failed (`password authentication failed`, `authentication
failed`, `role … does not exist`, `access denied`) **and** contain one of the names; the first query covers the last 10
minutes, and every query starts 2 minutes before the previous end (lines reach Loki late; a line already announced is
not announced again). Pick distinctive names (a line only has to *contain* the name), set the list **before** you create an `env`
decoy so that it uses the name, and make sure the database logs failed logins and reaches Loki.

**Test alarm.** `POST /v1/security/traps/test` sends a `security.trap` notice with `trap: "test"` through every channel
(push, the black box, Telegram) so you can see the whole path work.

## Alerts to the owner's Telegram

*Phase S-3.* A second channel for critical notices, for the day the phone app itself is the problem (lost, or taken
over). Set `security.alerts.telegramRecipient` to the id of a recipient of the [Telegram feature](telegram.md) on the
same agent (`PUT /v1/security/alerts {"telegramRecipient": "…"}`); the recipient must not have stopped the bot, and the
`telegram` feature needs its bot token. Push notifications are unchanged; this is extra.

The message is **a title only**: `🚨 Tiphys güvenlik · <host> · <title>`, with the host name of the agent. No path,
user, address or value is in it. The texts are in Turkish whatever the app language is. Which notices are sent:

| Notice | Title (Turkish) |
| --- | --- |
| `security.trap` | tuzak tetiklendi (the test alarm: deneme uyarısı) |
| `security.change` with `severity: critical` | beklenmeyen güvenlik değişikliği |
| `security.secretFound` | sır bulundu |
| `blackbox.broken` | kara kutu zinciri bozuk |
| `security.lockdown` | kilitleme yapıldı |

Everything else (`security.vulns`, `security.exposure`, `security.attack`, `security.unreachable`, a `warning`
change) stays push-only. Sending is best effort: if Telegram is unreachable or the recipient is missing, nothing
happens and nothing is retried. The nightly [black box anchor](#black-box) uses the same recipient.

## Black box

*Phase S-4. Setting `security.blackbox.mode`: `off` (default), `local`, `push`.*

An append-only record of **what was done through the agents**, chained with hashes so that a changed or deleted entry
is detectable. The question it answers after an incident: *which device did what, and when*, on a record that is hard
to rewrite quietly.

**Format.** `blackbox/chain.jsonl` next to `agent.json` (directory `0700`, file `0600`, opened append-only). Next to
it, `blackbox/head.json` holds the last written head (`{count, hash}`), see Verification. One JSON line per record:

```json
{"seq":1,"at":"2026-11-19T02:15:00.000Z","source":"atlas","kind":"audit","data":{…},"prev":"<64 hex>","hash":"<64 hex>"}
```

`hash = SHA-256(prev + "\n" + JSON.stringify({seq, at, source, kind, data}))`, the first `prev` being 64 zeros. `kind`
is `audit` (an entry of the agent's audit log: every non-`GET` request with the device, method, path, status and the
route's detail), `event` (a notice the agent sent, `{key, params}`; sensitive ones such as clipboard text are left out)
or `lockdown`. Data is bounded: strings of 500 characters, 50 list items, 30 keys, depth 3, 4000 characters in all
(`{"truncated": true}` otherwise). `GET` requests, request bodies and secrets are not in it. **Requests that never authenticated**
(a response of 401, 403 or 429 with no device) are not recorded either: anyone who can reach the port could make those,
and they would let a stranger fill the chain. The chain is never rotated or pruned, but it has a **size limit of
1 GiB**: at that size nothing more is appended, the agent sends `blackbox.broken` once with reason `full`, and `append`
answers `507 agent.blackbox.full`. Records must never fill the disk, and the agent never deletes the chain for you: moving it
away is a manual step (and `head.json` and the anchors then no longer fit, so keep them together with it).

**Modes.**

- **`local`**: this agent keeps the chain. This is the monitoring server (`atlas`). It also **accepts records from other
  agents** (`POST /v1/blackbox/append`) from a service token with the **`blackbox`** scope, at most 10 requests a
  minute per token and 200 records per request. The **`source` of a pushed record is `service:<name of the token that
  authenticated>`**, whatever the sender claims; the sender's own timestamp is kept as `data.sentAt`, `at` is the time
  of receipt.
- **`push`**: for another agent (the PC, `argo`). Its records go into a **persistent queue**
  (`blackbox-queue.jsonl`, `0600`) and are sent to the `url` of the monitoring server with a `blackbox` token every 30
  seconds, 200 at a time (20 s timeout, no redirects). While the server is unreachable nothing is lost, up to
  **10 000 queued records**: beyond that the oldest are dropped and their number is reported to the server with the
  next batch, which records a `blackbox.dropped` event. After a successful send the queue loses exactly the records that
  were sent, even if the front of the queue was trimmed meanwhile.
- **`off`**: nothing is recorded.

The mode is read when the agent **starts**: `PUT /v1/blackbox/settings` stores it and answers `restartRequired: true`
when it differs from the running one, so restart the agent. The push token is kept only while the URL stays the same.

**Verification.** `GET /v1/blackbox/verify` (and an hourly automatic check) walks the chain up to the head it had when
the call started (records appended meanwhile don't count) and checks every record's sequence number, its `prev` link
and its hash. A failure reports the first bad `seq` and a reason: `sequence`, `link`, `hash`, `truncated` (the chain
is shorter than what this agent has written) or `anchor` (an anchor disagrees, see below). The first failure sends
`blackbox.broken` (once, until the chain verifies again); the same notice with reason `full` is sent when the size
limit is reached. A verification can't tell that someone **recomputed the hashes of the whole file**: that is what
anchors are for.

- **Torn lines.** A crash in the middle of a write can leave an incomplete last line. The agent closes it with a newline
  when it starts, so later records begin clean, and verification **skips** a line that holds no record and counts it
  (`torn` in the answer, shown in the app). Skipping can't hide a change: the next record's `prev` must still match the
  record before the torn line, so a deleted record still breaks the link. A torn line alone does not make the chain
  `ok: false`.
- **Cuts while the agent was stopped.** After every append the agent writes `head.json` (count and hash). When it
  starts and finds a chain **shorter** than `head.json` says, it marks the chain `truncated`, so a cut made while the
  agent was down is found after the restart too, not only one made while it ran. (An attacker who can also delete
  `head.json` can hide that; anchors exist for them.)

**Anchors.** Between 03:00 and 03:59 local time, once a day and only if the chain verifies, the agent sends the
chain's head (date, record count, first 16 hex characters of the hash) to the **owner's Telegram** and records it,
with the full hash, in `blackbox/anchors.jsonl`. Telegram is outside the monitoring server, so an attacker who
rewrites the chain there can't rewrite those messages. Verification checks the anchors on file against the **whole
chain**, wherever the record sits: an anchor whose record has a different hash is listed in `anchorMismatch` (by
date), and an anchor for a count **past the end** of the chain means the chain was cut: it is a mismatch too and the
result is `ok: false` with reason `anchor`. Compare the last Telegram message with the `count` the app shows now: a
chain with **fewer** records than an anchor says has been cut. Remaining limit: anchors are only as good as
`anchors.jsonl`; someone who can edit that file as well as the chain can remove the anchors there (the Telegram
messages remain). `POST /v1/blackbox/anchor` makes today's anchor now (it does nothing if there already is one).

**`chattr +a` (optional, root, not enabled by default).** The agent only appends, but it runs as an ordinary user, and
so does anything that takes over that account. With the append-only attribute even that user can no longer truncate or
rewrite the file. It is a root step on the monitoring server that Tiphys doesn't do for you (start the agent in
`local` mode once so the file exists):

```bash
sudo chattr +a ~/.config/tiphys/blackbox/chain.jsonl
lsattr ~/.config/tiphys/blackbox/chain.jsonl     # shows the "a" flag
# to undo (for example to move the chain): sudo chattr -a …
```

Caveats: it needs a file system that supports the attribute (ext4, xfs, btrfs…); the file can then never be deleted
or replaced without root, which also blocks housekeeping you might want (the chain isn't rotated, so it only grows);
it does nothing against root itself. Apply it to `anchors.jsonl` too if you like.

## Lost phone

*Phase S-4.* If the phone is lost, the app that could lock everything is the lost thing. The **recovery code** is a
credential you keep elsewhere (a password manager, a printout) that locks everything from any device in the tailnet.

- **Create it** in the app (or `POST /v1/security/recovery {"confirm": true}`). The response shows the code **once**:
  five groups of five characters, `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`, from an alphabet without look-alikes (no `0`, `1`, `I`,
  `O`), about 125 bits. Case and the dashes are ignored when it is entered. Only a **scrypt hash** is stored
  (`N = 2^15`, `r = 8`, `p = 1`, a random 16-byte salt) in `agent.json`. The plan was Argon2; scrypt is what Node
  ships, so no native module is needed. Creating a new code replaces the old one. `GET /v1/security/recovery` says only
  whether one exists and when it was created.
- **Use it.** `POST /v1/security/lockdown {"code": "…"}` needs **no token**, because the phone's token is gone. The
  Tailscale identity check **still applies**: when `requireTailscaleLogin` is set, the request must come through
  `tailscale serve` with that login (so only you, from your tailnet, can even try the code). From a terminal on any machine with the agent built:

  ```bash
  node dist/cli.js lockdown --url https://atlas.my-tailnet.ts.net
  ```

  The code is read from **standard input** (typed at the prompt), not from the command line, so it doesn't land in
  the shell history or the process list. Use the **monitoring server's** URL: it holds the code.
- **What it does.** On the server: the code is checked, then the server **fans out** to every agent in
  `security.lockdownTargets`, calling `POST /v1/security/lockdown/remote` with the **`lockdown`-scoped service token**
  that agent gave it (all in parallel, 15 s each; an unreachable agent doesn't stop the rest), revokes everything on
  itself, and **only then** sends the `security.lockdown` notice (push and Telegram). The order matters: the lost
  phone's push endpoint is deleted by the revoke, so a notice sent before it would go to the thief's pocket; sent after,
  it reaches the owner's Telegram, the channel that survives. The same order is used for `lockdown/remote`. *Revoke all* means the same as the app's *Lock everything*:
  **all paired devices, all service tokens and all push endpoints** are deleted, immediately (a device that is
  holding a connection is cut at its next request). The CLI prints which targets did not answer, so you can do *Lock
  everything* there by hand. Not touched: the Telegram bot and its recipients, trap tokens and files, the recovery code
  itself, features and settings, and the tokens this agent *uses* towards others (they die when the other side locks).
- **Protection against guessing.** The limits bound the scrypt cost and the log, and must not let one peer in the
  tailnet lock the owner out by spending a shared budget. In this order: **the code's shape is checked first** (25
  characters of the alphabet once case and dashes are ignored): a malformed or missing code is `401
  agent.security.badRecoveryCode` and **costs nothing** against any limit. A well-formed code then counts against
  **5 attempts per address per 10 minutes** and **30 an hour in total**, and only **one check runs at a time** (another
  arriving meanwhile gets `429 agent.security.rateLimited`); the counters reset when the agent restarts. A well-formed
  wrong code is `401 agent.security.badRecoveryCode` and is written to the black box with the caller's address. At
  about 125 bits guessing is out of the question.
- **Afterwards: pair again.** Nothing can reach the machines with the old tokens. On each machine run
  `tiphys-agent pair --name "Phone" --url https://…` and scan the QR code, then create the service tokens you need
  again (`security-report`, `blackbox`, `lockdown`, `research`) and enter them where they are used. Notifications
  need the phone's push endpoint registered again (pairing does that). Create a **new recovery code** if you think the
  old one was seen.
- **Targets.** Each audited agent that should be locked gets a `lockdown` token created on it
  (`tiphys-agent service-token create --name atlas-lockdown --scope lockdown`), which you add on the monitoring server
  (`POST /v1/security/lockdown/targets {id, name, url, token}`, up to 20, `https` only; the token is never returned).
  Any device token can also call `/v1/security/lockdown/remote` (it is how the app's lock works), so keep *Lock
  everything* in mind as the day-to-day tool and the recovery code as the emergency one.

## Outside view

*Phase S-5. Off until `security.exposure.enabled` is on and there are targets.*

The audit looks at a machine from the inside. The outside view asks the other question, "what can the internet
reach?", from the monitoring server, **gently** and only against targets you list (up to 30; checking something that
isn't yours is on you).

- **`ip` targets.** A TCP connect (3 s timeout, 8 at a time) to a **fixed list of 64 common ports** (21, 22, 23, 25,
  80, 443, 445, 3306, 3389, 5432, 6379, 9200, 27017, Docker's 2375/2376 and the ports of usual self-hosted web tools)
  plus your `extraPorts`. Each open port that is not in the target's
  `expectedPorts` is `exposure.openPort` (high). It is a connect scan, not a full port scan, and it reports what
  answers, not what runs. **A machine that probes its own public address may not see its cloud firewall** (traffic
  from itself doesn't take the same path, or the address is routed locally): point the check at the *other*
  machine's public address, not the one it runs on.
- **`domain` targets.** The monitoring server fetches, with a plain `tiphys-exposure-check` user agent, one second
  apart (15 s timeout each): the **TLS certificate** (`exposure.tlsExpiry` under 14 days, critical under 3; the
  certificate is read **without verifying it**, so an already expired or wrong one is read and reported, not mistaken
  for "unreachable"), whether
  `http://` answers with a success instead of redirecting (`exposure.noHttps`, medium), `https://` itself (not
  reachable: `exposure.unreachable`), and from its answer: the **security headers** HSTS (`exposure.noHsts`, low) and
  `X-Content-Type-Options`, `X-Frame-Options` or CSP `frame-ancestors`, and `Referrer-Policy` (`exposure.headers`, low,
  lists the missing ones). A domain that **redirects** (for example `www` to the bare domain) is **not judged for
  headers**: the redirect target is judged as a target of its own, so add it.
- **Leak paths.** Twelve well-known paths are requested (`/.env`, `/.git/HEAD`, `/.git/config`, `/.DS_Store`,
  `/server-status`, `/phpinfo.php`, `/actuator/env`, `/config.json`, `/service-account-key.json`, `/backup.zip`,
  `/wp-config.php.bak`, `/.aws/credentials`). A **single-page app answers every path with its index page**, so a `200`
  alone proves nothing: a path counts (`exposure.leakPath`, critical) only if the body looks like the thing (for
  `.env`, `KEY=value` lines and not HTML; for `/.git/HEAD`, `ref: refs/`; …). Only the first 64 KiB of the body is read
  (the rest is cancelled, so a real `/backup.zip` is not downloaded) and nothing of it is stored.
- **Schedule.** Every `intervalDays` (default 7), at night; *Run now* (`POST /v1/security/exposure/run`) works any
  time, also while `enabled` is off. The last 12 runs are kept (`security-exposure.json`).
- **Notification** `security.exposure` (priority high): after the **first** run only critical findings and expiring
  certificates (`exposure.tlsExpiry`) are announced (so a first look doesn't flood you); later, anything **new** that is
  an open port, a leaking path, an expiring certificate or critical.
  A finding that was already there last run is not announced again.

## Attack detection from Cloudflare

*Phase S-5. Needs a Cloudflare API token; without one nothing runs. **Not yet validated against the live Cloudflare
API**: it was built from the documentation and tested against recorded answers. Expect to check the first runs
(`lastRun.error`) and adjust.*

The plan was CrowdSec. It was dropped for two reasons found while checking the real setup: sites behind a **Cloudflare
Tunnel** don't have the client's address in their own logs (the application logs have none; `cloudflared` logs only the
Cloudflare edge address, and only for errors), so CrowdSec has nothing to decide on; and Cloudflare's official bouncer
needs a broad Workers token. Cloudflare's **GraphQL Analytics** does know the client address, so the agent asks there.

- **Tokens** (`PUT /v1/security/cloudflare`, never returned by the API, only `hasReadToken` / `hasBlockToken`):
  - **read token** with **Zone › Analytics › Read** and **Zone › Zone › Read**, restricted to your zones. Required.
  - **block token**, only if you want blocking: **Zone › Firewall Services › Edit**, nothing else. A separate token, so
    reading never has write rights.
  `zones` limits the watch to those zone names (empty: every zone the token can read, up to 50).
- **What runs.** Every 15 minutes (day and night) the agent asks, per zone, for the requests that got a 4xx or 5xx
  response in the last window, grouped by client address and path (up to 2000 groups). An address is an
  **offender** with **at least 3 requests to well-known scanner paths** (`/.env`, `/.git/…`, `/.aws/…`, WordPress and
  `xmlrpc.php`, phpMyAdmin, `/vendor/phpunit`, `/cgi-bin/`, router paths, `/actuator`, `/server-status`, any
  `*.php|asp|aspx|jsp`, service-account, config and credentials files, backup and dump archives), **or at least 30 error
  responses over at least 10 different paths**. Counts add up over runs; offenders are kept for 7 days after the last
  sighting.
- **Notification** `security.attack` (priority default, no incident: scanning is the ordinary noise of the internet):
  at most **once per address and zone per day**, naming the number of new offenders and the zones.
- **Blocking** (off by default: `block: true` needs a block token). The offender gets a **zone IP Access Rule** with
  action `block` and the note `tiphys:<expiry time>` for `blockHours` hours (default 24, 1 to 720). On every run the agent
  lists the rules whose note starts with `tiphys:` and **deletes those whose expiry passed**, so blocks are never
  forever and **a rule you made by hand is never touched** (only the exact note form is). An address already
  blocked isn't blocked again before it expires. The expiry clean-up is **per zone**: when a block of one zone
  expires, the same address stays marked as blocked in another zone where its rule is still running. A block that fails
  (a rule that already exists, say) is skipped and does not stop the run or the clean-up; only an invalid or
  unauthorized token ends it with `lastRun.error`.
- **Never blocked:** every address in `allowIps` (put your servers' own public addresses and your own there, for
  example `203.0.113.10`), and always private and internal ranges: `10/8`, `172.16/12`, `192.168/16`, `127/8`,
  `169.254/16`, `100.64/10` (Tailscale), IPv6 loopback, `fc00::/7`, `fe80::/10`, and anything that isn't an address.
  A mistaken block of your own address still happens if you scan your own site from outside, so use `allowIps`.

State: `security-attacks.json` (mode `0600`).

## Fixing findings with Claude

*Needs the `security` feature on the monitoring server and the `claude` and `securityFix` features on the agent that
runs Claude (default off), plus at least one fix target. See
[Security fix sessions](claude.md#security-fix-sessions) for what the session can do and
[Security](../security.md#claude-security-fix-sessions) for its guardrails and limits.*

You can pick findings and send them to a Claude session that connects to the machines over SSH and fixes them with
guarded tools. The audit stays what it was: read-only. Only the session you start changes anything, in the permission
mode you choose, and the audit then runs again to check the result.

### The flow

1. **Select.** On the machine screen (findings and baseline changes), the vulnerabilities, the secrets and the outside
   view, *Select* turns on a selection mode. Tick items or use *Select all*, then *Send to Claude*. At most 30 items
   at a time.
2. **Brief.** The app asks the monitoring server for a brief of the selected items (`POST /v1/security/brief`, see
   below). The sheet shows the items with their mode (*Fix* or *Investigate*), the machines they concern (name, role,
   *last audit ran without root*) and the **fix target** of each machine. A machine without a target is marked *Set
   target*; Claude only works on machines that have one. The sheet also shows the brief that will be sent, byte for
   byte.
3. **Session.** You choose the permission mode (*Plan first*, *Ask every time*, *Accept edits, ask for commands*,
   *Don't ask*), may add a note, and start. *Don't ask* needs a second confirmation. The app sends the brief, the
   machines and your note to the agent that runs Claude, which opens a session of the kind `security` and starts
   working at once. Your note is your own instruction and is treated as trusted; the brief is not.
4. **Work.** Claude reads, changes files with backups, asks the phone for approvals and for the sudo password when
   it needs root. The chat shows a *Security session* panel with the changed files, backups, rollback timers and a
   *Roll back* button per machine. Details in [Claude](claude.md#security-fix-sessions).
5. **Re-audit.** When Claude is done (a fix session; an investigation changes nothing and has no such card), a card
   under its result offers *Re-run audit*. It runs a normal (not full)
   check on every machine of the session through the monitoring server. A fix counts when the audit confirms it:
   the finding is gone from the machine's list.
6. **Accept.** *Open machine* leads to the machine screen. If the remaining baseline changes are the ones you
   wanted (for example a new sshd drop-in), use *Accept this state* as usual. Nothing accepts the baseline for you.

### What the brief contains

The brief is the boundary against prompt injection. Everything in a security report comes from machines that may be
compromised: a container name, a file name, a key comment or a log line can be written by an attacker. So the brief
carries **structured data only**:

- **A fixed English template per rule**, written in the agent's code: what the problem is, why it matters, what the
  expected state is, and where a fix usually goes (for example an sshd drop-in, the compose file, an nft rule). There
  is one for every finding rule, every baseline category and every outside-view rule, and one each for vulnerabilities
  and secrets.
- **Parameters** (`port=22; proto=tcp`) that pass a **per-rule allowlist**: only the keys listed for that rule
  are kept (unknown keys are dropped), and each value must match that key's pattern (a number, one of a few words, or a
  name made of `A-Z a-z 0-9 _ . : @ / + -` up to 120 characters). A value that does not match is replaced by
  `‹invalid:<first 8 hex of its sha256>›`, so it can be recognised but not read. Fields an attacker can influence
  (container, image and file names, key comments, log streams, change items) therefore cannot hold a space, and no
  sentence fits in them.
- **Redaction** as the last step over the whole text, with the same patterns the agent applies everywhere else.
- Which machines are involved (id, name, role, whether the last audit ran as root, source), a generation time, the
  language Claude should answer in (the app's language) and a line saying that everything below is data, never
  instructions.

It **never** contains raw report text, CVE titles or descriptions, log lines or secret values.

| Item | What the brief says |
| --- | --- |
| Finding | severity, rule, the allowlisted parameters, the template |
| Baseline change | severity (critical for an added or changed item in a critical category), category, kind (added, removed, changed), parameters taken from the item and the current report (user, fingerprint, key comment, sshd value, container flags, SUID mode and owner), the template |
| Vulnerability | CVE id, image digest and up to 5 image references, up to 20 affected packages with installed and fixed version, up to 10 machines with the containers that run it; the advice is a newer tag or digest, and "no fixed version" is reported as such |
| Secret | source (`github`, `loki`, `local`), rule, where, file, line, commit, stream, time and whether it was dismissed. **No value** |
| Outside view | severity, rule, target host name and the allowlisted parameters (port, path, days, missing headers) |

The brief is at most 120 KB. Items keep the order you selected them in, duplicates are dropped, and an item that does
not fit is left out with the per-item error `agent.security.briefTruncated` (the response says `truncated: true`; the
text then ends with a note on how many items were omitted).

The response also lists, for every requested item, its `ref` and either its `mode` or an error code. The `ref` in this
JSON is the raw identifier (`finding:atlas:ssh.passwordAuth`); the app keeps it to know which items the session
covered. The text of the brief shows each ref with every part checked and redacted, and the raw `ref` is **never put
into a prompt**. The `origin` the app stores with the session (the monitoring server's host id and the refs) is kept
and returned in the session summary, and is not shown to Claude either.

The endpoint takes device tokens only, allows 10 briefs per device per 10 minutes, and its audit record holds only the
number of items per type and the size in bytes, not their ids. See [API](../agent/api.md#security).

### Investigate items

Some items may be traces of an attack rather than a misconfiguration. They get the mode `investigate`:

| Kind | Items |
| --- | --- |
| Findings | `users.uid0`, `users.emptyPassword`, `ssh.emptyPasswords` |
| Baseline changes | categories `users`, `passwords`, `sudoers`, `authKeys`, `cron`, `autostart`, `timers` |

If **any** selected item is `investigate`, the whole session is an investigation: it can only run in *Plan first* mode,
the app offers no other mode, and the agent refuses to start it or to switch it to another one
(`agent.claude.securityInvestigateReadOnly`). Claude only reads: it does not delete users, keys, cron entries or logs,
so evidence is kept, and it reports what it finds. Even a read that needs root asks you first. The brief carries the note *INVESTIGATE ONLY* for those items, and
the sudo password dialog warns that the machine may be compromised (do not type a password you use elsewhere). Fix the
other items in a separate session afterwards.

### Secrets

For a secret finding Claude gets the place (repository, file, line, commit) and no value. It is told to take the file
out of the working tree or the repository, add it to `.gitignore` or stop the program logging it, and **not** to read or
print the value. **Rotating or revoking the credential is your job**: Claude says so and never tries it. Rewriting git
history needs your explicit approval. The tools also mask secret files in everything they return, see
[Security](../security.md#claude-security-fix-sessions).

Findings the audit cannot judge are left alone as well: for a port that may be expected, Claude is told to change
nothing and to tell you to mark it as expected in the audit settings.

## Schedules and limits

- A timer ticks every minute (first tick 30 seconds after the agent starts). A machine is checked when
  `security.intervalMinutes` (default 15, 5 to 1440) has passed since its last attempt, **one machine at a time**.
  A failed attempt also counts as an attempt.
- The first check of a machine, and then one **full report** per day (24 hours), include the SUID scan
  (`find / -xdev`, 120 s limit) and the world-writable scan. Ordinary reports skip both; the last SUID and
  world-writable lists are carried over (for the baseline, the finding and the report details) until the next full report. *Full check* in the app forces a full report.
- Time limits: 90 s for an ordinary report, 5 minutes for a full one (SSH and agent pulls get 20 s more). A report
  larger than 2 MiB is rejected. Anything read from another machine (an agent's answer, a Loki, GitHub or Cloudflare
  response) is read with a size cap while it streams in, not after it has all been loaded.
- A machine is marked **stale** when it has had no successful report for more than 3 intervals; the app then shows
  the last known state with its age.
- At most 20 additional machines. Their ids (`[a-z0-9-]`, up to 63 characters) must not be one the app uses as a
  screen name: `self`, `settings`, `vulns`, `secrets`, `scanners`, `traps`, `exposure`, `attacks`, `cloudflare`,
  `blackbox`, `recovery` and `lockdown` are reserved (`409 agent.security.hostExists`). *Check now* is limited to 6 per 10 minutes per device.
- One check per machine runs at a time; a second request joins the running one.
- State is kept in `security-state.json` next to `agent.json` (mode `0600`, written atomically; a failed write does
  not block the next one). `agent.json` itself is saved the same way: saves are serialized and each uses its own
  temporary file, so two changes at once (a service token's last-used time and a revoke-all, say) no longer fail. A corrupt file is
  set aside as `security-state.json.corrupt-<time>` and the next report starts a new baseline without notification.
- **Timers of the later phases** (all start with the agent and need `security` on): scanners and the outside view check
  every 10 minutes whether it is night (default 02:00 to 06:00 local, `security.scanners.nightHours`): vulnerability
  scan of due images, secret scan when the last run is over 20 hours old, outside view when due (default weekly).
  Traps: decoy files and SSH audit events every 30 seconds, decoy database users every 2 minutes. Cloudflare attack
  detection every 15 minutes. Black box: push queue every 30 seconds, verification every hour, anchor at 03:xx.
- **Rate limits.** *Scan now* of images, secrets, the outside view and the attack run share one limit of 3 per 10
  minutes per device (`agent.security.rateLimited`); `blackbox` appends 10 a minute per token; the recovery-code
  lockdown 5 per address per 10 minutes and 30 an hour in total, one check at a time.
- **Heavy work stays on the monitoring server and at night:** the scanners run Docker containers of up to 2 GB
  of memory (Trivy) or 1 GB (gitleaks) on `atlas`, one scan at a time. Saving an image from an SSH-audited host loads
  *that* host's Docker daemon, which is why it is limited to 2 a night, 3 GB each.
- **Files** (all `0600`, next to `agent.json`): `security-vulns.json`, `security-secrets.json`,
  `security-exposure.json`, `security-attacks.json`, `blackbox/chain.jsonl`, `blackbox/anchors.jsonl` (directory
  `0700`) and `blackbox-queue.jsonl`. See [configuration](../agent/configuration.md#files-on-disk).

## Limits of the evaluation

- **The firewall evaluation is conservative.** From the `nft` ruleset it asks one question for each wildcard or public
  listener: would a *new* connection from an arbitrary internet address, arriving on an external interface, be
  accepted by every `input` hook chain? Interfaces such as `lo`, `tailscale*`, `docker*`, `br-*`, `veth*`, `virbr*`,
  `cni*`, `flannel*`, `cali*` and `wg*` don't count as external. Rules limited to certain source addresses don't match
  "anyone". Where a rule contains something the evaluator doesn't understand, it assumes the worst: an accepting rule
  matches (the port counts as `open`), a dropping rule doesn't. iptables-nft rules (conntrack, `REJECT`) are
  understood for the usual patterns. `defaultDeny` means an arbitrary high port is filtered on IPv4. In detail: a
  `return` ends the chain it is in and the caller carries on with its next rule; `fib` conditions are "unknown"; a
  `vmap` (for example `iifname vmap { eth0 : jump inbound }`) counts as open if **any** of its branches accepts, because
  the evaluator doesn't know which key a probe hits; `saddr != X` matches "anyone" while `saddr X` doesn't; a
  `tcp dport` test never matches a UDP probe (and the other way round), whatever the operator. Each probe has an
  evaluation budget of 10 000 rule and chain steps: a crafted ruleset (many jumps, deep nesting) must not freeze the
  agent, and one that exceeds the budget is treated as open, the conservative answer. An IPv4-mapped IPv6 address
  (`::ffff:127.0.0.1`) is judged as the IPv4 address it wraps.
- **Docker-published ports bypass `INPUT`.** Docker rewrites the destination before the input chains, so the
  evaluation doesn't judge them. A port published on all interfaces or a public address counts as exposed (unless
  you list it in the expected ports); published on loopback, a private or a Tailscale address it doesn't.
- **IPv6 is judged only on a machine with a global IPv6 address** (outside Tailscale and container interfaces). A
  wildcard IPv6 socket usually accepts IPv4 too, so it is judged for IPv4 either way.
- Without root there is no ruleset; see [Root and rootless](#root-and-rootless).
- The audit is a checklist of common weaknesses, not a vulnerability scanner or an intrusion detector. A clean score
  doesn't mean a machine is safe.
- **The scans have blind spots, too.** Trivy knows only published vulnerabilities (and no Java archives unless the Java
  DB is on); gitleaks and the local patterns find well-known formats, not every secret; the outside view tests a
  fixed list of ports and paths from one place; Cloudflare detection sees only traffic that goes through Cloudflare.
  None of them finds a quiet intruder: traps and the black box exist for that, and they only help if something
  touches them. See [Security](../security.md#security-center-scanners-traps-black-box-and-lockdown).

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

*Select* on the machine, vulnerability, secret and outside-view screens starts
[Fixing findings with Claude](#fixing-findings-with-claude). The app is gaining screens for S-2 to S-5 (vulnerabilities, secrets, traps, black box, recovery code, outside view,
attacks); this page and the [API reference](../agent/api.md#security) describe the agent behaviour they use, and the
endpoints can always be called directly with a device token. The notification links (`tiphys://security/vulns/…`,
`…/secrets`, `…/traps`, `…/exposure`, `…/attacks` and `…/blackbox`) point at those screens.

## Setup

See [Security center](../setup-guide.md#security-center) in the setup guide: enabling the feature, root-level audit
of the monitoring server itself, an SSH-only host, another agent, and (parts d to h) the scanners, traps, black box and
lockdown, the outside view and Cloudflare attack detection.
