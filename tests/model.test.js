// Unit tests for Model.js. Run: node --test tests/model.test.js
"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const MODEL = path.join(__dirname, "..", "Model.js")
const Model = require(MODEL)

// Date math depends on the zone the process starts in, so each zone case runs
// in a child node with TZ set before anything touches a Date.
//
// Node's V8 resolves a local time that falls in a DST gap forward (00:00 that
// does not exist becomes 01:00). QML's V4 engine resolves it backward, to
// 23:00 the day before, which is what broke the grid in the shell. The child
// swaps in a Date that resolves gaps the V4 way, so these tests fail on the
// local-time math the way the shell did.
const QML_DATE = `
var RealDate = Date;
function backward(ms, wantHour) {
  var d = new RealDate(ms);
  return d.getHours() !== wantHour ? ms - 3600000 : ms;
}
function QmlDate() {
  var a = Array.prototype.slice.call(arguments);
  var ms;
  if (a.length === 0) ms = RealDate.now();
  else if (a.length === 1) ms = new RealDate(a[0]).getTime();
  else {
    ms = new (Function.prototype.bind.apply(RealDate, [null].concat(a)))().getTime();
    var hour = a.length > 3 ? a[3] : 0;
    if (hour >= 0 && hour < 24) ms = backward(ms, hour);
  }
  var self = new RealDate(ms);
  Object.setPrototypeOf(self, QmlDate.prototype);
  return self;
}
QmlDate.prototype = Object.create(RealDate.prototype);
QmlDate.prototype.constructor = QmlDate;
QmlDate.prototype.setDate = function(day) {
  var hour = this.getHours();
  RealDate.prototype.setDate.call(this, day);
  return this.setTime(backward(this.getTime(), hour));
};
QmlDate.UTC = RealDate.UTC; QmlDate.parse = RealDate.parse; QmlDate.now = RealDate.now;
globalThis.Date = QmlDate;
`

function inZone(tz, body) {
  const script = QML_DATE + `const Model = require(${JSON.stringify(MODEL)});\n` +
    `process.stdout.write(JSON.stringify((function() { ${body} })()))`
  const out = execFileSync(process.execPath, ["-e", script], { env: { ...process.env, TZ: tz } })
  return JSON.parse(String(out))
}

function gridKeys(year, month, weekStart) {
  return `return Model.monthGrid(${year}, ${month}, ${weekStart}, "", null)` +
    `.map(function(w) { return w.days.map(function(d) { return d.key + "/" + d.weekday }) })`
}

function assertContiguous(rows, label) {
  const flat = rows.flat()
  assert.equal(flat.length, 42, label)
  for (let i = 1; i < flat.length; i++) {
    const [prevKey, prevDay] = flat[i - 1].split("/")
    const [key, day] = flat[i].split("/")
    const next = new Date(Date.parse(prevKey + "T00:00:00Z") + 86400000).toISOString().slice(0, 10)
    assert.equal(key, next, `${label}: ${flat[i - 1]} -> ${flat[i]}`)
    assert.equal(Number(day), (Number(prevDay) + 1) % 7, `${label}: weekday after ${prevKey}`)
  }
}

test("monthGrid has no repeated day where DST starts at midnight (America/Santiago, Sep 2026)", () => {
  const rows = inZone("America/Santiago", gridKeys(2026, 8, 1))
  assertContiguous(rows, "Santiago")
  // Sunday 6 September sits under Sunday, the last Monday-start column.
  assert.equal(rows[0][6], "2026-09-06/0")
})

test("monthGrid has no repeated day where DST starts at midnight (America/Havana, Mar 2026)", () => {
  const rows = inZone("America/Havana", gridKeys(2026, 2, 1))
  assertContiguous(rows, "Havana")
  assert.ok(rows.flat().includes("2026-03-08/0"))
})

test("monthGrid Sunday start in Havana March 2026", () => {
  const rows = inZone("America/Havana", gridKeys(2026, 2, 0))
  assertContiguous(rows, "Havana Sunday")
  assert.equal(rows[0][0], "2026-03-01/0")
})

test("stepMonth leaves a month whose first has no local midnight (Havana 2012)", () => {
  const next = inZone("America/Havana", "return Model.stepMonth(2012, 2, 1)")
  assert.deepEqual(next, { year: 2012, month: 3 })
  const back = inZone("America/Havana", "return Model.stepMonth(2012, 3, -1)")
  assert.deepEqual(back, { year: 2012, month: 2 })
  const wrap = inZone("America/Santiago", "return Model.stepMonth(2026, 11, 1)")
  assert.deepEqual(wrap, { year: 2027, month: 0 })
})

