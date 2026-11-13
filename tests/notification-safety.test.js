"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { execFileSync, spawnSync } = require("node:child_process")

const Safety = require("../NotificationSafety.js")

const REPO_ROOT = path.resolve(__dirname, "..")
const UNREAD_BIN = path.join(REPO_ROOT, "bin", "glance-unread")
const THUMB_BIN = path.join(REPO_ROOT, "bin", "glance-thumb")
const HISTORY_QML_PATH = path.join(REPO_ROOT, "NotificationHistory.qml")

function withTempDir(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "glance-safety-test-"))
  try {
    return fn(dir)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

function commandExists(cmd) {
  const res = spawnSync("which", [cmd], { encoding: "utf8" })
  return res.status === 0
}

// Extract a concatenated JS string literal property or command element from NotificationHistory.qml
function extractQmlStringBlock(qmlText, anchor, endMarker) {
  const start = qmlText.indexOf(anchor)
  assert.notEqual(start, -1, `anchor not found: ${anchor}`)
  const end = qmlText.indexOf(endMarker, start)
  assert.notEqual(end, -1, `endMarker not found: ${endMarker}`)
  const slice = qmlText.slice(start + anchor.length, end)
  const literals = []
  const re = /"((?:[^"\\]|\\.)*)"/g
  let m
  while ((m = re.exec(slice)) !== null) {
    literals.push(JSON.parse(`"${m[1]}"`))
  }
  return literals.join("")
}

test("localImagePath and localImageUrl enforce Security.js path rules", () => {
  assert.equal(Safety.localImagePath("/tmp/shot.png"), "/tmp/shot.png")
  assert.equal(Safety.localImagePath("/home/user/My Pics/shot 1.png"), "/home/user/My Pics/shot 1.png")
  assert.equal(Safety.localImagePath("/run/user/1000/shot.png"), "/run/user/1000/shot.png")
  assert.equal(Safety.localImagePath("file:///tmp/my%20pic.png"), "/tmp/my pic.png")
  assert.equal(Safety.localImagePath("FILE:///tmp/a.png"), "/tmp/a.png")
  assert.equal(Safety.localImagePath("image://icon//tmp/a.png"), "/tmp/a.png")
  assert.equal(Safety.localImageUrl("/tmp/my pic.png"), "file:///tmp/my%20pic.png")
  assert.equal(Safety.localImageUrl("file:///tmp/my%20pic.png"), "file:///tmp/my%20pic.png")

  const rejected = [
    "",
    null,
    undefined,
    123,
    "relative/path.png",
    "/dev/zero",
    "/dev/tty",
    "/dev/shm/hang.png",
    "/proc/self/fd/13",
    "/proc/self/environ",
    "/sys/class/net/lo",
    "/run/dbus/system_bus_socket",
    "/var/run/utmp",
    "/run/user/1000",
    "/run/user/1000/",
    "/tmp/../etc/passwd",
    "/tmp/./pic.png",
    "//etc/passwd",
    "/tmp/dir/",
    "file:////example.com/pic.png",
    "file://localhost/tmp/pic.png",
    "file:///tmp/pic.png?foo=1",
    "file:///tmp/pic.png#bar",
    "file:///tmp/%2e%2e/etc/passwd",
    "file:///tmp/%ZZ.png",
    "file:///tmp/bad%00.png",
    "/tmp/bad\n.png",
    "/tmp/bad\r.png",
    "/tmp/bad\u0000.png",
    "/tmp/bad\x1b.png",
    "/tmp/bad\x7f.png",
    "/tmp/bad\x9f.png",
    "https://example.com/pic.png",
    "http://example.com/pic.png",
    "image://qsimage/1/2",
    "image://other/provider",
    "image://icon/firefox",
    '<img src="https://evil.example/tracker.png">',
    '<img src="file:///tmp/pic.png">',
    "<img src=/tmp/pic.png >",
    "/" + "a".repeat(Safety.MAX_IMAGE_PATH)
  ]
  for (const input of rejected) {
    assert.equal(Safety.localImagePath(input), "", `expected rejection for ${JSON.stringify(input)}`)
    assert.equal(Safety.localImageUrl(input), "", `expected empty URL for ${JSON.stringify(input)}`)
  }
})

