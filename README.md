# Omarchy Glance

A centered Omarchy clock panel that combines a calendar, a renCal/Caldir agenda, and recent notification history.

## Features

- Keeps Omarchy's clock and centered calendar popup
- Shows colored event dots and a selectable daily agenda
- Announces the next event beside the clock near its start time
- Opens allowlisted Google Meet, Microsoft Teams, and Zoom links
- Shows the 10 most recent archived notifications on the right
- Opens stored notification actions or focuses the originating app
- Dismisses notifications after activation and supports **Dismiss all**

## Calendar architecture

Glance does not connect to Google, Microsoft, CalDAV, or any other provider.
renCal owns provider authentication and synchronization, while Caldir keeps the
result as standard RFC5545 files on disk:

```text
provider → renCal/Caldir → <caldir>/<calendar>/*.ics
                         → caldir --json events + UID/URL property lookup
                         → ~/.local/state/omarchy/calendar-events.json
                         → Omarchy Glance
```

The bundled `sync/caldir-export` adapter runs on shell startup, whenever the
panel opens, and every five minutes. It reads the Caldir location from
`${XDG_CONFIG_HOME:-~/.config}/caldir/config.toml`, asks the official `caldir`
CLI to expand recurrences and timezone overrides, and atomically writes
Glance's local JSON view. A shared nonblocking lock prevents multiple monitor
panels from launching duplicate exports.

Caldir's JSON can omit a conference URL stored only in an event's standard
`URL`/`CONFERENCE` property. The adapter therefore unfolds and scans only
those recognized properties plus `UID` in top-level
`<caldir>/<calendar>/*.ics` files, then attaches an allowlisted HTTPS
Meet/Teams/Zoom URL by Caldir's raw `(calendar, uid)`. It does not parse dates,
expand recurrence, read descriptions, read provider credentials, or modify
`.ics` files.

## Requirements

- Omarchy with the Quickshell bar
- [renCal](https://github.com/t4t5/rencal) configured with at least one calendar
- [Caldir](https://github.com/t4t5/caldir) CLI with JSON event output
- Python 3.11 or newer (`tomllib` is used by the stdlib-only adapter)

At the time of writing, `caldir --json events` is on Caldir `main` after the
v0.11.1 release. Install that official source build with:

```bash
cargo install --git https://github.com/t4t5/caldir.git \
  caldir-cli --bin caldir --root "$HOME/.local" --force
```

Confirm both the binary and local data are available:

```bash
caldir --version
caldir --json events --from "$(date -I)" --to "$(date -I -d '+30 days')" | jq
```

## Install

```bash
omarchy plugin add https://github.com/tiagovicente2/omarchy-glance.git --enable
~/.config/omarchy/plugins/omarchy-glance/setup/center-anchor
jq -e '.bar.centerAnchor == "omarchy-glance"' ~/.config/omarchy/shell.json
```

The helper changes only `bar.centerAnchor` and atomically preserves every
other `shell.json` setting. It refuses malformed JSON rather than replacing
it. With a custom `XDG_CONFIG_HOME`, use the corresponding plugin and config
paths.

Connect and sync providers in renCal. Glance automatically reads the same
Caldir configured by renCal; no additional OAuth or Google Cloud setup exists.

To open Glance with `SUPER + V`, add this to `~/.config/hypr/bindings.lua`:

```lua
hl.unbind("SUPER + V")
o.bind("SUPER + V", "Toggle calendar", "omarchy-shell shell toggle omarchy.clock")
```

Then validate Hyprland:

```bash
hyprctl reload
hyprctl configerrors
```

## Development

```bash
python3 -m unittest discover -s tests -v
node --test tests/model.test.js
qmllint -I /usr/share/omarchy/shell Panel.qml NotificationHistory.qml SettingsView.qml
omarchy plugin validate .
git diff --check
jq -e '.bar.centerAnchor == "omarchy-glance"' "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
```

Run the adapter directly:

```bash
./sync/caldir-export
jq '.source, (.events | length)' ~/.local/state/omarchy/calendar-events.json
```

## Known limitations

- Conference recovery intentionally ignores nested ICS files, descriptions,
  arbitrary `X-*` properties, non-HTTPS URLs, and hosts outside the explicit
  Meet/Teams/Zoom allowlist. This keeps the fallback narrow and safe.
- Caldir JSON does not currently expose generic event deep links or event
  types. Agenda rows therefore open only an available safe **Join** link; no
  working-location/out-of-office filter is advertised.
- The packaged Omarchy notification service owns a history-write queue. An
  already queued archive can land after **Dismiss all**; Glance does not patch
  that service, and the entry may appear on a later refresh.

## Attribution

- Calendar event model and interface adapted from
  [tmn73/omarchy-calendar](https://github.com/tmn73/omarchy-calendar) (MIT)
- Clock/calendar base derived from
  [Omarchy](https://github.com/basecamp/omarchy) (MIT)
- Calendar data and recurrence expansion provided by
  [renCal](https://github.com/t4t5/rencal) and
  [Caldir](https://github.com/t4t5/caldir)
