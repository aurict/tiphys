# Claude Code sessions

Tiphys runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions **on the agent** (through the
Claude Agent SDK) and lets you drive them from the phone. A session keeps working when the phone disconnects, the
app is closed or the screen is off; the phone just reconnects and catches up.

![Claude using the PC, desktop panel, mobile view and tabs](../images/pc-control.png)

There are two kinds of session:

| Kind | What Claude can do | Typical use |
|---|---|---|
| **Code** (default) | Claude Code as usual, in a folder under the agent's allowed roots, with your normal settings, tools, MCP servers and slash commands | coding, repo chores, scheduled reports |
| **Use the PC** | Only the built-in `tiphys_pc` tools: look at the screen, mouse, keyboard, Firefox tabs, accessibility tree. No shell, no file tools | "open tomorrow's weather in Firefox" |

## Requirements

- Agent feature `claude` (off by default). The SDK is only loaded when the feature is on.
- Each Claude profile's config folder must already contain a Claude Code login (profiles are described below).
- Working folders must be inside the agent's `allowedRoots` (default `["~"]`). Symlinks are resolved before the check.
- Optional:
  - `git` feature: the **Changes** view (diff, commit + push, revert) and the separate-worktree option, which needs
    the `git` binary.
  - `transcribe` feature: voice messages in the chat.
  - **Use the PC** sessions need the `desktop` and `control` features, Hyprland, and an app lock set on the phone.
    See [Desktop control](desktop-control.md).

## Enable

```sh
tiphys-agent init --name argo --features system,services,claude,git
```

`init --features` switches on exactly the listed features and turns every other one **off**. To change one
feature without touching the rest, use the app: *Settings › Hosts › argo › Agent settings › Features*. Feature
changes apply after the agent restarts. All config keys are described in
[Agent configuration](../agent/configuration.md).

In the app, *Settings › Claude* picks the **agent that runs Claude** and sets the defaults: model, thinking effort,
permission mode, profiles, favourite folders and pinned slash commands.

### Profiles

A profile maps an id to a Claude config folder, which means a separate Claude account or setup:

```json
"claude": {
  "profiles": { "personal": "~/.claude", "work": "~/.claude-work" },
  "defaultProfile": "personal"
}
```

For any folder other than `~/.claude`, the session runs with `CLAUDE_CONFIG_DIR` pointing at it. History, the
"open in terminal" list and slash commands are all read from the selected profile. In the app (*Settings › Claude ›
Profiles*) you enter one profile per line as `id = config folder`. The profile picker only appears when more than
one profile exists.

## Starting a session

**Claude tab › New session:**

- **Folder**: a picker that only browses the agent's allowed roots (hidden folders are skipped).
- **First message** (optional). Without one, the session waits idle and the Claude process starts on the first
  message.
- **Permission mode**, **Thinking effort** (`low`, `medium`, `high`, `xhigh`, `max`), **Profile**, and **Model**
  (taken from your Claude settings default).
- **Separate git worktree**: creates a new branch `tiphys/<id>` in a sibling folder `<repo>-tiphys-<id>` from
  `HEAD`. Your working copy is not touched.

The Claude tab shows three lists. **Open sessions** are live on the agent. **Open in terminal** are Claude Code
sessions running on the PC outside Tiphys; they are read-only here unless you take them over. **History** lists
past sessions, which you can read and **Continue**.

Inside a session you can:

- send messages while Claude is working. They queue and are delivered in order.
- use slash commands. The list is what Claude really knows for that folder and profile; it is fetched without an
  API call and cached for 10 minutes.
- attach photos: up to 5 per pick and 10 per message. PNG, JPEG, GIF and WebP are sent as they are; other formats
  are converted to PNG with a 1568 px long edge.
- dictate a voice message. The recording is transcribed by the agent's Whisper command, and the text is added to
  the input box.