test("verifiedLocalImageUrl and resolvePreviewSource require regular-file verification", () => {
  const verified = {
    "/tmp/real.png": true,
    "/home/tiago/Videos/rec.mp4": true,
    // Even if tampered into verified map, kernel/traversal paths stay blocked:
    "/dev/zero": true,
    "/tmp/../etc/passwd.png": true
  }

  assert.equal(Safety.verifiedLocalImageUrl("/tmp/real.png", verified), "file:///tmp/real.png")
  assert.equal(Safety.verifiedLocalImageUrl("file:///tmp/real.png", verified), "file:///tmp/real.png")
  // FIFO-like unverified path is rejected before binding to Image.source
  assert.equal(Safety.verifiedLocalImageUrl("/tmp/fifo.png", verified), "")
  assert.equal(Safety.verifiedLocalImageUrl("/dev/shm/fifo.png", verified), "")
  assert.equal(Safety.verifiedLocalImageUrl("/dev/zero", verified), "")
  assert.equal(Safety.verifiedLocalImageUrl("/tmp/../etc/passwd.png", verified), "")
  assert.equal(Safety.verifiedLocalImageUrl("/tmp/real.png", null), "")

  assert.equal(Safety.resolvePreviewSource("/tmp/real.png", "", verified), "file:///tmp/real.png")
  assert.equal(Safety.resolvePreviewSource("", "/tmp/real.png", verified), "file:///tmp/real.png")
  assert.equal(Safety.resolvePreviewSource("", "/home/tiago/Videos/rec.mp4", verified), "")
  assert.equal(Safety.resolvePreviewSource("https://evil.example/tracker.png", "", verified), "")
  assert.equal(Safety.resolvePreviewSource("image://evil/x", "", verified), "")
  assert.equal(Safety.resolvePreviewSource("/tmp/fifo.png", "/tmp/fifo2.png", verified), "")
})

test("isValidKey and resolveEntryKey enforce strict key regex", () => {
  assert.equal(Safety.isValidKey("n1a2b3"), true)
  assert.equal(Safety.isValidKey("1700000000000-42"), true)
  assert.equal(Safety.isValidKey("A_b-C_9"), true)
  assert.equal(Safety.isValidKey("a".repeat(120)), true)

  for (const bad of [
    "",
    "a".repeat(121),
    "../secret",
    "a/b",
    "foo.json",
    "foo bar",
    "key\n",
    "<script>",
    null,
    undefined,
    123
  ]) {
    assert.equal(Safety.isValidKey(bad), false, `expected invalid key: ${JSON.stringify(bad)}`)
  }

  // Explicit invalid key must not fall back to derived timestamp-id key
  assert.equal(Safety.resolveEntryKey({ key: "../evil" }, 1700000000000, 1), "")
  assert.equal(Safety.resolveEntryKey({ key: "" }, 1700000000000, 1), "")
  // Missing key derives valid fallback
  assert.equal(Safety.resolveEntryKey({}, 1700000000000, 7), "1700000000000-7")
})

test("icon-name and app-name helpers reject paths, URIs, markup, and control chars", () => {
  assert.equal(Safety.isValidIconName("zen-browser"), true)
  assert.equal(Safety.isValidIconName("org.telegram.desktop"), true)
  assert.equal(Safety.isValidIconName("App_1.0"), true)

  for (const badIcon of [
    "",
    "-leading-dash",
    ".leading-dot",
    "..",
    "../etc/passwd",
    "/dev/zero",
    "/proc/self/fd/13",
    "file:///tmp/a.png",
    "image://icon/firefox",
    "Google Chrome",
    "bad\nicon",
    "<img src=x>",
    "a".repeat(257)
  ]) {
    assert.equal(Safety.isValidIconName(badIcon), false, `expected invalid icon: ${JSON.stringify(badIcon)}`)
  }

  // Never treat app or appIcon paths/URIs as icon lookups
  for (const pathLike of [
    "/dev/zero",
    "/dev/tty",
    "/proc/self/fd/13",
    "/tmp/fifo.png",
    "file:///tmp/fifo.png",
    "image://provider/x",
    "../../etc/passwd",
    '<img src="https://evil.example/a.png">'
  ]) {
    assert.deepEqual(Safety.themedIconCandidates(pathLike), [])
    assert.deepEqual(Safety.desktopLookupCandidates(pathLike, true), [])
  }

  assert.deepEqual(Safety.themedIconCandidates("Google Chrome"), ["google-chrome"])
  assert.deepEqual(Safety.desktopLookupCandidates("Google Chrome", true), [
    "Google Chrome",
    "google chrome",
    "googlechrome"
  ])

  assert.equal(Safety.isFocusableApp("Firefox"), true)
  assert.equal(Safety.isFocusableApp("Google Chrome"), true)
  assert.equal(Safety.isFocusableApp(".*"), true) // safe: launchOrFocusScript uses fixed-string match
  assert.equal(Safety.isFocusableApp("notify-send"), false)
  assert.equal(Safety.isFocusableApp("omarchy-action"), false)
  assert.equal(Safety.isFocusableApp("App\nName"), false)
  assert.equal(Safety.isFocusableApp("App\rName"), false)
  assert.equal(Safety.isFocusableApp("App\x00Name"), false)
  assert.equal(Safety.isFocusableApp("App\x1bName"), false)
  assert.equal(Safety.isFocusableApp("   "), false)
  assert.equal(Safety.isFocusableApp("a".repeat(257)), false)
})