test("dateFromKey keeps the calendar day on a DST-start day", () => {
  for (const [tz, key] of [["America/Havana", "2026-03-08"], ["America/Santiago", "2026-09-06"]]) {
    const fields = inZone(tz, `var d = Model.dateFromKey(${JSON.stringify(key)}, null);` +
      "return [d.getFullYear(), d.getMonth() + 1, d.getDate()]")
    assert.deepEqual(fields, key.split("-").map(Number), tz)
  }
  assert.equal(Model.dateFromKey("nonsense", "fallback"), "fallback")
})

test("viewDate built at local noon reads back as the right month (Havana April 2012)", () => {
  const months = inZone("America/Havana", "return [new Date(2012, 3, 1, 12).getMonth(), new Date(2012, 3, 1).getMonth()]")
  assert.equal(months[0], 3)
  // The midnight form the panel used to build lands in March under QML's rules.
  assert.equal(months[1], 2)
})

test("msUntilNextTick stays within one step", () => {
  assert.equal(Model.msUntilNextTick(60000, 60000), 60000)
  assert.equal(Model.msUntilNextTick(60001, 60000), 59999)
  assert.equal(Model.msUntilNextTick(1999, 1000), 1)
})

test("formatCountdown returns catalog keys and numbers, never English", () => {
  assert.equal(Model.formatCountdown(null), null)
  assert.equal(Model.formatCountdown(-1), null)
  assert.equal(Model.formatCountdown(24 * 3600 * 1000), null)
  assert.deepEqual(Model.formatCountdown(30 * 1000), { key: "now", hours: 0, minutes: 0 })
  assert.deepEqual(Model.formatCountdown(10 * 60 * 1000), { key: "minutes", hours: 0, minutes: 10 })
  assert.deepEqual(Model.formatCountdown(2 * 3600 * 1000), { key: "hours", hours: 2, minutes: 0 })
  assert.deepEqual(Model.formatCountdown(90 * 60 * 1000), { key: "hoursMinutes", hours: 1, minutes: 30 })
})

test("announceLabel neutralizes markup-shaped titles", () => {
  const label = Model.announceLabel("Thu 10:00", '<img src="https://example.invalid/t">&amp;', "in 5 min", 80)
  assert.ok(!/[<>&]/.test(label), label)
  assert.ok(label.startsWith("Thu 10:00  ·  "))
  assert.ok(label.endsWith(" in 5 min"))
  assert.equal(Model.announceLabel("Thu 10:00", "<b>x</b>", "", 80), "Thu 10:00")
  assert.equal(Model.plainTextForAutoText("a\nb\u0000<i>"), "a b‹i›")
})

test("flag reads string booleans", () => {
  assert.equal(Model.flag("false", true), false)
  assert.equal(Model.flag("true", false), true)
  assert.equal(Model.flag(false, true), false)
  assert.equal(Model.flag(true, false), true)
  assert.equal(Model.flag(undefined, true), true)
  assert.equal(Model.flag("nonsense", false), false)
})

test("sanitizeEventsDocument drops malformed events and bounds the rest", () => {
  assert.equal(Model.sanitizeEventsDocument(null), null)
  assert.equal(Model.sanitizeEventsDocument({ version: 1 }), null)
  assert.equal(Model.sanitizeEventsDocument({ version: 1, events: {} }), null)
  assert.equal(Model.sanitizeEventsDocument({ version: 2, events: [] }), null)

  const good = { calendarId: "work", calendarName: 42, dateKey: "2026-11-12", start: "2026-11-12T10:00:00Z", title: "x".repeat(5000), color: "#aabbcc" }
  const doc = Model.sanitizeEventsDocument({
    version: 1,
    syncedAt: "2026-11-12T09:00:00Z",
    events: [null, 5, "s", [], { calendarId: 1, dateKey: "2026-11-12", start: "s", title: "t" }, { ...good, dateKey: "bad" }, good, { ...good, color: "red;" }]
  })
  assert.equal(doc.events.length, 2)
  assert.equal(doc.events[0].calendarName, "42")
  assert.equal(doc.events[0].title.length, 500)
  assert.equal(doc.events[1].color, "")
  assert.equal(doc.pulledAt, null)

  const many = Model.sanitizeEventsDocument({ version: 1, events: Array(Model.MAX_EVENTS + 50).fill(good) })
  assert.equal(many.events.length, Model.MAX_EVENTS)

  // The sanitized list is safe for the panel's helpers.
  assert.equal(Model.calendarsInDocument(doc).length, 1)
  assert.equal(Model.visibleEvents([null, good], [], {}).length, 1)
})

