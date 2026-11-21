# Sleep mode

The PC and the laptop stay on in the bedroom (they are not shut down or suspended) and become one quiet fireplace:
very dim **embers** across both screens, synthesized crackles whose sound sits where the spark is, a slow fade to a
night light, and in the morning a **sunrise alarm**: the screens brighten and birds sing until you turn it off from
the phone or the keyboard. One **morning summary** tells you what happened overnight. Everything is set from the
phone, per machine; both machines start and stop together, and nothing is left behind when it ends.

It is the fourth screen mode ([Screen modes](screen-modes.md)): the same kiosk framework, always full screen on its
own workspace (`uyku`), with no cards and no data producers running. API: [api.md › Sleep mode](../agent/api.md#sleep-mode).
Settings: [configuration.md › `modes.sleep`](../agent/configuration.md#screen). Security: [Security › Sleep
mode](../security.md#sleep-mode).

## Group and leader

The machines that sleep together are the **sleep group** (by default the PC and the laptop). One of them is the
**leader** (by default the PC, because Velour runs there): its timing and alarm settings count for the whole group,
it plays the Velour playlist or song, and it sends the phone's notifications (one per event, not one per machine).

*Go to sleep* on the phone makes one session (an id, a random seed, the start time `t0`, the members with their place
in the room, the leader), starts the leader first and passes the leader's answer, which now carries the night's
**plan** (phase lengths, alarm time, snoozes), to the other members. So every machine runs the same phases and the
same alarm even if the network drops later.

The laptop talks to the leader over the source connection it already has for the other screen modes (a `screen`
service token; no new token, the leader never connects to the laptop). A member needs a source for the leader, named
like it or whose address starts with its name; otherwise the start fails with `agent.sleep.noGroup` and the app
offers to add one. If one machine cannot start, the app shows which one and offers *Try again* or *Run on one
machine*.

## Room layout

Each machine has a place relative to the bed (`left`, `right`, `foot`, `head`) and a distance (`near`, `mid`,
`far`). The scene is one wide fireplace laid across the screens in that order, with a virtual gap between them, so
a spark that leaves one screen's edge appears on the other at the right moment. Sound follows the same layout: every
crackle has a position in the scene, which becomes the share between the machines (equal-power crossfade), a stereo
pan within a machine, and a level corrected for distance (the nearer machine plays quieter).

## Phases

| Phase | Default | What you see and hear |
|---|---|---|
| `settle` | 3 min | The full ember bed, sparks and a slight heat shimmer, crackles and the occasional log crack. |
| `fade` | 30 min (sound: 45 min) | Brightness eases out to the night light; the sound fades on its own, longer curve. |
| `night` | until the sunrise | A few ember clusters breathing very slowly on a black screen, no sparks; silence, or a very quiet hum (`nightSound`, off by default). |
| `sunrise` | 25 min before the alarm | The embers grow into a warm light that fills the screen, ember red → amber → warm white; silent. |
| `ring` | at the alarm time | The alarm sound, its volume rising over 3 min; the screen at morning brightness, breathing gently. |
| `snoozed` | 9 min | Bright and quiet, a "Snoozed · again at HH:MM" line; then it rings again. |
| `morning` | 10 min, off by default | A warm morning screen: clock, date, how long you slept and the summary. Then the mode ends by itself. |

Without an alarm the night is open-ended: stop it from the phone or hold **Esc** for one second. All lengths are
set on the phone; changes to them apply at the next start.

## Embers, sound and sync

The scene is one full-screen WebGL shader drawn at reduced resolution and scaled up (embers are soft anyway): a third
of the screen at 30 fps in `settle`, 20 fps in `fade`, a sixth at 2 fps at night, 1 fps when nothing glows.
Colours are warm only (blue and green close to zero). Without WebGL a simple 2D ember gradient is drawn.

Sound is synthesized in the page (no audio files): filtered noise for the hum, short noise bursts for crackles,
deeper rarer log cracks, optional wind and rain. Every crackle belongs to a spark or flare in a shared **timeline**
that each machine computes by itself from the seed and the start time (125 ms slices, integer hashing only, so
Firefox and Chromium compute the same list): no event stream crosses the network.

**Synchronisation.** Both machines use NTP. On top of it the laptop measures the clock difference to the leader over
its link (8 pings on every connect and every 10 minutes; the lowest round-trip samples count, because Wi-Fi delays
vary a lot) and corrects the page only above 20 ms. Each sound is scheduled on the audio clock with the output latency
compensated (`getOutputTimestamp`, `outputLatency`). Measured on the real pair (PLAN §21 S3, 60 s, 85 shared crackles):
the sound left the laptop a median **−6.1 ms** (−15.8 … +8.8 ms) relative to the PC, the picture **−7.4 ms**
(−23.4 … +7.6 ms); all 85 within the ±40 ms target. The rest is the uncorrected NTP difference (~7 ms).

## Alarm

With the alarm on (`alarm.enabled`, a time and days: once, weekdays, every day or chosen days), the sunrise starts
`sunriseMin` before it and the alarm rings at the time, in the **leader's local time** (the app shows it in the
phone's time). Sounds: birds (every chirp is a small point of light on the screen), a soft chime, or a song from
Velour played on the leader (the other screens add quiet birds, so the room still wakes up if the leader is down).

- **Snooze:** Space on any machine, or *Snooze* on the phone or in its notification: quiet and bright for
  `snoozeMin` (9), then it rings again.
- **Turn off:** hold **Esc** for one second on any machine, or *Turn off* on the phone: every machine stops ringing,
  shows the morning screen if it is on, then the mode ends.
- **Nobody answers:** after `autoStopMin` (20) the sound stops, the screens stay bright and the phone is told.
- **Firefox crashed overnight:** at the ring the agent notices the page is silent (no heartbeat for 30 s), plays a
  short synthesized alarm itself (`pw-play`, a WAV in the private tmpfs directory, deleted at stop) and starts the
  kiosk again.
- **The phone is the backup:** when the alarm rings the leader sends a high-priority notification with *Snooze* and
  *Turn off* (a full-screen alarm on Android, also on the lock screen). The phone also sets its **own local alarm** for
  3 minutes after the alarm time (moved along with a snooze, cancelled by turning it off), so you are woken even if
  both machines rebooted overnight. Android needs the *Alarms & reminders* (exact alarm) permission for it to be
  exact; *Settings › Phone backup alarm* shows the state.

The alarm exists only while the sleep mode runs (its state is in tmpfs): a machine that reboots at night has no alarm,
and the phone's backup rings. A permanent systemd timer is planned for a later release.

## Night notifications

While the mode runs, each machine sends only the notification kinds chosen as critical (`notify.critical`, default:
a host down, a security trap or alarm, a new incident, a disk 95 % full). The others are **held**: not sent, kept in
memory only as a count and the first three short titles for the morning summary. The filter lifts when the alarm is
turned off.

- Held notifications are still written to the agent's **event log** (`events.jsonl`), exactly as when they are sent:
  that is the regular notification history the app's *Events* list shows. Only the held list itself (count and three
  titles) is never written anywhere.
- Notifications sent by a separate `tiphys-agent run …` process (a long command wrapped by the CLI) do **not** pass
  through the running agent, so the night filter does not see them: they arrive at once. Start overnight jobs with
  `systemd-run --user --scope …` instead if you want them only in the morning summary (finished scopes are counted).
- **Desktop notification popups** (Quickshell on Hyprland) are not touched, by decision: they appear over the sleep
  screen as usual. Use the desktop shell's own do-not-disturb if a machine gets desktop notifications at night.

## Morning summary

When the alarm is turned off (or the mode is stopped, if there was no alarm) every member sends its night to the
leader, which sends **one** `sleep.morning` notification: how long you slept (start → turn off), jobs that finished
overnight (name, duration), backups (ok / failed), new incidents, and how many notifications waited with the first
three titles. Tapping it opens the summary card; the home screen shows a small card for 12 hours, and the morning
screen shows the same. A machine that was unreachable is counted as missing. The summary lives in memory only (12
hours, `GET /v1/sleep/summary`); `notify.morningSummary: false` keeps the card but sends no notification.

## Velour sleep playlist

With a playlist chosen (*Sound › Velour sleep playlist*), the leader starts it on Velour at the beginning, at its
start volume, fades it to silence over `velour.fadeMin` and lets Velour's own sleep timer stop it; the ember sounds
sit 12 dB lower while it plays and come back over 20 s. If Velour was already playing something it is left alone.
The playlist and a Velour alarm share one saved volume: Velour gets back exactly the volume it had before the night,
once, at the end (also after a crash). Needs the "desktop" feature on the leader; otherwise the playlist is skipped and
the sleep status says so.

## Per-machine settings

Each machine card on the phone has: join the group, place and distance, volume, start / night-light / morning
brightness (with a 5 s live preview on that machine), hardware dimming state, and three optional extras, all off by
default and restored at the end: a quiet power profile (`powerprofilesctl set power-saver`), a fixed system volume
(`wpctl`), and switching off plain lit LEDs (only LEDs without a trigger; an LED with a trigger such as mic-mute or
Wi-Fi is skipped because its trigger could not be restored). The group-wide settings (phases, sound layers, Velour,
alarm, notifications, a bedtime reminder) are written to every machine with the same values.

## Brightness and DDC/CI

Dimming has two layers. The **hardware**: the laptop backlight with `brightnessctl` (the `backlight` class device
only, at most every 2 s, never below 1 %, because some panels switch the backlight off at 0) or a desktop monitor over
**DDC/CI** with `ddcutil` (VCP 0x10, at most one step every 15 s, never below `ddc.min`, never at night). The
**content**: the page scales its own brightness between the hardware steps and does the darkest part. Every previous
value is saved before it changes and put back exactly at the end or after a crash.

A TN monitor (like the PC's ASUS VG248) still glows grey on a black screen in a dark room, so the desktop needs DDC to
really dim. Setup: install `ddcutil` (its udev rule gives the logged-in user the I²C device, no `i2c` group needed) and
turn DDC/CI on in the monitor's own menu. With the **NVIDIA proprietary driver** the hardware I²C usually fails
(`ddcutil getvcp 10` → "DDC communication failed"; `ddcutil detect` → "Invalid display"). The usual fix is the driver's
software I²C:

```sh
echo 'options nvidia NVreg_RegistryDwords=RMUseSwI2c=0x01;RMI2cSpeed=100' | sudo tee /etc/modprobe.d/nvidia-ddc.conf
sudo update-initramfs -u
# reboot, then: ddcutil detect && ddcutil getvcp 10
```

Until that works the PC dims by content only: the mode runs, `tiphys-agent doctor` warns with
`doctor.sleep.ddcUnavailable`, and the phone shows the hint. The first successful `ddcutil detect` stores the bus in
`ddc.bus`; set `ddc.min` to the lowest level that doesn't glow in your room.

## Stopping leaves nothing behind

A stop from the phone, Esc held on either machine, or the end of the morning stops every member. Everything the mode
changed is listed in a state file (`sleep.json`, 0600, in the tmpfs work dir) before it is changed and undone at the
stop, or by the next agent start after a crash: the kiosk unit and its profile, the workspace, backlight / DDC
brightness, power profile, system volume, LEDs, Velour (paused only if the mode started it, volume back), the WAV,
the timers and the held notifications. An agent **restart** keeps a running night (the new agent adopts it). The
event log gets only `sleep.started`, `sleep.stopped` and `sleep.alarm {state}`, without content.

## Resource use

The mode runs for eight hours, so it has the tightest budget of all modes; only the night phase runs long.

Measured 2026-11-21 in real time on the laptop (Iris Xe, 2160×1440 at 1.25, 16 logical cores; Firefox 140 ESR kiosk +
the agent, as a member of a two-machine group; % of **one** core; PipeWire listed apart; GPU = 1 − RC6 residency):

| Phase | Firefox | Agent | PipeWire | GPU busy | Budget |
|---|---|---|---|---|---|
| settle (5 min, 30 fps, 1/3 resolution) | 42.4 % | 0.5 % | 5.2 % | 57 % | — (3 min) |
| fade (3 min, 20 fps) | 32.4 % (before the fix: 56.6 %) | 0.5 % | 5.3 % | 52 % (81 %) | — (30 min) |
| **night, `nightSound: off`** (5 min) | **2.1 %** | **0.3 %** | 0 | 3.6 % | < 2 % |
| night, `nightSound: hum` (5 min) | 10.6 % (before: 13.4 %) | 0.3 % | 4.7 % | 3.5 % | |
| sunrise (3 min, 10 fps) | 12.1 % | 0.4 % | 0 | 29 % | — (25 min) |
| ring (2 min, 15 fps, birds) | 29.2 % | 0.3 % | 5.4 % | 43 % | — |
| Firefox memory (8 processes, PSS) | 525–547 MB | 91–101 MB | | | < 600 MB |

- The night without the hum is at the budget: what is left is Firefox's own per-frame compositor and Wayland work at
  1–2 fps (a kiosk Firefox idles at 1–1.5 % on this laptop in any mode). The hum alone keeps the audio stack running
  all night (Firefox's audio threads ~8 %, PipeWire ~5 %) for a sound at −40 dBFS, so **`nightSound` defaults to
  `off`**: the ambience plays where it is heard, while falling asleep (settle and the 45-minute sound fade).
- Power: the laptop was on mains (battery "not charging", `power_now` 0) and RAPL is root-only, so extra power was
  not measured. From the night numbers (system-wide CPU 1.11 % of all cores against 0.93 % idle, GPU 3.6 % against
  0.2 %) the night adds well under 1 W, inside the 1.5 W budget; the backlight at 3 % saves more than that.
- Memory: Firefox ESR with the light profile is ~500 MB PSS before any page (PLAN §20 W0); the sleep page adds
  little. The plan's 350 MB budget could not be met by any page, so the budget is < 600 MB.
- The desktop (leader): its real Firefox kiosk was not measured (no window may open on it during tests). As a proxy,
  the headless Chromium test leader with the agent used 0.04 % of all 8 cores at night without the hum (0.9 % with
  it, before the render fixes); budget < 1 %.
- Fixed by these measurements (S7): the content dimming ran as a CSS opacity transition over the canvas that the
  compositor redrew at the refresh rate through the whole fade (now the shader eases it: fade −43 %); the night draws
  at 2 fps (1 fps when no flare glows) instead of 5/2, skips the coal pattern outside the night clusters, and draws
  nothing while the content brightness is 0.

## Requirements

| Host | Need | Used for |
|---|---|---|
| Every member | the agent with the **`screen`** feature, Hyprland, Firefox, `systemd-run` | the kiosk (as for every screen mode) |
| Laptop | `brightnessctl` with write access to the backlight (`video` group or udev rule) | hardware dimming |
| Desktop | `ddcutil`, DDC/CI on in the monitor menu (NVIDIA: the driver fix above) | hardware dimming |
| Every member | PipeWire `pw-play` | the alarm's WAV fallback |
| Optional | `powerprofilesctl`, `wpctl` | quiet power profile, fixed system volume |
| Leader, optional | Velour and the "desktop" feature | the sleep playlist and the Velour alarm |
| Phone | notification permission, *Alarms & reminders* (Android) | the alarm notification and the backup alarm |

`tiphys-agent doctor` checks the dimming path (backlight, else `ddcutil` and a working `detect`), `pw-play`, and
`powerprofilesctl` when the quiet profile is on.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `agent.sleep.noGroup` `notMember` | This machine's name is not in the session: re-run the group wizard. |
| `agent.sleep.noGroup` `noLeaderSource` | The member has no source for the leader: *Connections › Add a source* on that machine. |
| `agent.sleep.memberDown` | A machine lost its link; it keeps running on its own timeline and the alarm still rings there. It reconnects by itself. |
| The PC screen glows grey at night | No hardware dimming on the monitor (`doctor.sleep.ddcUnavailable`): turn DDC/CI on in its menu; with NVIDIA apply the driver fix above. |
| Desktop popups appear over the embers | Desktop (Quickshell) notifications are not touched by design; use the shell's do-not-disturb. |
| A notification arrived at night that wasn't critical | It came from a `tiphys-agent run …` command (a separate process the night filter can't see), or from another app. |
| The alarm rang only on the phone | The machines rebooted or the mode was not running: the screen alarm only exists while the sleep mode runs. |
| `agent.sleep.running` when starting another mode | Stop the sleep mode first (or start it again from the mode chooser). |

## Test-only environment variables

Unset by default; never set them on a machine you use. `TIPHYS_SLEEP_SCALE=N` divides every phase length by N
(e.g. 60: settle 3 s, fade 30 s; the alarm's clock time and the hardware rate limits are not scaled).
`TIPHYS_SLEEP_SYNCLOG=1` makes the page log each crackle's speaker and screen time into the tmpfs work dir (the sync
measurement). `TIPHYS_SCREEN_HEADLESS=/abs/path/to/chromium` runs the kiosk as a headless, muted Chromium in its own
unit, with no window, no Hyprland step and no hardware (a temporary group leader for tests).
