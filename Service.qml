pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "StateMachine.js" as SM

// Headless service for joegeary.on-air. One instance per shell
// process: it owns every Process, Timer, file watcher and IPC handler in the
// plugin. BarWidget.qml is instantiated once per monitor and only reads
// properties / calls functions declared here.
//
// Detection (PLAN A2): `pactl subscribe` drives a short `pactl list
// source-outputs` re-read for microphone holders, a 2s `fuser` poll covers
// direct-V4L2 camera holders (PipeWire cannot see those), and
// ToplevelManager window titles label browser-hosted meetings. The debounced
// holder set is fed to StateMachine.js, which owns all hysteresis.
//
// Light control never happens here: every mutation goes through bin/on-air,
// driven by a single-in-flight reconciler comparing `desiredState` with the
// state the CLI last reported.
QtObject {
  id: root

  // ------------------------------------------------------------- injected
  // shell.qml sets these if the properties exist; nothing else is injected
  // into a service kind (in particular, no `settings`).
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || ""

  // ------------------------------------------------------- public surface
  // Everything BarWidget.qml binds to. Values are always defined, so the
  // widget only has to null-guard the service object itself.
  readonly property string state: _state
  // Manual on-air counts: the bar pill, the hero switch and the tooltip all
  // read this, and a manual override that lights the bulbs while the widget
  // still shows "off air" would look like a broken toggle.
  readonly property bool onAir: _state === "ON_AIR" || _state === "CLEARING"
    || _adoptedOnAir || _manualOnAir
  readonly property var activeApps: _activeApps
  readonly property var captures: _captures
  readonly property var detectedApps: _detectedApps
  readonly property int elapsedSeconds: _elapsedSeconds
  // Empty rather than "0s" when nothing is running, so callers can append it
  // conditionally.
  readonly property string elapsedText: _onAirSince > 0 ? root.formatElapsed(_elapsedSeconds) : ""
  readonly property var lastResult: _lastResult
  readonly property var targetRows: root.buildTargetRows(_targetHealth, _lastResult, root.targets)
  readonly property bool configured: root.targets.length > 0
  readonly property string lastError: _lastError
  readonly property bool paused: _paused
  readonly property bool manualOnAir: _manualOnAir
  readonly property bool stuckOnAir: _stuckOnAir
  readonly property bool degraded: _degraded
  readonly property bool busy: cliProcess.running

  // Config echoes, so the panel never parses config.json itself.
  readonly property string onAirColor: root.readColor(_config)
  readonly property int brightnessPercent: root.readBrightness(_config)
  readonly property int riseSeconds: Math.max(0, Math.round(Number(_config.riseSeconds)) || 0)
  readonly property int clearSeconds: Math.max(0, Math.round(Number(_config.clearSeconds)) || 0)
  readonly property var ignoreApps: _config.ignoreApps instanceof Array ? _config.ignoreApps : []
  readonly property var appNames: _config.appNames && typeof _config.appNames === "object" ? _config.appNames : ({})
  readonly property var targets: _config.targets instanceof Array ? _config.targets : []

  // Resolved once: the plugin dir is wherever the shell loaded this file from.
  // Qt.resolvedUrl(".") comes back without a trailing slash here, so the
  // separator is added explicitly rather than assumed.
  readonly property string pluginDir: root.ensureTrailingSlash(root.urlToPath(Qt.resolvedUrl(".")))
  readonly property string cliPath: pluginDir + "bin/on-air"
  // Mirrors bin/on-air's own resolution order exactly, because the FileView
  // watcher has to land on the file the CLI actually writes.
  readonly property string configPath: {
    var override = Quickshell.env("ON_AIR_CONFIG")
    if (override) return String(override)
    var configHome = Quickshell.env("XDG_CONFIG_HOME")
    if (!configHome) configHome = (Quickshell.env("HOME") || "") + "/.config"
    return String(configHome) + "/on-air/config.json"
  }
  // The directory the config lives in, watched as well: a watcher can only be
  // armed on something that exists, and config.json does not until setup runs.
  readonly property string configDir: {
    var path = root.configPath
    var cut = path.lastIndexOf("/")
    return cut > 0 ? path.slice(0, cut) : path
  }

  // The reconciler's target. Pause wins over everything, then a manual
  // override, then the state machine (adoption keeps a meeting that was
  // already lit from being cleared while the machine re-arms).
  readonly property string desiredState: {
    if (_paused) return "off_air"
    if (_manualOnAir) return "on_air"
    if (_state === "ON_AIR" || _state === "CLEARING") return "on_air"
    if (_adoptedOnAir) return "on_air"
    return "off_air"
  }

  // ------------------------------------------------------------- defaults
  // Used until `on-air config --json` answers, and whenever it cannot.
  readonly property var defaultConfig: ({
    version: 1,
    onAir: { color: "#ff0000", brightnessPercent: 100 },
    riseSeconds: 8,
    clearSeconds: 8,
    ignoreApps: ["obs", "obs-studio", "cheese", "guvcview", "voxtype", "pw-cat", "parecord", "arecord"],
    appNames: { zoom: "Zoom", "teams-for-linux": "Teams", slack: "Slack", discord: "Discord" },
    targets: []
  })

  // Browser binaries whose PipeWire identity says nothing useful — a meeting
  // in a Chromium app window reports "Chromium". Titles disambiguate.
  readonly property var browserBinaries: ["chromium", "chrome", "google-chrome", "google-chrome-stable",
    "brave", "brave-browser", "vivaldi", "vivaldi-bin", "microsoft-edge", "msedge",
    "firefox", "firefox-esr", "zen", "zen-bin", "librewolf", "waterfox", "epiphany"]

  // Ordered: the first pattern that matches a window title names the meeting.
  readonly property var meetingPatterns: [
    { re: /meet\.google\.com|google meet/i, label: "Google Meet" },
    { re: /\bzoom\b|zoom meeting|zoom workplace/i, label: "Zoom" },
    { re: /microsoft teams|\bteams\b/i, label: "Teams" },
    { re: /huddle|\bslack\b/i, label: "Slack" },
    { re: /\bdiscord\b/i, label: "Discord" },
    { re: /\bwebex\b/i, label: "Webex" },
    { re: /whereby|jitsi|bluejeans|gotomeeting/i, label: "Meeting" }
  ]

  // -------------------------------------------------------------- private
  property var _config: root.defaultConfig
  property var _machine: null
  property string _machineKey: ""

  property string _state: "OFF_AIR"
  property var _activeApps: []
  property var _captures: []
  property var _detectedApps: []
  property var _audioHolders: []
  property var _videoHolders: []
  // Bumped whenever any window title changes, so labels stay live.
  property int titleRevision: 0

  property bool _ready: false
  property bool _configLoaded: false
  property bool _statusLoaded: false
  property var _targetHealth: []
  property bool _audioScanned: false
  property bool _videoScanned: false
  property bool _shuttingDown: false

  property bool _paused: false
  // Lives in PersistentProperties: a hot reload fires on every file save under
  // the installed plugin dir, and a manual on-air that vanished there would let
  // startup adoption run `clear` in the middle of the user's own session.
  readonly property bool _manualOnAir: persisted.manualOnAir
  property bool _adoptedOnAir: false
  property bool _stuckOnAir: false
  property bool _degraded: false
  property bool _snapshotExists: false
  property double _snapshotStartedAt: 0

  property double _onAirSince: 0
  property int _elapsedSeconds: 0

  property string _reportedState: ""
  property string _requestedState: ""
  property var _lastResult: null
  property string _lastError: ""
  property bool _runOk: true
  property int _retryDelayMs: 1000
  // Wall-clock deadline the backoff is actually enforced against: the
  // reconciler runs on every scan, so the timer alone would never hold it back.
  property double _nextRetryAtMs: 0
  property string _cliErr: ""
  property var _auxQueue: []
  property string _auxKind: ""
  property bool _pauseBusy: false
  // Pause/unpause commands queued or in flight. A result from an older one
  // must never overwrite a newer intent.
  property int _pauseInFlight: 0
  property bool _statusPending: false
  // Set between PrepareForSleep(true) and the resume signal: the reconciler
  // must not re-light the bulbs the sleep hook has just cleared.
  property bool _suspending: false
  property double _suspendStartedAt: 0

  property int _monitorBackoffMs: 1000
  property int _sleepBackoffMs: 1000
  property bool _sleepArgPending: false

  // ------------------------------------------------------------ utilities
  function urlToPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.slice(7)
    return decodeURIComponent(value)
  }

  function ensureTrailingSlash(path) {
    var value = String(path || "")
    return value.length > 0 && value.charAt(value.length - 1) === "/" ? value : value + "/"
  }

  function baseName(value) {
    var parts = String(value || "").split("/")
    return parts[parts.length - 1]
  }

  function formatElapsed(seconds) {
    var total = Math.max(0, Math.floor(seconds))
    if (total < 60) return total + "s"
    var minutes = Math.floor(total / 60)
    var hours = Math.floor(minutes / 60)
    if (hours <= 0) return minutes + "m"
    var rest = minutes % 60
    return hours + "h " + (rest < 10 ? "0" : "") + rest + "m"
  }

  function readColor(config) {
    var onAirBlock = config && config.onAir ? config.onAir : ({})
    var value = String(onAirBlock.color || "#ff0000")
    return /^#[0-9a-fA-F]{6}$/.test(value) ? value.toLowerCase() : "#ff0000"
  }

  function readBrightness(config) {
    var onAirBlock = config && config.onAir ? config.onAir : ({})
    var value = Math.round(Number(onAirBlock.brightnessPercent))
    if (!isFinite(value)) value = 100
    return Math.max(1, Math.min(100, value))
  }

  function isIgnored(binary) {
    var wanted = String(binary || "").toLowerCase()
    var list = root.ignoreApps
    for (var i = 0; i < list.length; i++) {
      if (String(list[i] || "").toLowerCase() === wanted) return true
    }
    return false
  }

  function isBrowser(binary) {
    return root.browserBinaries.indexOf(String(binary || "").toLowerCase()) >= 0
  }

  // ------------------------------------------------------ window titles
  // Bound below through `_titleRevision` so a title *change* on an existing
  // toplevel re-runs the label lookup, not just open/close.
  function meetingTitleLabel() {
    var manager = ToplevelManager.toplevels
    var list = manager ? manager.values : []
    var patterns = root.meetingPatterns
    for (var p = 0; p < patterns.length; p++) {
      for (var i = 0; i < list.length; i++) {
        var toplevel = list[i]
        if (!toplevel) continue
        var title = String(toplevel.title || "")
        if (title !== "" && patterns[p].re.test(title)) return patterns[p].label
        var appId = String(toplevel.appId || "")
        if (appId !== "" && patterns[p].re.test(appId)) return patterns[p].label
      }
    }
    return ""
  }

  // Display name for a capture holder: window title for browser-hosted
  // meetings, otherwise the configured appNames mapping, otherwise nothing
  // (the state machine falls back to the binary name).
  function labelFor(binary) {
    var key = String(binary || "").toLowerCase()
    if (key === "") return ""
    if (root.isBrowser(key)) {
      var titleLabel = root.meetingTitleLabel()
      if (titleLabel !== "") return titleLabel
    }
    var names = root.appNames
    if (names[key]) return String(names[key])
    var keys = Object.keys(names)
    for (var i = 0; i < keys.length; i++) {
      if (String(keys[i]).toLowerCase() === key) return String(names[keys[i]])
    }
    return ""
  }

  // ------------------------------------------------------------- parsing
  // `pactl list source-outputs` is a flat indented block per stream.
  function parseSourceOutputs(text) {
    var records = []
    var lines = String(text || "").split("\n")
    var current = null
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var head = line.match(/^Source Output #(\d+)/)
      if (head) {
        if (current) records.push(current)
        current = { id: head[1], corked: false, props: ({}) }
        continue
      }
      if (!current) continue
      var corked = line.match(/^\s*Corked:\s*(\S+)/)
      if (corked) {
        current.corked = corked[1] === "yes"
        continue
      }
      var prop = line.match(/^\s*([A-Za-z0-9_.\-]+)\s*=\s*"(.*)"\s*$/)
      if (prop) current.props[prop[1]] = prop[2]
    }
    if (current) records.push(current)
    return records
  }

  function audioHoldersFrom(text) {
    var records = root.parseSourceOutputs(text)
    var holders = []
    for (var i = 0; i < records.length; i++) {
      var record = records[i]
      var mediaClass = String(record.props["media.class"] || "")
      // Stream/Input/Audio is a real capture; the .../Internal variant is
      // WirePlumber's own loopback plumbing and is always present.
      if (mediaClass.indexOf("Stream/Input/Audio") !== 0) continue
      if (mediaClass.indexOf("/Internal") >= 0) continue
      if (record.corked) continue
      var binary = record.props["application.process.binary"]
        || record.props["application.name"]
        || record.props["node.name"]
        || "unknown"
      holders.push({ binary: root.baseName(binary), kind: "audio" })
    }
    return holders
  }

  // One "<pid> <comm>" line per process holding a camera node.
  function videoHoldersFrom(text) {
    var holders = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].trim().split(/\s+/)
      if (parts.length < 2 || !/^\d+$/.test(parts[0])) continue
      holders.push({ binary: root.baseName(parts[1]), kind: "video" })
    }
    return holders
  }

  // --------------------------------------------------- machine plumbing
  function machineConfig() {
    var list = []
    var ignore = root.ignoreApps
    for (var i = 0; i < ignore.length; i++) list.push(String(ignore[i]))
    return {
      riseSeconds: root.riseSeconds,
      clearSeconds: root.clearSeconds,
      ignoreApps: list
    }
  }

  // Only the fields the machine actually consumes; a change here (and only
  // here) forces a rebuild.
  function machineKey() {
    return JSON.stringify(root.machineConfig())
  }

  // Timing and ignore-list edits are applied in place: StateMachine.js reads
  // those fields on every step, so a config change mid-meeting retimes the
  // windows without resetting the ON_AIR/OFF_AIR base state.
  function ensureMachine() {
    var key = root.machineKey()
    if (root._machine && key === root._machineKey) return
    var config = root.machineConfig()
    if (!root._machine) {
      root._machine = SM.createMachine(config)
    } else {
      root._machine.riseSeconds = config.riseSeconds
      root._machine.clearSeconds = config.clearSeconds
      root._machine.ignoreApps = config.ignoreApps
    }
    root._machineKey = key
  }

  function currentCaptures() {
    var holders = []
    var seen = ({})
    var sources = [root._audioHolders, root._videoHolders]
    for (var s = 0; s < sources.length; s++) {
      var list = sources[s] || []
      for (var i = 0; i < list.length; i++) {
        var binary = String(list[i].binary || "")
        if (binary === "") continue
        var key = list[i].kind + "\n" + binary.toLowerCase()
        if (seen[key]) continue
        seen[key] = true
        var label = root.labelFor(binary)
        var capture = { binary: binary, kind: list[i].kind }
        if (label !== "") capture.app = label
        holders.push(capture)
      }
    }
    return holders
  }

  function describeCaptures(captures) {
    var rows = []
    var seen = ({})
    for (var i = 0; i < captures.length; i++) {
      var binary = String(captures[i].binary || "")
      var key = binary.toLowerCase()
      if (seen[key]) continue
      seen[key] = true
      rows.push({
        binary: binary,
        label: String(captures[i].app || binary),
        kind: String(captures[i].kind || ""),
        ignored: root.isIgnored(binary)
      })
    }
    return rows
  }

  function evaluate() {
    root.ensureMachine()
    var captures = root.currentCaptures()
    var now = Date.now()
    var result = SM.step(root._machine, captures, now)

    root._captures = captures
    root._detectedApps = root.describeCaptures(captures)
    root._state = String(result.state || "OFF_AIR")
    root._activeApps = result.activeApps instanceof Array ? result.activeApps : []

    if (result.transition === "to_on_air") root.enterOnAir(now)
    else if (result.transition === "to_off_air") root.enterOffAir()

    root.scheduleWake(result.nextWakeMs, now)
    root.refreshAdoption()
    root.expirePause()
    root.reconcile()
  }

  // SPEC: a pause is scoped to the current meeting and expires once capture has
  // been quiet for clearSeconds — which is precisely "the machine is OFF_AIR
  // with nothing holding a capture". Keying off the to_off_air transition
  // instead would make a pause taken while already off-air (right-click, or one
  // restored from pause.json at startup) permanent, silently blocking every
  // later meeting. A manual override is not meeting-scoped, so it holds.
  function expirePause() {
    if (!root._paused || root._manualOnAir || root._adoptedOnAir) return
    if (root._state !== "OFF_AIR" || root._activeApps.length > 0) return
    root.setPaused(false)
  }

  function enterOnAir(now) {
    root._adoptedOnAir = false
    if (root._onAirSince <= 0) root._onAirSince = now
    root.tickElapsed()
  }

  function enterOffAir() {
    // A manual override outlives the meeting that happened to be running, so
    // its clock keeps going (SPEC/A4: manual on-air never auto-clears).
    if (!root._manualOnAir) {
      root._onAirSince = 0
      root._elapsedSeconds = 0
    }
    // The pause expires here too, but through expirePause() — see there for
    // why the quiet condition, not this transition, is what ends it.
  }

  function refreshAdoption() {
    if (!root._adoptedOnAir) return
    // Adoption ends either when the machine agrees we are live, or when there
    // is nothing left holding a capture to sustain it.
    if (root._state === "ON_AIR" || root._activeApps.length === 0) root._adoptedOnAir = false
  }

  function scheduleWake(nextWakeMs, now) {
    if (nextWakeMs === null || nextWakeMs === undefined) {
      wakeTimer.stop()
      return
    }
    wakeTimer.interval = Math.max(50, Math.round(Number(nextWakeMs) - now))
    wakeTimer.restart()
  }

  function tickElapsed() {
    root._elapsedSeconds = root._onAirSince > 0
      ? Math.floor((Date.now() - root._onAirSince) / 1000)
      : 0
  }

  function forceResync(reason) {
    if (root._machine) SM.forceResync(root._machine)
    if (String(reason || "") !== "") root._lastError = String(reason)
    root.scanAudio()
    root.scanVideo()
    root.evaluate()
  }

  // ------------------------------------------------------------ scanning
  function scanAudio() {
    if (audioScanProcess.running) {
      audioDebounce.restart()
      return
    }
    audioScanProcess.running = true
  }

  function scanVideo() {
    if (videoScanProcess.running) return
    videoScanProcess.running = true
  }

  function markReady() {
    if (root._ready) return
    if (!root._configLoaded || !root._statusLoaded || !root._audioScanned || !root._videoScanned) return
    root._ready = true
    root.runStartupAdoption()
    root.reconcile()
  }

  // SPEC startup adoption: a snapshot plus an active capture means the shell
  // restarted mid-meeting — adopt ON_AIR without re-snapshotting. A snapshot
  // with nothing capturing means the lights are stranded: clear them.
  function runStartupAdoption() {
    // A manual on-air survived a hot reload. Its clock is not persisted, so it
    // is re-armed from the snapshot the previous instance left behind rather
    // than restarting at zero.
    if (root._manualOnAir && root._onAirSince <= 0) {
      root._onAirSince = root._snapshotStartedAt > 0 ? root._snapshotStartedAt : Date.now()
      root.tickElapsed()
    }
    if (!root._snapshotExists) {
      root._reportedState = "off_air"
      return
    }
    // The CLI last left the lights on-air; the reconciler decides from here.
    root._reportedState = "on_air"
    // desiredState already reads on_air from the manual override, so there is
    // no adoption to do and — crucially — no `clear` to run.
    if (root._manualOnAir) return
    if (root._activeApps.length > 0) {
      root._adoptedOnAir = true
      // The rise window already elapsed in the shell process that took the
      // snapshot, so seed the machine hot rather than counting it again: the
      // bulb is red right now, and a PENDING widget above a red bulb reads as
      // a bug. The latch above still covers the gap until the next evaluate().
      if (root._machine && SM.adopt(root._machine, root._captures)) {
        root._state = "ON_AIR"
      }
      root._onAirSince = root._snapshotStartedAt > 0 ? root._snapshotStartedAt : Date.now()
      root.tickElapsed()
    }
  }

  // ---------------------------------------------------------- config I/O
  function reloadConfig() {
    if (root._degraded) {
      root._configLoaded = true
      root.markReady()
      return
    }
    if (configProcess.running) {
      configDebounce.restart()
      return
    }
    configProcess.command = [root.cliPath, "config", "--json"]
    configProcess.running = true
  }

  function applyConfig(text) {
    var parsed = null
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (error) {
      parsed = null
    }
    if (!parsed || typeof parsed !== "object") return false

    var merged = ({})
    var defaults = root.defaultConfig
    var keys = Object.keys(defaults)
    for (var i = 0; i < keys.length; i++) merged[keys[i]] = defaults[keys[i]]
    var incoming = Object.keys(parsed)
    for (var j = 0; j < incoming.length; j++) {
      if (parsed[incoming[j]] !== null && parsed[incoming[j]] !== undefined) {
        merged[incoming[j]] = parsed[incoming[j]]
      }
    }
    root._config = merged
    return true
  }

  // `on-air status --json` is the runtime half: pause file, snapshot (with the
  // startedAt that makes elapsed survive a shell restart) and per-target
  // reachability. It probes the bridges, so it runs at startup and on an
  // explicit refresh only — never on every config reload.
  function loadStatus() {
    if (root._degraded) {
      root._statusLoaded = true
      root.markReady()
      return
    }
    // Never drop a requested re-read: a probe that is already in flight was
    // started before whatever just changed, and a pause/unpause still in the
    // queue would have this one racing the file it is about to write.
    if (statusProcess.running || root._pauseInFlight > 0) {
      root._statusPending = true
      return
    }
    root._statusPending = false
    statusProcess.command = [root.cliPath, "status", "--json"]
    statusProcess.running = true
  }

  function applyStatus(text) {
    var parsed = null
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (error) {
      parsed = null
    }
    if (!parsed || typeof parsed !== "object") return false

    var reported = String(parsed.state || "off_air")
    root._paused = reported === "paused"
    // A pause restores the lights while keeping the snapshot, so only a plain
    // on_air means the bulbs are currently red.
    root._reportedState = reported === "on_air" ? "on_air" : "off_air"

    var snapshot = parsed.snapshot && typeof parsed.snapshot === "object" ? parsed.snapshot : null
    root._snapshotExists = snapshot !== null
    // The CLI stores epoch seconds; everything in QML is milliseconds.
    var startedAt = snapshot ? Number(snapshot.startedAt) : 0
    root._snapshotStartedAt = isFinite(startedAt) && startedAt > 0 ? startedAt * 1000 : 0

    root._targetHealth = parsed.targets instanceof Array ? parsed.targets : []
    return true
  }

  // ---------------------------------------------------------- reconciler
  // Single in flight: one CLI process at a time, queued transitions collapse
  // to whatever `desiredState` says when the current run exits.
  function reconcile() {
    if (!root._ready || root._degraded || root._shuttingDown) return
    if (root._pauseBusy) return
    // The machine is on its way down and the sleep hook has already cleared
    // the lights; re-triggering now would leave them red for the whole suspend.
    if (root._suspending) return
    // Nothing configured means nothing to converge on; running `trigger` would
    // only fail, notify and retry forever.
    if (root.targets.length === 0) return
    if (cliProcess.running) return
    if (root._reportedState === root.desiredState && root._runOk) {
      retryTimer.stop()
      root._nextRetryAtMs = 0
      return
    }
    // A run that failed, or one that succeeded without converging, backs off
    // (capped at 60s). evaluate() calls reconcile() on every scan, so the
    // deadline — not retryTimer alone — is what holds the retry back; only a
    // genuinely new target jumps the queue.
    if (root.desiredState === root._requestedState && Date.now() < root._nextRetryAtMs) return
    root.runCli(root.desiredState === "on_air" ? ["trigger"] : ["clear"])
  }

  function runCli(args) {
    retryTimer.stop()
    root._requestedState = root.desiredState
    var command = [root.cliPath]
    for (var i = 0; i < args.length; i++) command.push(args[i])
    cliProcess.command = command
    cliProcess.running = true
  }

  // Every mutating command prints exactly one JSON line; take the last one so
  // stray output cannot break parsing.
  function parseResultLine(text) {
    var lines = String(text || "").split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = lines[i].trim()
      if (line.indexOf("{") !== 0) continue
      try {
        var parsed = JSON.parse(line)
        if (parsed && typeof parsed === "object") return parsed
      } catch (error) {
        // keep looking at earlier lines
      }
    }
    return null
  }

  function resultErrorText(result, exitCode) {
    if (result && result.failed instanceof Array && result.failed.length > 0) {
      var first = result.failed[0] || ({})
      return String(first.error || "failed") + (first.target ? " (" + first.target + ")" : "")
    }
    if (result && result.error) return String(result.error)
    // No JSON line at all: the CLI died on a usage/config error and said why
    // on stderr.
    if (root._cliErr !== "") return root._cliErr
    return "on-air exited " + exitCode
  }

  // The CLI's result line reports one of on_air / off_air / paused. Anything
  // else — the "error" line a usage failure prints, or the "test" flash — says
  // nothing about where the lights ended up, so the last known reported state
  // has to stand or the reconciler would chase a value it can never match.
  function applyReportedState(state) {
    var value = String(state || "")
    if (value === "on_air" || value === "off_air") {
      root._reportedState = value
      return
    }
    if (value === "paused") {
      // `trigger` refuses while a pause file exists: something outside this
      // shell (a terminal, another session) owns the pause. Adopt it rather
      // than retrying a command that will keep being refused.
      root._paused = true
      root._reportedState = "off_air"
    }
  }

  function handleCliExit(exitCode, output) {
    var result = root.parseResultLine(output)
    if (result) {
      root._lastResult = result
      root.applyReportedState(result.state)
    }
    var failedCount = result && result.failed instanceof Array ? result.failed.length : 0
    root._runOk = exitCode === 0 && failedCount === 0 && result !== null

    if (root._runOk) {
      root._lastError = ""
      root._retryDelayMs = 1000
      root._nextRetryAtMs = 0
      root._stuckOnAir = false
      root.noteSuccess()
      retryTimer.stop()
      // The target moved while the CLI was in flight (the user paused
      // mid-run): converge on the newest desired state immediately. A run
      // that succeeded but still disagrees with an unchanged target is a CLI
      // disagreement, not a queued transition — that goes through the backoff
      // below so we can never spin.
      if (root.desiredState !== root._requestedState) root.reconcile()
      else if (root._reportedState !== root.desiredState) root.scheduleRetry()
      return
    }

    root._lastError = root.resultErrorText(result, exitCode)
    // A snapshot that will not restore is the one failure we never abandon.
    root._stuckOnAir = root.desiredState === "off_air"
    root.noteFailure(root._lastError)
    root.scheduleRetry()
  }

  // Capped exponential backoff, retried indefinitely: SPEC never lets a red
  // light be silently abandoned.
  function scheduleRetry() {
    retryTimer.interval = root._retryDelayMs
    root._nextRetryAtMs = Date.now() + root._retryDelayMs
    root._retryDelayMs = Math.min(60000, root._retryDelayMs * 2)
    retryTimer.restart()
  }

  // ------------------------------------------------------- notifications
  function notify(message) {
    var base = root.omarchyPath || Quickshell.env("OMARCHY_PATH") || ""
    var binary = base !== "" ? base + "/bin/omarchy-notification-send" : "omarchy-notification-send"
    Quickshell.execDetached([binary, "On Air", String(message)])
  }

  function noteFailure(message) {
    if (persisted.notifiedFailure) return
    persisted.notifiedFailure = true
    root.notify("Lights did not respond: " + message)
  }

  function noteSuccess() {
    if (!persisted.notifiedFailure) return
    persisted.notifiedFailure = false
    root.notify("Lights are back under control.")
  }

  // --------------------------------------------------------- CLI actions
  function queueAux(args) {
    if (root._degraded) return
    var queue = root._auxQueue.slice()
    queue.push(args)
    root._auxQueue = queue
    root.pumpAux()
  }

  function pumpAux() {
    if (auxProcess.running || root._auxQueue.length === 0) return
    var queue = root._auxQueue.slice()
    var next = queue.shift()
    root._auxQueue = queue
    root._auxKind = String(next[0])
    var command = [root.cliPath]
    for (var i = 0; i < next.length; i++) command.push(String(next[i]))
    auxProcess.command = command
    auxProcess.running = true
  }

  // ------------------------------------------------------ public actions
  // A4 hero switch: one control, four meanings depending on where we are.
  function toggleManual() {
    if (root._paused) {
      root.setPaused(false)
      return
    }
    if (root._manualOnAir) {
      persisted.manualOnAir = false
      // A meeting that is genuinely live keeps its own clock running.
      if (root._state !== "ON_AIR" && root._state !== "CLEARING") {
        root._onAirSince = 0
        root._elapsedSeconds = 0
      }
      return
    }
    if (root.onAir) {
      root.setPaused(true)
      return
    }
    persisted.manualOnAir = true
    if (root._onAirSince <= 0) {
      root._onAirSince = Date.now()
      root.tickElapsed()
    }
  }

  // Quick pause/resume (bar right-click, IPC). Pausing is only meaningful
  // while something is on air: a pause taken off-air has nothing to restore and
  // would only sit there blocking the next meeting until it expired.
  function pauseResume() {
    if (root._paused) {
      root.setPaused(false)
      return
    }
    if (root.onAir) root.setPaused(true)
  }

  // `on-air pause` restores the lights itself and keeps the snapshot, so the
  // reconciler must stay out of the way until the CLI has finished and
  // `status --json` has told us what actually happened. Without the latch the
  // desiredState handler fires a `clear` the instant _paused flips, which
  // deletes the very snapshot the pause is supposed to preserve.
  function setPaused(value) {
    var next = value === true
    if (next === root._paused) return
    if (next) root._reportedState = "off_air"
    if (!root._degraded) root._pauseBusy = true
    root._paused = next
    if (!root._degraded) root._pauseInFlight = root._pauseInFlight + 1
    root.queueAux([next ? "pause" : "unpause"])
  }

  function setConfigValue(key, jsonValue) {
    root.queueAux(["config", "set", String(key), String(jsonValue)])
  }

  function addIgnore(binary) {
    var name = String(binary || "").trim()
    if (name === "") return
    root.queueAux(["ignore", "add", name])
  }

  function removeIgnore(binary) {
    var name = String(binary || "").trim()
    if (name === "") return
    root.queueAux(["ignore", "remove", name])
  }

  function runTestFlash() {
    root.queueAux(["test"])
  }

  // Terminal fallback chain lives in the script so one detached process can
  // try each launcher in order without us probing the system first.
  function openWizard() {
    if (root._degraded) return
    var script = 'cli="$1"; '
      + 'if command -v alacritty >/dev/null 2>&1; then exec alacritty -e "$cli" setup; fi; '
      + 'if [ -n "$TERMINAL" ] && command -v "$TERMINAL" >/dev/null 2>&1; then exec "$TERMINAL" -e "$cli" setup; fi; '
      + 'if command -v xdg-terminal-exec >/dev/null 2>&1; then exec xdg-terminal-exec "$cli" setup; fi; '
      + 'if command -v omarchy-notification-send >/dev/null 2>&1; then '
      + 'omarchy-notification-send "On Air" "No terminal found. Run: $cli setup"; fi'
    Quickshell.execDetached(["bash", "-c", script, "on-air-wizard", root.cliPath])
  }

  function refresh() {
    root.reloadConfig()
    root.loadStatus()
    root.forceResync("")
  }

  function statusJson() {
    return JSON.stringify({
      state: root._state,
      onAir: root.onAir,
      apps: root._activeApps,
      elapsedSeconds: root._elapsedSeconds,
      paused: root._paused,
      manualOnAir: root._manualOnAir,
      stuckOnAir: root._stuckOnAir,
      degraded: root._degraded,
      desired: root.desiredState,
      reported: root._reportedState,
      lastError: root._lastError
    })
  }

  // ----------------------------------------------------------- panel rows
  function targetLabel(target) {
    var driver = String(target.driver || "target")
    if (target.bridgeId) return driver + ":" + String(target.bridgeId).slice(-6)
    if (target.baseUrl) return driver + ":" + String(target.baseUrl)
    return driver
  }

  // One row per configured target: reachability comes from the last
  // `status --json` probe, the error text prefers the most recent real
  // failure the reconciler saw for that driver.
  function buildTargetRows(health, result, configuredTargets) {
    var failed = result && result.failed instanceof Array ? result.failed : []
    var rows = []
    var i = 0

    if (health.length > 0) {
      for (i = 0; i < health.length; i++) {
        var probe = health[i] || ({})
        var driver = String(probe.driver || "")
        var reachable = probe.reachable === true
        rows.push({
          id: driver + (probe.id ? ":" + String(probe.id) : ""),
          driver: driver,
          ok: reachable,
          error: reachable ? root.failureFor(failed, driver) : String(probe.error || "unreachable")
        })
      }
      return rows
    }

    for (i = 0; i < configuredTargets.length; i++) {
      var target = configuredTargets[i] || ({})
      var configuredDriver = String(target.driver || "")
      rows.push({
        id: root.targetLabel(target),
        driver: configuredDriver,
        ok: null,
        error: root.failureFor(failed, configuredDriver)
      })
    }
    return rows
  }

  // Failure entries are labelled "<driver>:<lightId>".
  function failureFor(failed, driver) {
    if (driver === "") return ""
    for (var i = 0; i < failed.length; i++) {
      var entry = failed[i] || ({})
      if (String(entry.target || "").split(":")[0] === driver) return String(entry.error || "failed")
    }
    return ""
  }

  // ------------------------------------------------------------ lifecycle
  Component.onCompleted: {
    root.ensureMachine()
    cliCheckProcess.running = true
  }

  Component.onDestruction: {
    root._shuttingDown = true
    // Live-reload must never leave a monitor behind.
    subscribeProcess.running = false
    sleepMonitorProcess.running = false
    audioScanProcess.running = false
    videoScanProcess.running = false
    cliProcess.running = false
    auxProcess.running = false
    configProcess.running = false
    statusProcess.running = false
    sleepClearProcess.running = false
  }

  // ------------------------------------------------------------ processes
  // One-shot executable check: a missing or non-executable CLI puts us in
  // degraded mode (meetings still tracked, no light control).
  property Process cliCheckProcess: Process {
    id: cliCheckProcess
    command: ["test", "-x", root.cliPath]
    onExited: function (exitCode) {
      root._degraded = exitCode !== 0
      if (root._degraded && !persisted.notifiedMissingCli) {
        persisted.notifiedMissingCli = true
        root.notify("bin/on-air is missing or not executable — running without light control.")
      }
      if (!root._degraded) persisted.notifiedMissingCli = false
      root.reloadConfig()
      root.loadStatus()
      root.scanAudio()
      root.scanVideo()
      // Guarded, because configRetry re-runs this check while degraded: the
      // monitors must not be restarted (or stacked) every 15 seconds.
      if (!subscribeProcess.running && !root._shuttingDown) subscribeProcess.running = true
      if (!sleepMonitorProcess.running && !root._shuttingDown) sleepMonitorProcess.running = true
    }
  }

  property Process statusProcess: Process {
    id: statusProcess
    command: []
    stdout: StdioCollector {
      id: statusCollector
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode === 0) root.applyStatus(statusCollector.text)
      root._statusLoaded = true
      root.markReady()
      root.reconcile()
      if (root._statusPending) root.loadStatus()
    }
  }

  property Process configProcess: Process {
    id: configProcess
    command: []
    stdout: StdioCollector {
      id: configCollector
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode === 0) root.applyConfig(configCollector.text)
      root._configLoaded = true
      // Evaluate before markReady so startup adoption sees this scan's result.
      root.evaluate()
      root.markReady()
    }
  }

  // Long-running event stream. One line per PulseAudio event; only
  // source-output events can change who holds the microphone.
  property Process subscribeProcess: Process {
    id: subscribeProcess
    // Both pactl readers parse its English output ("Source Output #",
    // "Corked:", the event lines here). Under a localised session pactl
    // translates those, and every match silently stops firing. `env` execs
    // pactl in place, so this costs no extra process and the Process still
    // owns the pactl pid directly. (Process.environment is a QVariantHash,
    // which a QML object literal cannot be assigned to without a qmllint
    // incompatible-type warning.)
    command: ["env", "LC_ALL=C", "pactl", "subscribe"]
    stdout: SplitParser {
      onRead: function (line) {
        if (String(line).indexOf("source-output") >= 0) audioDebounce.restart()
      }
    }
    onExited: function () {
      if (root._shuttingDown) return
      monitorRestart.interval = root._monitorBackoffMs
      root._monitorBackoffMs = Math.min(30000, root._monitorBackoffMs * 2)
      monitorRestart.restart()
    }
  }

  property Process audioScanProcess: Process {
    id: audioScanProcess
    // LC_ALL=C for the same reason as the subscribe monitor above.
    command: ["env", "LC_ALL=C", "pactl", "list", "source-outputs"]
    stdout: StdioCollector {
      id: audioCollector
      waitForEnd: true
    }
    onExited: function () {
      root._audioHolders = root.audioHoldersFrom(audioCollector.text)
      root._audioScanned = true
      root.evaluate()
      root.markReady()
    }
  }

  // fuser resolves the holder PID for us (a /proc/*/fd walk would have to
  // enumerate every process); comm turns it into a binary name. Every capture
  // node that exists is probed, not a guess at video0/video1 — a second webcam
  // or a camera that came up as video2 was invisible before.
  property Process videoScanProcess: Process {
    id: videoScanProcess
    command: ["bash", "-c",
      'devs=(); for d in /dev/video*; do [ -e "$d" ] || continue; devs+=("$d"); done; '
      + '[ ${#devs[@]} -gt 0 ] || exit 0; '
      + 'for pid in $(fuser "${devs[@]}" 2>/dev/null); do '
      + 'comm=$(cat /proc/$pid/comm 2>/dev/null); echo "$pid ${comm:-unknown}"; done']
    stdout: StdioCollector {
      id: videoCollector
      waitForEnd: true
    }
    onExited: function () {
      root._videoHolders = root.videoHoldersFrom(videoCollector.text)
      root._videoScanned = true
      root.evaluate()
      root.markReady()
    }
  }

  property Process cliProcess: Process {
    id: cliProcess
    command: []
    stdout: StdioCollector {
      id: cliCollector
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: cliErrCollector
      waitForEnd: true
    }
    onExited: function (exitCode) {
      root._cliErr = String(cliErrCollector.text || "").split("\n")[0]
      root.handleCliExit(exitCode, cliCollector.text)
    }
  }

  // Non-reconciling commands (pause/resume/config set/ignore/test). They are
  // serialised so two config writes cannot race each other.
  property Process auxProcess: Process {
    id: auxProcess
    command: []
    stdout: StdioCollector {
      id: auxCollector
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: auxErrCollector
      waitForEnd: true
    }
    onExited: function (exitCode) {
      var result = root.parseResultLine(auxCollector.text)
      var kind = root._auxKind
      root._auxKind = ""
      root._cliErr = String(auxErrCollector.text || "").split("\n")[0]
      var failed = result && result.failed instanceof Array ? result.failed : []
      var pauseKind = kind === "pause" || kind === "unpause"
      // A newer pause/unpause is already queued, so this result describes an
      // intent the user has since replaced: report it, but never adopt it.
      var superseded = false
      if (pauseKind) {
        root._pauseInFlight = Math.max(0, root._pauseInFlight - 1)
        superseded = root._pauseInFlight > 0
      }
      if (result) {
        root._lastResult = result
        if (!superseded && String(result.state || "") === "paused") root._paused = true
      }
      if (failed.length > 0) {
        root._lastError = root.resultErrorText(result, exitCode)
        // A pause that could not restore every light leaves one red, and the
        // reconciler would otherwise sit converged on "off_air" while the bulb
        // is still on-air. Hand it back to the retry machinery.
        if (kind === "pause") {
          root._stuckOnAir = true
          root._runOk = false
          root.scheduleRetry()
        }
        root.noteFailure(root._lastError)
      } else if (exitCode !== 0) {
        // A rejected `config set`, a `test` refused because a real snapshot
        // exists: worth showing in the panel, not worth a desktop notification.
        root._lastError = root.resultErrorText(result, exitCode)
      } else if (root._runOk && !root._stuckOnAir) {
        // Clean run and nothing else is broken: drop a stale message.
        root._lastError = ""
      }
      root.pumpAux()
      // Pause writes state, not config: re-read the runtime half, and let the
      // status result release the reconciler. Everything else edits config.json.
      // While a newer pause/unpause is still queued the latch stays closed and
      // the re-read waits for it, so status cannot read a half-applied pause.
      if (pauseKind) {
        if (!superseded) {
          root._pauseBusy = false
          root.loadStatus()
        }
      } else {
        root.reloadConfig()
      }
    }
  }

  // Suspend/resume. dbus-monitor prints the member on one line and its
  // boolean argument on the next.
  property Process sleepMonitorProcess: Process {
    id: sleepMonitorProcess
    command: ["dbus-monitor", "--system",
      "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'"]
    stdout: SplitParser {
      onRead: function (line) {
        var text = String(line)
        if (text.indexOf("PrepareForSleep") >= 0) {
          root._sleepArgPending = true
          return
        }
        if (!root._sleepArgPending) return
        var match = text.match(/boolean\s+(true|false)/)
        if (!match) return
        root._sleepArgPending = false
        if (match[1] === "true") root.prepareForSleep()
        else root.resumeFromSleep()
      }
    }
    onExited: function () {
      if (root._shuttingDown) return
      sleepMonitorRestart.interval = root._sleepBackoffMs
      root._sleepBackoffMs = Math.min(30000, root._sleepBackoffMs * 2)
      sleepMonitorRestart.restart()
    }
  }

  property Process sleepClearProcess: Process {
    id: sleepClearProcess
    command: []
    onExited: function () {
      // The lights are back to their prior state but the snapshot survives, so
      // a wake that is still mid-meeting re-triggers instead of re-snapshotting.
      // The suspend latch is what keeps the reconciler from doing that *now*,
      // while the machine is still going down.
      root._reportedState = "off_air"
    }
  }

  function prepareForSleep() {
    if (root._degraded) return
    root._suspending = true
    root._suspendStartedAt = Date.now()
    sleepClearProcess.command = [root.cliPath, "clear", "--keep-snapshot"]
    sleepClearProcess.running = true
  }

  function resumeFromSleep() {
    root._suspending = false
    root._monitorBackoffMs = 1000
    if (!subscribeProcess.running && !root._shuttingDown) subscribeProcess.running = true
    root.forceResync("")
  }

  // Safety valve for a resume signal that never arrives (dbus-monitor died
  // across the suspend, the bus dropped the second signal): this only ever runs
  // while the machine is awake, so a long gap means we are back and no light
  // control has been happening.
  property Timer suspendLatchGuard: Timer {
    id: suspendLatchGuard
    interval: 15000
    repeat: true
    running: root._suspending
    onTriggered: {
      if (!root._suspending) return
      if (Date.now() - root._suspendStartedAt < 120000) return
      root._suspending = false
      root.forceResync("")
    }
  }

  // -------------------------------------------------------------- timers
  property Timer audioDebounce: Timer {
    id: audioDebounce
    interval: 250
    repeat: false
    onTriggered: root.scanAudio()
  }

  property Timer configDebounce: Timer {
    id: configDebounce
    interval: 250
    repeat: false
    onTriggered: root.reloadConfig()
  }

  property Timer videoPoll: Timer {
    id: videoPoll
    interval: 2000
    repeat: true
    running: true
    onTriggered: root.scanVideo()
  }

  // Hysteresis deadlines: the machine tells us when it next needs to be
  // stepped even if no event arrives.
  property Timer wakeTimer: Timer {
    id: wakeTimer
    interval: 1000
    repeat: false
    onTriggered: root.evaluate()
  }

  property Timer elapsedTimer: Timer {
    id: elapsedTimer
    interval: 1000
    repeat: true
    running: root._onAirSince > 0
    onTriggered: root.tickElapsed()
  }

  property Timer retryTimer: Timer {
    id: retryTimer
    interval: 1000
    repeat: false
    onTriggered: {
      // The wait is over: clear the deadline so reconcile() does not measure
      // this very call against it.
      root._nextRetryAtMs = 0
      root.reconcile()
    }
  }

  property Timer monitorRestart: Timer {
    id: monitorRestart
    interval: 1000
    repeat: false
    onTriggered: {
      if (root._shuttingDown) return
      subscribeProcess.running = true
      // Incremental events were missed while the monitor was down.
      root.forceResync("")
    }
  }

  property Timer sleepMonitorRestart: Timer {
    id: sleepMonitorRestart
    interval: 1000
    repeat: false
    onTriggered: if (!root._shuttingDown) sleepMonitorProcess.running = true
  }

  // ------------------------------------------------------------ watchers
  // SPEC: the service never parses config.json itself; the watcher only tells
  // it when to ask the CLI again.
  //
  // Three layers, because config.json does not exist until the wizard runs and
  // FileView cannot arm a watcher on a file that is not there (the same reason
  // the shell's own Bar.qml watches a toggles *directory* rather than the flag
  // file inside it):
  //   1. the file watcher, once the file exists;
  //   2. a watcher on the containing directory, which catches its creation;
  //   3. a slow poll for the first-run case where the directory itself is
  //      missing, or the CLI was not runnable when we last asked.
  property FileView configWatcher: FileView {
    id: configWatcherView
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: {
      configWatcherView.reload()
      configDebounce.restart()
    }
  }

  property FileView configDirWatcher: FileView {
    id: configDirWatcherView
    path: root.configDir
    watchChanges: true
    printErrors: false
    // Only the file view is reloaded: that is what re-arms its watcher now
    // that config.json exists. Reading the directory itself would just fail.
    onFileChanged: {
      configWatcherView.reload()
      configDebounce.restart()
    }
  }

  // Cheap (one `on-air config --json`) and only while there is nothing to
  // watch: the moment a config with targets loads, this stops.
  property Timer configRetry: Timer {
    id: configRetry
    interval: 15000
    repeat: true
    running: !root._shuttingDown && (root._degraded || !root.configured)
    onTriggered: {
      configWatcherView.reload()
      // Degraded means the CLI itself was missing when we looked; re-checking
      // is the only way back, and it re-reads the config on the way.
      if (root._degraded) {
        if (!cliCheckProcess.running) cliCheckProcess.running = true
      } else {
        root.reloadConfig()
      }
    }
  }

  // Reactive labels: a Chromium window that becomes a Zoom meeting changes
  // its title without opening or closing, so watch each toplevel's title.
  property Instantiator titleWatcher: Instantiator {
    id: titleWatcher
    model: ToplevelManager.toplevels
    delegate: Connections {
      required property var modelData
      target: modelData
      function onTitleChanged(): void {
        root.titleRevision = root.titleRevision + 1
      }
    }
  }

  property Timer labelDebounce: Timer {
    id: labelDebounce
    interval: 400
    repeat: false
    onTriggered: root.evaluate()
  }

  onTitleRevisionChanged: labelDebounce.restart()

  property PersistentProperties persisted: PersistentProperties {
    id: persisted
    reloadableId: "joegeary.on-air"
    property bool notifiedFailure: false
    property bool notifiedMissingCli: false
    property bool manualOnAir: false
  }

  // --------------------------------------------------------------- IPC
  property IpcHandler ipc: IpcHandler {
    id: ipc
    target: "on-air"

    function status(): string {
      return root.statusJson()
    }

    function toggle(): string {
      root.toggleManual()
      return root.desiredState
    }

    function pause(): string {
      // Same rule as the bar's right-click: there is nothing to pause off-air.
      if (!root.onAir) return "not on air"
      root.setPaused(true)
      return "ok"
    }

    function resume(): string {
      root.setPaused(false)
      return "ok"
    }

    function refresh(): string {
      root.refresh()
      return "ok"
    }

    function ping(): string {
      return "ok"
    }
  }

  onDesiredStateChanged: root.reconcile()
}
