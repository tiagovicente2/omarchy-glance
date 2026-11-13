// Pure safety and validation helpers for notification history rendering and actions.
// Compatible with both QML JS imports and Node unit tests (via module.exports).

var MAX_APP_NAME = 256
var MAX_SUMMARY = 2048
var MAX_BODY = 32768
var MAX_URL = 4096
var MAX_IMAGE_PATH = 1024
var MAX_EXEC_ARGS = 32
var MAX_HISTORY_ENTRIES = 30
var MAX_TOMBSTONE_KEYS = 500

var KEY_REGEX = /^[A-Za-z0-9_-]{1,120}$/
var ICON_NAME_REGEX = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,255}$/
var KERNEL_PATHS = /^\/(?:proc|sys|dev)(?:\/|$)/
var RUN_PATHS = /^\/(?:var\/)?run(?:\/|$)/
var VIDEO_EXT_REGEX = /\.(?:mp4|mkv|webm|mov|avi)$/i
var IMAGE_EXT_REGEX = /\.(?:jpe?g|png|webp|gif)$/i
var MEDIA_EXT_REGEX = /\.(?:jpe?g|png|webp|gif|mp4|mkv|webm|mov|avi)$/i

function bounded(value, max) {
  return typeof value === "string" ? value.slice(0, max) : ""
}

function containsControlChars(value) {
  return /[\x00-\x1f\x7f-\x9f]/.test(String(value || ""))
}

function isValidKey(value) {
  return typeof value === "string" && KEY_REGEX.test(value)
}

function resolveEntryKey(entry, stamp, origId) {
  if (entry && entry.key !== undefined && entry.key !== null) {
    return isValidKey(entry.key) ? entry.key : ""
  }
  var tsPart = Math.floor(Number(stamp) || 0)
  var idPart = Math.floor(Number(origId) || 0)
  if (!isFinite(tsPart) || tsPart < 0 || !isFinite(idPart) || idPart < 0) return ""
  var derived = String(tsPart) + "-" + String(idPart)
  return isValidKey(derived) ? derived : ""
}

function isValidIconName(value) {
  return typeof value === "string" && ICON_NAME_REGEX.test(value)
}

function iconSlug(text) {
  return String(text || "").slice(0, MAX_APP_NAME).toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-").replace(/^[-.]+|[-.]+$/g, "").slice(0, 100)
}

function isSafeLookupName(value) {
  if (typeof value !== "string") return false
  var s = value.trim()
  if (!s || s.length > MAX_APP_NAME || containsControlChars(s)) return false
  if (s.charAt(0) === "/" || s.indexOf("/") >= 0 || s.indexOf("://") >= 0 || s.indexOf("..") >= 0) return false
  return true
}

function isFocusableApp(app) {
  if (typeof app !== "string") return false
  var name = app.trim()
  if (!name || name.length > MAX_APP_NAME || containsControlChars(name)) return false
  if (name === "notify-send" || name === "omarchy-action") return false
  return true
}

function safeGlyph(value) {
  var text = typeof value === "string" ? value : ""
  if (!text || text.length > 16 || containsControlChars(text)) return ""
  return text
}

// Stock Security.js localImagePath rules: accepts only clean absolute paths or
// file:/// URIs (plus image://icon/<abs-path>), rejecting kernel interfaces,
// non-user /run paths, control chars, and `.`/`..`/empty segments.
function localImagePath(raw) {
  var text = typeof raw === "string" && raw.length <= MAX_IMAGE_PATH * 3 ? raw : ""
  if (text.indexOf("image://icon/") === 0) text = text.slice("image://icon/".length)
  if (/^file:\/\//i.test(text)) {
    if (!/^file:\/\/\//i.test(text) || /[?#]/.test(text)) return ""
    try {
      text = decodeURIComponent(text.slice("file://".length))
    } catch (e) {
      return ""
    }
  }
  if (!text || text.length > MAX_IMAGE_PATH || text.charAt(0) !== "/" || containsControlChars(text)) return ""
  var parts = text.slice(1).split("/")
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === "" || parts[i] === "." || parts[i] === "..") return ""
  }
  if (KERNEL_PATHS.test(text)) return ""
  if (RUN_PATHS.test(text) && !/^\/run\/user\/[0-9]+\/./.test(text)) return ""
  return text
}

function localImageUrl(path) {
  var text = localImagePath(path)
  return text ? "file://" + text.split("/").map(encodeURIComponent).join("/") : ""
}

