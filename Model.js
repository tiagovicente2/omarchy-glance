// Pure date and format math for the clock widget and its calendar panel.
// Everything here is locale- and Qt-free so it can be unit tested under node
// (node --test tests/model.test.js); the QML owns month/weekday naming
// through Qt.locale() and every displayed string through its i18n catalogs.

var MS_PER_DAY = 86400000

// Weekday indices match both JS Date.getDay() and QML's Locale.Sunday…
// Locale.Saturday, so a locale's firstDayOfWeek can be passed straight in.
var WEEKDAY_NAMES = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

// ---- Bar label formats. Right-clicking the clock walks these in order and
//      writes the result back to shell.json, so the label the bar shows and
//      the format the config stores are always the same thing.
//
// The locale-shaped time presets are each followed by their 12-hour twin, so
// the walk from a 24-hour label to the same label in AM/PM is a single right
// click rather than a lap of the ring. The ISO preset is deliberately left
// without one: ISO 8601 writes time on a 24-hour clock, so an AM/PM variant
// would contradict the only thing that format is for.
var CLOCK_FORMATS = [
  "dddd HH:mm",
  "dddd h:mm AP",
  "dddd HH:mm:ss",
  "dddd h:mm:ss AP",
  "HH:mm",
  "h:mm AP",
  "ddd d MMM HH:mm",
  "ddd d MMM h:mm AP",
  "d MMMM 'W'ww yyyy",
  "yyyy-MM-dd HH:mm"
]

// Vertical bars have room for a few stacked lines and nothing else, so the
// ring stays short. AM/PM costs a fourth line, which is why only the plain
// time carries it here.
var VERTICAL_CLOCK_FORMATS = [
  "HH\n—\nmm",
  "h\n—\nmm\nAP",
  "dd\nMMM\n'W'ww\n''yy",
  "HH\nmm"
]

