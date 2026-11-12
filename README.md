# Omarchy Glance

**Your day at a glance, from the clock.** Glance replaces the Omarchy bar clock
with one panel: a month calendar, the day's agenda from your calendars, and
your recent notifications.

## Install

```bash
omarchy plugin add https://github.com/tiagovicente2/omarchy-glance.git --enable
```

Glance takes the built-in clock's place. Disable or remove it and the stock
clock comes back. Calendars need [caldir](#dependencies).

## Features

- **Agenda**: the selected day's events, with a **Join** button on Google
  Meet, Microsoft Teams and Zoom meetings shortly before they start
- **Next up in the bar**: the clock announces the next event shortly before it
  starts (15 minutes by default)
- **Notifications**: your 30 most recent, grouped by day, with image and
  screen-recording previews. Click one to run its action or focus its app, or
  dismiss them one by one or all at once
- **Unread dot** on the clock when something new arrives
- **Calendar**: month grid with colored dots for days that have events and a
  switchable week start
- **Settings**: hide calendars, hide declined invitations, and show year or
  life progress
- **Keyboard**: `↑` `↓` move through notifications, `←` `→` or `[` `]` change
  month, `t` jumps to today, `w` flips the week start
- Follows the Omarchy theme and language (English and Brazilian Portuguese)

## Dependencies

- [caldir](https://github.com/t4t5/caldir) 0.12 or newer, with a calendar
  connected (`caldir connect google`, `icloud`, `outlook` or `caldav`)
- `python3`, `jq` and `inotify-tools`
- Optional: `ffmpegthumbnailer` or `ffmpeg`, for screen-recording thumbnails

Everything except caldir ships with Omarchy. Install caldir from source,
pinned to the reviewed release:

```bash
cargo install --git https://github.com/t4t5/caldir.git \
  --rev d19547fe02a3635a7281828e32556363cd2fdd8c \
  caldir-cli caldir-provider-google --root "$HOME/.local" --force
```

Swap `caldir-provider-google` for `caldir-provider-icloud`,
`-outlook` or `-caldav` as needed. [renCal](https://github.com/t4t5/rencal) also
installs caldir's providers if you prefer a calendar app.

## Optional

Keep calendars syncing in the background, even with the panel closed. This
installs a systemd user timer that runs `caldir sync` every five minutes:

```bash
~/.config/omarchy/plugins/omarchy-glance/install-helper.sh
```

Open Glance with a key. This example takes `SUPER + V` from Omarchy's
universal paste, so pick another key if you use that. Add to
`~/.config/hypr/bindings.lua`:

```lua
hl.unbind("SUPER + V")
o.bind("SUPER + V", "Glance", "omarchy-shell shell toggle omarchy.clock")
```

## Uninstall

```bash
omarchy plugin remove omarchy-glance
systemctl --user disable --now caldir-sync.timer 2>/dev/null
rm -f ~/.config/systemd/user/caldir-sync.{service,timer}
rm -rf ~/.local/state/omarchy-glance ~/.local/state/omarchy/calendar-events.json
```

## How it works

Glance only reads files: caldir's calendars and Omarchy's notification history.
It never signs in to a calendar provider. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the data flow, files and
known limitations.

## Credits

- [Omarchy](https://github.com/basecamp/omarchy): the built-in clock this
  started from (MIT)
- [tmn73/omarchy-calendar](https://github.com/tmn73/omarchy-calendar): calendar
  event model and interface (MIT)
- [jankeesvw/omarchy-notification-center](https://github.com/jankeesvw/omarchy-notification-center):
  notification history helpers (MIT)
- [caldir](https://github.com/t4t5/caldir): calendar sync and recurrence
  expansion

MIT licensed. See [LICENSE](LICENSE).