// Only emit a file:// URL when the target passed localImagePath AND was
// verified to be a readable regular file (never a FIFO, tty, or device node).
function verifiedLocalImageUrl(raw, verifiedFilesMap) {
  var path = localImagePath(raw)
  if (!path) return ""
  if (!verifiedFilesMap || verifiedFilesMap[path] !== true) return ""
  return localImageUrl(path)
}

function isVideoFile(path) {
  return typeof path === "string" && VIDEO_EXT_REGEX.test(path)
}

function isImageFile(path) {
  return typeof path === "string" && IMAGE_EXT_REGEX.test(path)
}

function isMediaFile(path) {
  return typeof path === "string" && MEDIA_EXT_REGEX.test(path)
}

function resolvePreviewSource(preview, file, verifiedFilesMap) {
  if (preview) {
    var previewUrl = verifiedLocalImageUrl(preview, verifiedFilesMap)
    if (previewUrl) return previewUrl
  }
  if (file && !isVideoFile(file)) {
    var fileUrl = verifiedLocalImageUrl(file, verifiedFilesMap)
    if (fileUrl) return fileUrl
  }
  return ""
}

function uniqueStrings(list) {
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && out.indexOf(list[i]) < 0) out.push(list[i])
  }
  return out
}

function themedIconCandidates(value) {
  if (!isSafeLookupName(value)) return []
  var name = value.trim()
  var candidates = [name, name.toLowerCase(), iconSlug(name)]
  var out = []
  for (var i = 0; i < candidates.length; i++) {
    if (isValidIconName(candidates[i])) out.push(candidates[i])
  }
  return uniqueStrings(out)
}

function desktopLookupCandidates(value, includeCompact) {
  if (!isSafeLookupName(value)) return []
  var name = value.trim()
  var list = [name, name.toLowerCase()]
  if (includeCompact) {
    var compact = name.toLowerCase().replace(/[^a-z0-9]+/g, "")
    if (compact) list.push(compact)
  }
  return uniqueStrings(list)
}

// Stock Security.js parseExecArgv rules: JSON array of 1..32 strings, bounded
// lengths, no NUL byte, and argv[0] cannot begin with '-'.
function parseExecArgv(value) {
  if (value === null || value === undefined) return null
  if (Array.isArray(value)) {
    try {
      value = JSON.stringify(value)
    } catch (e) {
      return null
    }
  }
  var text = String(value || "")
  if (!text || text.length > MAX_BODY) return null

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!Array.isArray(parsed) || parsed.length === 0 || parsed.length > MAX_EXEC_ARGS) return null
  for (var i = 0; i < parsed.length; i++) {
    if (typeof parsed[i] !== "string" || parsed[i].length > MAX_URL || parsed[i].indexOf("\u0000") >= 0) return null
  }
  if (!parsed[0] || parsed[0].charAt(0) === "-") return null
  return parsed
}

