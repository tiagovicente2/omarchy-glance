import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: root

  property var bar: null
  property var notificationService: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color dimForeground: Qt.darker(foreground, 1.4)
  readonly property color borderColor: Style.normalBorderFor(foreground, Color.accent)
  readonly property color hoverColor: Style.hoverFillFor(foreground, Color.accent)
  readonly property int cardRadius: notificationService ? notificationService.cornerRadius : Style.cornerRadius

  readonly property string historyDir: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/notifications/history"
  readonly property string popupDir: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/notifications"
  readonly property string imagesDir: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/notifications/images"
  readonly property string ncImagesDir: (Quickshell.env("HOME") || "") + "/.local/state/omarchy-notification-center/images"

  readonly property string ncBinPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/jankeesvw.notification-center/bin/notification-center"
  readonly property string unreadBinPath: Qt.resolvedUrl("bin/glance-unread").toString().replace(/^file:\/\//, "")

  signal notificationActivated()

  // Arrow keys navigate this list while the panel is open.
  property bool cursorActive: false
  property int cursorIndex: -1

  ListModel { id: historyModel }

  // Persistent unread tracking
  PersistentProperties {
    id: localState
    reloadableId: "omarchy-glance-notifications"
    property double lastSeen: 0
  }

  property double readMark: 0
  property double nowMs: Date.now()

  property bool discardPendingResults: false
  property bool reloadPending: false

  function refresh() {
    discardPendingResults = false
    nowMs = Date.now()
    root.deactivateCursor()

    readMark = Number(localState.lastSeen || 0)
    localState.lastSeen = nowMs
    Quickshell.execDetached(["bash", "-c",
      "unreadbin=\"$1\"; ncbin=\"$2\"; stamp=\"$3\"\n" +
      "[[ -x $unreadbin ]] && \"$unreadbin\" mark-seen \"$stamp\" >/dev/null 2>&1 || true\n" +
      "[[ -x $ncbin ]] && \"$ncbin\" seen \"$stamp\" >/dev/null 2>&1 || true",
      "--", unreadBinPath, ncBinPath, String(nowMs)])
    reload()
  }

  function reload() {
    if (historyLoader.running) {
      reloadPending = true
      return
    }
    historyLoader.command = ["bash", "-c",
      "ncbin=\"$1\"; popup=\"$2\"; hist=\"$3\"\n" +
      "if [[ -x $ncbin ]]; then\n" +
      "  {\n" +
      "    find \"$popup\" -maxdepth 1 -type f -name '*.json' -exec cat {} + 2>/dev/null\n" +
      "    \"$ncbin\" list 30 2>/dev/null\n" +
      "  } | jq -c -s '\n" +
      "    (.[0:-1][]? // empty), (.[-1][]? // empty)\n" +
      "    | select(.key or .timestamp or .id)\n" +
      "  ' 2>/dev/null | jq -c -s '\n" +
      "    unique_by(.key // (.timestamp|tostring))\n" +
      "    | sort_by(.timestamp)\n" +
      "    | reverse\n" +
      "    | .[0:30]\n" +
      "    | .[]\n" +
      "  ' 2>/dev/null\n" +
      "else\n" +
      "  find \"$popup\" \"$hist\" -maxdepth 1 -type f -name '*.json' 2>/dev/null | while read -r f; do\n" +
      "    cat \"$f\" 2>/dev/null; echo \"\"\n" +
      "  done | jq -c -s '\n" +
      "    map(select(.timestamp or .id))\n" +
      "    | sort_by(.timestamp)\n" +
      "    | reverse\n" +
      "    | .[0:30]\n" +
      "    | .[]\n" +
      "  ' 2>/dev/null\n" +
      "fi",
      "--", ncBinPath, popupDir, historyDir]
    historyLoader.running = true
  }

  function replaceHistory(raw) {
    if (discardPendingResults) return
    historyModel.clear()
    var lines = String(raw || "").split("\n")
    var seenKeys = ({})
    for (var i = 0; i < lines.length && historyModel.count < 30; i++) {
      var line = lines[i].trim()
      if (!line) continue
      try {
        var entry = JSON.parse(line)
        var origId = Number(entry.originalId || entry.id || 0)
        var stamp = Number(entry.timestamp || 0)
        if (!stamp && entry.key) {
          stamp = Number(String(entry.key).split("-")[0] || 0)
        }
        var key = String(entry.key || (stamp + "-" + origId))
        if (seenKeys[key]) continue
        seenKeys[key] = true

        var fileSrc = root.extractMediaFilePath(entry.file || entry.execArgv || entry.exec)
        var previewSrc = entry.preview || ""
        if (!previewSrc && fileSrc) {
          if (root.isVideoFile(fileSrc)) {
            previewSrc = "file://" + ncImagesDir + "/" + key + "-preview"
          } else {
            previewSrc = Util.fileUrl(fileSrc)
          }
        }

        historyModel.append({
          key: key,
          id: origId,
          originalId: origId,
          app: String(entry.app || ""),
          appIcon: String(entry.appIcon || ""),
          summary: String(entry.summary || ""),
          body: String(entry.body || ""),
          image: String(entry.image || ""),
          preview: String(previewSrc || ""),
          file: String(fileSrc || ""),
          glyph: String(entry.glyph || ""),
          exec: "",
          urgency: Number(entry.urgency || 1),
          timestamp: stamp,
          day: dayOf(stamp)
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
    localState.lastSeen = Date.now()

    if (notificationService && typeof notificationService.clearHistory === "function") {
      notificationService.clearHistory()
    }
    Quickshell.execDetached(["bash", "-c",
      "ncbin=\"$1\"; popup=\"$2\"; hist=\"$3\"; unreadbin=\"$4\"\n" +
      "[[ -x $ncbin ]] && \"$ncbin\" clear >/dev/null 2>&1 || true\n" +
      "[[ -x $unreadbin ]] && \"$unreadbin\" mark-seen >/dev/null 2>&1 || true\n" +
      "rm -f -- \"$popup\"/*.json \"$hist\"/*.json 2>/dev/null || true",
      "--", ncBinPath, popupDir, historyDir, unreadBinPath])

    historyModel.clear()
    root.deactivateCursor()
  }

  function isFocusableApp(app) {
    var name = String(app || "")
    return name !== "" && name !== "notify-send" && name !== "omarchy-action"
  }

  function isVideoFile(path) {
    return /\.(?:mp4|mkv|webm|mov|avi)$/i.test(String(path || ""))
  }

  function isImageFile(path) {
    return /\.(?:jpe?g|png|webp|gif)$/i.test(String(path || ""))
  }

  function extractMediaFilePath(value) {
    if (!value) return ""
    var items = []
    if (Array.isArray(value)) {
      items = value
    } else {
      var str = String(value).trim()
      if (!str) return ""
      if (str.charAt(0) === "[") {
        try {
          var parsed = JSON.parse(str)
          if (Array.isArray(parsed)) items = parsed
        } catch (_) {}
      }
      if (items.length === 0) {
        items = [str]
      }
    }

    var mediaRegex = /(?:file:\/\/)?(\/[^"'\r\n\0]+\.(?:jpe?g|png|webp|gif|mp4|mkv|webm|mov|avi))(?=$|["'\s])/i
    for (var i = 0; i < items.length; i++) {
      var itemStr = String(items[i] || "").trim()
      if (!itemStr) continue
      var clean = itemStr.replace(/^file:\/\//, "")
      if (/^\/[^"'\r\n\0]+\.(?:jpe?g|png|webp|gif|mp4|mkv|webm|mov|avi)$/i.test(clean)) {
        return clean
      }
      var m = mediaRegex.exec(itemStr)
      if (m && m[1]) return m[1].replace(/^file:\/\//, "")
    }
    return ""
  }

  function appInitial(appName) {
    var name = String(appName || "").trim()
    return name === "" ? "?" : name.charAt(0).toUpperCase()
  }

  function canOpen(entry) {
    return !!entry
  }

  function dismissHistoryEntry(index) {
    if (index < 0 || index >= historyModel.count) return
    var entry = historyModel.get(index)
    if (!entry) return

    var key = String(entry.key || "")
    var origId = String(entry.originalId || entry.id || "")
    var stamp = String(entry.timestamp || "")

    Quickshell.execDetached(["bash", "-c",
      "ncbin=\"$1\"; popup=\"$2\"; hist=\"$3\"; key=\"$4\"; stem=\"$5\"\n" +
      "[[ -x $ncbin ]] && \"$ncbin\" remove \"$key\" >/dev/null 2>&1 || true\n" +
      "rm -f -- \"$popup/$stem.json\" \"$hist/$stem.json\" \"$popup/$key.json\" \"$hist/$key.json\" 2>/dev/null || true",
      "--", ncBinPath, popupDir, historyDir, key, stamp + "-" + origId])

    historyModel.remove(index)
    root.clampCursor()
  }

  function openNotification(index) {
    if (index < 0 || index >= historyModel.count) return
    var entry = historyModel.get(index)
    if (!entry) return

    var filePath = String(entry.file || "")
    if (filePath === "") {
      filePath = extractMediaFilePath(entry.file || entry.execArgv || entry.exec || entry.image)
    }

    // 1. If a media file (image, screenshot, or video recording) is resolved, open directly via xdg-open without a shell
    if (filePath !== "") {
      Quickshell.execDetached(["xdg-open", filePath])
      dismissHistoryEntry(index)
      notificationActivated()
      return
    }

    // 2. Otherwise focus or launch the application safely
    if (isFocusableApp(entry.app)) {
      launchApp(entry.app)
      dismissHistoryEntry(index)
      notificationActivated()
      return
    }

    // 3. System / informational notifications (notify-send, omarchy-action without file, etc.):
    // Clicking acknowledges and dismisses the notification, closing Glance
    dismissHistoryEntry(index)
    notificationActivated()
  }

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

  // Keyboard navigation
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

  function dayOf(timestamp) {
    if (!timestamp || timestamp <= 0) return "Earlier"
    var when = new Date(timestamp)
    var now = new Date(root.nowMs)
    var midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    if (timestamp >= midnight) return "Today"
    if (timestamp >= midnight - 86400000) return "Yesterday"
    if (timestamp >= midnight - 6 * 86400000) return Qt.formatDateTime(when, "dddd")
    if (when.getFullYear() === now.getFullYear()) return Qt.formatDateTime(when, "d MMMM")
    return Qt.formatDateTime(when, "d MMMM yyyy")
  }

  function timeLabel(timestamp) {
    var stamp = Number(timestamp || 0)
    if (!isFinite(stamp) || stamp <= 0) return ""
    var age = Math.max(0, root.nowMs - stamp)
    if (age < 60000) return "now"
    if (age < 3600000) return Math.round(age / 60000) + "m ago"
    return Qt.formatDateTime(new Date(stamp), "HH:mm")
  }

  Timer {
    interval: 30000
    running: root.visible
    repeat: true
    onTriggered: root.nowMs = Date.now()
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

      readonly property real lane: Style.space(8)
      ScrollBar.vertical: ScrollBar {
        id: listScroll
        policy: ScrollBar.AsNeeded
      }

      section.property: "day"
      section.criteria: ViewSection.FullString
      section.delegate: Item {
        id: daySection
        required property string section
        width: notificationList.width - notificationList.lane
        height: dayLabel.implicitHeight + Style.space(12)

        Text {
          id: dayLabel
          anchors.left: parent.left
          anchors.leftMargin: Style.space(2)
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(4)
          text: daySection.section.toUpperCase()
          color: root.dimForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
          font.bold: true
        }
      }

      delegate: BorderSurface {
        id: card

        required property int index
        required property string key
        required property string app
        required property string appIcon
        required property string summary
        required property string body
        required property string image
        required property string preview
        required property string file
        required property string glyph
        required property int urgency
        required property double timestamp
        required property int originalId

        readonly property bool opens: root.canOpen(card)
        readonly property bool selected: root.cursorActive && card.index === root.cursorIndex
        readonly property string bodyText: root.readableBody(body)
        readonly property string resolvedIcon: root.iconSource(image !== "" ? image : appIcon)
        readonly property bool unread: card.timestamp > root.readMark

        readonly property string previewSource: {
          if (card.preview !== "") return card.preview
          if (card.file !== "" && !root.isVideoFile(card.file)) return Util.fileUrl(card.file)
          return ""
        }
        readonly property bool hasPreview: previewSource !== "" && previewImg.status === Image.Ready

        width: notificationList.width - notificationList.lane
        implicitHeight: cardContent.implicitHeight + Style.space(16)
        radius: root.cardRadius

        HoverHandler { id: cardHover }
        readonly property bool hovered: cardHover.hovered

        color: card.selected
          ? Style.selectedFillFor(root.foreground, Color.accent)
          : (cardHover.hovered ? root.hoverColor : "transparent")
        borderSpec: Border.flat(card.selected
          ? Style.selectedBorderFor(root.foreground, Color.accent)
          : root.borderColor, Style.normalBorderWidth)

        // Urgent alert: accent bar on the leading edge
        Rectangle {
          visible: card.urgency === 2
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(6)
          width: Style.space(3)
          radius: width / 2
          color: Color.urgent
        }

        // Unread indicator: accent dot on the leading edge
        Rectangle {
          visible: card.unread && card.urgency !== 2
          anchors.left: parent.left
          anchors.leftMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(5)
          height: width
          radius: width / 2
          color: Color.accent
        }

        MouseArea {
          id: cardMouse
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          enabled: true
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: root.selectCursor(card.index)
          onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) {
              root.dismissHistoryEntry(card.index)
            } else {
              root.openNotification(card.index)
            }
          }
        }

        RowLayout {
          id: cardContent
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.topMargin: Style.space(10)
          anchors.leftMargin: card.borderLeft + Style.space(12)
          anchors.rightMargin: card.borderRight + Style.space(12)
          spacing: Style.space(10)

          // Avatar / App Icon badge
          Item {
            id: avatar
            Layout.preferredWidth: Style.space(32)
            Layout.preferredHeight: Style.space(32)
            Layout.alignment: Qt.AlignTop

            Rectangle {
              anchors.fill: parent
              radius: Style.space(9)
              visible: !avatar.hasIcon
              color: root.foreground
              opacity: 0.12
            }

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              visible: !avatar.hasIcon && card.glyph === ""
              text: (card.summary.indexOf("Screen recording") !== -1 || root.isVideoFile(card.file)) ? "󰻂" : root.appInitial(card.app)
              font.family: root.fontFamily
              font.pixelSize: (card.summary.indexOf("Screen recording") !== -1 || root.isVideoFile(card.file)) ? Style.font.icon : Style.font.caption
              font.bold: true
              color: root.foreground
              opacity: 0.7
            }

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              visible: !avatar.hasIcon && card.glyph !== ""
              text: card.glyph
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
              color: root.foreground
              opacity: 0.8
            }

            Image {
              id: cardIcon
              anchors.fill: parent
              source: card.resolvedIcon
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
              visible: avatar.hasIcon
            }

            readonly property bool hasIcon: card.resolvedIcon !== "" && cardIcon.status !== Image.Error
          }

          // Content column
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)

            // Header row: App Name (left) and Time / Dismiss button (right)
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: card.app !== "" ? card.app : "System"
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: 0.5
              }

              Item {
                Layout.preferredWidth: Math.max(whenText.implicitWidth, Style.space(18))
                Layout.preferredHeight: Math.max(whenText.implicitHeight, Style.space(18))
                Layout.alignment: Qt.AlignVCenter

                Text {
                  id: whenText
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !cardHover.hovered
                  text: root.timeLabel(card.timestamp)
                  color: root.dimForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  opacity: 0.45
                }

                Rectangle {
                  id: dismissBtn
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: cardHover.hovered
                  width: Style.space(18)
                  height: width
                  radius: width / 2
                  color: root.foreground
                  opacity: dismissHover.hovered ? 0.25 : 0.15

                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: "×"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                  }

                  HoverHandler { id: dismissHover }
                  TapHandler {
                    onTapped: root.dismissHistoryEntry(card.index)
                  }
                }
              }
            }

            // Summary / Title
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              visible: card.summary !== ""
              text: card.summary
              font.family: "Liberation Sans"
              font.pixelSize: Style.font.body
              font.bold: true
              color: root.foreground
              elide: Text.ElideRight
              maximumLineCount: 1
            }

            // Body message
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              visible: card.bodyText !== ""
              text: card.bodyText
              wrapMode: Text.WordWrap
              elide: Text.ElideRight
              maximumLineCount: 2
              font.family: "Liberation Sans"
              font.pixelSize: Style.font.caption
              color: root.foreground
              opacity: 0.75
            }

            // Preview image
            Item {
              id: previewBox
              Layout.fillWidth: true
              Layout.topMargin: Style.space(4)
              Layout.preferredHeight: card.hasPreview && width > 0 ? Math.min(width * 9 / 16, Style.space(104)) : 0
              visible: card.hasPreview
              clip: true

              Image {
                id: previewImg
                anchors.fill: parent
                source: card.previewSource
                sourceSize.width: Math.round(Math.max(1, width) * Screen.devicePixelRatio)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true

                layer.enabled: true
                layer.effect: MultiEffect {
                  maskEnabled: true
                  maskSource: previewMask
                  maskThresholdMin: 0.5
                  maskSpreadAtMin: 1.0
                }
              }

              Rectangle {
                id: previewMask
                anchors.fill: parent
                radius: Style.space(8)
                color: "black"
                visible: false
                layer.enabled: true
                layer.smooth: true
              }
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