test("extractMediaFilePath blocks https URLs, markup, kernel paths, and traversal", () => {
  assert.equal(Safety.extractMediaFilePath("/tmp/shot.png"), "/tmp/shot.png")
  assert.equal(Safety.extractMediaFilePath(["imv", "/tmp/my shot.png"]), "/tmp/my shot.png")
  assert.equal(Safety.extractMediaFilePath('["imv","file:///tmp/my%20shot.png"]'), "/tmp/my shot.png")
  assert.equal(Safety.extractMediaFilePath(["sh", "-c", "imv '/tmp/shot 1.png'"]), "/tmp/shot 1.png")
  assert.equal(Safety.extractMediaFilePath(["sh", "-c", "mpv --file=/home/user/Videos/rec.mp4"]), "/home/user/Videos/rec.mp4")
  assert.equal(Safety.extractMediaFilePath(["sh", "-c", 'mpv --file="/home/user/Videos/my rec.mp4"']), "/home/user/Videos/my rec.mp4")

  // HTTPS / HTTP URLs must never match //example.com/pic.png
  assert.equal(Safety.extractMediaFilePath("https://example.com/pic.png"), "")
  assert.equal(Safety.extractMediaFilePath("http://example.com/clip.mp4"), "")
  assert.equal(Safety.extractMediaFilePath(["curl", "https://example.com/pic.png"]), "")
  assert.equal(Safety.extractMediaFilePath(["sh", "-c", "echo https://example.com/?img=/tmp/a.png"]), "")
  assert.equal(Safety.extractMediaFilePath(["sh", "-c", "echo /foo https://example.com/pic.png"]), "")

  // If https URL precedes a real local path, skip URL and match the real path
  assert.equal(
    Safety.extractMediaFilePath(["sh", "-c", "echo https://example.com/x.png && imv /tmp/real.png"]),
    "/tmp/real.png"
  )

  // Kernel, traversal, control chars, and markup-shaped inputs
  assert.equal(Safety.extractMediaFilePath(["imv", "/dev/shm/hang.png"]), "")
  assert.equal(Safety.extractMediaFilePath(["imv", "/proc/self/fd/1.png"]), "")
  assert.equal(Safety.extractMediaFilePath(["imv", "/tmp/../etc/a.png"]), "")
  assert.equal(Safety.extractMediaFilePath(["imv", "file:////evil.com/a.png"]), "")
  assert.equal(Safety.extractMediaFilePath(["imv", "/tmp/bad\n.png"]), "")
  assert.equal(Safety.extractMediaFilePath('<img src="https://evil.example/tracker.png">'), "")
  assert.equal(Safety.extractMediaFilePath('<img src="/tmp/a.png">'), "")
  assert.equal(Safety.extractMediaFilePath("<img src=/tmp/a.png >"), "")
})

