# Omarchy Glance

A user-owned clone of Omarchy's clock/calendar widget with recent notification history integrated into the calendar panel.

## Features

- Keeps Omarchy's clock and centered calendar popup
- Shows the 10 most recent archived notifications on the right
- Opens stored notification actions or focuses the originating app
- Dismisses a notification after activation
- Clears notification history with **Dismiss all**

## Install

```bash
omarchy plugin add https://github.com/tiagovicente2/omarchy-glance.git --enable
```

To open the calendar with `SUPER + V`, add this to `~/.config/hypr/bindings.lua`:

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
qmllint -I /usr/share/omarchy/shell Panel.qml NotificationHistory.qml
omarchy plugin validate .
omarchy restart shell
```

Derived from Omarchy's built-in clock plugin.
