# Password vault and quick notes

Tiphys includes a small password vault that lives only on the phone, and a quick-note screen that saves notes to Obsidian. Neither feature needs the agent, with two exceptions: importing into the vault (over SSH/SFTP) and dictating a note (through the agent's `transcribe` feature).

## Password vault

### What it does

- Stores entries with a title, username, password, URL, notes and tags.
- Searches by title, username, URL and tags. Search is case-insensitive, and every word in the query must match. Passwords and notes are never searched.
- Generates passwords with `Random.secure()`. The default length is 20 and the maximum is 128, with an optional **Symbols** toggle. Look-alike characters (`l`, `I`, `O`, `0`, `1`) are left out, and every character class appears at least once.
- **Copy password** puts the value on the clipboard with Android's "sensitive" flag, so keyboards and the clipboard preview hide it. The copy is cleared after 30 seconds if the clipboard still holds it. Locking the vault clears it immediately.
- **Import** reads a Markdown password list from one of your hosts (see below).

### Requirements

- The app lock (PIN or fingerprint) must be enabled: **Settings › Security**. Without it, the vault shows "Turn on the PIN or fingerprint lock first" and won't open.

### How to use

Open it from **Settings › Security › Password vault**, or add the **Password vault** shortcut to the home screen. Each time you open the vault, the app asks for the PIN or fingerprint again, even if the app itself is already unlocked.

The vault locks again when:

- it has been idle for 2 minutes;
- the app goes to the background;
- you leave the vault screen.

If the vault locked because you switched apps, a pending password copy is **not** cleared right away; the 30-second timer still runs. This lets you paste into another app. When you lock the vault explicitly, the copy is cleared at once.

### Import from a Markdown file

**Import** reads a Markdown file (default `~/SIFRELER.md`, at most 1 MiB) from an SSH host over SFTP. The default host is the PC used for Claude, then a host with Wake-on-LAN, then the first SSH host.

- Each Markdown table row becomes an entry, and `## Group` headings become tags. Columns are recognised by their header names (for example *Service / Server*, *Address / URL*, *User / Email*, *Password / Token*). If no header is recognised, columns are assigned by position: 2 columns = title, password; 3 = title, user, password; 4 = title, address, user, password.
- If a cell contains a value in backticks, that value is used and the rest of the cell goes into the notes. A dash (`—`) means empty.
- A preview list with masked passwords lets you choose which rows to import. Rows without a password are not selected by default.
- An entry with the same title and username is updated instead of duplicated: non-empty fields overwrite, tags are merged, and notes are appended.
- After importing, you can **Delete file** on the host. It uses `shred -u` if available, otherwise `rm`. The default is to keep the file.

The app reads this one Markdown table format and nothing else. There is no Bitwarden, KeePass or CSV import.

### Storage and backup

- All entries are stored as one JSON document in the app's secret store (`flutter_secure_storage`, which Android Keystore backs). They are never written to the plain profile file and never logged.
- The vault is included **only** in the encrypted profile export. That export uses Argon2id (19 MiB, t=2, p=1) and XChaCha20-Poly1305, with a passphrase you choose. A plain export doesn't include it.
- When you restore an encrypted backup, the restored vault is **merged** into the current one, not written over it. Entries are matched by ID, and the most recently updated version of each entry wins.

### Security notes

- While a vault screen is open, the window sets `FLAG_SECURE`. Screenshots and the recent-apps preview are blocked.
- Entries are held in memory only while the vault is open. Any save attempted after the vault has locked is refused, so an old dialog can't write an empty list over the vault.
- The PIN is stored as an Argon2id hash. After 5 wrong PINs, the wait doubles with each further failure, starting at 30 seconds.
- Phone → PC clipboard sync never sends a password copied from the vault while it is still waiting to be cleared (see [system.md](system.md#clipboard-sync)).
- See [../security.md](../security.md) for the overall threat model.

## Quick note (Obsidian)

### What it does

The quick note sends text to the **Obsidian app on the phone** through an `obsidian://new` link (`silent=true`). Tiphys never talks to CouchDB and never writes to the vault itself. Obsidian saves the note, and if you use the Self-hosted LiveSync plugin, LiveSync encrypts and syncs it as usual. End-to-end encryption therefore stays intact.

Two modes:

- **New note**: creates `<folder>/<title>.md`. The title is the **Title** field, or the first line of the note, or a timestamp. Characters Obsidian rejects are removed, and the title is cut to 60 characters.
- **Append to daily note**: appends to the daily-note path. In the pattern, `YYYY`, `MM` and `DD` are replaced with today's date.

### Requirements

- The Obsidian app must be installed on the phone. Otherwise: "Obsidian could not be opened".
- To dictate, you need an agent host with the `transcribe` feature (see [system.md](system.md#transcription)).

### How to enable

Go to **Settings › Integrations › Obsidian** and set:

- **Vault name**: exactly as shown in Obsidian's vault switcher.
- **Folder for new notes**
- **Daily note path**
- **Default** mode

### How to use

Open **Quick note** from the home-screen shortcut, or use **Save to Obsidian** in these places:

- on a Claude answer or away summary ([claude.md](claude.md));
- on selected terminal text ([terminal-files-git.md](terminal-files-git.md));
- on a log line in Log search or Dozzle ([monitoring.md](monitoring.md)).

The screen shows the target path (`vault › path.md`) before you save. **Dictate** records audio, sends it to the agent's `/v1/transcribe`, and appends the recognised text.

### Limitations

- A note can be at most 50,000 characters, because that is the most the link can safely carry.
- Obsidian briefly comes to the front while it saves the note.
- Tiphys can't confirm that Obsidian actually saved the note. It only knows the link was opened.