test("exportOutcome follows the exporter exit-code contract", () => {
  assert.equal(Model.exportOutcome(75, "busy"), null)
  assert.deepEqual(Model.exportOutcome(0, ""), { error: "", pullFailed: false, caldirMissing: false })
  assert.deepEqual(Model.exportOutcome(3, "caldir export failed: [Errno 2]"), { error: "", pullFailed: false, caldirMissing: true })
  assert.deepEqual(Model.exportOutcome(10, "caldir pull failed: offline\n"), { error: "offline", pullFailed: true, caldirMissing: false })
  assert.deepEqual(Model.exportOutcome(1, "caldir export failed: no calendars"), { error: "no calendars", pullFailed: false, caldirMissing: false })
  // A python exit 2 is a generic failure, not a pull failure.
  assert.equal(Model.exportOutcome(2, "python3: can't open file").pullFailed, false)
  assert.equal(Model.exportOutcome(1, "").error, "exit status 1")
})

test("syncState judges staleness by pulledAt when present", () => {
  const now = Date.parse("2026-11-12T12:00:00Z")
  assert.equal(Model.syncState(null, now, 300), "missing")
  assert.equal(Model.syncState({ syncedAt: "2026-11-12T11:59:00Z" }, now, 300), "ok")
  assert.equal(Model.syncState({ syncedAt: "2026-11-12T11:00:00Z" }, now, 300), "stale")
  assert.equal(Model.syncState({ syncedAt: "2026-11-12T11:59:00Z", pulledAt: "2026-11-12T10:00:00Z" }, now, 300), "stale")
  assert.equal(Model.syncState({ syncedAt: "2026-11-12T11:59:00Z", pulledAt: null }, now, 300), "ok")
})

test("countdownText fills the catalog's plural forms with formatted numbers", () => {
  // QML strings carry .arg(), which fills the lowest-numbered %N; give the
  // test strings the same method.
  const withArg = (text) => Object.assign(new String(text), {
    arg(value) {
      const marks = String(this).match(/%\d/g) || []
      if (marks.length === 0) return withArg(String(this))
      const lowest = marks.sort()[0]
      return withArg(String(this).split(lowest).join(String(value)))
    }
  })
  const catalog = {
    t: (key) => withArg({ "countdown.now": "agora", "countdown.hoursMinutes": "em %1 h %2 min" }[key]),
    tn: (key, n) => withArg({ "countdown.minutes": n === 1 ? "em %1 minuto" : "em %1 min", "countdown.hours": "em %1 h" }[key])
  }
  const arabic = { formatNumber: (n) => String(n).replace(/[0-9]/g, (d) => String.fromCharCode(0x660 + Number(d))) }
  assert.equal(String(Model.countdownText(null, catalog, arabic)), "")
  assert.equal(String(Model.countdownText(Model.formatCountdown(1000), catalog, arabic)), "agora")
  assert.equal(String(Model.countdownText(Model.formatCountdown(60 * 1000), catalog, arabic)), "em \u0661 minuto")
  assert.equal(String(Model.countdownText(Model.formatCountdown(12 * 60 * 1000), catalog, arabic)), "em \u0661\u0662 min")
  assert.equal(String(Model.countdownText(Model.formatCountdown(3 * 3600 * 1000), catalog, arabic)), "em \u0663 h")
  assert.equal(String(Model.countdownText(Model.formatCountdown(75 * 60 * 1000), catalog, arabic)), "em \u0661 h \u0661\u0665 min")
})

test("exporterCommand pulls through the exporter's rate limit, forces only on request", () => {
  assert.deepEqual(Model.exporterCommand("/x", false, "force", 300), ["/x"])
  assert.deepEqual(Model.exporterCommand("/x", true, "pull", 300), ["/x", "--pull", "--pull-interval", "300"])
  assert.deepEqual(Model.exporterCommand("/x", true, "force", 300), ["/x", "--force-pull"])
})
