# agy: Antigravity CLI sessions

Tiphys can run Antigravity CLI (`agy`) sessions **on the PC** and let you drive them
from the phone, the same way it does for Claude Code. You start a session in a folder, send prompts, watch the
answers, thoughts and tool calls stream in, and answer agy's permission questions from the phone, also from a
notification. A session keeps working when the phone disconnects; the phone reconnects and catches up.

## Requirements

- Agent feature `agy` (off by default, risk **high** like `claude`: it runs code on the PC). Turn it on with the other
  features and restart the agent; see the [setup guide](../setup-guide.md#agy-antigravity-cli).
- `agy` installed on the PC, on the agent's `PATH`, and **logged in** (run `agy` once in a terminal as the agent's
  user and sign in). Without the binary a session fails with `agent.agy.missing` (501); an agy that isn't logged in
  can't start a session (the start fails with an `agent.agy.*` error).
- Working folders must be inside the agent's `allowedRoots`, like Claude sessions. Symlinks are resolved first.

## How it works

The agent starts **one `agy acp` process per session** and talks to it over the **Agent Client Protocol** (JSON-RPC,
one JSON object per line on the process's standard input and output). The agent offers agy no file-system or terminal
capability: agy does its own file and shell work, and asks for permission through the protocol. The agent turns what
agy reports into a list of events (your messages, agy's answers and thoughts, tool calls and their results, plans,
mode changes, permission requests) that the phone fetches with a long poll
([API](../agent/api.md#agy)). The conversation itself belongs to agy: it is stored by agy, not by Tiphys, and stays
there when a session is closed.

## Modes

A session has a mode that decides how much agy asks. The list comes from agy itself, with agy's own descriptions
(agy 1.5.12):

| Mode | agy's description |
| --- | --- |
| `default` | Ask before edits and commands, per your permission settings. |
| `accept-edits` | Approve file edits in the workspace without asking. |
| `auto` | Approve edits and safe commands; ask before irreversible actions. |
| `plan` | Plan carefully before executing a task. |

The names and the set can change with agy's version: the session reports the modes it was given (`modes`), and only
those can be chosen (`agent.agy.unknownMode` otherwise). Choose the mode when the session starts or change it at any
time. The mode is agy's, the agent adds no extra approval level. The `--dangerously-skip-permissions` option of agy
(approve everything without asking) is **never** used and can't be selected. You can also change the model, from the
list agy offers.

## Permission prompts

When agy wants to do something its mode doesn't allow without asking, the session status becomes `waiting`, the
`permission` event shows what (the tool, and the command line for a shell command) and the options agy offers
(typically allow and deny variants), and you tap one in the app. The agent sends a high-priority `agy.waiting`
notification with the session and request ids as data, so the phone can show the options as **notification buttons**
that answer without opening the app, as for Claude's `claude.waiting`. Until you answer, agy waits. Cancelling the turn
answers every pending prompt as cancelled. When a turn ends you get `agy.done` (low priority); a failed turn gives
`agy.error`.

## Resuming earlier conversations

*Earlier conversations* lists what agy has stored for the folder you ask about (`GET /v1/agy/conversations?cwd=`),
**including conversations that were started in a terminal**. Starting a session with `resume: <conversation id>`
loads that conversation: its history is replayed into the session as events marked `replay`, so the phone shows the
earlier turns, and the next message continues it. A conversation can be open in only one live session of the agent at
a time (`agent.agy.alreadyOpen`); the list shows which session holds it (`liveId`).

## Continue on the PC

The session summary has a `resumeCommand`, for example

```sh
cd '/home/me/code/my-project' && agy --conversation 7f3c1c1a-0000-4000-8000-000000000000
```

Paste it into a terminal on the PC to carry on the same conversation there. **Close the session on the phone first.**
A conversation open in a terminal and on the phone at the same time would **fork**: both sides would add to their own
copy, and one of the two histories would be lost or confused. The folder in the command is the session's working
folder (single-quoted for the shell). `resumeCommand` is `null` until agy has assigned the conversation id.

## Limits

- At most **6 live sessions** (`agent.agy.tooManySessions`). Ended sessions don't count.
- A session that has been **idle for 2 hours** is closed (the process is stopped; the conversation stays in agy and
  can be resumed). Ended sessions disappear from the list 2 hours after they ended.
- Starting a session is limited to 6 a minute and listing conversations to 10 a minute per device.
- The agent keeps the last **3000 events** of a session in memory; a streamed message grows to at most 100 000
  characters.
- Working folders must be inside `allowedRoots`. agy itself is not confined to that folder once it runs.
- No `--dangerously-skip-permissions`, and no file-system or terminal access is handed to agy by the agent.
- Device tokens only; a service token can't use these routes.
- agy processes are stopped when the agent stops. Sessions are not restored after an agent restart; resume the
  conversation to continue.

## Security notes

An agy session runs commands and edits files on the PC as the agent's user, driven from the phone: anyone holding a
paired device token can start one in any folder under `allowedRoots` and, by approving prompts or choosing `auto`,
run code. See [Security › agy sessions](../security.md#agy-sessions). The audit log records starts, answers, mode and
model changes, cancels and closes with the session id, folder, mode or option, never the prompt text.

See also: [API](../agent/api.md#agy), [Claude](claude.md), [Security](../security.md).