test("parseExecArgv enforces stock Security.js limits", () => {
  assert.deepEqual(Safety.parseExecArgv(["imv", "/tmp/a.png"]), ["imv", "/tmp/a.png"])
  assert.deepEqual(Safety.parseExecArgv('["imv","/tmp/a.png"]'), ["imv", "/tmp/a.png"])
  assert.deepEqual(Safety.parseExecArgv(Array.from({ length: 32 }, (_, i) => i === 0 ? "cmd" : "arg")), [
    "cmd",
    ...Array.from({ length: 31 }, () => "arg")
  ])

  assert.equal(Safety.parseExecArgv([]), null)
  assert.equal(Safety.parseExecArgv("[]"), null)
  assert.equal(Safety.parseExecArgv("imv /tmp/a.png"), null)
  assert.equal(Safety.parseExecArgv(["-rf", "/"]), null)
  assert.equal(Safety.parseExecArgv(["", "arg"]), null)
  assert.equal(Safety.parseExecArgv(["cmd", "bad\u0000arg"]), null)
  assert.equal(Safety.parseExecArgv(["cmd", 42]), null)
  assert.equal(Safety.parseExecArgv(Array.from({ length: 33 }, () => "x")), null)
  assert.equal(Safety.parseExecArgv(["cmd", "x".repeat(Safety.MAX_URL + 1)]), null)
  assert.equal(Safety.parseExecArgv(JSON.stringify(["cmd", "a".repeat(Safety.MAX_BODY)])), null)
})

test("tombstone and readableBody helpers handle filtering and markup", () => {
  const tb = Safety.normalizeTombstone({
    clearedBefore: 1000,
    dismissedKeys: ["k1", "../bad", "k2", "k1"]
  })
  assert.deepEqual(tb, { clearedBefore: 1000, dismissedKeys: ["k1", "k2"] })

  assert.equal(Safety.isEntryDismissed("k3", 999, tb), true)
  assert.equal(Safety.isEntryDismissed("k3", 1000, tb), true)
  assert.equal(Safety.isEntryDismissed("k3", 1001, tb), false)
  assert.equal(Safety.isEntryDismissed("k2", 2000, tb), true)
  assert.equal(Safety.isEntryDismissed("../bad", 2000, tb), true)

  const zeroTb = Safety.normalizeTombstone({ clearedBefore: 0, dismissedKeys: ["k1"] })
  assert.equal(Safety.isEntryDismissed("k2", 0, zeroTb), false)
  assert.equal(Safety.isEntryDismissed("k1", 0, zeroTb), true)

  assert.equal(
    Safety.readableBody('Hello<img src="https://evil.example/x.png"><br/><b>World</b>'),
    "Hello\nWorld"
  )
})

test("bin/glance-unread enforces 0700/0600 permissions, symlink safety, and tombstones", () => {
  withTempDir((tmp) => {
    const stateHome = path.join(tmp, "state")
    const popupsDir = path.join(stateHome, "omarchy", "notifications")
    const histDir = path.join(popupsDir, "history")
    fs.mkdirSync(histDir, { recursive: true })

    fs.writeFileSync(
      path.join(popupsDir, "history.json"),
      JSON.stringify([
        { key: "k1", ts: 1000, summary: "One" },
        { key: "k2", ts: 2000, summary: "Two" },
        { key: "k3", ts: 3000, summary: "Three" },
        { key: "../bad", ts: 4000, summary: "Bad key" }
      ])
    )

    const env = { ...process.env, XDG_STATE_HOME: stateHome, HOME: tmp }

    const runUnread = (args) =>
      JSON.parse(execFileSync(UNREAD_BIN, args, { env, encoding: "utf8" }))

    // Initial unread count excludes invalid key "../bad"
    assert.deepEqual(runUnread(["unread"]), { ok: true, unread: 3 })

    // Verify private directory permissions (0700)
    const glanceState = path.join(stateHome, "omarchy-glance")
    assert.equal(fs.statSync(glanceState).mode & 0o777, 0o700)

    // Single dismiss removes k2 from unread count even before Service.qml rewrites history.json
    assert.deepEqual(runUnread(["dismiss-key", "k2"]), { ok: true, key: "k2" })
    assert.equal(fs.statSync(path.join(glanceState, "tombstone.json")).mode & 0o777, 0o600)
    assert.deepEqual(runUnread(["unread"]), { ok: true, unread: 2 })

    // Reject path-traversal key in dismiss-key
    const badDismiss = spawnSync(UNREAD_BIN, ["dismiss-key", "../evil"], { env, encoding: "utf8" })
    assert.notEqual(badDismiss.status, 0)

    // Clear all up to 2,500,000 ms (ts=2000 -> 2,000,000 ms; ts=3000 -> 3,000,000 ms)
    assert.deepEqual(runUnread(["clear-all", "2500000"]), { ok: true, clearedBefore: 2500000 })
    assert.equal(fs.statSync(path.join(glanceState, "seen")).mode & 0o777, 0o600)
    assert.deepEqual(runUnread(["unread"]), { ok: true, unread: 1 })

    // Clear all past all entries
    assert.deepEqual(runUnread(["clear-all", "3500000"]), { ok: true, clearedBefore: 3500000 })
    assert.deepEqual(runUnread(["unread"]), { ok: true, unread: 0 })

    // Symlinked seen file is replaced safely without writing through symlink
    const targetOutside = path.join(tmp, "outside.txt")
    fs.writeFileSync(targetOutside, "untouched\n")
    fs.unlinkSync(path.join(glanceState, "seen"))
    fs.symlinkSync(targetOutside, path.join(glanceState, "seen"))
    assert.deepEqual(runUnread(["mark-seen", "12345"]), { ok: true, seen: 12345 })
    assert.equal(fs.readFileSync(targetOutside, "utf8"), "untouched\n")
    assert.equal(fs.lstatSync(path.join(glanceState, "seen")).isSymbolicLink(), false)

    // Symlinked glance_state directory is refused
    fs.rmSync(glanceState, { recursive: true, force: true })
    const dirTarget = path.join(tmp, "sym-target")
    fs.mkdirSync(dirTarget)
    fs.symlinkSync(dirTarget, glanceState)
    const symRun = spawnSync(UNREAD_BIN, ["unread"], { env, encoding: "utf8" })
    assert.notEqual(symRun.status, 0)
  })
})

