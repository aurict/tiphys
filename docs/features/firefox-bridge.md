# Firefox bridge

The Tiphys Bridge is a Firefox extension that lets the phone see and manage the tabs open on your PC (`argo`):
list, switch, close, pin, mute, reload, reopen the last closed tab, open a link from the phone in a new tab, and,
with an extra opt-in permission, read a page in reader view, control the video or audio on it, scroll it and type
into the focused text field.

The extension makes no network requests. It talks only to a small native-messaging helper that Firefox starts
locally, and the helper relays messages to the Tiphys agent over a Unix socket.

```
phone ──HTTPS over Tailscale──> agent ──Unix socket──> native helper ──stdio──> Firefox extension
```

For the protocol and endpoint details see [the agent API reference](../agent/api.md).

## Requirements

- The agent on the PC with the **`desktop`** feature on. The bridge socket is opened only when `desktop` is on at
  agent start (`$XDG_RUNTIME_DIR/tiphys/firefox.sock`).
- The **`control`** feature (Remote control) on, and an active control session in the app, for everything except
  the connection status. The tab list counts as browsing history, so it is gated the same way as window control. See
  [Desktop control](desktop-control.md).
- Firefox **140 or later** (`strict_min_version` in the manifest). The extension is unsigned, so the Firefox build
  must allow unsigned add-ons; see [Install](#install).
- A built agent (`cd agent && npm run build`, which produces `agent/dist/firefox_host.js`) and a built XPI (see
  below).
- Optional: on Hyprland, switching to a tab also focuses the Firefox window. On other desktops the tab is still
  activated, but the window is not raised.

Feature flags and their config are described in [Agent configuration](../agent/configuration.md).

## Install

1. Build the extension (once, and after updates):

   ```sh
   cd firefox
   npm install
   npm run vendor   # copies Mozilla Readability into src/vendor and checks its pinned SHA-256
   npm run build    # writes firefox/dist/tiphys-bridge-<version>.xpi
   ```

2. Register the native-messaging helper on the PC:

   ```sh
   tiphys-agent firefox install
   ```

   This writes:
   - a launcher script at `$XDG_DATA_HOME/tiphys/firefox-host` (default `~/.local/share/tiphys/firefox-host`) that
     runs the current Node binary with `agent/dist/firefox_host.js`;
   - the native-messaging manifest `~/.mozilla/native-messaging-hosts/dev.tiphys.bridge.json`, which allows only the
     extension ID `bridge@tiphys.dev`.

   It prints the path of the newest XPI in `firefox/dist/`. It does not touch your Firefox profile.

3. Allow unsigned add-ons: open `about:config` and set `xpinstall.signatures.required` to `false`.
   The command output targets Firefox 140 ESR. Standard release and beta builds of Firefox ignore this preference;
   use ESR, Developer Edition, Nightly or an unbranded build.

4. Install the XPI: `about:addons` › gear icon › **Install Add-on From File…** › pick the XPI printed in step 2.

5. Optional: grant the page content permission (see [Permissions](#permissions)).

The same steps are shown in the app when the bridge is not connected (**Browser** row › *Firefox bridge not
connected*).

> Turning off signature checks lets Firefox install any unsigned add-on. Only install add-ons you trust.

### Checking the connection

Click the Tiphys Bridge icon in the Firefox toolbar (also available as the add-on's Options page). The popup shows
three states: the local helper (running / missing: run `tiphys-agent firefox install`), the Tiphys agent
(connected / not connected), and the page content permission.

If the agent is not running, the helper retries every 5 seconds. If the helper itself is missing or crashes, the
extension retries with a growing delay (5 s up to 60 s).

Only one Firefox can be connected to an agent at a time. A second Firefox instance (or an old copy of the
extension) is refused with `busy` and retries with a growing delay (up to 10 minutes), so two instances never knock
each other off. A protocol version mismatch is refused the same way.

## Permissions

Always requested (shown at install): `tabs`, `sessions` (reopen closed tab) and `nativeMessaging`.

Optional, granted from the toolbar popup only by a click: **page content** (`scripting` plus access to all sites).
The popup button is labelled "Sayfa içeriği iznini ver" (grant page content permission), and the same popup can
revoke it. Page content is needed for reader view, media control, scrolling and sending text. Without it those
actions return `permissionRequired` and the app shows *Page content permission needed*.

When granted, the page script is injected into a tab only at the moment you use one of those actions; nothing runs
in the background on your pages.

## Using it in the app

Open the PC host's **Desktop** screen › **Tools** › **Browser** (subtitle *Firefox connected · tabs, reader view*
or *Firefox bridge not set up · setup steps*). The tab list is also reachable from the live screen's remote strip.

### Tabs

The **Tabs** page is live (Server-Sent Events; changes in Firefox appear within about 300 ms). Tabs are grouped by
window, the active tab is highlighted, and badges show *pinned*, *muted* and *playing sound*. You can search tabs.

- **Tap** a tab: switch to it on the PC (*Switch to this tab*).
- **Swipe**: close it, with an undo.
- **Long-press**: multi-select, then **Close tabs** (with confirmation; up to 200 at once).
- **New tab**: open an http(s) URL in a new tab on the PC.
- **Reopen closed tab**: restores the most recently closed tab or window.
- **Tab actions** sheet: *Open on phone*, reload, back/forward, *Pin*/*Unpin*, *Mute*/*Unmute*,
  *Reader view*, *Page controls*.

*Open on phone* opens the tab's address in the phone's browser (http/https only). It is handled entirely in the
app; the extension does not push tabs to the phone.

### Open on PC

**Open on PC** (from the share menu, the phone clipboard or a home shortcut) sends a link to the agent. If the
bridge is connected, it opens in a new Firefox tab and the window is focused; otherwise the agent falls back to the
desktop's default opener (`xdg-open`). If the extension does not answer in time, the agent reports an error instead
of falling back, to avoid opening the link twice. Only http(s) links are accepted. See
[Desktop control](desktop-control.md) for the rest of the desktop features.

### Reader view (page content permission)

Extracts the article with Mozilla Readability and shows it as plain, selectable text with headings and lists,
adjustable text size, and a **Summarize with Claude** button (see [Claude](claude.md)). Text is capped at 200 KB
(the app notes when it was shortened). Pages without a readable article return `noArticle`.

### Page controls (page content permission)

- **Media on the page**: play, pause, back/forward 10 seconds, playback speed (0.25x to 4x). The playing element
  is used; if none is playing, the largest video or audio element.
- **Scroll the page**: up/down by screen, to top or bottom; the app shows how far down the page you are.
- **Send to text field**: types text (up to 10,000 characters) into the **focused** editable field on the PC page
  (text, search, email, URL and phone inputs, text areas, contenteditable). It is inserted as if typed, so the page's
  input events and undo work. If no editable field has focus, or focus is inside a frame, the request is refused
  (`noInput`).

Only http, https and file pages are supported. Privileged pages (for example `about:` pages and
addons.mozilla.org) return `unsupported`.

## Privacy

What is sent to the agent:

- For each tab: ID, window, position, title (up to 500 characters), URL, pinned/muted/audible/active flags and last
  access time.
- URLs only for `http:`, `https:`, `file:` and `about:` addresses; others (extension pages, `view-source:`,
  `data:` and so on) are sent as empty.
- Favicons only when Firefox already has them as `data:` URLs, downscaled to 32 px. Remote icons are never
  downloaded.
- Page text, media state and scroll position only in reply to a request you make in the app.

What is never sent:

- Tabs in private windows. The extension is also not allowed to run in private windows (`incognito: not_allowed`).
- Form values. Reader view strips form controls before extracting text.
- Anything from a page that has a password field focused or filled: reader view and *Send to text field* are both
  refused (`passwordField`).

On the agent, tab URLs, titles and page text pass through memory only. They are not written to the event log or to
disk; the audit log records only the request method and path (action and tab ID). The app keeps the tab list in
memory only.

## Security notes

- The Unix socket directory is `0700` and the socket `0600`, so only your user can connect. The agent refuses to
  start the bridge if the directory is not owned by you or another agent is already listening.
- The native-messaging manifest allows a single extension ID, `bridge@tiphys.dev`.
- The extension's content security policy blocks all network connections (`connect-src 'none'`).
- Every tab endpoint except the status needs a control session and is rate limited (20 requests per 5 seconds per
  session). The live tab stream closes when the control session ends.
- New tabs accept only http(s) URLs without whitespace or control characters.
- Messages are size-limited (1 MB per frame); oversized tab lists are trimmed (favicons first, then long URLs and
  titles, then trailing tabs).

See also [Security](../security.md).

## Limitations

- Firefox only, Linux only (native-messaging manifest path `~/.mozilla/native-messaging-hosts/`).
- Unsigned XPI: requires a Firefox build that honours `xpinstall.signatures.required = false`.
- One connected Firefox per agent.
- Requests time out after 5 seconds.
- At most 1,000 tabs are reported.
- Window focusing works on Hyprland only.
- Troubleshooting: [Troubleshooting](../troubleshooting.md).
