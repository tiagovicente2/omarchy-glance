import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Date/time label for the bar, and the host for the calendar popup.
//
// Left click reveals the calendar — asking "what is the date?" is what a
// click on a clock means — right click walks the common label formats, and
// middle click opens the timezone picker.
BarWidget {
  id: root
  moduleName: "omarchy.clock"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property date displayDate: clock.date

  readonly property string configuredFormat: vertical
    ? setting("verticalFormat", "HH\n—\nmm")
    : setting("format", "dddd HH:mm")
  readonly property string configuredAltFormat: vertical
    ? setting("verticalFormatAlt", "dd\nMMM\n'W'ww\n''yy")
    : setting("formatAlt", "d MMMM 'W'ww yyyy")

  readonly property var formatRing: Model.clockFormatRing(configuredFormat, configuredAltFormat, Model.clockFormats(vertical))

  // What the bar shows is what shell.json stores, so a cycled format is the
  // format from then on rather than something that reverts on restart.
  readonly property string activeFormat: configuredFormat

  // A seconds label needs the clock to tick sixty times as often, and a
  // repaint a second is a price only the formats that print seconds pay.
  readonly property bool showsSeconds: Model.clockNeedsSeconds(activeFormat)

  // ---- The next thing coming up. The panel owns the file and the calendar
  //      filtering; the bar just reads the already-filtered list off it. The
  //      panel Loader is active even while closed, so this keeps counting
  //      whether or not anyone has opened the calendar.
  //
  //      displayDate is driven by WallClock at minute precision, which is
  //      exactly the granularity a "in 10 min" countdown needs. No extra timer.
  readonly property var visibleEventList: panelLoader.item ? panelLoader.item.visibleEventList : []
  readonly property real nowMs: displayDate.getTime()

  readonly property int announceLeadMinutes: setting("announceLeadMinutes", 15)
  readonly property var upcomingEvent: Model.nextEvent(visibleEventList, nowMs)
  readonly property bool announcing: announceLeadMinutes > 0
    && Model.shouldAnnounce(upcomingEvent, nowMs, announceLeadMinutes)

  // Built inside the binding so a language switch re-renders it.
  readonly property string countdownPhrase: announcing
    ? Model.countdownText(Model.formatCountdown(Model.millisUntil(upcomingEvent, nowMs)), strings, Commons.I18n)
    : ""

  // The clock stays. This widget replaces the desktop's clock, so trading the
  // time away for a title would be a downgrade the rest of the day pays for.
  //
  // A vertical bar is left as a clock: it is a narrow column of stacked
  // lines, and an event title has nowhere to go in it.
  readonly property string displayText: vertical || countdownPhrase === ""
    ? formatted(displayDate)
    : Model.announceLabel(formatted(displayDate), upcomingEvent.title, countdownPhrase)
  readonly property var verticalLines: displayText.split("\n")

  function refresh() {
    displayDate = new Date()
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function cycleFormat() {
    var current = String(configuredFormat)
    var next = Model.nextClockFormat(formatRing, current)
    if (next === "" || next === current) return

    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry[vertical ? "verticalFormat" : "format"] = next

    // Applied locally first so the label changes on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Qt has no ISO week token, so the week goes in as a quoted literal, and
  // Qt prints literals as they are: each digit is mapped to the language's
  // own digits first, as stock Omarchy's clock does.
  function formatted(date) {
    var week = Model.isoWeekLiteral(date.getFullYear(), date.getMonth(), date.getDate())
    week = week.split("").map(function(digit) { return Commons.I18n.formatNumber(digit) }).join("")
    return Qt.locale(I18n.formatLocale).toString(date, activeFormat.replace(/ww/g, week))
  }

  // ---- Calendar popup. Shape contract for shell.summon/hide/toggle
  //      routing: Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  onOpenedChanged: {
    if (root.opened) root.markSeen()
    else root.checkUnread()
  }

  function open() {
    root.markSeen()
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (!root.opened) root.markSeen()
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function toggleWeekStart() {
    if (panelLoader.item) panelLoader.item.toggleWeekStart()
  }

  // The clock fills more slot than it paints a mark for, at both
  // orientations: horizontally it is a text label in a padded slot, so the
  // dot takes the label width; vertically it is a stack of icon-sized lines,
  // so the dot takes one line — the same mark every icon widget gets, rather
  // than a rule running the height of the whole stack.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("moduleName" in target) target.moduleName = root.moduleName
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    // The bar injects bar and then settings in one pass, so by the next turn
    // of the event loop after the bar arrives the settings are real. Until
    // then setting() answers with fallbacks, and a first export started from
    // those would pull even for someone who turned sync off.
    if (root.bar && "settingsReady" in target && !target.settingsReady)
      Qt.callLater(root.markPanelSettingsReady)
  }

  function markPanelSettingsReady() {
    var target = panelLoader.item
    if (target && root.bar && "settingsReady" in target) target.settingsReady = true
  }

  // ---- One instance per shell leads. Every monitor's bar builds its own
  //      copy of this widget, and only one of them should run the
  //      notification watcher and the exporter timer. ShellIpc already
  //      elects the first live copy of a target and hands over when it
  //      goes, so the lead follows that election; the others read the
  //      shared state the leader pushes to them.
  readonly property bool leads: clockIpc.enabled

  function peers() {
    var items = root.bar && typeof root.bar.moduleWidgets === "function"
      ? root.bar.moduleWidgets(root.moduleName) : []
    var out = []
    for (var i = 0; i < items.length; i++)
      if (items[i] && items[i] !== root) out.push(items[i])
    return out
  }

  // The exporter outcome is the same for every monitor, whichever panel ran it.
  function shareExportOutcome(outcome) {
    var others = root.peers()
    for (var i = 0; i < others.length; i++)
      if (typeof others[i].receiveExportOutcome === "function") others[i].receiveExportOutcome(outcome)
  }

  function receiveExportOutcome(outcome) {
    if (panelLoader.item && typeof panelLoader.item.applyExportOutcome === "function")
      panelLoader.item.applyExportOutcome(outcome)
  }

  function setUnreadCount(count) {
    root.unreadCount = count
  }

  function notificationsChanged() {
    if (root.opened && panelLoader.item && typeof panelLoader.item.refreshNotifications === "function")
      panelLoader.item.refreshNotifications()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: {
    injectPanel()
    // A copy that does not lead asks the leader once it can see its peers.
    Qt.callLater(root.checkUnread)
  }
  onSettingsChanged: injectPanel()

  WallClock {
    id: clock
    step: root.showsSeconds ? 1000 : 60000
    onDateChanged: root.displayDate = date
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  ShellIpc {
    id: clockIpc
    target: "omarchy.clock"

    function refresh(): void { root.broadcast("refresh") }
    function cycleFormat(): void { root.cycleFormat() }
    function toggleWeekStart(): void { root.toggleWeekStart() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  property int unreadCount: 0

  readonly property string unreadScript:
    Qt.resolvedUrl("bin/glance-unread").toString().replace(/^file:\/\//, "")

  // Only the leader counts; it pushes the result to every other copy.
  function checkUnread() {
    if (!root.leads) {
      var others = root.peers()
      for (var i = 0; i < others.length; i++)
        if (others[i].leads && typeof others[i].checkUnread === "function") others[i].checkUnread()
      return
    }
    if (unreadProc.running) return
    unreadProc.command = [unreadScript, "unread"]
    unreadProc.running = true
  }

  function markSeen() {
    root.unreadCount = 0
    if (markSeenProc.running) return
    markSeenProc.command = [unreadScript, "mark-seen"]
    markSeenProc.running = true
  }

  Process {
    id: unreadProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data && data.ok === true) {
            var count = Math.max(0, Math.floor(Number(data.unread) || 0))
            root.unreadCount = count
            var others = root.peers()
            for (var i = 0; i < others.length; i++)
              if (typeof others[i].setUnreadCount === "function") others[i].setUnreadCount(count)
          }
        } catch (e) {}
      }
    }
  }

  Process {
    id: markSeenProc
  }

  // The watcher reports every change (inotify, or its own five-second poll
  // when inotifywait is missing), so no timer is needed while it runs.
  // Cleared when the watcher exits and set again by restartWatch, so
  // `running` stays a binding and a copy that stops leading stops watching.
  property bool watchArmed: true

  Process {
    id: watchProc
    command: [root.unreadScript, "watch"]
    running: root.leads && root.watchArmed
    stdout: SplitParser {
      onRead: function(line) {
        root.checkUnread()
        root.notificationsChanged()
        var others = root.peers()
        for (var i = 0; i < others.length; i++)
          if (typeof others[i].notificationsChanged === "function") others[i].notificationsChanged()
      }
    }
    onExited: {
      root.watchArmed = false
      restartWatch.restart()
    }
  }

  Timer {
    id: restartWatch
    interval: 5000
    onTriggered: root.watchArmed = true
  }

  // Only while the watcher is down (between a crash and its restart).
  Timer {
    interval: 10000
    running: root.leads && !watchProc.running
    repeat: true
    onTriggered: root.checkUnread()
  }

  onLeadsChanged: if (root.leads) root.checkUnread()

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: root.unreadCount > 0 && !root.vertical ? 18 : 8.75
    verticalPadding: 8.75
    tooltipText: root.unreadCount > 0
      ? strings.tn("bar.newNotifications", root.unreadCount).arg(Commons.I18n.formatNumber(root.unreadCount))
      : strings.t("bar.toggleFormatHint")

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleFormat()
      else if (b === Qt.MiddleButton) { if (root.bar) root.bar.run("omarchy-menu-timezone") }
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3
            ? button.fontSize * 0.9
            : button.fontSize
          color: button.foreground
        }
      }
    }
  }

  Rectangle {
    id: unreadDot
    visible: opacity > 0
    opacity: (root.unreadCount > 0 && !root.opened) ? 1 : 0
    anchors.right: button.right
    anchors.rightMargin: Style.space(5)
    anchors.verticalCenter: button.verticalCenter
    width: Style.space(6)
    height: width
    radius: width / 2
    color: Color.accent
    z: 2

    Behavior on opacity {
      NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
    }
  }
}