// Whether a format prints seconds, so the widget can tick once a second only
// for the formats that show them. Quoted literals go first: the s in a 'Sat'
// is text rather than a token, and an opening quote with no closing one runs
// to the end of the format the way Qt reads it.
function clockNeedsSeconds(format) {
  var text = String(format === undefined || format === null ? "" : format)
  return /s/.test(text.replace(/'[^']*'?/g, ""))
}

function clockFormats(vertical) {
  return vertical ? VERTICAL_CLOCK_FORMATS.slice() : CLOCK_FORMATS.slice()
}

// The presets in a fixed order, plus the configured alternate and current
// format when they are something else. The order must not depend on which
// entry is current: cycling writes the result back to shell.json, and a ring
// that reshuffled itself around the current value would bounce between two
// entries instead of walking.
function clockFormatRing(configured, configuredAlt, presets) {
  var ring = []
  var candidates = (presets || []).concat([configuredAlt, configured])
  for (var i = 0; i < candidates.length; i++) {
    var format = String(candidates[i] === undefined || candidates[i] === null ? "" : candidates[i])
    if (format === "" || ring.indexOf(format) !== -1) continue
    ring.push(format)
  }
  return ring.length > 0 ? ring : ["HH:mm"]
}

// Next entry after `current`. An unknown current format (a hand-written one
// that is not in the ring) starts the walk at the top.
function nextClockFormat(ring, current) {
  if (!ring || ring.length === 0) return ""
  var index = ring.indexOf(String(current === undefined || current === null ? "" : current))
  return ring[(index + 1) % ring.length]
}

// Two-digit ISO week, substituted into a format's 'ww' token before Qt
// formats it -- Qt has no ISO week specifier of its own.
function isoWeekLiteral(year, month, day) {
  return pad2(isoWeek(year, month, day))
}

function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

// Stable "yyyy-MM-dd" identity for a day, so a grid cell can be compared
// against today without dragging Date objects through bindings.
function dateKey(year, month, day) {
  return year + "-" + pad2(Number(month) + 1) + "-" + pad2(day)
}

function keyForDate(date) {
  return dateKey(date.getFullYear(), date.getMonth(), date.getDate())
}

function coerceWeekStart(value) {
  if (value === undefined || value === null) return null
  if (typeof value === "number")
    return isFinite(value) ? ((Math.round(value) % 7) + 7) % 7 : null

  var text = String(value).replace(/^\s+|\s+$/g, "").toLowerCase()
  if (text === "") return null

  for (var i = 0; i < WEEKDAY_NAMES.length; i++)
    if (WEEKDAY_NAMES[i] === text || WEEKDAY_NAMES[i].substr(0, 3) === text) return i

  var parsed = parseInt(text, 10)
  return isFinite(parsed) ? ((parsed % 7) + 7) % 7 : null
}

// Configured week start, falling back to the locale's own first day when
// the setting is missing or nonsense.
function normalizedWeekStart(value, fallback) {
  var configured = coerceWeekStart(value)
  if (configured !== null) return configured
  var fallbackStart = coerceWeekStart(fallback)
  return fallbackStart === null ? 1 : fallbackStart
}

function weekStartSettingName(index) {
  return WEEKDAY_NAMES[normalizedWeekStart(index, 1)]
}

// The toggle flips between the two conventions people actually switch
// between. A calendar configured to any other start (Saturday, say) is
// shown as-is and lands on Monday the first time it is toggled.
function toggledWeekStart(index) {
  return normalizedWeekStart(index, 1) === 1 ? 0 : 1
}

function weekdayOrder(weekStart) {
  var start = normalizedWeekStart(weekStart, 1)
  var out = []
  for (var i = 0; i < 7; i++) out.push((start + i) % 7)
  return out
}

// ISO-8601 week number: the week owning the Thursday of that date's
// Monday-based week. Mirrors the clock widget's 'ww' format token.
function isoWeek(year, month, day) {
  var date = new Date(Date.UTC(year, month, day))
  var weekday = date.getUTCDay() || 7
  date.setUTCDate(date.getUTCDate() + 4 - weekday)
  var yearStart = new Date(Date.UTC(date.getUTCFullYear(), 0, 1))
  return Math.ceil(((date.getTime() - yearStart.getTime()) / MS_PER_DAY + 1) / 7)
}

function dayOfYear(year, month, day) {
  return Math.round((Date.UTC(year, month, day) - Date.UTC(year, 0, 1)) / MS_PER_DAY) + 1
}

function daysInYear(year) {
  return dayOfYear(year, 11, 31)
}

// Share of the year already behind you: whole days completed over days in
// the year, so January 1 reads 0% and December 31 reads 100%.
function yearProgress(year, month, day) {
  var total = daysInYear(year)
  if (total <= 0) return 0
  return Math.max(0, Math.min(1, (dayOfYear(year, month, day) - 1) / total))
}

function yearProgressPercent(year, month, day) {
  return Math.round(yearProgress(year, month, day) * 100)
}

// Memento mori. The default span is a round number rather than anything from
// an actuarial table: the point of the bar is the reminder, not the
// arithmetic, and whoever wants a different number can say so.
var DEFAULT_LIFE_EXPECTANCY = 90

// A birth year rather than an age, so the bar keeps counting on its own
// instead of going stale the moment it is entered. 0 means "not set", which
// is also what a blank, malformed, future, or implausibly distant year means.
function parseBirthYear(value, currentYear) {
  var now = Math.round(Number(currentYear))
  if (!isFinite(now)) return 0
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^\d{4}$/.test(text)) return 0
  var year = parseInt(text, 10)
  if (!isFinite(year) || year > now || year < now - 120) return 0
  return year
}

// Whole years, the way people say their age: born in 1979 makes you 47 for
// all of 2026, whichever side of your birthday today falls.
function ageFromBirthYear(birthYear, currentYear) {
  var born = parseBirthYear(birthYear, currentYear)
  if (born <= 0) return 0
  return Math.round(Number(currentYear)) - born
}

// 0 means "not set", which is also what a blank, negative, fractional, or
// absurd entry means — the life bar simply stays hidden.
function parseAge(value) {
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^\d+$/.test(text)) return 0
  var years = parseInt(text, 10)
  if (!isFinite(years) || years <= 0 || years > 120) return 0
  return years
}

