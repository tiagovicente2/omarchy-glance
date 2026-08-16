import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: root

  property var notificationService: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color dimForeground: Qt.darker(foreground, 1.4)
  readonly property color borderColor: Style.normalBorderFor(foreground, Color.accent)
  readonly property color hoverColor: Style.hoverFillFor(foreground, Color.accent)
  readonly property int cardRadius: notificationService ? notificationService.cornerRadius : Style.cornerRadius
  readonly property string historyDir: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/notifications/history"
  readonly property string imagesDir: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/notifications/images"

  signal notificationActivated()

  // Arrow keys always navigate this list while the panel is open — no hover
  // required. Left/Right still drive the calendar on the other side; today's
  // grid can always be reached with the 't' key or a click, and the '[' ']'
  // '{' '}' text keys keep stepping months and years.
  property bool cursorActive: false
  property int cursorIndex: -1

  ListModel { id: historyModel }

  // Clearing history is asynchronous in the first-party service. Ignore any
  // read already in flight until the panel is opened again, otherwise stale
  // output can repopulate rows immediately after "Dismiss all".
  property bool discardPendingResults: false

  function refresh() {
    discardPendingResults = false
    root.deactivateCursor()
    reload()
  }

  function reload() {
    if (historyLoader.running) {
      reloadPending = true
      return
    }
    historyLoader.command = ["bash", "-c",
      "find \"$1\" -maxdepth 1 -type f -name '*.json' -printf '%f\\n' 2>/dev/null | sort -rn | head -n 10 | while IFS= read -r file; do cat \"$1/$file\"; done",
      "--", historyDir]
    historyLoader.running = true
  }

  property bool reloadPending: false

  function replaceHistory(raw) {
    if (discardPendingResults) return
    historyModel.clear()
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length && historyModel.count < 10; i++) {
      var line = lines[i].trim()
      if (!line) continue
      try {
        var entry = JSON.parse(line)
        historyModel.append({
          id: Number(entry.id || 0),
          originalId: Number(entry.originalId || entry.id || 0),
          app: String(entry.app || ""),
          appIcon: String(entry.appIcon || ""),
          summary: String(entry.summary || ""),
          body: String(entry.body || ""),
          image: String(entry.image || ""),
          glyph: String(entry.glyph || ""),
          exec: String(entry.exec || ""),
          urgency: Number(entry.urgency || 0),
          timestamp: Number(entry.timestamp || 0)
        })
      } catch (error) {
        console.warn("clock notifications: invalid history entry:", error)
      }
    }
    root.clampCursor()
  }

  function dismissAll() {
    discardPendingResults = true
    reloadPending = false
    if (notificationService && typeof notificationService.clearHistory === "function")
      notificationService.clearHistory()
    historyModel.clear()
    root.deactivateCursor()
  }

  function isFocusableApp(app) {
    var name = String(app || "")
    return name !== "" && name !== "notify-send" && name !== "omarchy-action"
  }

  function canOpen(entry) {
    if (!entry) return false
    if (String(entry.exec || "") !== "") return true
    return isFocusableApp(entry.app)
  }

  function dismissHistoryEntry(index) {
    if (index < 0 || index >= historyModel.count) return
    var entry = historyModel.get(index)
    var stem = String(entry.timestamp || 0) + "-" + String(entry.originalId || 0)
    Quickshell.execDetached(["bash", "-c",
      "rm -f -- \"$1/$3.json\" \"$2/$3\"-*",
      "--", historyDir, imagesDir, stem])
    historyModel.remove(index)
    root.clampCursor()
  }

  function openNotification(index) {
    if (index < 0 || index >= historyModel.count) return
    var entry = historyModel.get(index)
    if (!canOpen(entry)) return

    var command = String(entry.exec || "")
    if (command !== "") {
      Util.execDetached(command)
    } else {
      launchApp(entry.app)
    }
    dismissHistoryEntry(index)
    notificationActivated()
  }

  // Launch-or-focus a notification's sender. The notification service's own
  // focusApp only focuses a window that already exists, which makes clicking
  // a history entry for a closed app do nothing. Resolve the sender's desktop
  // file instead: focus a matching window when one is open, otherwise launch
  // the app (uwsm-app runs the desktop entry through the session manager, the
  // same path omarchy's own launch-or-focus helpers use).
  function launchApp(appName) {
    if (launchProc.running) return
    launchProc.command = ["bash", "-c", root.launchOrFocusScript, "--", String(appName || "")]
    launchProc.running = true
  }

  readonly property string launchOrFocusScript:
    "app=$1\n" +
    "desktop=\n" +
    "for dir in \"$HOME/.local/share/applications\" \"$HOME/.nix-profile/share/applications\" \"/usr/local/share/applications\" \"/usr/share/applications\"; do\n" +
    "  for file in \"$dir\"/*.desktop; do\n" +
    "    [[ -f $file ]] || continue\n" +
    "    if [[ $(basename \"$file\" .desktop) == \"$app\" ]] || grep -m1 -qi \"^Name=$app$\" \"$file\"; then desktop=\"$file\"; break 2; fi\n" +
    "  done\n" +
    "done\n" +
    "if [[ -z $desktop ]]; then\n" +
    "  omarchy-hyprland-focus-app \"$app\"\n" +
    "  exit 0\n" +
    "fi\n" +
    "id=$(basename \"$desktop\" .desktop)\n" +
    "wmclass=$(sed -n 's/^StartupWMClass=//p' \"$desktop\" | head -n1)\n" +
    "pattern=$(printf '%s|%s|%s' \"$id\" \"$wmclass\" \"$app\")\n" +
    "address=$(hyprctl clients -j 2>/dev/null | jq -r --arg p \"$pattern\" 'first(.[] | select((.class // \"\") | test($p; \"i\"))).address // empty')\n" +
    "if [[ -n $address ]]; then\n" +
    "  hyprctl dispatch \"hl.dsp.focus({ window = \\\"address:$address\\\" })\" >/dev/null 2>&1 || \\\n" +
    "    hyprctl dispatch focuswindow \"address:$address\" >/dev/null\n" +
    "else\n" +
    "  setsid uwsm-app -- \"$id.desktop\" >/dev/null 2>&1 &\n" +
    "fi"

  Process {
    id: launchProc
    running: false
  }

  // ---- Keyboard cursor. Selection only ever lands on an openable entry, so
  //      Enter always has something to act on, and the pointer places the
  //      cursor on whatever card it is hovering — Enter opens exactly what
  //      is pointed at.

  function activateCursor() {
    if (historyModel.count === 0) return
    cursorActive = true
    clampCursor()
    if (cursorIndex < 0) cursorIndex = nextOpenable(-1, 1)
    positionCursor()
  }

  function selectCursor(index) {
    if (!canOpenAt(index)) return
    cursorActive = true
    cursorIndex = index
    positionCursor()
  }

  function deactivateCursor() {
    cursorActive = false
    cursorIndex = -1
  }

  function moveCursor(delta) {
    if (historyModel.count === 0) return
    cursorActive = true
    var from = cursorIndex >= 0 && cursorIndex < historyModel.count
      ? cursorIndex
      : (delta > 0 ? -1 : historyModel.count)
    var next = nextOpenable(from, delta)
    if (next >= 0) cursorIndex = next
    positionCursor()
  }

  // True when the cursor opened something; false when the panel should fall
  // back to its own default (focussing today) instead. Enter engages the
  // cursor first, so a bare Enter opens the most recent openable
  // notification without any arrowing.
  function handleActivate() {
    activateCursor()
    if (cursorIndex < 0) return false
    openCursor()
    return true
  }

  function openCursor() {
    var index = cursorIndex
    deactivateCursor()
    openNotification(index)
  }

  function nextOpenable(from, step) {
    var stride = step > 0 ? 1 : -1
    for (var i = from + stride; i >= 0 && i < historyModel.count; i += stride)
      if (canOpenAt(i)) return i
    return -1
  }

  function canOpenAt(index) {
    return index >= 0 && index < historyModel.count && canOpen(historyModel.get(index))
  }

  function clampCursor() {
    if (historyModel.count === 0 || !cursorActive) {
      cursorIndex = -1
      return
    }
    if (canOpenAt(cursorIndex)) return
    cursorIndex = nextOpenable(-1, 1)
    if (cursorIndex < 0) cursorIndex = nextOpenable(historyModel.count, -1)
  }

  function positionCursor() {
    if (cursorActive && cursorIndex >= 0 && cursorIndex < historyModel.count)
      notificationList.positionViewAtIndex(cursorIndex, ListView.Contain)
  }

  function iconSource(value) {
    var icon = String(value || "")
    if (icon === "") return ""
    if (icon.indexOf("file://") === 0 || icon.indexOf("image://") === 0) return icon
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    return Quickshell.iconPath(icon, true)
  }

  function readableBody(value) {
    return String(value || "")
      .replace(/<img[^>]*>/gi, "")
      .replace(/<br\s*\/?\s*>/gi, "\n")
      .replace(/<[^>]+>/g, "")
      .trim()
  }

  function timeLabel(value) {
    var timestamp = Number(value || 0)
    if (!isFinite(timestamp) || timestamp <= 0) return ""
    var date = new Date(timestamp)
    var now = new Date()
    if (date.getFullYear() === now.getFullYear()
        && date.getMonth() === now.getMonth()
        && date.getDate() === now.getDate())
      return Qt.formatTime(date, "HH:mm")
    return Qt.formatDate(date, "MMM d")
  }

  Process {
    id: historyLoader
    running: false
    onExited: {
      if (!root.reloadPending || root.discardPendingResults) return
      root.reloadPending = false
      Qt.callLater(root.reload)
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.replaceHistory(text)
    }
  }

  Component.onCompleted: refresh()

  ColumnLayout {
    anchors.fill: parent
    spacing: Style.space(10)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      Text {
        Layout.fillWidth: true
        text: "Recent notifications"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }

      BorderSurface {
        visible: historyModel.count > 0
        Layout.preferredWidth: dismissLabel.implicitWidth + Style.space(16)
        Layout.preferredHeight: Math.max(Style.space(26), dismissLabel.implicitHeight + Style.space(8))
        radius: Math.min(Style.space(6), root.cardRadius)
        color: dismissMouse.containsMouse ? root.hoverColor : "transparent"
        borderSpec: Border.flat(root.borderColor, Style.normalBorderWidth)

        Text {
          id: dismissLabel
          anchors.centerIn: parent
          text: "Dismiss all"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: dismissMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.dismissAll()
        }
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Style.spacing.hairline
      color: root.borderColor
      opacity: 0.55
    }

    ListView {
      id: notificationList
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      spacing: Style.space(8)
      model: historyModel
      visible: count > 0
      boundsBehavior: Flickable.StopAtBounds

      delegate: BorderSurface {
        id: card

        required property int index
        required property string app
        required property string appIcon
        required property string summary
        required property string body
        required property string image
        required property string glyph
        required property string exec
        required property int urgency
        required property double timestamp
        required property int originalId

        readonly property bool opens: root.canOpen(card)
        readonly property bool selected: root.cursorActive && card.index === root.cursorIndex
        readonly property string bodyText: root.readableBody(body)
        readonly property string resolvedIcon: root.iconSource(image !== "" ? image : appIcon)

        width: notificationList.width
        implicitHeight: cardContent.implicitHeight + Style.space(20)
        radius: root.cardRadius
        color: card.selected
          ? Style.selectedFillFor(root.foreground, Color.accent)
          : (opens && cardMouse.containsMouse ? root.hoverColor : "transparent")
        borderSpec: Border.flat(card.selected
          ? Style.selectedBorderFor(root.foreground, Color.accent)
          : root.borderColor, Style.normalBorderWidth)

        MouseArea {
          id: cardMouse
          anchors.fill: parent
          enabled: card.opens
          hoverEnabled: true
          cursorShape: card.opens ? Qt.PointingHandCursor : Qt.ArrowCursor
          onEntered: root.selectCursor(card.index)
          onClicked: root.openNotification(card.index)
        }

        RowLayout {
          id: cardContent
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: card.borderLeft + Style.space(10)
          anchors.rightMargin: card.borderRight + Style.space(10)
          spacing: Style.space(10)

          Item {
            Layout.preferredWidth: Style.space(34)
            Layout.preferredHeight: Style.space(34)
            Layout.alignment: Qt.AlignTop

            Image {
              id: cardIcon
              anchors.fill: parent
              source: card.resolvedIcon
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
              visible: source !== "" && status !== Image.Error
            }

            Text {
              anchors.centerIn: parent
              visible: !cardIcon.visible && card.glyph !== ""
              text: card.glyph
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
            }

            Text {
              anchors.centerIn: parent
              visible: !cardIcon.visible && card.glyph === ""
              text: "󰂚"
              color: root.dimForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                Layout.fillWidth: true
                text: card.summary !== "" ? card.summary : card.app
                textFormat: Text.PlainText
                color: root.foreground
                font.family: "Liberation Sans"
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
                maximumLineCount: 1
              }

              Text {
                text: root.timeLabel(card.timestamp)
                color: root.dimForeground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              Layout.fillWidth: true
              visible: card.bodyText !== ""
              text: card.bodyText
              textFormat: Text.PlainText
              color: root.dimForeground
              font.family: "Liberation Sans"
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              elide: Text.ElideRight
              maximumLineCount: 2
            }

            Text {
              Layout.fillWidth: true
              visible: !card.opens && card.app !== ""
              text: card.app
              textFormat: Text.PlainText
              color: Qt.darker(root.dimForeground, 1.2)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }
    }

    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
      visible: historyModel.count === 0

      ColumnLayout {
        anchors.centerIn: parent
        spacing: Style.space(6)

        Text {
          Layout.alignment: Qt.AlignHCenter
          text: "󰂚"
          color: root.borderColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
        }

        Text {
          Layout.alignment: Qt.AlignHCenter
          text: "No recent notifications"
          color: root.dimForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
