# Troubleshooting

Start with these three checks. They answer most questions:

```sh
systemctl --user status tiphys-agent           # is it running?
journalctl --user -u tiphys-agent -n 100       # what did it log?
curl -s https://argo.my-tailnet.ts.net:7443/v1/health   # name, version, enabled features (no token needed)
```

The agent reports errors as codes (`agent.<area>.<reason>`), and the app shows the translated text. The full code
list is in [agent/api.md](agent/api.md). Below are the problems that come up in practice.

## Connection

### "Agent unreachable (is the PC on and Tailscale connected?)"

- Is Tailscale connected on the phone **and** the machine (`tailscale status`)?
- Run `tiphys-agent doctor` on the machine: it checks Tailscale, `tailscale serve`, the agent, the settings file and
  the tools of enabled features, and prints a fix for each problem.
- Is the agent running and listening on `127.0.0.1:7443`? Check with `curl -s http://127.0.0.1:7443/v1/health` on
  the machine.
- Is it published? Check with `tailscale serve status`. If nothing is listed, run
  `tailscale serve --bg --https=7443 http://127.0.0.1:7443` (with `sudo` unless your user is the Tailscale operator).
- Does the host's agent address in the app use the full MagicDNS name and port, e.g.
  `https://argo.my-tailnet.ts.net:7443`?

### "Secure connection failed"

- The app accepts only HTTPS with a valid certificate. Enable **HTTPS certificates** and **MagicDNS** in the Tailscale
  admin console, and use the `*.ts.net` name, not the `100.x.y.z` IP address. The certificate is not valid for the IP.
- `http://` agent addresses do not work on Android (cleartext is blocked).
- Older agents put `http://127.0.0.1:7443` into the QR when paired without `--url`. Pair again (current agents take
  the address from Tailscale), or fix the address in *Settings › Hosts*.

### "The agent rejected this phone; pair again" (`agent.auth.invalidToken`, `agent.auth.missingToken`)

The token is unknown to the agent. It may have been revoked, the agent may use a different `agent.json`, or *Lock
everything* was used. Pair again. The running agent accepts a newly paired device at once; `pair` says so. If it
says the agent did not confirm the device (an agent from before this change), restart it once:
`systemctl --user restart tiphys-agent`.

### "This Tailscale account is not allowed on the agent" (`agent.auth.tailnetUserNotAllowed`)

`requireTailscaleLogin` is set and the request came from another Tailscale user, or from a tagged device that has
no user login. Check the login with `tailscale status` on the phone, or change the setting with
`node dist/cli.js init --tailscale-login you@example.com`.

### "This feature is turned off on the agent" / `agent.route.notFound`

The feature flag is off, or it was changed without restarting the agent. Enable it under *Agent settings ›
Features* or with `init --features …`, then run `systemctl --user restart tiphys-agent`.

### The app warns that the agent is outdated

The app expects the agent version from the same commit. Rebuild and restart the agent (`npm ci && npm run build`),
or re-run `tools/deploy-agent.sh` for servers.

### The agent restarted unexpectedly