test("bin/glance-thumb restricts thumbnails to XDG videos dir, rejects FIFOs, and uses -protocol_whitelist file", () => {
  if (!commandExists("ffmpeg")) return

  withTempDir((tmp) => {
    const stateHome = path.join(tmp, "state")
    const configHome = path.join(tmp, "config")
    const videosDir = path.join(tmp, "Videos")
    const siblingDir = path.join(tmp, "VideosEvil")
    fs.mkdirSync(configHome, { recursive: true })
    fs.mkdirSync(videosDir, { recursive: true })
    fs.mkdirSync(siblingDir, { recursive: true })
    fs.writeFileSync(path.join(configHome, "user-dirs.dirs"), `XDG_VIDEOS_DIR="${videosDir}"\n`)

    const validVid = path.join(videosDir, "clip.mp4")
    const outsideVid = path.join(siblingDir, "outside.mp4")
    const homeVid = path.join(tmp, "home-direct.mp4")
    const symlinkEscape = path.join(videosDir, "escape.mp4")
    const fifoVid = path.join(videosDir, "hang.mp4")

    // Generate one tiny valid mp4 and copy it
    execFileSync(
      "ffmpeg",
      ["-f", "lavfi", "-i", "color=c=black:s=64x64:d=1", "-t", "0.5", validVid, "-y"],
      { stdio: "ignore" }
    )
    fs.copyFileSync(validVid, outsideVid)
    fs.copyFileSync(validVid, homeVid)
    fs.symlinkSync(outsideVid, symlinkEscape)
    execFileSync("mkfifo", [fifoVid])

    const env = { ...process.env, HOME: tmp, XDG_STATE_HOME: stateHome, XDG_CONFIG_HOME: configHome }

    // Outside videos dir, sibling prefix, symlink escape, and FIFO must all be skipped cleanly
    const out1 = execFileSync(
      THUMB_BIN,
      [validVid, outsideVid, homeVid, symlinkEscape, fifoVid],
      { env, encoding: "utf8" }
    ).trim()

    const lines1 = out1 ? out1.split("\n").map((l) => JSON.parse(l)) : []
    assert.equal(lines1.length, 1)
    assert.equal(lines1[0].file, validVid)
    assert.equal(fs.statSync(path.join(stateHome, "omarchy-glance", "thumbs")).mode & 0o777, 0o700)
    assert.equal(fs.statSync(lines1[0].thumb).mode & 0o777, 0o600)

    // Test when xdg-user-dir falls back to $HOME (no user-dirs.dirs): $HOME/home-direct.mp4 must be refused
    const emptyConfig = path.join(tmp, "empty-config")
    fs.mkdirSync(emptyConfig, { recursive: true })
    const outFallback = execFileSync(
      THUMB_BIN,
      [homeVid, validVid],
      { env: { ...env, XDG_CONFIG_HOME: emptyConfig }, encoding: "utf8" }
    ).trim()
    const fallbackLines = outFallback ? outFallback.split("\n").map((l) => JSON.parse(l)) : []
    assert.equal(fallbackLines.length, 1)
    assert.equal(fallbackLines[0].file, validVid)

    // Test the ffmpeg fallback path explicitly (mask ffmpegthumbnailer via custom bin dir)
    const fakeBin = path.join(tmp, "bin")
    fs.mkdirSync(fakeBin, { recursive: true })
    fs.writeFileSync(path.join(fakeBin, "ffmpegthumbnailer"), "#!/bin/sh\nexit 127\n", { mode: 0o644 })
    // Remove cache so ffmpeg runs fresh
    fs.rmSync(path.join(stateHome, "omarchy-glance", "thumbs"), { recursive: true, force: true })
    // Symlink every needed tool except ffmpegthumbnailer into fakeBin, or shadow PATH with a non-exec file + ffmpeg
    const cleanPath = `${fakeBin}:/usr/bin:/bin`
    // Note: non-executable file in fakeBin skips command -v ffmpegthumbnailer!
    const outFfmpeg = execFileSync(THUMB_BIN, [validVid], {
      env: { ...env, PATH: cleanPath },
      encoding: "utf8"
    }).trim()
    const ffmpegLines = outFfmpeg ? outFfmpeg.split("\n").map((l) => JSON.parse(l)) : []
    assert.equal(ffmpegLines.length, 1)
    assert.equal(fs.existsSync(ffmpegLines[0].thumb), true)

    // Also confirm the script passes -protocol_whitelist file to ffmpeg
    const thumbScript = fs.readFileSync(THUMB_BIN, "utf8")
    assert.match(thumbScript, /ffmpeg\b[^\n]*-protocol_whitelist\s+file\b/)
  })
})