// Unset or nonsense falls back to the default rather than to zero, so the
// bar always has something to measure against.
function parseLifeExpectancy(value) {
  var text = String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
  if (!/^\d+$/.test(text)) return DEFAULT_LIFE_EXPECTANCY
  var years = parseInt(text, 10)
  if (!isFinite(years) || years <= 0 || years > 150) return DEFAULT_LIFE_EXPECTANCY
  return years
}

function lifeProgress(age, expectancy) {
  var years = parseAge(age)
  var span = parseLifeExpectancy(expectancy)
  if (years <= 0 || span <= 0) return 0
  return Math.max(0, Math.min(1, years / span))
}

function lifeProgressPercent(age, expectancy) {
  return Math.round(lifeProgress(age, expectancy) * 100)
}

// Always six rows of seven days. A fixed grid keeps the popup exactly the
// same height in every month, so stepping through the year never makes the
// panel jump under the pointer.
//
// Walked in UTC, as stock Omarchy's clock does. A local walk breaks wherever
// daylight saving starts at midnight (Santiago, Havana, Cairo, Beirut, the
// Azores): that midnight does not exist, new Date(y, m, d) lands on 23:00 the
// day before, and the grid repeats a day and shifts every later weekday.
// UTC has no gaps, and only calendar fields are read back off the cursor.
function monthGrid(year, month, weekStart, todayKey, eventIndex) {
  var start = normalizedWeekStart(weekStart, 1)
  var leading = (new Date(Date.UTC(year, month, 1)).getUTCDay() - start + 7) % 7
  var cursor = new Date(Date.UTC(year, month, 1 - leading))
  var today = String(todayKey || "")
  var weeks = []

  for (var w = 0; w < 6; w++) {
    var days = []
    var thursday = null
    for (var d = 0; d < 7; d++) {
      var cellYear = cursor.getUTCFullYear()
      var cellMonth = cursor.getUTCMonth()
      var cellDay = cursor.getUTCDate()
      var weekday = cursor.getUTCDay()
      var key = dateKey(cellYear, cellMonth, cellDay)
      if (weekday === 4) thursday = { year: cellYear, month: cellMonth, day: cellDay }
      days.push({
        key: key,
        year: cellYear,
        month: cellMonth,
        day: cellDay,
        weekday: weekday,
        inMonth: cellMonth === month && cellYear === year,
        weekend: weekday === 0 || weekday === 6,
        today: key === today,
        hasEvent: eventIndex ? !!eventIndex[key] : false,
        dots: eventIndex ? eventColors(eventIndex, key, 3) : []
      })
      cursor.setUTCDate(cursor.getUTCDate() + 1)
    }
    // Number every row by the ISO week owning its Thursday. That is the
    // definition itself for Monday-start weeks, and the only answer that
    // stays stable for the other starts, where a row straddles two ISO
    // weeks but shares all of Monday through Thursday with one of them.
    var anchor = thursday || days[0]
    weeks.push({
      week: isoWeek(anchor.year, anchor.month, anchor.day),
      days: days
    })
  }
  return weeks
}

// Milliseconds from nowMs to the next whole step (1000 or 60000), always in
// (0, step]. Counted on the epoch clock: local wall time repeats an hour when
// daylight saving ends, and a whole local minute starts on a whole epoch one.
// From stock Omarchy's clock (plugins/panels/clock/Model.js), for WallClock.qml.
function msUntilNextTick(nowMs, step) {
  return step - nowMs % step
}

// UTC for the same reason as the grid: the month is read back off the date, so
// a first of the month that has no local midnight would step into the wrong one.
function stepMonth(year, month, delta) {
  var target = new Date(Date.UTC(year, Number(month) + Number(delta), 1))
  return { year: target.getUTCFullYear(), month: target.getUTCMonth() }
}

// A boolean setting. `omarchy bar set ... false` without --json stores the
// string "false", which a QML bool would read as true.
function flag(value, fallback) {
  if (value === true || value === 1 || value === "true" || value === "1") return true
  if (value === false || value === 0 || value === "false" || value === "0") return false
  return fallback === true
}