You get an "agent restarted" notification after an unclean stop. The usual cause is memory: each Claude process
uses roughly 500 MB. The unit file from [setup guide](setup-guide.md#run-it-as-a-systemd-user-service) sets no
memory limit and `OOMPolicy=continue`. With a `MemoryMax=` limit or `OOMPolicy=stop`, the first Claude session can
take the whole agent down. Claude sessions come back idle after a restart.

## Notifications

### Push notifications do not arrive, or arrive late

- *Settings › Notifications* must show "Notifications are on" and list the agents it registered with. Use *Send a
  test notification*.
- The **ntfy app** must use your server as its default server and be signed in. Tiphys has no notification
  connection of its own: ntfy is the UnifiedPush distributor.
- Exempt **ntfy** (and Tiphys) from battery optimisation. On Xiaomi/Redmi/POCO phones also set ntfy's battery saver
  to "No restrictions" and allow autostart. Other vendors (Samsung "sleeping apps", Huawei, OnePlus) have similar
  settings.
- If your ntfy server needs authentication to publish, set `push.token` in each agent's `agent.json` and restart.
  The agent logs `notification endpoint … response 401/403` otherwise.
- Re-pairing or a new ntfy installation changes the endpoint. Turn notifications off and on again in Tiphys so every
  agent gets the new one.
- Uptime Kuma site alerts do not go through Tiphys. Subscribe to their ntfy topic in the ntfy app.

### The PC clipboard notification never shows up

Clipboard sync needs the `desktop` feature, `desktop.clipboardSync` (on by default), `wl-paste` on the PC, and an
encrypted push registration. The clipboard is sensitive, so it is never sent to endpoints without WebPush keys.
Content marked by a password manager is skipped on purpose.

## Desktop control

### "Hyprland not found" (`agent.desktop.noHyprland`) or "no display" (`agent.desktop.noDisplay`)

The agent looks for the Hyprland instance and the Wayland socket under `$XDG_RUNTIME_DIR`. It must run as the same
user as your graphical session, as a **user** service, not a system service. If you log out, desktop features stop
until you log in again.

### Control session will not open (`agent.control.indicatorFailed`, `agent.desktop.hyprctlFailed`)

The session is refused when the PC indicator (notification + border colour) cannot be set.

- Check that `hyprctl` works for your user and that `notify-send` exists (libnotify).
- **Lua config (Hyprland 0.55+, `hyprland.lua`):** classic `hyprctl keyword`/`dispatch` commands do not work there.
  The agent detects the mode once per Hyprland instance with `hyprctl eval 'return 1'` and then uses
  `hl.dispatch(...)` and `hl.config(...)`. If you switched config style without restarting Hyprland, restart the
  agent so it detects the mode again.
- `agent.control.disabled`: the `control` flag is off. `agent.control.busy`: another device holds the session. Stop
  it from any paired device, or wait for it to expire.

### Live screen is slow ("Slow mode: wf-recorder is not installed")

Without `wf-recorder` the agent falls back to a `grim` loop at no more than 4 fps. Install `wf-recorder`. It needs
a compositor with wlr-screencopy, which Hyprland has.

### Live screen is black, or H.264 falls back to JPEG (`agent.desktop.codecFallback`)

- H.264 uses NVIDIA NVENC through `wf-recorder -c h264_nvenc`. On non-NVIDIA GPUs, or if `ffmpeg`/`wf-recorder` lack
  NVENC support, the agent falls back to MJPEG automatically. Select *Codec: JPEG* to stop it trying.
- Test outside Tiphys with `wf-recorder -c h264_nvenc -f /tmp/t.mp4` (Ctrl+C after a few seconds).
- A black picture in **Moonlight** usually means Sunshine's capture method. Try `capture = kms` instead of `wlr` in
  `~/.config/sunshine/sunshine.conf` (KMS capture needs `cap_sys_admin` on the Sunshine binary, which its package
  normally sets).
- The phone needs a hardware `video/avc` decoder for automatic H.264. The Claude chat preview strip always uses JPEG.

### Clicks or keys do nothing (`agent.desktop.inputFailed`)

Pointer and keys go through `ydotool`, which needs the `ydotoold` daemon and access to its socket. The agent uses
`$YDOTOOL_SOCKET` or `$XDG_RUNTIME_DIR/.ydotool_socket`. Text goes through `wtype`. Remote key combinations use a US
layout table, so some shortcuts may not match on other layouts. Add your own buttons under *Settings › App controls*.

### Sunshine / Moonlight

- `agent.sunshine.noCredentials` / `unauthorized`: enter or fix Sunshine's web UI user name and password under
  *Agent settings › Sunshine*.
- `agent.sunshine.setupRequired`: open Sunshine's web UI once, or run `sunshine --creds USER PASSWORD`.
- `agent.sunshine.noPendingPairing`: tap the PC in Moonlight first, so it shows the PIN, then enter the PIN in Tiphys.
- `agent.sunshine.certMismatch`: the configured URL serves a different certificate than Sunshine's own. Use the
  default `https://127.0.0.1:47990`.

## Firefox bridge

### "Not connected" (`agent.browser.notConnected`)

1. `desktop` is enabled and the agent was restarted after `node dist/cli.js firefox install`. The bridge socket
   is created at start-up.
2. `~/.mozilla/native-messaging-hosts/dev.tiphys.bridge.json` exists and points to `~/.local/share/tiphys/firefox-host`.
   Re-run `firefox install` after moving the checkout or changing the Node.js installation, because the launcher
   stores absolute paths.
3. The extension is installed and enabled in `about:addons`. If installation failed with "could not be verified",
   `xpinstall.signatures.required` is still `true`, or you are on release Firefox, which ignores that preference.
   Use ESR, Developer Edition or Nightly.
4. Only one Firefox instance can be connected at a time. A second one is told the bridge is busy.
5. The extension popup shows the connection state. After a failure it retries with growing intervals, from 5 s up
   to 10 min, and immediately when the agent sends a request.

`firefox install` prints "no add-on XPI" when `firefox/dist/` has no built XPI. Run `cd firefox && npm ci && npm run
build`. Servers deployed with `deploy-agent.sh` do not get the XPI. The bridge is meant for the PC agent running
from a checkout.

### Reader view or page controls do not work

- `agent.browser.permissionRequired`: grant page access from the extension icon.
- `agent.browser.passwordField`: the page has a focused or filled password field. Reading is refused on purpose.
- `agent.browser.unsupported`: `about:` pages, `view-source:`, add-on pages and other privileged pages cannot be read.
- `agent.browser.noArticle`: Readability found no article on the page.

## Mobile view

### "This app doesn't share its controls" (`agent.ui.unsupported`)

The window exposes no usable accessibility tree, or it could not be matched:

- Apps without AT-SPI support (kitty, Steam, Blender and others) are not supported. Use the live screen and the
  remote strip.
- **VS Code (flatpak):** run `node dist/cli.js vscode-a11y install` and restart VS Code.
- **Qt apps** may need `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` in their environment.
- Two windows of the same app with the **same title** cannot be told apart. Private-browsing Firefox windows are
  refused on purpose.
- The window must be visible on the active workspace.

### "Accessibility helper missing" (`agent.ui.helperMissing`)

Install `python3-gi` and `gir1.2-atspi-2.0` (Debian/Ubuntu package names). The helper runs with the system
`python3`.

### `agent.ui.stale`, `agent.ui.timeout`, "partial"

The window changed between snapshot and action. The app refreshes automatically. Very large trees, such as GTK4 file
managers, are cut off after 1500 nodes or 1.5 s and marked partial. Use the search field.

## Claude

### Claude sessions fail to start

- `agent.route.notFound` on `/v1/claude/…`: the `claude` feature is off.
- The Claude Code binary is missing: the SDK installs it as an **optional** npm dependency
  (`@anthropic-ai/claude-agent-sdk-<platform>`). Agents deployed with `tools/deploy-agent.sh` use `--omit=optional`
  and therefore cannot run Claude. Run the PC agent from a checkout with a full `npm ci`.
- Not logged in: run `claude` once in a terminal on that machine as the same user and log in. For extra profiles, log
  in with `CLAUDE_CONFIG_DIR` set to that profile's folder. `agent.claude.unknownProfile` means the profile name is not
  in `claude.profiles`.
- `agent.claude.folderNotAllowed`: the folder is outside `allowedRoots`.
- `agent.claude.worktreeFailed` / `notGitRepo`: worktree sessions need the folder to be inside a git repository.

### Terminal session cannot be taken over

`agent.claude.terminalBusy`: Claude is working in that terminal. Wait until it is idle. `terminalStuck`: the terminal
process did not exit. Close it by hand. To go back to the PC later: `claude --resume <session-id>`.

### "Use the PC" is missing or fails (`agent.claude.pcUnavailable`)

PC sessions need `claude`, `desktop` and `control`, an app lock, and an open control session. When the control
session ends, Claude stops and the chat offers to re-open control.

### Scheduled task did not run

Schedules use the agent's local time zone. Runs missed while the agent was off are **not** made up. A run is skipped
if the previous run of the same task is still going (`claude.scheduleSkipped` event).

## Other

- **Port sharing fails (`agent.ports.shareFailed`):** the agent runs `tailscale serve` as your user. Run
  `sudo tailscale set --operator=$USER` once.
- **Services: "Not permitted (system services need root)":** the agent runs as your user. Actions on system units
  fail unless polkit allows them. User units work.
- **Wake-on-LAN does nothing:** the magic packet is a LAN broadcast. Send it from the phone on the same Wi-Fi, or
  enable `wake` on an always-on agent in the same LAN, and enable WoL in the target's BIOS/NIC.
- **Voice messages fail (`agent.transcribe.failed`):** the configured `transcribe.command` must accept
  `FILE -m MODEL [-l LANG]` and print the text to stdout.
- **Terminal falls back to a plain shell:** install `tmux` on the host. Without it, sessions do not survive
  reconnects.
- **APK build kills the desktop:** build through `tools/limited.sh` (see [setup guide](setup-guide.md#build)).
- **Release APK will not install over the existing app:** it was signed with a different key (for example the
  debug key because `key.properties` was missing). Restore your release key, or uninstall first. Uninstalling loses
  on-device secrets, so export an encrypted profile beforehand.
