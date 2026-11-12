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

It runs when the shell starts, when the panel opens, and every five minutes.

With **Sync calendars** on (the default, stored as `syncCalendars` in
`shell.json`), it first runs `caldir pull` to fetch remote changes. Glance only
pulls and never pushes, so it cannot change your calendars. caldir finds its
providers on `PATH`, so the exporter adds `~/.local/bin`, `~/.cargo/bin` and
renCal's provider folder (`/usr/lib/renCal/providers`) when they exist. If the
pull fails, the exporter still exports what is on disk and exits with status 2,
and the panel shows "Calendar sync failed". Sync only runs while the Omarchy
shell is running.

### Meeting links

Caldir's JSON can leave out a meeting link stored only in an event's `URL` or
`CONFERENCE` property. To fill the gap, the exporter scans only those
properties (plus the Google and Microsoft variants and `UID`) in the top-level
`.ics` files of each calendar. It keeps HTTPS links to `meet.google.com`,
`teams.microsoft.com`, `zoom.us` and `zoomgov.com`, and matches them to events
by `(calendar, UID)`.

It does not parse dates, expand recurrence, read descriptions or credentials,
or change any `.ics` file.

## Notifications

Glance reads the history that Omarchy's built-in notification service already
writes. It does not replace that service.

- **History**: `live.json`, `history.json` and `history/*.json` under
  `~/.local/state/omarchy/notifications/`, merged and limited to the 30 newest
- **Unread dot**: `bin/glance-unread` compares notification times with the
  last time the panel was opened (`~/.local/state/omarchy-glance/seen`). It
  watches the folder with `inotifywait`, or polls every five seconds without it
- **Actions**: clicking a notification runs its stored action, or focuses the
  app that sent it
- **Video thumbnails**: `bin/glance-thumb` saves one frame per screen
  recording with `ffmpegthumbnailer` or `ffmpeg` in
  `~/.local/state/omarchy-glance/thumbs/`. A thumbnail is reused until the video
  changes and deleted after 30 days unused

## Files

| Path | Purpose |
| --- | --- |
| `BarWidget.qml` | Bar clock, next-event announcement, unread dot |
| `Panel.qml` | Calendar, agenda and panel layout |
| `NotificationHistory.qml` | Notification list |
| `SettingsView.qml` | Settings page inside the panel |
| `Model.js` | Date, event and meeting-link logic |
| `sync/` | Caldir exporter |
| `bin/` | Unread counter and thumbnail helper |
| `i18n/` | Translations |

## Known limitations

- Meeting-link lookup ignores nested `.ics` files, event descriptions, other
  `X-*` properties, non-HTTPS links and hosts outside the list above.
- Caldir's JSON has no event deep links or event types, so agenda rows only
  open a **Join** link, and there is no out-of-office filter.
- Omarchy's notification service queues history writes. One already queued
  when you press **Dismiss all** can still appear on a later refresh.

## Development

```bash
qmllint -I /usr/share/omarchy/shell Panel.qml NotificationHistory.qml SettingsView.qml
omarchy plugin validate .
./sync/caldir-export && jq '.source, (.events | length)' ~/.local/state/omarchy/calendar-events.json
```