// Event helpers. The widget renders whatever the sync wrote; none of this
// knows where the events came from.

var STALE_INTERVAL_MULTIPLIER = 4

// Anything can write calendar-events.json, so the document is shape-checked
// and bounded before the panel indexes it: a null event or a numeric name
// would otherwise throw inside the bindings and silently stop the bar.
var MAX_EVENTS = 2000
var MAX_TITLE = 500
var MAX_TEXT = 500
var MAX_ID = 512
var MAX_NAME = 200
var MAX_STAMP = 64
var MAX_URL = 4096

function boundedString(value, limit) {
  if (value === undefined || value === null) return ""
  var text = typeof value === "string" ? value : (typeof value === "object" ? "" : String(value))
  return text.length > limit ? text.substring(0, limit) : text
}

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

function sanitizeEvent(raw) {
  if (!isPlainObject(raw)) return null
  if (typeof raw.calendarId !== "string" || typeof raw.dateKey !== "string"
      || typeof raw.start !== "string" || typeof raw.title !== "string") return null
  if (raw.calendarId === "" || raw.calendarId.length > MAX_ID) return null
  if (!/^\d{4}-\d{2}-\d{2}$/.test(raw.dateKey)) return null
  if (raw.start.length > MAX_STAMP) return null

  var color = typeof raw.color === "string" && /^#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?$/.test(raw.color) ? raw.color : ""
  var event = {
    id: boundedString(raw.id, MAX_ID),
    calendarId: raw.calendarId,
    calendarName: boundedString(raw.calendarName, MAX_NAME) || raw.calendarId,
    color: color,
    start: raw.start,
    end: typeof raw.end === "string" && raw.end.length <= MAX_STAMP ? raw.end : raw.start,
    allDay: raw.allDay === true,
    title: boundedString(raw.title, MAX_TITLE),
    location: boundedString(raw.location, MAX_TEXT),
    dateKey: raw.dateKey,
    continuation: raw.continuation === true
  }
  if (typeof raw.meetingUrl === "string" && raw.meetingUrl.length <= MAX_URL) event.meetingUrl = raw.meetingUrl
  if (typeof raw.responseStatus === "string" && raw.responseStatus.length <= MAX_STAMP) event.responseStatus = raw.responseStatus
  return event
}

// A version-1 document with every event checked, or null when it is not one.
function sanitizeEventsDocument(parsed) {
  if (!isPlainObject(parsed) || parsed.version !== 1 || !Array.isArray(parsed.events)) return null
  var events = []
  for (var i = 0; i < parsed.events.length && events.length < MAX_EVENTS; i++) {
    var event = sanitizeEvent(parsed.events[i])
    if (event) events.push(event)
  }
  return {
    version: 1,
    syncedAt: boundedString(parsed.syncedAt, MAX_STAMP),
    pulledAt: typeof parsed.pulledAt === "string" ? boundedString(parsed.pulledAt, MAX_STAMP) : null,
    source: boundedString(parsed.source, MAX_NAME),
    events: events
  }
}

// ---- Exporter outcome, per the exit codes in sync/caldir-export:
//      0 ok, 3 caldir missing, 10 exported but the pull failed, 75 another
//      export holds the lock (keep the current state), anything else failed.
var EXIT_OK = 0
var EXIT_CALDIR_MISSING = 3
var EXIT_PULL_FAILED = 10
var EXIT_BUSY = 75
var MAX_EXPORT_ERROR = 300

function exportErrorText(stderrText) {
  var lines = String(stderrText === undefined || stderrText === null ? "" : stderrText)
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "")
    .split("\n")
    .map(function(line) { return line.trim() })
    .filter(function(line) { return line !== "" })
  var text = lines.length > 0 ? lines[lines.length - 1] : ""
  text = text.replace(/^caldir (?:pull|export) failed: /, "")
  return text.length > MAX_EXPORT_ERROR ? text.substring(0, MAX_EXPORT_ERROR - 1) + "…" : text
}