function extractMediaFilePath(value) {
  if (!value) return ""
  var items = []
  if (Array.isArray(value)) {
    items = value.slice(0, MAX_EXEC_ARGS)
  } else {
    var str = String(value).trim()
    if (!str || str.length > MAX_BODY) return ""
    if (str.charAt(0) === "[") {
      try {
        var parsed = JSON.parse(str)
        if (Array.isArray(parsed)) items = parsed.slice(0, MAX_EXEC_ARGS)
      } catch (_) {}
    }
    if (items.length === 0) items = [str]
  }

  // Quoted paths must be preceded by start-of-string, whitespace, or a long flag
  // (`--opt=`), avoiding HTML attributes like `src="/tmp/a.png"`. Unquoted
  // tokens may follow whitespace or `=` after http(s):// URLs are stripped so
  // https://example.com/a.png can never match //example.com/a.png.
  var quotedMediaRegex = /(?:^|\s|--[a-z0-9_-]+=)(["'])((?:file:\/\/\/(?!\/)|\/(?!\/))[^"'\r\n\0]+?\.(?:jpe?g|png|webp|gif|mp4|mkv|webm|mov|avi))\1(?=$|[\s;])/gi
  var tokenMediaRegex = /(?:^|[\s=])((?:file:\/\/\/(?!\/)|\/(?!\/))[^\s"'\r\n\0]+?\.(?:jpe?g|png|webp|gif|mp4|mkv|webm|mov|avi))(?=$|[\s;])/gi

  for (var i = 0; i < items.length; i++) {
    if (typeof items[i] !== "string") continue
    var itemStr = items[i].trim()
    if (!itemStr || itemStr.length > MAX_URL || containsControlChars(itemStr)) continue
    if (/^\s*<[a-z!/][^>]*>\s*$/i.test(itemStr)) continue

    var direct = localImagePath(itemStr)
    if (direct && isMediaFile(direct)) return direct

    var scrubbed = itemStr.replace(/https?:\/\/[^\s"'\r\n\0]+/gi, " ")

    quotedMediaRegex.lastIndex = 0
    var qm
    while ((qm = quotedMediaRegex.exec(scrubbed)) !== null) {
      if (qm[2]) {
        var qPath = localImagePath(qm[2])
        if (qPath && isMediaFile(qPath)) return qPath
      }
    }

    tokenMediaRegex.lastIndex = 0
    var tm
    while ((tm = tokenMediaRegex.exec(scrubbed)) !== null) {
      if (tm[1]) {
        var tPath = localImagePath(tm[1])
        if (tPath && isMediaFile(tPath)) return tPath
      }
    }
  }
  return ""
}

function normalizeTombstone(raw) {
  var obj = raw
  if (typeof raw === "string") {
    try {
      obj = JSON.parse(raw)
    } catch (e) {
      obj = null
    }
  }
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) {
    return { clearedBefore: 0, dismissedKeys: [] }
  }
  var cleared = Number(obj.clearedBefore || 0)
  if (!isFinite(cleared) || cleared < 0) cleared = 0
  cleared = Math.floor(cleared)

  var keys = []
  if (Array.isArray(obj.dismissedKeys)) {
    for (var i = 0; i < obj.dismissedKeys.length; i++) {
      var k = obj.dismissedKeys[i]
      if (isValidKey(k) && keys.indexOf(k) < 0) keys.push(k)
    }
    if (keys.length > MAX_TOMBSTONE_KEYS) {
      keys = keys.slice(keys.length - MAX_TOMBSTONE_KEYS)
    }
  }
  return { clearedBefore: cleared, dismissedKeys: keys }
}

function isEntryDismissed(key, timestampMs, tombstone) {
  if (!isValidKey(key)) return true
  var tb = normalizeTombstone(tombstone)
  var stamp = Number(timestampMs || 0)
  if (!isFinite(stamp) || stamp < 0) stamp = 0
  if (tb.clearedBefore > 0 && stamp <= tb.clearedBefore) return true
  return tb.dismissedKeys.indexOf(key) >= 0
}

function readableBody(value) {
  return bounded(String(value || ""), MAX_BODY)
    .replace(/<img[^>]*>/gi, "")
    .replace(/<br\s*\/?\s*>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .trim()
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    MAX_APP_NAME: MAX_APP_NAME,
    MAX_SUMMARY: MAX_SUMMARY,
    MAX_BODY: MAX_BODY,
    MAX_URL: MAX_URL,
    MAX_IMAGE_PATH: MAX_IMAGE_PATH,
    MAX_EXEC_ARGS: MAX_EXEC_ARGS,
    MAX_HISTORY_ENTRIES: MAX_HISTORY_ENTRIES,
    MAX_TOMBSTONE_KEYS: MAX_TOMBSTONE_KEYS,
    KEY_REGEX: KEY_REGEX,
    ICON_NAME_REGEX: ICON_NAME_REGEX,
    bounded: bounded,
    containsControlChars: containsControlChars,
    isValidKey: isValidKey,
    resolveEntryKey: resolveEntryKey,
    isValidIconName: isValidIconName,
    iconSlug: iconSlug,
    isSafeLookupName: isSafeLookupName,
    isFocusableApp: isFocusableApp,
    safeGlyph: safeGlyph,
    localImagePath: localImagePath,
    localImageUrl: localImageUrl,
    verifiedLocalImageUrl: verifiedLocalImageUrl,
    isVideoFile: isVideoFile,
    isImageFile: isImageFile,
    isMediaFile: isMediaFile,
    resolvePreviewSource: resolvePreviewSource,
    themedIconCandidates: themedIconCandidates,
    desktopLookupCandidates: desktopLookupCandidates,
    parseExecArgv: parseExecArgv,
    extractMediaFilePath: extractMediaFilePath,
    normalizeTombstone: normalizeTombstone,
    isEntryDismissed: isEntryDismissed,
    readableBody: readableBody
  }
}
