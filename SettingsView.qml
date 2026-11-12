import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The calendar's settings page, shown in place of the month grid.
//
// Kept in its own file rather than folded into Panel.qml: the panel is
// already long, and everything here is presentation over values the panel
// owns. This component reads state and emits intent, it never writes
// shell.json itself.
Column {
  id: root

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property color foreground: "white"
  property string fontFamily: ""

  property var calendars: []
  property var hiddenCalendars: []
  property bool showYearProgress: false
  property bool weekStartsMonday: true
  property bool hideDeclined: false
  property bool syncCalendars: true
  property int announceLeadMinutes: 15

  property string syncedAt: ""
  property string sourceLabel: ""
  property int eventCount: 0
  property string syncState: "missing"
  property string exportError: ""
  property bool pullFailed: false

  signal calendarToggled(string calendarId)
  signal yearProgressToggled()
  signal weekStartToggled()
  signal hideDeclinedToggled()
  signal syncCalendarsToggled()
  signal leadMinutesPicked(int minutes)

  readonly property color muted: Qt.darker(foreground, 1.5)
  readonly property color faint: Qt.darker(foreground, 1.9)

  spacing: Style.space(10)

  component SectionTitle: Text {
    color: root.faint
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
    font.bold: true
  }

  // A row that reads as a switch without pulling in a control library the
  // rest of this plugin does not use.
  component ToggleRow: Rectangle {
    id: toggle

    property string label: ""
    property string hint: ""
    property bool checked: false
    property color swatch: "transparent"

    signal activated()

    width: parent ? parent.width : 0
    height: toggleBody.height + Style.space(6)
    radius: Style.cornerRadius
    color: hovered.hovered
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
      : "transparent"

    HoverHandler { id: hovered }
    TapHandler { onTapped: toggle.activated() }

    Row {
      id: toggleBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(3)
      anchors.rightMargin: Style.space(3)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(14)
        text: toggle.checked ? "✓" : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: toggle.swatch != "transparent"
        width: Style.space(4)
        height: width
        radius: width / 2
        color: toggle.checked ? toggle.swatch : "transparent"
        border.width: Style.spacing.hairline
        border.color: toggle.swatch
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: toggleBody.width - Style.space(26)
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: toggle.label
          textFormat: Text.PlainText
          color: toggle.checked ? root.foreground : root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: toggle.hint !== ""
          text: toggle.hint
          textFormat: Text.PlainText
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  // ---- Calendars

  SectionTitle { text: strings.t("settings.calendars") }

  Text {
    width: parent.width
    visible: root.calendars.length === 0
    text: strings.t("settings.noCalendars")
    color: root.faint
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Repeater {
    model: root.calendars

    ToggleRow {
      required property var modelData

      label: modelData.name
      swatch: modelData.color
      checked: root.hiddenCalendars.indexOf(modelData.id) === -1
      onActivated: root.calendarToggled(modelData.id)
    }
  }

  // ---- Display

  SectionTitle { text: strings.t("settings.display") }

  ToggleRow {
    label: strings.t("settings.weekStartsMonday")
    hint: strings.t("settings.weekStartsMondayHint")
    checked: root.weekStartsMonday
    onActivated: root.weekStartToggled()
  }

  ToggleRow {
    // Every row on this page reads "checked means shown". Phrasing this one as
    // "Hide ..." inverted that and made the page contradict itself.
    label: strings.t("settings.declinedInvitations")
    hint: strings.t("settings.declinedInvitationsHint")
    checked: !root.hideDeclined
    onActivated: root.hideDeclinedToggled()
  }

  ToggleRow {
    label: strings.t("settings.yearLifeProgress")
    hint: strings.t("settings.yearLifeProgressHint")
    checked: root.showYearProgress
    onActivated: root.yearProgressToggled()
  }

  // ---- Bar

  SectionTitle { text: strings.t("settings.barLabel") }

  Text {
    width: parent.width
    text: strings.t("settings.barLabelHint")
    color: root.faint
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  Row {
    spacing: Style.space(3)

    Repeater {
      model: [0, 5, 15, 30, 60]

      Rectangle {
        required property var modelData

        readonly property bool active: modelData === root.announceLeadMinutes

        width: leadLabel.width + Style.space(8)
        height: leadLabel.height + Style.space(4)
        radius: height / 2
        color: active
          ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
          : "transparent"
        border.width: Style.spacing.hairline
        border.color: active ? root.muted : Qt.darker(root.foreground, 2.4)

        Text {
          id: leadLabel
          anchors.centerIn: parent
          text: modelData === 0 ? strings.t("settings.never") : strings.t("settings.leadMinutes").arg(Commons.I18n.formatNumber(modelData))
          color: active ? root.foreground : root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        TapHandler { onTapped: root.leadMinutesPicked(modelData) }
      }
    }
  }

  // ---- Sync status. Caldir owns providers and OAuth; Glance only reads the
  //      local Caldir export produced by the bundled adapter.

  SectionTitle { text: strings.t("settings.sync") }

  ToggleRow {
    label: strings.t("settings.syncCalendars")
    hint: strings.t("settings.syncCalendarsHint")
    checked: root.syncCalendars
    onActivated: root.syncCalendarsToggled()
  }

  Text {
    width: parent.width
    color: root.faint
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText

    text: {
      if (root.exportError !== "")
        return strings.t(root.pullFailed ? "settings.pullFailed" : "settings.exportFailed").arg(root.exportError)
      if (root.syncState === "missing") return strings.t("settings.syncMissing")
      if (root.syncState === "version") return strings.t("settings.syncVersion")

      var line = strings.tn("settings.eventRows", root.eventCount)
        .arg(Commons.I18n.formatNumber(root.eventCount))
        .arg(root.sourceLabel)
      if (root.syncState === "stale") return line + "\n" + strings.t("settings.syncStale")
      return line + "\n" + strings.t("settings.lastExport").arg(root.syncedAt)
    }
  }
}