test("NotificationHistory.qml historyLoader checks regular files, rejects FIFOs/https, and honors tombstones", () => {
  const qml = fs.readFileSync(HISTORY_QML_PATH, "utf8")
  const loaderScript = extractQmlStringBlock(qml, 'historyLoader.command = ["bash", "-c",', '"--", popupDir')

  // Verify Component.onCompleted calls reload(), not refresh()
  assert.match(qml, /Component\.onCompleted:\s*reload\(\)/)
  // Verify nonexistent stock calls are gone. Plugins get no handle on the
  // service's history (only a do-not-disturb proxy), so dismissal goes
  // through the tombstone and the public notifications IPC target.
  assert.equal(qml.includes("clearHistory"), false)
  assert.equal(qml.includes("notifications clear"), false)
  assert.equal(/notificationService\.(historyEntries|liveEntries|saveSoon)/.test(qml), false)
  assert.match(qml, /\["omarchy-shell", "-q", "notifications", "dismissAll"\]/)
  assert.match(qml, /"clear-all"|clear-all/)
  assert.match(qml, /dismiss-key/)
  // Verify openNotification runs parseExecArgv before xdg-open, drops entry.image, and passes --
  const openStart = qml.indexOf("function openNotification(")
  const openEnd = qml.indexOf("function launchApp(", openStart)
  const openFn = qml.slice(openStart, openEnd)
  assert.ok(openFn.indexOf("parseExecArgv") < openFn.indexOf("xdg-open"))
  assert.equal(openFn.includes("entry.image"), false)
  assert.match(openFn, /\["xdg-open",\s*"--",\s*filePath\]/)
  // Verify all Text elements explicitly set Text.PlainText
  const textBlocks = [...qml.matchAll(/\bText\s*\{[^}]*\}/gs)]
  assert.ok(textBlocks.length >= 10)
  for (const m of textBlocks) {
    assert.match(m[0], /textFormat:\s*Text\.PlainText/, `missing PlainText in: ${m[0]}`)
  }

  withTempDir((tmp) => {
    const stateHome = path.join(tmp, "state")
    const popupsDir = path.join(stateHome, "omarchy", "notifications")
    const histDir = path.join(popupsDir, "history")
    const glanceState = path.join(stateHome, "omarchy-glance")
    fs.mkdirSync(histDir, { recursive: true })
    fs.mkdirSync(glanceState, { recursive: true })

    const realPng = path.join(tmp, "real.png")
    const fifoPng = path.join(tmp, "fifo.png")
    const devLinkPng = path.join(tmp, "devlink.png")
    fs.writeFileSync(realPng, "PNGDATA")
    execFileSync("mkfifo", [fifoPng])
    fs.symlinkSync("/dev/zero", devLinkPng)

    fs.writeFileSync(
      path.join(glanceState, "tombstone.json"),
      JSON.stringify({ clearedBefore: 1500, dismissedKeys: ["k_dismissed"] })
    )

    fs.writeFileSync(
      path.join(popupsDir, "history.json"),
      JSON.stringify([
        { key: "k_old", timestamp: 1000, summary: "Cleared" },
        { key: "k_dismissed", timestamp: 2000, summary: "Dismissed" },
        { key: "../traversal", timestamp: 2500, summary: "Bad key" },
        {
          key: "k_real",
          timestamp: 3000,
          summary: "Real",
          image: realPng,
          execArgv: ["imv", realPng]
        },
        {
          key: "k_fifo",
          timestamp: 4000,
          summary: "FIFO",
          image: fifoPng,
          preview: devLinkPng,
          execArgv: ["curl", "https://evil.example/tracker.png"]
        }
      ])
    )

    const rawOut = execFileSync("bash", ["-c", loaderScript, "--", popupsDir, histDir, glanceState], {
      encoding: "utf8"
    })
    const parsed = JSON.parse(rawOut)
    assert.deepEqual(
      parsed.entries.map((e) => e.key),
      ["k_fifo", "k_real"]
    )
    assert.deepEqual(parsed.verifiedFiles, [realPng])
  })
})

