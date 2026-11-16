# Terminal, files, share-to-PC and git

The terminal, the file browser and share-to-PC work over plain **SSH**. They don't need the agent and work on any host with SSH configured, such as `argo` (the PC) or `atlas` (a server). Git goes through the **agent**.

## SSH connections (shared by all SSH features)

- Hosts are set up under **Settings › Hosts**: address, port (default 22), user, and authentication by key or password. The key or password is stored in the app's secret store (see **Settings › Keys & secrets**), never in the profile file.
- SSH keys can be imported (OpenSSH/PEM, including passphrase-protected keys) or generated (ed25519). An imported key is stored without its passphrase, because the secret store is already encrypted.
- **Host keys use trust-on-first-use.** The fingerprint is saved on the first connection. If it changes later, the connection is refused with "The server key changed!". The app has no button to reset a saved fingerprint.
- Connect timeout is 12 s, and keep-alive runs every 20 s.
- Use Tailscale addresses (for example `argo.my-tailnet.ts.net`) so you don't expose SSH publicly. See [../getting-started.md](../getting-started.md).

## Terminal

### What it does

- One tab per session. Each tab is an SSH connection that runs:
  `tmux new-session -A -s <tmuxSession>`
  This attaches to the named tmux session, or creates it if it doesn't exist. The session name defaults to `tiphys` and is set per host.
- If tmux isn't installed, a plain login shell (`$SHELL -l`) starts instead.
- Because the session lives in tmux on the server, a dropped connection loses nothing. **Reconnect** resumes where you left off. When the app returns to the foreground, dropped or silently dead tabs reconnect on their own.
- Features:
  - xterm-256color with a 10,000-line scrollback;
  - pinch to change font size;
  - full-screen and landscape mode;
  - an extra key bar with sticky Ctrl/Alt;
  - command snippets;
  - **Save to Obsidian** for selected text ([vault-and-notes.md](vault-and-notes.md#quick-note-obsidian)).

### Requirements

- An SSH server on the host. `tmux` is recommended.

### Configuration

Go to **Settings › Terminal**:

- **Font size**
- **Extra keys**: space-separated, for example `esc tab ctrl alt up down left right | ~ /`.
- **Snippets**: one per line, in the format `name | command | host (optional)`. Tapping a snippet types the command and presses Enter.

### Limitations

- Sessions stay open only while the app is running. The tmux session on the server keeps running after that.
- Each tmux session is shared by every client that attaches to it, including your desktop terminal.

## File browser (SFTP)

### What it does

**Files** tab: pick a host, then browse over SFTP. You can:

- **Preview** text files up to 2 MiB and images (png/jpg/gif/webp/bmp) up to 20 MiB.
- **Edit** text files up to 1 MiB. Non-UTF-8 files don't open. Before saving, the editor warns you if the file changed on the server in the meantime.
- **Upload here**, and **Download / share**.
  - Transfers can be paused and resumed. Each one uses its own SSH connection, and an interrupted transfer continues from where it stopped.
  - Unfinished uploads are kept as hidden `.name.size.tiphys-part` files in the target folder.
  - Downloads go to the app's own `downloads/` folder, and you can share them from there.
  - When you download a folder, it is first compressed on the server into `/tmp/tiphys-…`: `.zip` if `zip` is installed, otherwise `.tar.gz`. There is a 30-minute limit.
- Rename, move, copy (`cp -a`), and create a folder.
- **Move to trash**: moves the item to the freedesktop trash (`~/.local/share/Trash`), so you can restore it from the desktop. The app has no "delete forever" action for files.
- **Terminal here** and **Claude here** open a terminal or a Claude session in the current folder. The **Git** button appears for hosts that have an agent.

### Configuration

Go to **Settings › Files**:

- **Show hidden files**
- **Bookmarks**: one per line, as `host:path`. For example `argo:~/Desktop` or `atlas:~/stack`.

### Security notes

- The file browser works with the SSH user's own permissions. The agent's `allowedRoots` does **not** limit SFTP.

## Share to PC (Android share menu)

### What it does

Tiphys is a share target for any file or text: Android `SEND` and `SEND_MULTIPLE` with `*/*`. Shared items open the **Send to computer** screen:

- Pick a **Computer** (any SSH host) and a **Folder** (default `~/Downloads`; it is created if missing), then tap **Send**.
  - Files are uploaded over SFTP.
  - Shared text is saved as `paylasim-<timestamp>.txt`.
- If you share only text and the chosen host has an agent, **Send to PC** puts the text on the PC clipboard instead (`PUT /v1/desktop/clipboard`, which needs the `desktop` feature).
- If the shared text contains a link, **Open on argo** opens it in the PC's browser. See [system.md](system.md#open-on-pc).

### Limitations

- Each shared file is read fully into memory and uploaded in one write, without pause/resume. For very large files, use **Upload here** in the file browser.

## Git

### What it does

Git runs on the agent host, through the agent's git routes:

- status: branch, ahead/behind, staged, unstaged, untracked and conflicted files;
- diff (cut off at 512 KiB);
- history (log);
- local and remote branches;
- stage and unstage;
- **Discard changes** (asks for confirmation);
- commit (staged, or **Commit all changes**);
- **Push**, **Pull** (`--ff-only`), **Fetch** (`--all --prune`);
- switching to a branch or creating one.

Commits and pushes are recorded in the event log ([system.md](system.md#event-log)).

### Requirements

- The agent feature `git` (off by default) and the `git` binary on the host.
- The repository must be inside the agent's `allowedRoots` (default `["~"]`).

### How to enable

Do either of these, then restart the agent:

- turn on **Git** under **Settings › Hosts › (host) › Agent settings › Features**;
- set `"features": { "git": true }` in `agent.json`.

See [../agent/configuration.md](../agent/configuration.md).

### How to use

- In **Files**, open a folder inside the repository and tap the **Git** button.
- The Claude session changes view also links to git for the session's working folder ([claude.md](claude.md)).

### Limitations

- Git runs with `GIT_TERMINAL_PROMPT=0`. Operations that need interactive credentials fail with an authentication error instead of hanging. Use SSH keys or a credential helper on the host.
- Push and pull time out after 120 s. Other git commands time out after 20 s.
- If the branch has no upstream, push fails with "The branch has no upstream". The git screen doesn't offer `--set-upstream`. The Claude session-changes view does, through `setUpstream`.
- The pull is fast-forward only. Merge conflicts must be resolved elsewhere, for example in the terminal.

### Security notes

- `allowedRoots` is checked in `agent/src/paths.ts` after symlinks are resolved. Both the requested path and the repository top level must be inside an allowed root; otherwise the agent returns `agent.path.notAllowed` (403).
- Discarding back to HEAD refuses to delete new (untracked) files unless that is confirmed explicitly.
- API details: [../agent/api.md](../agent/api.md).