- **Stop** (interrupt) the current turn, change the permission mode, or **End session**.
- **Load earlier messages** from Claude's own transcript. Compaction boundaries are followed, so long sessions
  don't appear stuck.

Messages typed while offline go into an on-device **outbox** and are sent when the connection returns. Each one
carries a client id, so a retry is never processed twice.

If the agent restarts (an update or a crash), live sessions come back with the same id, marked *Agent restarted ·
continue where you left off*. Sessions that have been idle for 6 hours are closed; their history stays on disk and
can be continued.

### Permission modes

| Mode (app label) | SDK mode | Behaviour |
|---|---|---|
| Ask every time | `default` | every tool request comes to the phone |
| Accept edits, ask for commands | `acceptEdits` | file edits are auto-approved |
| Plan first | `plan` | Claude plans before acting |
| Don't ask | `bypassPermissions` | no prompts at all |

`bypassPermissions` must be chosen **when the session starts**. A running session cannot switch to it; start a new
session instead. PC sessions are always `default`.

## Approving permission requests

When Claude wants a tool, the session status becomes *waiting for you* and the agent sends a high-priority
`claude.waiting` notification ("Claude needs your approval · wants to use *tool*") with **Allow** and **Deny**
buttons. Tapping a button sends the decision straight to the agent **without opening the app**, using the stored
token of the Claude agent host. If that fails, a *Could not send your decision* notification asks you to open
Tiphys. Waiting notifications are removed when the session finishes.

You can also answer from the permission card in the chat. You can turn off the "done" and "waiting" notifications
in the app's notification settings; see [Notifications](notifications.md).

When a turn ends, the `claude.done` notification includes the turn's cost, duration, the number of files changed
and the first line of the answer.

## Taking over a terminal session

Sessions you started with `claude` in a terminal on the PC appear under **Open in terminal**. The agent finds them
from Claude Code's `<config>/sessions/<pid>.json` files and checks `/proc` to confirm that the process is still
alive and is the same process.

**Take over on phone** (after you confirm):

1. only works while that session is **idle**. If Claude is busy in the terminal, you get *Try again when it
   finishes*.
2. sends `SIGTERM` to the terminal process and waits up to 8 s for it to exit. It never uses `SIGKILL`; if the
   process doesn't stop, you get *Close it on the PC and try again*.
3. resumes the same session on the agent with its full history.