test("NotificationHistory.qml launchOrFocusScript rejects control chars and avoids regex matching", () => {
  const qml = fs.readFileSync(HISTORY_QML_PATH, "utf8")
  const launchScript = extractQmlStringBlock(
    qml,
    "readonly property string launchOrFocusScript:",
    "Process {"
  )

  withTempDir((tmp) => {
    const appsDir = path.join(tmp, ".local", "share", "applications")
    const binDir = path.join(tmp, "bin")
    const logFile = path.join(tmp, "calls.log")
    fs.mkdirSync(appsDir, { recursive: true })
    fs.mkdirSync(binDir, { recursive: true })

    // Desktop file WITHOUT StartupWMClass
    fs.writeFileSync(
      path.join(appsDir, "my-app.desktop"),
      "[Desktop Entry]\nName=My App\nExec=my-app\n"
    )

    // Mock hyprctl, uwsm-app, omarchy-hyprland-focus-app
    fs.writeFileSync(
      path.join(binDir, "hyprctl"),
      `#!/usr/bin/env bash
if [[ "$1" == "clients" ]]; then
  printf '[{"class":"unrelated-terminal","address":"0xdeadbeef"}]\\n'
else
  printf 'hyprctl:%s\\n' "$*" >> "${logFile}"
fi
`,
      { mode: 0o755 }
    )
    fs.writeFileSync(
      path.join(binDir, "uwsm-app"),
      `#!/usr/bin/env bash
printf 'uwsm-app:%s\\n' "$*" >> "${logFile}"
`,
      { mode: 0o755 }
    )
    fs.writeFileSync(
      path.join(binDir, "omarchy-hyprland-focus-app"),
      `#!/usr/bin/env bash
printf 'focus-app:%s\\n' "$1" >> "${logFile}"
`,
      { mode: 0o755 }
    )

    const env = { ...process.env, HOME: tmp, PATH: `${binDir}:/usr/bin:/bin` }

    // 1. Control chars rejected immediately (nothing called)
    execFileSync("bash", ["-c", launchScript, "--", "My App\nEvil"], { env })
    assert.equal(fs.existsSync(logFile), false)

    // 2. Regex metacharacter app name ".*" must NOT match Name=My App and must escape before focus-app
    execFileSync("bash", ["-c", launchScript, "--", ".*"], { env })
    assert.equal(fs.readFileSync(logFile, "utf8").trim(), "focus-app:\\.\\*")

    // 3. Matching "My App" with empty StartupWMClass must NOT match unrelated-terminal via ||
    fs.unlinkSync(logFile)
    execFileSync("bash", ["-c", launchScript, "--", "My App"], { env })
    // wait briefly for background setsid uwsm-app to append? Run synchronously or wait up to 200ms
    const deadline = Date.now() + 500
    while (!fs.existsSync(logFile) && Date.now() < deadline) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10)
    }
    assert.equal(fs.readFileSync(logFile, "utf8").trim(), "uwsm-app:-- my-app.desktop")
  })
})