// The exporter command line. With sync off it only exports what is on disk.
// With sync on, "pull" asks for a pull that the exporter skips when the last
// successful one is younger than intervalSeconds, so the timer and every panel
// open stay cheap; "force" (sync just turned on) pulls regardless.
function exporterCommand(exporterPath, syncOn, mode, intervalSeconds) {
  if (!syncOn) return [exporterPath]
  if (mode === "force") return [exporterPath, "--force-pull"]
  var interval = Math.max(0, Math.floor(Number(intervalSeconds) || 0))
  return [exporterPath, "--pull", "--pull-interval", String(interval)]
}

// null means "leave the panel's state as it is" (lock busy).
function exportOutcome(exitCode, stderrText) {
  var code = Number(exitCode)
  if (code === EXIT_BUSY) return null
  if (code === EXIT_OK) return { error: "", pullFailed: false, caldirMissing: false }
  if (code === EXIT_CALDIR_MISSING) return { error: "", pullFailed: false, caldirMissing: true }
  var error = exportErrorText(stderrText) || ("exit status " + code)
  return { error: error, pullFailed: code === EXIT_PULL_FAILED, caldirMissing: false }
}

function indexEventsByDate(events) {
  var index = {}
  if (!events || !events.length) return index
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    var key = event && event.dateKey
    if (!key) continue
    if (!index[key]) index[key] = []
    index[key].push(event)
  }
  return index
}

function eventsForDateKey(index, dateKey) {
  if (!index || !dateKey) return []
  return index[dateKey] || []
}

// The calendars present in a synced document, in display order, each with
// the colour the sync resolved for it. Derived from the events themselves so
// the widget needs no separate calendar list and no configuration file: it
// can only ever offer you calendars you actually have events in.
function calendarsInDocument(doc) {
  var events = (doc && doc.events) || []
  var byId = {}
  var ordered = []

  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    var id = event && event.calendarId
    if (!id || byId[id]) continue
    byId[id] = true
    ordered.push({
      id: id,
      name: String(event.calendarName || id),
      color: String(event.color || "")
    })
  }

  ordered.sort(function(a, b) {
    return a.name.localeCompare(b.name)
  })
  return ordered
}

function isCalendarHidden(hidden, calendarId) {
  if (!hidden || !hidden.length) return false
  return hidden.indexOf(String(calendarId)) !== -1
}

// Returns a new list rather than mutating, so the caller can hand the result
// straight to persistSettings without touching the settings object in place.
function toggleHiddenCalendar(hidden, calendarId) {
  var id = String(calendarId)
  var next = []
  var found = false

  for (var i = 0; i < (hidden || []).length; i++) {
    if (String(hidden[i]) === id) { found = true; continue }
    next.push(hidden[i])
  }

  if (!found) next.push(id)
  return next
}

function isDeclined(event) {
  return !!event && String(event.responseStatus || "") === "declined"
}

// Only https links to a known meeting host are ever launched. A meeting link
// is supplied by whoever sent the invitation, and calendar-events.json can be
// written by anything, so this is the last gate before Qt.openUrlExternally.
// The grammar is the exporter's (sync/caldir_export.py strict_meeting_url),
// modelled on stock Omarchy's notifications/Security.js: one narrow ASCII
// spelling that every URL parser reads the same way. The result is the
// canonical string, which is what gets launched.
var MEETING_HOSTS = ["meet.google.com", "teams.microsoft.com", "teams.live.com", "zoom.us", "zoomgov.com"]
var MAX_MEETING_URL = 4096
var MAX_MEETING_HOSTNAME = 253

function meetingHostname(raw) {
  if (typeof raw !== "string" || raw.length > MAX_MEETING_HOSTNAME) return ""
  var host = raw.toLowerCase().replace(/\.$/, "")
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(host)) return ""
  // A numeric-looking last label makes a WHATWG parser read an IPv4 address.
  if (/^(?:0x[0-9a-f]*|[0-9]+)$/i.test(host.split(".").pop())) return ""
  for (var i = 0; i < MEETING_HOSTS.length; i++) {
    var allowed = MEETING_HOSTS[i]
    if (host === allowed || host.slice(-(allowed.length + 1)) === "." + allowed) return host
  }
  return ""
}