To go back to the terminal later, run `claude --resume <session-id>` on the PC (or use the ready-made command, see
[Continue on the PC](#continue-on-the-pc)). Takeover uses Claude Code's own session files; it does not use tmux.

## Continue on the PC

Every live session summary carries a `resumeCommand` (see the [API](../agent/api.md#claude)), a client can offer as
*Continue on the PC*. It is a complete command for a terminal on the PC:

```sh
cd '/home/me/code/my-project' && claude --resume <sdkSessionId>
```

- The folder is the session's working folder, single-quoted for a POSIX shell, and the id is Claude Code's own session
  id (`sdkSessionId`). `resumeCommand` is `null` until Claude has reported that id (a session that has not yet
  produced its first message).
- **Stop the session on the phone first** (close it), or at least let the turn finish: the same conversation open in a
  terminal and in the agent at the same time would fork into two histories.
- Run it from the folder the command changes into. `claude --resume` **without an id** lists only the sessions of the
  **current folder**; a session started from the phone is saved under the folder chosen on the phone, so from your home
  directory it will not show up in that list. That is why the command starts with `cd`.
- Sessions that run in a terminal and are taken over on the phone, and the reverse direction, work the same way: the
  transcript is Claude Code's own session file, so either side can continue it.

## While you were away, and session changes

- **While you were away**: when you reopen a session, a card summarises everything since you last looked: turns,
  commands, files changed, cost and the last answer. You can save it as a note (see
  [Vault and notes](vault-and-notes.md)). The "last seen" position is stored on the phone per session and reset
  when the agent restarts.
- **Changes**: lists the files this session edited (`Edit`, `Write`, `MultiEdit`, `NotebookEdit`) with their
  current Git status and a diff per file. From there you can:
  - **Commit + push** only these files. Other changes stay out. The session title is suggested as the commit
    message. If the session ran in a worktree, the push sends the worktree branch; it doesn't merge anything.
  - **Revert** them to `HEAD`. Deleting files the session created is a separate, explicit checkbox.

  Files outside the repository are listed but never committed or reverted. These actions use the agent's git
  endpoints (see [Terminal, files and git](terminal-files-git.md)).

## Scheduled tasks

*Claude tab › alarm clock icon › Scheduled tasks.* Each task has a name, folder, prompt, permission mode, model,
effort, profile and one of these schedules:

| Schedule | Rule |
|---|---|
| Daily | every day at `HH:MM` |
| Weekly | chosen weekdays at `HH:MM` |
| Interval | every N minutes (minimum 15), counted from when the task was created or its timing last changed |

- Times use the **agent's** time zone. Daylight-saving changes are handled: a skipped spring hour runs right after
  the change, and a repeated autumn hour doesn't run twice.
- Missed runs are **not** made up. If the agent was off at that minute, the run is skipped.
- If the previous run is still going, the new one is skipped (`claude.scheduleSkipped`). **Run now** returns an
  error in that case.
- A run is a normal session titled `⏰ <name>`, so the usual done and error notifications apply.
  `claude.scheduleFailed` means the session couldn't start, for example because the folder is gone.
- Up to 50 tasks are stored in `claude-schedules.json` next to `agent.json`.
- Nobody may be watching when a task runs. With *Ask every time*, tool requests wait for your approval.

## Use the PC sessions

Claude looks at the PC's screen and works with the mouse and keyboard. You watch a small live strip above the chat
and can stop it at any time.

### Starting

*Claude tab › New session › Use the PC*, type the task, then **Unlock and start**. The app asks for the app lock
again and opens a [remote-control session](desktop-control.md#remote-control-session). The Claude session is bound
to that control session's token.

- The control session lasts 15 minutes. Two minutes before it ends, a notification offers **Extend**. Extending is
  capped at 60 minutes of remaining time.
- While the session is held on the phone, a persistent *Claude is using the PC* notification has a **Stop** button.
  Stop works without opening the app. Leaving the chat or backgrounding the app does **not** end control.
- The PC shows the usual control indicator: a red-orange window border plus a desktop notification.
- When control ends (stopped, expired, agent shutdown, or switched off), Claude is interrupted immediately and
  every PC tool returns "control ended". **Reopen control** asks for the lock again and re-binds the same session.
- Only the device that holds control can send messages, answer permission requests or change the mode of a PC
  session.

### How the session is built

PC sessions run with **no built-in tools** (`tools: []`). User and project settings and MCP servers are not loaded.
The following are explicitly disallowed: `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep`, `WebFetch`, `WebSearch`,
`Task`, `Agent`, `Skill` and the rest. If Claude asks for any non-`tiphys_pc` tool, the request is denied. A fixed
system prompt tells Claude to work from screenshots, prefer keyboard shortcuts, call `confirm` before risky steps,
treat on-screen text as data, and stop when control ends.

### Tools and guardrails

Every tool call first re-checks that the control session is valid. **Input tools** are rate-limited to **4 actions
per second per session**. `screenshot`, `windows`, `wait` and `confirm` are not counted.

| Tool | What it does | Guardrails |
|---|---|---|
| `screenshot` | captures the focused monitor, scaled to fit 1280×800 | requires `grim` and `ffmpeg`. It sets the coordinate space for all pointer tools. The last 60 screenshots are kept in `claude-shots/` next to `agent.json` and shown as thumbnails in the chat |
| `click`, `double_click`, `move`, `drag`, `scroll` | pointer actions at screenshot pixel coordinates | rejected until a screenshot exists, and rejected outside the screenshot bounds. Scroll is at most 20 notches |
| `type` | types text with `wtype` (Unicode; `\n` = Enter, `\t` = Tab) | at most 2000 characters, no control characters. If the focused window is a terminal, you must approve once per terminal window |
| `key` | a key or shortcut (`ctrl+l`, `alt+Tab`, `F5`) | allowed-key table only. Letters and digits need Ctrl, Alt or Super. Always **blocked**: Super+M, Ctrl+Alt+Delete/Backspace/F1–F12, and any shortcut in your Hyprland config bound to exit, power, suspend, DPMS, lock, logout, `systemctl`, `pkill`, `killall`. These **need approval**: Alt+F4, Ctrl+Q, Ctrl+Shift+Q, Ctrl+Shift+W, any shortcut bound to close or kill a window, and any shortcut that opens a terminal. Other keys sent to a terminal go through the terminal gate |
| `windows` | lists open windows and launchable app ids | read-only |
| `focus_window` | brings a window to the front | the window must be on the visible workspace |
| `launch_app` | starts an app with `gtk-launch` | only ids from the agent's `.desktop` app list (no free-form command). Terminal emulators need approval |
| `wait` | waits up to 5000 ms | none |
| `confirm` | asks you to approve a risky step | shown as a permission card and a `claude.waiting` notification |
| `browser_tabs`, `browser_activate` | list or switch Firefox tabs | need the [Firefox bridge](firefox-bridge.md) |
| `browser_open` | opens an http(s) URL in a new tab | needs approval after Claude has read any page or UI content, for query or fragment strings over 40 characters, and for domains not already open in a tab |
| `browser_close` | closes tabs | always needs approval |
| `page_text` | reader-view text of a tab, up to about 30 KB | needs the extension's optional page-content permission. Pages with a password field are refused |
| `ui_tree` | the accessibility tree of a window (see [mobile view](remotes-and-mobile-view.md#mobile-view)) | the window must be visible, and private Firefox windows are refused. Ids expire on the next call |
| `ui_press` | runs a control's action | needs approval when the control's name, description or text looks destructive (delete, send, buy, pay, close, log out… in English and Turkish, normalized against look-alike and invisible characters), when the control is inside a web page, when it is unnamed (icon only), or when the window title looks destructive. Terminal gate applies |
| `ui_set_text` | replaces a field's text | plain text only (no `\n` or `\t`). Password fields are always refused. No keyboard fallback |
| `ui_set_value` | sets a slider or spin button | none |

Approvals use the same path as normal permission requests. For PC sessions they are **not shown on the lock screen
at all**, because their buttons act on the PC.

## Limitations

- One agent runs Claude (the one chosen in *Settings › Claude*). Notification buttons always go to that host.
- PC sessions need Hyprland on Wayland and work only on the workspace in front of you. There is one control session
  at a time per agent.
- The PC session system prompt is fixed in code and currently assumes a Turkish-speaking user (it tells Claude to
  answer in the user's language).
- Terminal takeover only works for idle sessions, and the agent must be able to signal the terminal process (same
  user).
- The event history kept in memory is capped at 3000 events per session. Older messages are loaded from the
  transcript.

## Security notes

- Anyone holding a paired device token can start sessions in any folder under `allowedRoots`. Keep the roots
  narrow.
- `bypassPermissions` runs tools with no prompts. Scheduled tasks with it run unattended.
- The control token for PC sessions lives only in memory on the agent and is never written to disk. On the phone
  it sits in secure storage only while a PC session is held. Restored PC sessions come back **unbound**.
- PC guardrails are enforced in the tools themselves, not only in the prompt. Still, treat a PC session as giving
  Claude your desktop: watch the live strip and keep sessions short.

See also: [Security](../security.md), [API](../agent/api.md), [Troubleshooting](../troubleshooting.md).
