# Architecture

How Omarchy Glance gets its data. For install and features, see the
[README](../README.md).

## Calendar

Glance never talks to Google, Microsoft, iCloud or CalDAV itself. Caldir owns
provider sign-in and sync, and keeps every calendar as standard RFC 5545 files
on disk. Glance only reads them:

```text
provider ─ caldir pull ─▶ ~/caldir/<calendar>/*.ics
                          │
                          ├─ caldir --json events      (recurrence, timezones)
                          └─ URL / CONFERENCE lookup    (meeting links)
                          ▼
              sync/caldir-export
                          ▼
              ~/.local/state/omarchy/calendar-events.json
                          ▼
              Panel.qml / BarWidget.qml
```

`sync/caldir-export` (a stdlib-only Python script, `sync/caldir_export.py`):

- optionally runs `caldir pull` (see below)
- reads the Caldir folder from `${XDG_CONFIG_HOME:-~/.config}/caldir/config.toml`
- runs `caldir --json events` for the last 7 and next 60 days, so Caldir
  expands recurrences and timezone overrides
- writes the result atomically to `calendar-events.json`
- takes a nonblocking `flock`, so several monitors' panels never export twice
  at once
- caps what it writes: titles and locations at 512 characters, calendar names
  at 128, 5,000 rows, and an 8 MB file

Only one bar instance (elected per shell) runs the five-minute timer and the
notification watcher, however many monitors there are. The exporter also runs
when the panel opens.

With **Sync calendars** on (the default, stored as `syncCalendars` in
`shell.json`), it first runs `caldir pull`, but only when the last successful
pull (`pulledAt` in the output file) is more than five minutes old. Turning the
switch on forces a pull right away. No pull runs until the shell has handed
Glance its settings, so turning sync off is respected at startup too. Glance
only pulls and never pushes, so it cannot change your calendars. caldir finds
its providers on `PATH`, so the exporter adds `~/.local/bin`, `~/.cargo/bin`
and renCal's provider folder (`/usr/lib/renCal/providers`) when they exist. A
pull that takes over two minutes is stopped together with every provider
process it started. Sync only runs while the Omarchy shell is running.

Exit codes, which the panel turns into messages:

| Code | Meaning | Panel shows |
| --- | --- | --- |
| 0 | Exported (pulled, or no pull due) | events |
| 3 | `caldir` not installed | the install hint |
| 10 | Exported what is on disk, pull failed | "Calendar sync failed: ..." |
| 75 | Another export is running | keeps its current state |
| 1 | Anything else | "Calendar export failed: ..." with caldir's own message |

The data counts as stale when the last pull is more than 20 minutes old, or,
if the file has never recorded a pull, when the last export is.

### Meeting links

Caldir's JSON can leave out a meeting link stored only in an event's `URL` or
`CONFERENCE` property. To fill the gap, the exporter scans only those
properties (plus the Google and Microsoft variants and `UID`) in the top-level
`.ics` files of each calendar, skipping nested components such as `VALARM`.
It keeps HTTPS links to `meet.google.com`, `teams.microsoft.com`,
`teams.live.com`, `zoom.us` and `zoomgov.com` (and their subdomains), and
matches them to events by `(calendar, UID)`.

A link must pass one strict grammar, in the exporter and again in the panel
right before it opens: no user info (`@`), backslashes, `%` escapes or control
characters in the host part, and no port other than 443. The panel opens the
normalized link, not the raw text.

It does not parse dates, expand recurrence, read descriptions or credentials,
or change any `.ics` file.

## Notifications

Glance reads the history that Omarchy's built-in notification service already
writes. It does not replace that service. Notification fields come from any
local app, so Glance treats them as untrusted; the checks live in
`NotificationSafety.js`, which follows the rules of Omarchy's own
`notifications/Security.js`.

- **History**: `live.json`, `history.json` and `history/*.json` under
  `~/.local/state/omarchy/notifications/`, merged and limited to the 30 newest.
  Files over 5 MB and symlinks are skipped
- **Unread dot**: `bin/glance-unread` compares notification times with the
  last time the panel was opened (`~/.local/state/omarchy-glance/seen`). It
  watches the folder with `inotifywait`, and polls every ten seconds only
  while the watcher is down. Restarting the shell does not mark anything read
- **Dismiss**: Omarchy gives plugins no way to edit its history, so Glance
  records dismissals in `~/.local/state/omarchy-glance/tombstone.json` (a
  cleared-before time and dismissed keys) and hides those rows. **Dismiss all**
  also closes cards on screen through `omarchy-shell notifications dismissAll`.
  The rows stay in Omarchy's `history.json`, and in its history shortcut,
  until Omarchy's 24-hour retention removes them
- **Actions**: clicking a notification runs its stored action (the same argv
  limits as Omarchy), opens its media file with `xdg-open`, or focuses the app
  that sent it. App names are matched as plain text, never as a pattern
- **Images**: previews and icons load only local regular files outside
  `/proc`, `/sys`, `/dev` and `/run` (except your own `/run/user/<uid>`), so a
  crafted path cannot stall the shell's image loader. App names are never
  treated as file paths
- **Video thumbnails**: `bin/glance-thumb` saves one frame per screen
  recording with `ffmpegthumbnailer` or `ffmpeg` (file protocol only) in
  `~/.local/state/omarchy-glance/thumbs/`, and only for files inside your XDG
  Videos folder. A thumbnail is reused until the video changes and deleted
  after 30 days unused

Glance's state folder and files are created owner-only (`700` and `600`).

## Files

| Path | Purpose |
| --- | --- |
| `BarWidget.qml` | Bar clock, next-event announcement, unread dot |
| `WallClock.qml` | Tick timer that stays correct across daylight-saving changes (from Omarchy) |
| `Panel.qml` | Calendar, agenda and panel layout |
| `NotificationHistory.qml` | Notification list |
| `NotificationSafety.js` | Checks for untrusted notification data |
| `SettingsView.qml` | Settings page inside the panel |
| `Model.js` | Date, event and meeting-link logic |
| `sync/` | Caldir exporter |
| `bin/` | Unread counter, dismiss tombstone and thumbnail helper |
| `i18n/` | Translations |
| `tests/` | Tests for the exporter, `Model.js` and the notification checks |

## Known limitations

- Meeting-link lookup ignores nested `.ics` files, event descriptions, other
  `X-*` properties, non-HTTPS links and hosts outside the list above.
- Caldir's JSON has no event deep links or event types, so agenda rows only
  open a **Join** link, and there is no out-of-office filter.
- Caldir's JSON does not say which instance of a recurring event a row is, so
  a rescheduled instance with its own meeting link can show the series' link.
- Dismissed notifications stay in Omarchy's own history for up to 24 hours
  (see Dismiss above).

## Development

```bash
node --test tests/model.test.js tests/notification-safety.test.js
python3 -m unittest tests/test_caldir_export.py
/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell BarWidget.qml Panel.qml NotificationHistory.qml SettingsView.qml
omarchy plugin validate .
./sync/caldir-export && jq '.source, .pulledAt, (.events | length)' ~/.local/state/omarchy/calendar-events.json
```

Use Qt 6's `qmllint`; `/usr/bin/qmllint` is the Qt 5 one and cannot parse
these files.