function safeUrl(url) {
  if (typeof url !== "string" || url.length > MAX_MEETING_URL) return ""
  // No whitespace, controls, non-ASCII, backslashes or quotes anywhere, and
  // no escapes that decode to a control, a backslash or another escape.
  if (/[^\x21-\x7e]|[\\<>"']/.test(url)) return ""
  if (/%(?:0[0-9a-f]|1[0-9a-f]|7f|25|5c)|%(?![0-9a-f]{2})/i.test(url)) return ""
  var parts = url.match(/^(https):\/\/([^\/?#]+)([^]*)$/i)
  if (!parts) return ""
  // No userinfo (@), no escapes (%) in the authority; port absent or 443.
  var authority = parts[2].match(/^([^:%@]+)(?::([0-9]{1,5}))?$/)
  if (!authority) return ""
  if (authority[2] !== undefined && authority[2] !== "" && Number(authority[2]) !== 443) return ""
  var host = meetingHostname(authority[1])
  if (!host) return ""
  return "https://" + host + (parts[3] || "/")
}

// Turn the QML file URL of a bundled script into something a person can paste.
// Derived rather than hardcoded: `omarchy plugin add` uses the manifest id, but
// a hand-cloned checkout can live anywhere, and a wrong path in the one message
// a new user sees is worse than no message.
function commandPathFromUrl(fileUrl, home) {
  var text = String(fileUrl || "")
  if (text.indexOf("file://") === 0) text = text.substring(7)
  try { text = decodeURIComponent(text) } catch (error) { /* keep malformed escapes literal */ }
  if (home && text.indexOf(home + "/") === 0) text = "~" + text.substring(home.length)
  return text
}

function meetingUrlFor(event) {
  return event ? safeUrl(event.meetingUrl) : ""
}

// How long before the start, and after the end, a meeting still counts as
// joinable. A Join button on next Tuesday's meeting is noise that dilutes the
// one that matters, so the affordance only appears around the actual time.
var JOIN_LEAD_MINUTES = 15
var JOIN_GRACE_MINUTES = 15

function isJoinableNow(event, nowMs, todayKey) {
  if (!meetingUrlFor(event)) return false

  // An all-day event has no useful clock window, so it stays joinable for the
  // whole day it belongs to.
  if (event.allDay) return event.dateKey === todayKey

  var startMs = Date.parse(event.start)
  var endMs = Date.parse(event.end)
  if (isNaN(startMs)) return false
  if (isNaN(endMs) || endMs < startMs) endMs = startMs

  var opensAt = startMs - JOIN_LEAD_MINUTES * 60 * 1000
  var closesAt = endMs + JOIN_GRACE_MINUTES * 60 * 1000
  return nowMs >= opensAt && nowMs <= closesAt
}

function visibleEvents(events, hidden, options) {
  if (!events || !events.length) return []

  var dropDeclined = options && options.hideDeclined === true
  var visible = []
  for (var i = 0; i < events.length; i++) {
    var event = events[i]
    if (!event) continue
    if (isCalendarHidden(hidden, event.calendarId)) continue
    if (dropDeclined && isDeclined(event)) continue
    visible.push(event)
  }
  return visible
}

// ---- The next thing coming up.

var MINUTE_MS = 60 * 1000
var HOUR_MS = 60 * MINUTE_MS
var DAY_MS = 24 * HOUR_MS

// All-day events are deliberately excluded. They start at midnight, so a
// countdown to one either reads as hours in the past or as tomorrow, and
// neither tells you anything you wanted to know.
function nextEvent(events, nowMs) {
  var best = null
  var bestMs = null

  for (var i = 0; i < (events || []).length; i++) {
    var event = events[i]
    if (!event || event.allDay) continue

    var startMs = Date.parse(event.start)
    if (isNaN(startMs) || startMs < nowMs) continue

    if (bestMs === null || startMs < bestMs) {
      bestMs = startMs
      best = event
    }
  }

  return best
}

// The popup's "what is next" line is scoped to today on purpose. Something
// eighteen hours out is tomorrow, and answering "what is next" with tomorrow
// is noise when the day's agenda is listed right below it.
function nextEventToday(events, nowMs, todayKey) {
  var todays = []
  for (var i = 0; i < (events || []).length; i++) {
    if (events[i] && events[i].dateKey === todayKey) todays.push(events[i])
  }
  return nextEvent(todays, nowMs)
}

// Returns null past a day out, which is the caller's signal to show nothing
// rather than a countdown nobody is acting on. Otherwise the catalog key
// suffix and the numbers to fill it with; the QML owns the words
// (countdown.now / .minutes / .hours / .hoursMinutes).
function formatCountdown(deltaMs) {
  if (deltaMs === null || isNaN(deltaMs) || deltaMs < 0 || deltaMs >= DAY_MS) return null
  if (deltaMs < MINUTE_MS) return { key: "now", hours: 0, minutes: 0 }

  var minutes = Math.floor(deltaMs / MINUTE_MS)
  if (minutes < 60) return { key: "minutes", hours: 0, minutes: minutes }

  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  return rest === 0
    ? { key: "hours", hours: hours, minutes: 0 }
    : { key: "hoursMinutes", hours: hours, minutes: rest }
}

// The countdown in the user's language. `catalog` is the plugin's
// Commons.Translations and `numbers` is Commons.I18n; both are passed in so
// this stays testable. Call it inside a binding so a language switch
// re-renders it.
function countdownText(countdown, catalog, numbers) {
  if (!countdown || !catalog) return ""
  var fmt = function(n) { return numbers ? numbers.formatNumber(n) : String(n) }
  if (countdown.key === "now") return catalog.t("countdown.now")
  if (countdown.key === "minutes")
    return catalog.tn("countdown.minutes", countdown.minutes).arg(fmt(countdown.minutes))
  if (countdown.key === "hours")
    return catalog.tn("countdown.hours", countdown.hours).arg(fmt(countdown.hours))
  return catalog.t("countdown.hoursMinutes").arg(fmt(countdown.hours)).arg(fmt(countdown.minutes))
}

var MAX_ANNOUNCE_TITLE = 28

// A bar label is a fixed budget of horizontal space shared with every other
// widget, so a long event title has to give.
function truncateTitle(title, limit) {
  var text = String(title === undefined || title === null ? "" : title)
  var max = limit || MAX_ANNOUNCE_TITLE
  if (text.length <= max) return text
  return text.substring(0, max - 1).replace(/\s+$/, "") + "…"
}

// The clock is kept rather than replaced. Giving it up was a real cost for a
// widget whose whole job used to be telling the time, and there is room for
// both.
// WidgetButton does not expose Text.textFormat. Neutralize rich-text markers
// before external event titles reach its AutoText label.
function plainTextForAutoText(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "")
    .replace(/[\r\n\t]+/g, " ")
    .replace(/&/g, "＆")
    .replace(/</g, "‹")
    .replace(/>/g, "›")
}

function announceLabel(clockText, title, countdown, limit) {
  if (!countdown) return clockText
  var shown = truncateTitle(plainTextForAutoText(title), limit)
  if (!shown) return clockText
  return clockText + "  ·  " + shown + " " + countdown
}

// How long until an event starts, or null when it cannot be read.
function millisUntil(event, nowMs) {
  if (!event) return null
  var startMs = Date.parse(event.start)
  if (isNaN(startMs)) return null
  return startMs - nowMs
}

// The bar label only gives up the clock when something is close enough to
// act on. Further out it stays a clock, which is what it is most of the day.
function shouldAnnounce(event, nowMs, leadMinutes) {
  var delta = millisUntil(event, nowMs)
  if (delta === null || delta < 0) return false
  return delta <= leadMinutes * MINUTE_MS
}

// Turn a YYYY-MM-DD key back into a local Date, for formatting a heading.
// Built field by field rather than parsed from the string, because
// new Date("2026-08-10") is UTC midnight and lands on the previous day for
// anyone west of Greenwich. Local noon, not midnight: midnight does not exist
// on the day daylight saving starts in Havana or Santiago, and would resolve
// to 23:00 the day before.
function dateFromKey(dateKey, fallback) {
  var parts = String(dateKey || "").split("-")
  if (parts.length !== 3) return fallback

  var year = parseInt(parts[0], 10)
  var month = parseInt(parts[1], 10)
  var day = parseInt(parts[2], 10)
  if (isNaN(year) || isNaN(month) || isNaN(day)) return fallback

  return new Date(year, month - 1, day, 12)
}

function eventColors(index, dateKey, limit) {
  var events = eventsForDateKey(index, dateKey)
  var colors = []
  for (var i = 0; i < events.length; i++) {
    var color = events[i].color
    if (!color || colors.indexOf(color) !== -1) continue
    colors.push(color)
    if (limit > 0 && colors.length >= limit) break
  }
  return colors
}

// "missing" means we have nothing to show and should say so rather than
// render an empty calendar that looks like a quiet week. Freshness is judged
// by the last successful pull when the document records one: the export runs
// every few minutes whether or not the pull works, so syncedAt alone would
// never look old.
function syncState(doc, nowMs, intervalSeconds) {
  if (!doc || !doc.syncedAt) return "missing"

  var syncedMs = Date.parse(doc.syncedAt)
  if (isNaN(syncedMs)) return "missing"

  var pulledMs = doc.pulledAt ? Date.parse(doc.pulledAt) : NaN
  var freshMs = isNaN(pulledMs) ? syncedMs : pulledMs

  var thresholdMs = intervalSeconds * STALE_INTERVAL_MULTIPLIER * 1000
  return (nowMs - freshMs) > thresholdMs ? "stale" : "ok"
}

if (typeof module !== "undefined") {
  module.exports = {
    msUntilNextTick: msUntilNextTick,
    flag: flag,
    sanitizeEventsDocument: sanitizeEventsDocument,
    exportErrorText: exportErrorText,
    exportOutcome: exportOutcome,
    exporterCommand: exporterCommand,
    MAX_EVENTS: MAX_EVENTS,
    dateKey: dateKey,
    keyForDate: keyForDate,
    normalizedWeekStart: normalizedWeekStart,
    weekStartSettingName: weekStartSettingName,
    toggledWeekStart: toggledWeekStart,
    weekdayOrder: weekdayOrder,
    isoWeek: isoWeek,
    dayOfYear: dayOfYear,
    daysInYear: daysInYear,
    yearProgress: yearProgress,
    yearProgressPercent: yearProgressPercent,
    parseAge: parseAge,
    parseBirthYear: parseBirthYear,
    ageFromBirthYear: ageFromBirthYear,
    parseLifeExpectancy: parseLifeExpectancy,
    lifeProgress: lifeProgress,
    lifeProgressPercent: lifeProgressPercent,
    monthGrid: monthGrid,
    stepMonth: stepMonth,
    clockFormats: clockFormats,
    clockNeedsSeconds: clockNeedsSeconds,
    clockFormatRing: clockFormatRing,
    nextClockFormat: nextClockFormat,
    isoWeekLiteral: isoWeekLiteral,
    indexEventsByDate: indexEventsByDate,
    dateFromKey: dateFromKey,
    calendarsInDocument: calendarsInDocument,
    nextEvent: nextEvent,
    nextEventToday: nextEventToday,
    formatCountdown: formatCountdown,
    countdownText: countdownText,
    truncateTitle: truncateTitle,
    announceLabel: announceLabel,
    millisUntil: millisUntil,
    shouldAnnounce: shouldAnnounce,
    isCalendarHidden: isCalendarHidden,
    toggleHiddenCalendar: toggleHiddenCalendar,
    visibleEvents: visibleEvents,
    isDeclined: isDeclined,
    safeUrl: safeUrl,
    commandPathFromUrl: commandPathFromUrl,
    plainTextForAutoText: plainTextForAutoText,
    meetingUrlFor: meetingUrlFor,
    isJoinableNow: isJoinableNow,
    eventsForDateKey: eventsForDateKey,
    eventColors: eventColors,
    syncState: syncState
  }
}
