import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "NotificationSafety.js" as Safety

Item {
  id: root

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var bar: null
  property var notificationService: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color dimForeground: Qt.darker(foreground, 1.4)
  readonly property color borderColor: Style.normalBorderFor(foreground, Color.accent)
  readonly property color hoverColor: Style.hoverFillFor(foreground, Color.accent)
  readonly property int cardRadius: notificationService ? notificationService.cornerRadius : Style.cornerRadius

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string glanceStateDir: stateHome + "/omarchy-glance"
  readonly property string thumbsDir: glanceStateDir + "/thumbs"
  readonly property string historyDir: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/notifications/history"
  readonly property string popupDir: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/notifications"
  readonly property string imagesDir: (Quickshell.env("HOME") || "") + "/.local/state/omarchy/notifications/images"

  readonly property string unreadBinPath: Qt.resolvedUrl("bin/glance-unread").toString().replace(/^file:\/\//, "")
  readonly property string thumbBinPath: Qt.resolvedUrl("bin/glance-thumb").toString().replace(/^file:\/\//, "")

  // Video path -> cached thumbnail file URL, filled in by glance-thumb.
  property var videoThumbs: ({})
  property var pendingThumbFiles: []
  // Verified regular local files checked by historyLoader or glance-thumb.
  property var verifiedFiles: ({})
  // In-memory tombstone mirror so immediate reloads do not resurrect dismissed
  // entries before glance-unread finishes writing tombstone.json.
  property double localClearedBefore: 0
  property var localDismissedKeys: ({})

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
  property int loadGeneration: 0
  property int activeLoadGeneration: 0

  function isTombstoned(key, stamp) {
    if (!Safety.isValidKey(key)) return true
    if (localDismissedKeys[key] === true) return true
    if (localClearedBefore > 0 && Number(stamp || 0) <= localClearedBefore) return true
    return false
  }

  function isAllowedThumbPath(path) {
    var safe = Safety.localImagePath(path)
    if (!safe || !Safety.isImageFile(safe)) return false
    return safe.indexOf(root.thumbsDir + "/") === 0
  }

  function refresh() {
    discardPendingResults = false
    nowMs = Date.now()
    root.deactivateCursor()

    readMark = Number(localState.lastSeen || 0)
    localState.lastSeen = nowMs
    Quickshell.execDetached(["bash", "-c",
      "unreadbin=\"$1\"; stamp=\"$2\"\n" +
      "[[ -x $unreadbin ]] && \"$unreadbin\" mark-seen \"$stamp\" >/dev/null 2>&1 || true",
      "--", unreadBinPath, String(Math.floor(nowMs))])
    reload()
  }

  function reload() {
    if (historyLoader.running) {
      reloadPending = true
      return
    }
    discardPendingResults = false
    loadGeneration += 1
    activeLoadGeneration = loadGeneration
    historyLoader.command = ["bash", "-c",
      "popup=\"$1\"; hist=\"$2\"; glance_state=\"$3\"\n" +
      "files=()\n" +
      "if [[ -d \"$popup\" && ! -L \"$popup\" ]]; then\n" +
      "  for fixed in \"$popup/live.json\" \"$popup/history.json\"; do\n" +
      "    if [[ -f \"$fixed\" && ! -L \"$fixed\" && -s \"$fixed\" ]]; then\n" +
      "      sz=$(stat -c %s -- \"$fixed\" 2>/dev/null || echo 0)\n" +
      "      (( sz > 0 && sz <= 5242880 )) && files+=(\"$fixed\")\n" +
      "    fi\n" +
      "  done\n" +
      "  while IFS= read -r f; do\n" +
      "    [[ -n \"$f\" && ! -L \"$f\" && -s \"$f\" ]] || continue\n" +
      "    sz=$(stat -c %s -- \"$f\" 2>/dev/null || echo 0)\n" +
      "    (( sz > 0 && sz <= 5242880 )) && files+=(\"$f\")\n" +
      "  done < <(find \"$popup\" -maxdepth 1 -type f -name '*.json' ! -name 'live.json' ! -name 'history.json' ! -name 'quiet.json' 2>/dev/null)\n" +
      "fi\n" +
      "if [[ -d \"$hist\" && ! -L \"$hist\" ]]; then\n" +
      "  while IFS= read -r f; do\n" +
      "    [[ -n \"$f\" && ! -L \"$f\" && -s \"$f\" ]] || continue\n" +
      "    sz=$(stat -c %s -- \"$f\" 2>/dev/null || echo 0)\n" +
      "    (( sz > 0 && sz <= 5242880 )) && files+=(\"$f\")\n" +
      "  done < <(find \"$hist\" -maxdepth 1 -type f -name '*.json' ! -name 'live.json' ! -name 'history.json' ! -name 'quiet.json' 2>/dev/null)\n" +
      "fi\n" +
      "valid_files=()\n" +
      "for f in \"${files[@]}\"; do\n" +
      "  jq -e . \"$f\" >/dev/null 2>&1 && valid_files+=(\"$f\")\n" +
      "done\n" +
      "if (( ${#valid_files[@]} == 0 )); then\n" +
      "  printf '{\"entries\":[],\"verifiedFiles\":[]}\\n'\n" +
      "  exit 0\n" +
      "fi\n" +
      "tomb='{\"clearedBefore\":0,\"dismissedKeys\":[]}'\n" +
      "if [[ -n \"$glance_state\" && -d \"$glance_state\" && ! -L \"$glance_state\" && -f \"$glance_state/tombstone.json\" && ! -L \"$glance_state/tombstone.json\" ]]; then\n" +
      "  tsz=$(stat -c %s -- \"$glance_state/tombstone.json\" 2>/dev/null || echo 0)\n" +
      "  if (( tsz > 0 && tsz <= 262144 )); then\n" +
      "    tc=$(jq -c 'if type == \"object\" then {clearedBefore: ((.clearedBefore // 0) | if type == \"number\" and isfinite and . >= 0 then floor else 0 end), dismissedKeys: ((.dismissedKeys // []) | if type == \"array\" then map(select(type == \"string\" and test(\"^[A-Za-z0-9_-]{1,120}$\"))) | .[-500:] else [] end)} else {clearedBefore:0,dismissedKeys:[]} end' \"$glance_state/tombstone.json\" 2>/dev/null || true)\n" +
      "    [[ -n \"$tc\" ]] && tomb=\"$tc\"\n" +
      "  fi\n" +
      "fi\n" +
      "entries=$(jq -c -s --argjson tomb \"$tomb\" '\n" +
      "  def to_entries:\n" +
      "    if type == \"array\" then .[]\n" +
      "    elif type == \"object\" then .\n" +
      "    else empty\n" +
      "    end;\n" +
      "  def valid_key:\n" +
      "    type == \"string\" and test(\"^[A-Za-z0-9_-]{1,120}$\");\n" +
      "  ($tomb.clearedBefore // 0) as $cleared\n" +
      "  | ($tomb.dismissedKeys // []) as $dismissed\n" +
      "  | [\n" +
      "      .[]?\n" +
      "      | to_entries\n" +
      "      | select(type == \"object\")\n" +
      "      | select(.key or .id or .originalId or .ts or .timestamp)\n" +
      "      | .timestamp = (\n" +
      "          if (.timestamp | type) == \"number\" and (.timestamp | isfinite) then (.timestamp | floor)\n" +
      "          elif (.ts | type) == \"number\" and (.ts | isfinite) then ((.ts * 1000) | floor)\n" +
      "          else 0\n" +
      "          end\n" +
      "        )\n" +
      "      | (if has(\"key\") and .key != null then .key\n" +
      "         else \"\\(.timestamp)-\\(.originalId // .id // 0)\"\n" +
      "         end) as $k\n" +
      "      | select($k | valid_key)\n" +
      "      | .key = $k\n" +
      "      | select($cleared <= 0 or .timestamp > $cleared)\n" +
      "      | select(($dismissed | index($k)) == null)\n" +
      "    ]\n" +
      "  | unique_by(.key)\n" +
      "  | sort_by(.timestamp)\n" +
      "  | reverse\n" +
      "  | .[0:30]\n" +
      "' \"${valid_files[@]}\" 2>/dev/null || echo '[]')\n" +
      "urldecode() {\n" +
      "  local s=\"$1\" out=\"\" hex byte val\n" +
      "  while [[ $s =~ ^([^%]*)%([0-9A-Fa-f]{2})(.*)$ ]]; do\n" +
      "    out+=\"${BASH_REMATCH[1]}\"\n" +
      "    hex=\"${BASH_REMATCH[2]}\"\n" +
      "    val=$((16#$hex))\n" +
      "    if (( val < 32 || val == 127 || (val >= 128 && val <= 159) )); then return 1; fi\n" +
      "    printf -v byte \"\\\\x$hex\"\n" +
      "    out+=\"$byte\"\n" +
      "    s=\"${BASH_REMATCH[3]}\"\n" +
      "  done\n" +
      "  [[ $s == *%* ]] && return 1\n" +
      "  REPLY=\"$out$s\"\n" +
      "}\n" +
      "check_local_regular_file() {\n" +
      "  local p=\"$1\"\n" +
      "  p=\"${p#\"${p%%[![:space:]]*}\"}\"\n" +
      "  p=\"${p%\"${p##*[![:space:]]}\"}\"\n" +
      "  [[ -n \"$p\" && ${#p} -le 3072 ]] || return 1\n" +
      "  [[ \"$p\" == image://icon/* ]] && p=\"${p#image://icon/}\"\n" +
      "  if [[ \"${p,,}\" == file://* ]]; then\n" +
      "    [[ \"${p,,}\" == file:///* && \"$p\" != *[?#]* ]] || return 1\n" +
      "    urldecode \"${p:7}\" || return 1\n" +
      "    p=\"$REPLY\"\n" +
      "  fi\n" +
      "  [[ -n \"$p\" && ${#p} -le 1024 && \"$p\" == /* && \"$p\" != *[[:cntrl:]]* ]] || return 1\n" +
      "  [[ \"$p\" != *//* && \"$p\" != */ ]] || return 1\n" +
      "  local segs seg\n" +
      "  IFS=/ read -ra segs <<< \"${p:1}\"\n" +
      "  for seg in \"${segs[@]}\"; do\n" +
      "    [[ -n \"$seg\" && \"$seg\" != \".\" && \"$seg\" != \"..\" ]] || return 1\n" +
      "  done\n" +
      "  [[ ! \"$p\" =~ ^/(proc|sys|dev)(/|$) ]] || return 1\n" +
      "  if [[ \"$p\" =~ ^/(var/)?run(/|$) ]] && [[ ! \"$p\" =~ ^/run/user/[0-9]+/. ]]; then return 1; fi\n" +
      "  [[ -f \"$p\" && -r \"$p\" ]] || return 1\n" +
      "  local rp\n" +
      "  rp=$(realpath -e -- \"$p\" 2>/dev/null) || return 1\n" +
      "  [[ -f \"$rp\" && -r \"$rp\" ]] || return 1\n" +
      "  [[ ! \"$rp\" =~ ^/(proc|sys|dev)(/|$) ]] || return 1\n" +
      "  if [[ \"$rp\" =~ ^/(var/)?run(/|$) ]] && [[ ! \"$rp\" =~ ^/run/user/[0-9]+/. ]]; then return 1; fi\n" +
      "  REPLY=\"$p\"\n" +
      "}\n" +
      "verified=\"\"\n" +
      "while IFS= read -r cand; do\n" +
      "  [[ -n \"$cand\" ]] || continue\n" +
      "  if check_local_regular_file \"$cand\"; then\n" +
      "    verified+=\"$REPLY\"$'\\n'\n" +
      "  fi\n" +
      "done < <(\n" +
      "  printf '%s\\n' \"$entries\" | jq -r '\n" +
      "    def exec_items:\n" +
      "      if type == \"array\" then .[]\n" +
      "      elif type == \"string\" then\n" +
      "        (if startswith(\"[\") then (fromjson? // [.]) else [.] end)\n" +
      "        | if type == \"array\" then .[] else empty end\n" +
      "      else empty\n" +
      "      end;\n" +
      "    .[]\n" +
      "    | (\n" +
      "        (.image // empty | strings),\n" +
      "        (.preview // empty | strings),\n" +
      "        (.file // empty | strings),\n" +
      "        (((.execArgv | exec_items), (.exec // empty | strings)) | strings |\n" +
      "          .,\n" +
      "          (\n" +
      "            gsub(\"(?i)https?://[^\\\\s\\\"'\\''\\\\r\\\\n]+\"; \" \")\n" +
      "            | (\n" +
      "                (scan(\"(?:^|\\\\s|--[a-z0-9_-]+=)([\\\"'\\''])((?i:file:///)(?!/)|/(?!/))([^\\\"'\\''\\\\r\\\\n]+?\\\\.(?i:jpe?g|png|webp|gif|mp4|mkv|webm|mov|avi))\\\\1(?=$|[\\\\s;])\") | .[1] + .[2]),\n" +
      "                (scan(\"(?:^|[\\\\s=])(((?i:file:///)(?!/)|/(?!/))[^\\\\s\\\"'\\''\\\\r\\\\n]+?\\\\.(?i:jpe?g|png|webp|gif|mp4|mkv|webm|mov|avi))(?=$|[\\\\s;])\") | .[0])\n" +
      "              )\n" +
      "          )\n" +
      "        )\n" +
      "      )\n" +
      "    | select(test(\"[\\r\\n]\") | not)\n" +
      "  ' 2>/dev/null | awk '!seen[$0]++'\n" +
      ")\n" +
      "jq -cn --argjson entries \"$entries\" --arg v \"$verified\" \\\n" +
      "  '{entries: $entries, verifiedFiles: ($v | split(\"\\n\") | map(select(length > 0)) | unique)}'",
      "--", popupDir, historyDir, glanceStateDir]
    historyLoader.running = true
  }

  function replaceHistory(raw) {
    if (discardPendingResults || activeLoadGeneration !== loadGeneration) return
    historyModel.clear()
    var entries = []
    var verifiedMap = ({})
    var trimmed = String(raw || "").trim()
    if (trimmed) {
      try {
        var payload = JSON.parse(trimmed)
        if (payload && typeof payload === "object" && !Array.isArray(payload) && Array.isArray(payload.entries)) {
          entries = payload.entries
          if (Array.isArray(payload.verifiedFiles)) {
            for (var v = 0; v < payload.verifiedFiles.length; v++) {
              var vp = Safety.localImagePath(payload.verifiedFiles[v])
              if (vp) verifiedMap[vp] = true
            }
          }
        }
      } catch (parseErr) {
        console.warn("clock notifications: invalid history loader payload:", parseErr)
      }
    }
    root.verifiedFiles = verifiedMap

    var seenKeys = ({})
    var videoFiles = []
    for (var i = 0; i < entries.length && historyModel.count < Safety.MAX_HISTORY_ENTRIES; i++) {
      try {
        var entry = entries[i]
        if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue
        var origId = Number(entry.originalId || entry.id || 0)
        if (!isFinite(origId) || origId < 0) origId = 0
        var stamp = Number(entry.timestamp || (entry.ts ? entry.ts * 1000 : 0) || 0)
        if (!isFinite(stamp) || stamp < 0) stamp = 0
        if (!stamp && typeof entry.key === "string") {
          var keyStamp = Number(entry.key.split("-")[0] || 0)
          if (isFinite(keyStamp) && keyStamp > 0) stamp = keyStamp
        }
        var key = Safety.resolveEntryKey(entry, stamp, origId)
        if (!key) continue
        if (root.isTombstoned(key, stamp)) continue
        if (seenKeys[key]) continue
        seenKeys[key] = true

        var fileSrc = Safety.extractMediaFilePath(entry.file || entry.execArgv || entry.exec)
        if (fileSrc && verifiedMap[fileSrc] !== true) fileSrc = ""

        var previewSrc = Safety.verifiedLocalImageUrl(entry.preview, verifiedMap)
        if (!previewSrc && fileSrc) {
          if (!Safety.isVideoFile(fileSrc)) {
            previewSrc = Safety.verifiedLocalImageUrl(fileSrc, verifiedMap)
          } else if (root.videoThumbs[fileSrc]) {
            var thumbPath = Safety.localImagePath(root.videoThumbs[fileSrc])
            if (thumbPath && root.isAllowedThumbPath(thumbPath)) {
              verifiedMap[thumbPath] = true
              previewSrc = Safety.localImageUrl(thumbPath)
            }
          } else if (videoFiles.indexOf(fileSrc) === -1) {
            videoFiles.push(fileSrc)
          }
        }

        var safeImageUrl = Safety.verifiedLocalImageUrl(entry.image, verifiedMap)
        var parsedArgv = Safety.parseExecArgv(entry.execArgv)
        var argvStr = parsedArgv
          ? JSON.stringify(parsedArgv)
          : (typeof entry.execArgv === "string" ? Safety.bounded(entry.execArgv, Safety.MAX_BODY) : "")

        historyModel.append({
          key: key,
          id: origId,
          originalId: origId,
          app: Safety.bounded(String(entry.app || ""), Safety.MAX_APP_NAME),
          appIcon: Safety.bounded(String(entry.appIcon || ""), Safety.MAX_APP_NAME),
          summary: Safety.bounded(String(entry.summary || ""), Safety.MAX_SUMMARY),
          body: Safety.bounded(String(entry.body || ""), Safety.MAX_BODY),
          image: safeImageUrl,
          preview: previewSrc,
          file: fileSrc,
          glyph: Safety.safeGlyph(entry.glyph),
          exec: "",
          execArgv: argvStr,
          urgency: Number(entry.urgency || 1),
          timestamp: stamp,
          day: dayOf(stamp)
        })
      } catch (error) {
        console.warn("clock notifications: invalid history entry:", error)
      }
    }
    root.verifiedFiles = verifiedMap
    root.clampCursor()
    root.requestThumbs(videoFiles)
  }

  function dismissAll() {
    loadGeneration += 1
    discardPendingResults = true
    reloadPending = false

    var clearedAt = Math.floor(Date.now())
    localClearedBefore = Math.max(localClearedBefore, clearedAt)
    localDismissedKeys = ({})
    readMark = Math.max(readMark, clearedAt)
    localState.lastSeen = clearedAt

    // Omarchy gives plugins no way to edit its notification history (bar
    // plugins get a do-not-disturb proxy only), so Glance cannot delete rows
    // from history.json. The tombstone written below hides them here and in
    // the unread count; Omarchy drops them itself after its 24 h retention.
    // Cards still on screen are closed through the public IPC target.
    Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "dismissAll"])

    Quickshell.execDetached(["bash", "-c",
      "unreadbin=\"$1\"; stamp=\"$2\"\n" +
      "[[ -x $unreadbin ]] && \"$unreadbin\" clear-all \"$stamp\" >/dev/null 2>&1 || true",
      "--", unreadBinPath, String(clearedAt)])

    historyModel.clear()
    root.deactivateCursor()
  }

  function isFocusableApp(app) {
    return Safety.isFocusableApp(app)
  }

  function isVideoFile(path) {
    return Safety.isVideoFile(path)
  }

  function isImageFile(path) {
    return Safety.isImageFile(path)
  }

  function extractMediaFilePath(value) {
    return Safety.extractMediaFilePath(value)
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
    if (!Safety.isValidKey(key)) {
      historyModel.remove(index)
      root.clampCursor()
      return
    }

    localDismissedKeys[key] = true

    Quickshell.execDetached(["bash", "-c",
      "unreadbin=\"$1\"; key=\"$2\"\n" +
      "[[ -x $unreadbin ]] && \"$unreadbin\" dismiss-key \"$key\" >/dev/null 2>&1 || true",
      "--", unreadBinPath, key])

    historyModel.remove(index)
    root.clampCursor()
  }

  function parseExecArgv(value) {
    return Safety.parseExecArgv(value)
  }

  function openNotification(index) {
    if (index < 0 || index >= historyModel.count) return
    var entry = historyModel.get(index)
    if (!entry) return

    // 1. If an execArgv command is available, execute it safely first
    var argv = Safety.parseExecArgv(entry.execArgv)
    if (argv) {
      Util.execArgv(argv)
      dismissHistoryEntry(index)
      notificationActivated()
      return
    }

    // 2. Fallback: if a validated local media file is resolved, open via xdg-open --
    var filePath = Safety.localImagePath(entry.file)
    if (!filePath) {
      filePath = Safety.extractMediaFilePath(entry.execArgv || entry.exec)
    }
    if (filePath !== "" && root.verifiedFiles[filePath] === true) {
      Quickshell.execDetached(["xdg-open", "--", filePath])
      dismissHistoryEntry(index)
      notificationActivated()
      return
    }

    // 3. Otherwise focus or launch the application safely
    if (Safety.isFocusableApp(entry.app)) {
      launchApp(entry.app)
      dismissHistoryEntry(index)
      notificationActivated()
      return
    }

    // 4. System / informational notifications (notify-send, omarchy-action without file, etc.):
    // Clicking acknowledges and dismisses the notification, closing Glance
    dismissHistoryEntry(index)
    notificationActivated()
  }

  function launchApp(appName) {
    if (launchProc.running) return
    var name = String(appName || "").trim()
    if (!Safety.isFocusableApp(name)) return
    launchProc.command = ["bash", "-c", root.launchOrFocusScript, "--", name]
    launchProc.running = true
  }

  readonly property string launchOrFocusScript:
    "app=$1\n" +
    "if [[ -z $app || ${#app} -gt 256 || $app == *[[:cntrl:]]* ]]; then\n" +
    "  exit 0\n" +
    "fi\n" +
    "desktop=\n" +
    "app_lower=${app,,}\n" +
    "shopt -s nullglob\n" +
    "for dir in \"$HOME/.local/share/applications\" \"$HOME/.nix-profile/share/applications\" \"/usr/local/share/applications\" \"/usr/share/applications\"; do\n" +
    "  [[ -d $dir ]] || continue\n" +
    "  files=(\"$dir\"/*.desktop)\n" +
    "  (( ${#files[@]} > 0 )) || continue\n" +
    "  for file in \"${files[@]}\"; do\n" +
    "    [[ -f $file ]] || continue\n" +
    "    base=$(basename \"$file\" .desktop)\n" +
    "    if [[ $base == \"$app\" || ${base,,} == \"$app_lower\" ]]; then desktop=\"$file\"; break 2; fi\n" +
    "  done\n" +
    "  desktop=$(TARGET_APP=\"$app\" awk '\n" +
    "    BEGIN { target = tolower(ENVIRON[\"TARGET_APP\"]); in_entry = 0 }\n" +
    "    FNR == 1 { in_entry = 0 }\n" +
    "    /^\\[/ {\n" +
    "      if ($0 == \"[Desktop Entry]\") { in_entry = 1 }\n" +
    "      else { in_entry = 0 }\n" +
    "      next\n" +
    "    }\n" +
    "    in_entry && /^Name=/ {\n" +
    "      val = substr($0, 6)\n" +
    "      sub(/\\r$/, \"\", val)\n" +
    "      if (tolower(val) == target) { print FILENAME; exit 0 }\n" +
    "    }\n" +
    "  ' \"${files[@]}\" 2>/dev/null)\n" +
    "  [[ -n $desktop ]] && break\n" +
    "done\n" +
    "if [[ -z $desktop ]]; then\n" +
    "  escaped_app=$(printf '%s' \"$app\" | sed 's/[][(){}.+*?^$|\\\\]/\\\\&/g')\n" +
    "  omarchy-hyprland-focus-app \"$escaped_app\"\n" +
    "  exit 0\n" +
    "fi\n" +
    "id=$(basename \"$desktop\" .desktop)\n" +
    "wmclass=$(awk '\n" +
    "  BEGIN { in_entry = 0 }\n" +
    "  /^\\[/ {\n" +
    "    if ($0 == \"[Desktop Entry]\") { in_entry = 1 }\n" +
    "    else if (in_entry) { exit 0 }\n" +
    "    next\n" +
    "  }\n" +
    "  in_entry && /^StartupWMClass=/ {\n" +
    "    val = substr($0, 16)\n" +
    "    sub(/\\r$/, \"\", val)\n" +
    "    if (val != \"\") { print val; exit 0 }\n" +
    "  }\n" +
    "' \"$desktop\" 2>/dev/null)\n" +
    "address=$(hyprctl clients -j 2>/dev/null | jq -r --arg id \"$id\" --arg wmclass \"$wmclass\" --arg app \"$app\" '\n" +
    "  ([$id, $wmclass, $app] | map(select(type == \"string\" and length > 0) | ascii_downcase)) as $needles\n" +
    "  | first(\n" +
    "      .[]\n" +
    "      | select(\n" +
    "          ((.class // \"\") | ascii_downcase) as $cls\n" +
    "          | ($cls | length) > 0 and any($needles[]; . as $n | $cls | contains($n))\n" +
    "        )\n" +
    "    ).address // empty\n" +
    "')\n" +
    "if [[ $address =~ ^0x[0-9a-fA-F]+$ ]]; then\n" +
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

  readonly property int _appsRevision: DesktopEntries.applications ? DesktopEntries.applications.values.length : 0

  function resolveEntryIcon(iconName) {
    var value = String(iconName || "").trim()
    if (!Safety.isValidIconName(value)) return ""
    return Quickshell.iconPath(value, true)
  }

  function resolveDesktopIcon(deIcon) {
    var value = String(deIcon || "").trim()
    if (!value) return ""
    if (Safety.isValidIconName(value)) return Quickshell.iconPath(value, true)
    if (value.charAt(0) === "/") return Safety.localImageUrl(value)
    return ""
  }

  function resolveNotificationIcon(image, appIcon, app) {
    var dummy = root._appsRevision

    // 1. Direct image from notification (Security.js localImagePath rules + verified regular file)
    var img = String(image || "").trim()
    if (img !== "") {
      var imgUrl = Safety.verifiedLocalImageUrl(img, root.verifiedFiles)
      if (imgUrl) return imgUrl
    }

    // 2. Explicit appIcon (theme icon name only; never a path; + DesktopEntries lookup)
    var icon = String(appIcon || "").trim()
    if (Safety.isSafeLookupName(icon)) {
      var iconCandidates = Safety.themedIconCandidates(icon)
      for (var i = 0; i < iconCandidates.length; i++) {
        var iconPath = Quickshell.iconPath(iconCandidates[i], true)
        if (iconPath) return iconPath
      }
      var iconEntries = Safety.desktopLookupCandidates(icon, false)
      for (var j = 0; j < iconEntries.length; j++) {
        try {
          var entryFromIcon = DesktopEntries.heuristicLookup(iconEntries[j])
          if (entryFromIcon && entryFromIcon.icon) {
            var p = resolveDesktopIcon(entryFromIcon.icon)
            if (p) return p
          }
        } catch (_) {}
      }
    }

    // 3. Application name lookup (e.g. "ZapZap", "Zen", "Spotify"); never treat app as a path
    var appName = String(app || "").trim()
    if (Safety.isFocusableApp(appName) && appName !== "System" && Safety.isSafeLookupName(appName)) {
      var appIconCandidates = Safety.themedIconCandidates(appName)
      for (var k = 0; k < appIconCandidates.length; k++) {
        var direct = Quickshell.iconPath(appIconCandidates[k], true)
        if (direct) return direct
      }

      var appEntries = Safety.desktopLookupCandidates(appName, true)
      for (var m = 0; m < appEntries.length; m++) {
        try {
          var de = DesktopEntries.heuristicLookup(appEntries[m])
          if (de && de.icon) {
            var dePath = resolveDesktopIcon(de.icon)
            if (dePath) return dePath
          }
        } catch (_) {}
      }
    }

    return ""
  }

  function iconSource(value) {
    return resolveEntryIcon(value)
  }

  function readableBody(value) {
    return Safety.readableBody(value)
  }

  function dayOf(timestamp) {
    if (!timestamp || timestamp <= 0) return strings.t("notifications.earlier")
    var when = new Date(timestamp)
    var now = new Date(root.nowMs)
    var midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    if (timestamp >= midnight) return strings.t("notifications.today")
    if (timestamp >= midnight - 86400000) return strings.t("notifications.yesterday")
    var locale = Qt.locale(I18n.formatLocale)
    if (timestamp >= midnight - 6 * 86400000) return locale.toString(when, "dddd")
    if (when.getFullYear() === now.getFullYear()) return locale.toString(when, "d MMMM")
    return locale.toString(when, "d MMMM yyyy")
  }

  function timeLabel(timestamp) {
    var stamp = Number(timestamp || 0)
    if (!isFinite(stamp) || stamp <= 0) return ""
    var age = Math.max(0, root.nowMs - stamp)
    if (age < 60000) return strings.t("notifications.now")
    if (age < 3600000) return strings.t("notifications.minutesAgo").arg(Commons.I18n.formatNumber(Math.round(age / 60000)))
    return Qt.locale(I18n.formatLocale).toString(new Date(stamp), "HH:mm")
  }

  // Day sections are stored in the model when history loads, so rebuild them
  // when the Omarchy language changes.
  Connections {
    target: I18n
    function onFormatLocaleChanged() { root.reload() }
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
      if (!root.reloadPending) return
      root.reloadPending = false
      Qt.callLater(root.reload)
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.replaceHistory(text)
    }
  }

  function requestThumbs(files) {
    if (!files || files.length === 0) return
    if (thumbLoader.running) {
      root.pendingThumbFiles = files
      return
    }
    thumbLoader.command = [root.thumbBinPath].concat(files)
    thumbLoader.running = true
  }

  function applyThumbs(raw) {
    var lines = String(raw || "").split("\n")
    var next = Object.assign({}, root.videoThumbs)
    var nextVerified = Object.assign({}, root.verifiedFiles)
    var changed = false
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      try {
        var item = JSON.parse(line)
        var file = Safety.localImagePath(item.file)
        var thumb = Safety.localImagePath(item.thumb)
        if (!file || !Safety.isVideoFile(file) || !root.isAllowedThumbPath(thumb)) continue
        nextVerified[thumb] = true
        next[file] = Safety.localImageUrl(thumb)
        changed = true
      } catch (error) {}
    }
    if (!changed) return
    root.verifiedFiles = nextVerified
    root.videoThumbs = next
    for (var j = 0; j < historyModel.count; j++) {
      var row = historyModel.get(j)
      if (row.preview === "" && row.file !== "" && next[row.file])
        historyModel.setProperty(j, "preview", next[row.file])
    }
  }

  Process {
    id: thumbLoader
    running: false
    onExited: {
      if (root.pendingThumbFiles.length === 0) return
      var files = root.pendingThumbFiles
      root.pendingThumbFiles = []
      Qt.callLater(function() { root.requestThumbs(files) })
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyThumbs(text)
    }
  }

  Component.onCompleted: reload()

  ColumnLayout {
    anchors.fill: parent
    spacing: Style.space(10)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: strings.t("notifications.title")
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
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: strings.t("notifications.dismissAll")
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
          textFormat: Text.PlainText
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
        required property string execArgv
        required property int urgency
        required property double timestamp
        required property int originalId

        readonly property bool opens: root.canOpen(card)
        readonly property bool selected: root.cursorActive && card.index === root.cursorIndex
        readonly property string bodyText: root.readableBody(body)
        readonly property string resolvedIcon: root.resolveNotificationIcon(card.image, card.appIcon, card.app)
        readonly property string effectiveGlyph: {
          if (card.glyph !== "") return card.glyph
          if (card.summary.indexOf("Screen recording") !== -1 || root.isVideoFile(card.file)) return "󰻂"
          if (card.summary.indexOf("Screenshot") !== -1 || root.isImageFile(card.file)) return "󰹑"
          if (card.app === "notify-send" || card.app === "omarchy-action" || card.app === "" || card.app === "System") return "󰂚"
          return ""
        }
        readonly property bool unread: card.timestamp > root.readMark

        readonly property string previewSource: Safety.resolvePreviewSource(card.preview, card.file, root.verifiedFiles)
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
              visible: !avatar.hasIcon && card.effectiveGlyph !== ""
              text: card.effectiveGlyph
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
              color: root.foreground
              opacity: 0.85
            }

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              visible: !avatar.hasIcon && card.effectiveGlyph === ""
              text: root.appInitial(card.app)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.foreground
              opacity: 0.7
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
                text: card.app !== "" ? card.app : strings.t("notifications.system")
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
          textFormat: Text.PlainText
          Layout.alignment: Qt.AlignHCenter
          text: "󰂚"
          color: root.borderColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
        }

        Text {
          textFormat: Text.PlainText
          Layout.alignment: Qt.AlignHCenter
          text: strings.t("notifications.empty")
          color: root.dimForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
