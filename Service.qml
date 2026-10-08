import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Uses Proton's official CLI as the connection owner. The CLI performs live
// server selection, DNS setup, NetworkManager integration, and firewall
// handling; this plugin only presents that state in the Omarchy bar.
Item {
  id: root

  property var settings: ({})

  // Set by BarWidget: true while this monitor's panel is open. Open panel =
  // faster CLI status polling.
  property bool panelOpen: false

  property bool installed: false
  property bool connected: false
  property string tunnelIp: ""
  property string tunnelDevice: ""
  property string rxRate: ""
  property string txRate: ""
  property string serverName: ""
  property string serverCity: ""
  property string serverCountry: ""
  property string serverLoad: ""
  property string protocol: ""
  property string backendState: "Unknown"
  property string statusText: "Checking\u2026"
  property string connectedUptime: ""
  property var connectedSince: 0
  property string actionStatus: ""
  property string lastError: ""
  property var freeCountries: []
  property var serverRows: ({})
  property string serverFilter: "all"
  property var _parsedList: null
  signal filterChanged()
  // Fires once a requested connection is confirmed by a status poll.
  signal connectSucceeded()
  // Fires when a connect target is used so the panel can persist it
  // (settings.lastTarget) for the next plain connect.
  signal targetUsed(var target)

  // Last place we connected to, { code, city, name, filter }. Plain connect
  // (switch, right click, hotkey + enter) goes back there instead of
  // "fastest anywhere". The local copy wins over the saved setting until the
  // shell has written it back.
  property var _lastTargetLocal: null
  readonly property var lastTarget: {
    if (_lastTargetLocal) return _lastTargetLocal
    var t = settings ? settings.lastTarget : null
    if (!t || typeof t !== "object") return null
    return { code: t.code || "", city: t.city || "", name: t.name || "", filter: t.filter || "all" }
  }
  function describeTarget(t) { return t ? Model.describeFavorite(_parsedList, Model.targetAsFavorite(t), _countryNames) : null }
  property bool refreshing: false
  property bool toggling: false

  // ---- shared polling (one Service per monitor; see Model.claimLeader) ----
  readonly property string _iid: Math.random().toString(36).slice(2, 10)
  property bool isLeader: false
  // Cheap, keyring-free sample of the live network state; see Model.parseQuick.
  property var quick: Model.parseQuick("")
  property string _lastQuickText: ""
  property string _lastStatusStdout: ""
  property real _lastCliAt: 0
  property int _sharedRev: 0
  property real _mismatchAt: 0
  property int _mismatchTries: 0
  property real _rxChangedAt: 0
  property real _lastRx: -1
  property int _protectionTick: 0
  // "off" | "protected" | "leaking" | "stale" | "blocked"; see Model.protectionState.
  readonly property var protectionInfo: {
    _protectionTick
    var idle = connected && _rxChangedAt > 0 ? Date.now() - _rxChangedAt : 0
    return Model.protectionState(connected, quick, idle)
  }
  readonly property string protection: protectionInfo.state
  // True from a connect request until the CLI returns; drives the bar's
  // "acquiring" icon.
  property bool connecting: false
  property bool _sharedConnect: false
  readonly property bool connectingAny: connecting || _sharedConnect

  // ---- torrent tunnel (system/ install; see README) ----
  // Installed when /usr/local/bin/pvpn-torrent-launch exists. The namespace
  // check and qBittorrent's whereabouts come from comparing network namespace
  // inodes, which needs no root; tunnel details come from the status file the
  // root port-forward loop writes.
  property bool torrentInstalled: false
  property bool _torrentNs: false
  readonly property bool torrentUp: _torrentNs && torrentStatus.up === "1"
  property bool torrentBusy: false
  property var torrentStatus: ({})
  // "none" | "inside" | "outside" (leak: real connection) | "stale" (in an
  // old namespace after a tunnel restart: no network until restarted)
  property string qbtState: "none"
  // Other torrent apps (transmission, deluge, ...) running outside the tunnel.
  property var otherOutside: []
  readonly property bool torrentLeak: qbtState === "outside" && torrentInstalled
  // Re-evaluated whenever the status file (every 15s) or the qBittorrent
  // check (every 10s) updates; see Model.torrentHealth.
  // _healthTick (bumped every 10s) makes the handshake age re-evaluate even if
  // the status file stops updating.
  property int _healthTick: 0
  readonly property var torrentHealth: { _healthTick; return Model.torrentHealth(torrentInstalled, torrentUp, qbtState, torrentStatus, Date.now(), otherOutside) }
  readonly property string torrentState: torrentHealth.state
  onTorrentStateChanged: {
    if (torrentState === "error" && Model.shouldNotifyTorrent("error:" + torrentHealth.reason, Date.now()))
      notify("Torrent tunnel problem", torrentHealth.reason, true)
    else if (torrentState !== "error") Model.shouldNotifyTorrent(torrentState, Date.now())
  }

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property bool notificationsEnabled: boolSetting("notificationsEnabled", true)
  // Optimistic switch state: -1 follows the real `connected`, 0/1 is the
  // desired state set the instant a toggle is clicked. The panel switch binds
  // to this so its knob throws immediately instead of waiting for the next
  // status poll, then reconciles with reality in applyStatus.
  readonly property bool switchOn: _desiredConnected === -1 ? connected : (_desiredConnected === 1)
  readonly property bool busy: statusProcess.running || deviceIpProcess.running || toggleProcess.running || whichProcess.running
  readonly property string serverListPath: (Quickshell.env("HOME") || "") + "/.cache/Proton/VPN/serverlist.json"

  property string _statusOutput: ""
  property string _statusError: ""
  property string _deviceIpOutput: ""
  property string _toggleOutput: ""
  property string _toggleError: ""
  property string _countryOutput: ""
  property var _countryNames: ({})
  property string _serverListText: ""
  property bool _stateKnown: false
  property bool _settingsLoaded: false
  property bool _lastConnected: false
  property var _netBytes: null
  property var _netSampleAt: 0
  property string _netDevOutput: ""
  property int _desiredConnected: -1

  function intSetting(name, fallback, min, max) {
    var v = parseInt(settings ? settings[name] : undefined, 10)
    if (isNaN(v)) return fallback
    return Math.max(min, Math.min(max, v))
  }

  function boolSetting(name, fallback) {
    if (!settings || settings[name] === undefined || settings[name] === null) return fallback
    var v = String(settings[name]).toLowerCase()
    if (v === "true" || v === "1" || v === "on" || v === "yes") return true
    if (v === "false" || v === "0" || v === "off" || v === "no") return false
    return fallback
  }

  // Fires a desktop notification through the shell's notification daemon via
  // notify-send, so do-not-disturb and popup styling are handled centrally.
  function notify(summary, body, critical) {
    if (!notificationsEnabled) return
    var args = ["notify-send", "--app-name=Proton VPN", "--urgency=" + (critical ? "critical" : "normal")]
    args.push(String(summary || ""))
    if (body !== "") args.push(String(body))
    Quickshell.execDetached(args)
  }

  // Runs the CLI status command. Only the leader polls on its own; any
  // instance can force one after an action it started. The result is
  // published so the other monitor's Service shows the same state without
  // running the CLI (and touching the keyring) itself.
  function refresh(force) {
    if (!installed) {
      if (!whichProcess.running) {
        whichProcess.command = ["which", "protonvpn"]
        whichProcess.running = true
      }
      return
    }
    if (!force && !isLeader) return
    if (!statusProcess.running) {
      refreshing = true
      _statusOutput = ""
      _statusError = ""
      _lastCliAt = Date.now()
      statusProcess.command = ["protonvpn", "status"]
      statusProcess.running = true
    }
  }

  // One shell call gathering everything the icon needs: tunnel device, route,
  // DNS, bytes received, kill switch, Tailscale, local network. No root, no
  // keyring access.
  function runQuick() {
    if (quickProcess.running) return
    quickProcess.running = true
  }

  function applyQuick(text, fromShared) {
    _lastQuickText = text
    var q = Model.parseQuick(text)
    quick = q
    var now = Date.now()
    if (q.rx !== _lastRx) { _lastRx = q.rx; _rxChangedAt = now }
    if (q.vpnDevice === "") _rxChangedAt = 0
    else if (_rxChangedAt === 0) _rxChangedAt = now
    setTunnelDevice(q.vpnDevice)
    _protectionTick++
    maybeLookupExitIp()
    if (fromShared) return

    // Leader: decide whether the CLI needs to run.
    var interval = (panelOpen ? refreshIntervalSec : Math.max(300, refreshIntervalSec * 10)) * 1000
    var mismatch = (q.vpnDevice !== "") !== connected
    // A lasting disagreement (CLI failing, an unusual tunnel device) must not
    // turn into a CLI call every 5s: one immediate refresh, then back off
    // 5s, 10s, 20s ... up to 60s until the two agree again.
    var mismatchDue = false
    if (mismatch) {
      if (now >= _mismatchAt) {
        mismatchDue = true
        _mismatchAt = now + Math.min(60000, 5000 * Math.pow(2, _mismatchTries))
        _mismatchTries++
      }
    } else {
      _mismatchTries = 0
      _mismatchAt = 0
    }
    if (!installed || !_stateKnown || mismatchDue || now - _lastCliAt >= interval) refresh(true)
    else Model.publishShared(_lastStatusStdout, text, now)
    maybeAlwaysOn()
  }

  // Public address of the desktop VPN, fetched through the tunnel interface
  // (so it can only succeed through it) while this instance's panel is open,
  // once per new tunnel/server.
  property string exitIp: ""
  property string _exitIpFor: ""
  property real _exitIpTriedAt: 0

  function maybeLookupExitIp() {
    if (!connected || tunnelDevice === "") {
      if (exitIp !== "" || _exitIpFor !== "") { exitIp = ""; _exitIpFor = "" }
      return
    }
    if (!panelOpen || exitIpProcess.running) return
    var key = tunnelDevice + "|" + serverName
    if (key === _exitIpFor) return
    if (Date.now() - _exitIpTriedAt < 60000 && exitIp === "" && _exitIpFor === "") return
    _exitIpFor = key
    _exitIpTriedAt = Date.now()
    exitIpProcess.command = ["curl", "-s", "--max-time", "6", "--interface", tunnelIp !== "" ? tunnelIp : tunnelDevice, "https://ifconfig.me/ip"]
    exitIpProcess.running = true
  }

  onPanelOpenChanged: if (panelOpen) maybeLookupExitIp()

  function setTunnelDevice(device) {
    if (device === tunnelDevice) return
    tunnelDevice = device
    if (device === "") {
      tunnelIp = ""
      rxRate = ""
      txRate = ""
      _netBytes = null
      return
    }
    deviceIpProcess.command = ["nmcli", "-g", "IP4.ADDRESS", "dev", "show", device]
    if (!deviceIpProcess.running) deviceIpProcess.running = true
  }

  // Followers copy what the leader published instead of polling themselves.
  function syncFromShared() {
    var snap = Model.sharedSnapshot()
    if (snap.rev === _sharedRev) return
    _sharedRev = snap.rev
    if (snap.quick !== "") applyQuick(snap.quick, true)
    if (snap.status !== "") applyStatus(snap.status, true)
  }

  // ---- Always On: reconnect after an unexpected drop ----
  // Off by default. Acts only in the leader instance and only when the user
  // wanted the VPN up (a plugin disconnect clears that). 30s backoff between
  // tries; after one failed try it falls back to "fastest" instead of the
  // last target.
  property int _alwaysOnLocal: -1
  readonly property bool alwaysOn: _alwaysOnLocal !== -1 ? _alwaysOnLocal === 1 : boolSetting("alwaysOn", false)
  signal alwaysOnToggled()
  property real _aoNextAt: 0
  property bool _aoFailed: false
  property bool _autoAttempt: false
  property bool _aoNotified: false

  function setAlwaysOn(on) {
    _alwaysOnLocal = on ? 1 : 0
    alwaysOnToggled()
    if (on && !connected && !toggling) {
      // Turning it on while disconnected connects right away.
      connect()
    } else if (on && connected) {
      Model.setWantUp(true)
    }
    if (!on) _aoFailed = false
  }

  function maybeAlwaysOn() {
    var now = Date.now()
    // The tunnel device is ground truth: a failed CLI status call must never
    // fire a connect on top of a live tunnel.
    if (!isLeader || !alwaysOn || connected || connecting || toggling || !_stateKnown || quick.vpnDevice !== "") return
    if (!Model.wantUp() || Model.actionBusy(now) || now < _aoNextAt) return
    _aoNextAt = now + 30000
    if (!_aoNotified) {
      _aoNotified = true
      notify("Proton VPN dropped", _aoFailed ? "Reconnecting to the fastest server\u2026" : "Reconnecting\u2026", false)
    }
    _autoAttempt = true
    if (_aoFailed || !lastTarget) connectServer("", "", "", "all", true)
    else connectServer(lastTarget.code, lastTarget.city, lastTarget.name, lastTarget.filter, true)
  }

  // ---- Proton settings (kill switch, NetShield, ... and the protocol) ----
  property var protonSettings: ({})
  property bool settingBusy: false
  property string protocolSetting: ""

  function refreshSettings() {
    if (!installed || settingsListProcess.running) return
    settingsListProcess.running = true
    protocolFile.reload()
  }

  function protonSettingValue(def) {
    if (def.kind === "plugin") return alwaysOn ? "on" : "off"
    return def.kind === "file" ? protocolSetting : (protonSettings[def.key] || "")
  }

  // Cycles one setting to its next value.
  function cycleSetting(def) {
    if (settingBusy) return
    var next = Model.nextSettingValue(def, protonSettingValue(def))
    if (def.kind === "plugin") { setAlwaysOn(next === "on"); return }
    // Don't edit Proton's settings file while a CLI command may be using it.
    if (def.kind === "file" && (toggling || statusProcess.running || Model.actionBusy(Date.now()))) return
    settingBusy = true
    _settingKey = def.key
    _settingValue = next
    if (def.kind === "cli") {
      settingSetProcess.command = ["protonvpn", "config", "set", def.key, next]
    } else {
      // Atomic edit of one key; never creates the file, refuses unknown values.
      settingSetProcess.command = ["python3", "-I", "-c",
        "import json,os,sys\np=os.path.expanduser('~/.config/Proton/VPN/settings.json')\nd=json.load(open(p))\nassert sys.argv[1] in ('wireguard','openvpn-udp','openvpn-tcp')\nd['protocol']=sys.argv[1]\nt=p+'.tmp'\njson.dump(d,open(t,'w'),indent=2)\nos.replace(t,p)", next]
    }
    settingSetProcess.running = true
  }
  property string _settingKey: ""
  property string _settingValue: ""

  // ---- torrent tunnel leak check (read-only root helper) ----
  property bool checkAvailable: false
  property bool checkRunning: false
  property var checkResult: null
  property real checkAt: 0

  // Runs pvpn-torrent-check, saves the full report under
  // ~/Documents/VPN leak checks/ (newest 20 kept) and keeps the summary.
  function runLeakCheck() {
    if (checkRunning || !torrentInstalled) return
    checkRunning = true
    checkProcess.running = true
  }

  function openReports() {
    Quickshell.execDetached(["sh", "-c", "mkdir -p \"$HOME/Documents/VPN leak checks\" && xdg-open \"$HOME/Documents/VPN leak checks\""])
  }

  function refreshTorrent() {
    _healthTick++
    if (qbtCheckProcess.running) return
    qbtCheckProcess.running = true
    torrentStatusFile.reload()
  }

  function setTorrentTunnel(on) {
    if (torrentBusy || !torrentInstalled) return
    torrentBusy = true
    actionStatus = on ? "Starting torrent tunnel\u2026" : "Stopping torrent tunnel\u2026"
    torrentToggleProcess.command = ["sudo", "-n", "systemctl", on ? "start" : "stop", "pvpn-torrent.service"]
    torrentToggleProcess.running = true
  }

  // Through the wrapper, which re-launches inside the namespace via sudo and
  // refuses (with a notification) when the tunnel is down.
  function openQbittorrent() {
    Quickshell.execDetached(["/usr/local/bin/qbittorrent"])
    torrentRecheck.restart()
  }

  function applyQbtCheck(text) {
    var r = Model.parseQbtCheck(text)
    torrentInstalled = r.installed
    _torrentNs = r.nsUp
    otherOutside = r.otherOutside
    checkAvailable = r.checkAvailable
    qbtState = r.outside > 0 ? "outside" : (r.stale > 0 ? "stale" : (r.inside > 0 ? "inside" : "none"))
  }

  function refreshServerList() {
    if (!countryProcess.running) {
      _countryOutput = ""
      countryProcess.command = ["protonvpn", "countries", "list"]
      countryProcess.running = true
    }
    serverListFile.reload()
  }

  function applyServerList() {
    _parsedList = Model.parseServerList(_serverListText)
    var rows = Model.serverListRows(_parsedList, _countryNames)
    freeCountries = rows.free || []
    serverRows = rows
  }

  function searchRows(query) { return Model.searchRows(_parsedList, serverFilter, query, serverRows[serverFilter] || [], _countryNames, 40) }
  function describeFavorite(fav) { return Model.describeFavorite(_parsedList, fav, _countryNames) }
  // ---- map data (computed on demand, cached per filter) ----
  function mapPointsFor(filter) {
    return Model.mapPointsCached(_parsedList, filter)
  }

  // Where the connected server is (and, for Secure Core, where it enters).
  readonly property var connectedLocation: connected && serverName !== "" ? Model.serverLocation(_parsedList, serverName) : null
  readonly property var secureCoreEntry: connectedLocation && connectedLocation.secureCore ? Model.countryCenter(_parsedList, connectedLocation.entry) : null

  function cityRows(country) { return Model.cityRows(_parsedList, serverFilter, country) }
  function serverRowsIn(country, city) { return Model.serverRowsIn(_parsedList, serverFilter, country, city) }

  // Connects to the fastest server matching the active type filter, narrowed
  // by country and/or city, using the CLI's feature flags where they exist
  // (--p2p / --securecore / --tor). `name` connects to one specific server.
  function connectServer(code, city, name, filterKey, auto) {
    if (toggling) return
    if (!Model.beginAction(Date.now(), "connect")) return
    var filter = filterKey || serverFilter
    var target = { code: code || "", city: city || "", name: name || "", filter: filter }
    if (!auto) {
      _lastTargetLocal = target
      targetUsed(target)
      Model.setWantUp(true)
    }
    _desiredConnected = 1
    var args = ["protonvpn", "connect"]
    var flag = Model.filterFlag(filter)
    if (name) {
      args.push(String(name))
    } else {
      if (flag !== "") args.push(flag)
      if (city && city !== "Other") args.push("--city", String(city))
      else if (code) args.push("--country", String(code))
    }
    toggling = true
    connecting = true
    lastError = ""
    actionStatus = "Connecting to " + (name ? name : "fastest " + (flag !== "" ? filter + " " : "") + "server" + (city ? " in " + city : (code ? " in " + code : ""))) + "\u2026"
    toggleProcess.command = args
    toggleProcess.running = true
  }

  function cycleServerFilter() {
    var list = Model.SERVER_FILTERS
    var idx = 0
    for (var i = 0; i < list.length; i++) if (list[i].key === serverFilter) idx = i
    // Skip filters with nothing to show on this plan (Free always stays).
    for (var step = 1; step <= list.length; step++) {
      var next = list[(idx + step) % list.length]
      var rows = serverRows[next.key]
      if (next.key === "all" || (rows && rows.length > 0)) { serverFilter = next.key; filterChanged(); return }
    }
  }

  function applyStatus(stdout, fromShared) {
    _lastStatusStdout = stdout
    var parsed = Model.parseCliStatus(stdout)
    var prevConnected = root._lastConnected
    connected = parsed.connected
    // Once the real state matches the optimistic value, drop back to tracking
    // reality so the knob always reflects the true connection.
    if (_desiredConnected !== -1 && connected === (_desiredConnected === 1)) _desiredConnected = -1
    if (connecting && !toggling) {
      connecting = false
      if (connected) connectSucceeded()
    }
    serverName = parsed.serverName
    serverCity = parsed.serverCity
    serverCountry = parsed.serverCountry
    serverLoad = parsed.load
    protocol = parsed.protocol
    refreshing = false
    backendState = connected ? "Connected" : "Disconnected"
    statusText = connected ? "Connected" : "Disconnected"
    if (connected) {
      if (!prevConnected && _stateKnown) connectedSince = Date.now()
    } else {
      connectedSince = 0
    }
    connectedUptime = connected ? formatUptime() : ""
    _lastConnected = connected
    if (_stateKnown && prevConnected !== connected) {
      if (connected && Model.shouldNotifyTransition(true, Date.now())) {
        notify("Proton VPN connected", "Connected to " + Model.serverLabel(parsed.serverName, parsed.serverCity, parsed.serverCountry, ""), false)
      } else if (!connected && Model.shouldNotifyTransition(false, Date.now())) {
        notify("Proton VPN disconnected", "", false)
      }
    }
    _stateKnown = true
    if (connected) {
      _aoNotified = false
      _aoFailed = false
      if (alwaysOn) Model.setWantUp(true)
    }
    maybeAlwaysOn()
  }

  function sampleTraffic() {
    if (!connected || !tunnelDevice || netProcess.running) return
    _netDevOutput = ""
    netProcess.command = ["cat", "/proc/net/dev"]
    netProcess.running = true
  }

  function applyNetDev(stdout) {
    var bytes = Model.parseNetDev(String(stdout), tunnelDevice)
    if (!bytes) return
    var now = Date.now()
    if (_netBytes) {
      var dt = Math.max(1, now - _netSampleAt) / 1000
      rxRate = Model.formatRate(Math.max(0, bytes.rx - _netBytes.rx), dt)
      txRate = Model.formatRate(Math.max(0, bytes.tx - _netBytes.tx), dt)
    }
    _netBytes = bytes
    _netSampleAt = now
  }

  function toggle() {
    if (toggling) return
    if (connected) disconnect()
    else connect()
  }

  function connect() {
    if (toggling || connected) return
    if (lastTarget) {
      connectServer(lastTarget.code, lastTarget.city, lastTarget.name, lastTarget.filter)
      return
    }
    if (!Model.beginAction(Date.now(), "connect")) return
    Model.setWantUp(true)
    toggling = true
    connecting = true
    lastError = ""
    _desiredConnected = 1
    actionStatus = "Connecting to fastest server\u2026"
    toggleProcess.command = ["protonvpn", "connect"]
    toggleProcess.running = true
  }

  function disconnect() {
    if (toggling || !connected) return
    if (!Model.beginAction(Date.now(), "disconnect")) return
    Model.setWantUp(false)
    _aoNotified = false
    toggling = true
    lastError = ""
    _desiredConnected = 0
    actionStatus = "Disconnecting\u2026"
    toggleProcess.command = ["protonvpn", "disconnect"]
    toggleProcess.running = true
  }

  function copyText(text) {
    if (text === "") return
    Quickshell.execDetached(["sh", "-c", "printf '%s' '" + String(text).replace(/'/g, "'\\''") + "' | wl-copy"])
    actionStatus = "Copied " + text
    actionStatusTimer.restart()
  }

  // Formats the elapsed wall-clock time of the current session uptime.
  function formatUptime() {
    if (!connectedSince) return ""
    return Model.formatUptime(Date.now() - connectedSince)
  }

  Timer {
    id: torrentTimer
    interval: 10000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshTorrent()
  }

  Timer {
    id: torrentRecheck
    interval: 2500
    onTriggered: root.refreshTorrent()
  }

  Process {
    id: qbtCheckProcess
    // installed/ns header, then where each qBittorrent process lives.
    command: ["sh", "-c", "i=0; [ -x /usr/local/bin/pvpn-torrent-launch ] && i=1; n=0; [ -e /run/netns/pvpntor ] && n=1; c=0; [ -x /usr/local/bin/pvpn-torrent-check ] && c=1; echo \"installed=$i ns=$n check=$c\"; ns=$(stat -Lc %i /run/netns/pvpntor 2>/dev/null); me=$(stat -Lc %i /proc/self/ns/net); for a in qbittorrent qbittorrent-nox transmission-daemon transmission-gtk transmission-qt deluged deluge deluge-gtk rtorrent ktorrent aria2c; do for p in $(pgrep -u \"$(id -u)\" -x \"$a\"); do x=$(stat -Lc %i /proc/$p/ns/net 2>/dev/null) || continue; if [ -n \"$ns\" ] && [ \"$x\" = \"$ns\" ]; then echo \"inside $a\"; elif [ \"$x\" = \"$me\" ]; then echo \"outside $a\"; else echo \"stale $a\"; fi; done; done; for s in transmission transmission-daemon deluged qbittorrent-nox rtorrent; do systemctl is-active --quiet $s.service 2>/dev/null && echo \"outside $s.service\"; done; true"]
    stdout: StdioCollector { id: qbtCheckStdout; waitForEnd: true }
    onExited: root.applyQbtCheck(String(qbtCheckStdout.text || ""))
  }

  Process {
    id: settingsListProcess
    command: ["protonvpn", "config", "list"]
    stdout: StdioCollector { id: settingsListStdout; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.protonSettings = Model.parseConfigList(String(settingsListStdout.text || ""))
    }
  }

  Process {
    id: settingSetProcess
    command: []
    stderr: StdioCollector { id: settingSetStderr; waitForEnd: true }
    stdout: StdioCollector { id: settingSetStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.settingBusy = false
      if (exitCode !== 0) {
        root.lastError = Model.elideStatus(settingSetStderr.text || settingSetStdout.text || "Could not change the setting")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        if (root._settingKey === "protocol") root.actionStatus = "Protocol applies on the next connect"
        else if (root._settingKey === "kill-switch" && root._settingValue === "standard" && root.quick.tailscale)
          root.actionStatus = "Kill switch is on: it blocks Tailscale while the VPN is connected"
        else root.actionStatus = ""
        if (root.actionStatus !== "") actionStatusTimer.restart()
      }
      root.refreshSettings()
    }
  }

  FileView {
    id: protocolFile
    path: (Quickshell.env("HOME") || "") + "/.config/Proton/VPN/settings.json"
    printErrors: false
    onLoaded: {
      try { root.protocolSetting = String(JSON.parse(text()).protocol || "") } catch (e) { root.protocolSetting = "" }
    }
  }

  Process {
    id: checkProcess
    command: ["sh", "-c", "d=\"$HOME/Documents/VPN leak checks\"; mkdir -p \"$d\"; ts=$(date +%Y-%m-%d_%H%M%S); out=$(sudo -n /usr/local/bin/pvpn-torrent-check 2>&1); { echo \"Proton VPN torrent tunnel check, $(date)\"; echo; printf '%s\\n' \"$out\" | awk -F'\\t' '$1==\"SUMMARY\"{print \"RESULT: \" $2 \" passed, \" $3 \" failed, \" $4 \" warnings\"; next} {print $1 \": \" $2}'; } > \"$d/torrent-$ts.txt\"; cp \"$d/torrent-$ts.txt\" \"$d/latest-torrent.txt\"; ls -1t \"$d\"/torrent-*.txt | tail -n +21 | xargs -r rm -f; printf '%s\\n' \"$out\""]
    stdout: StdioCollector { id: checkStdout; waitForEnd: true }
    onExited: function() {
      var r = Model.parseCheckOutput(String(checkStdout.text || ""))
      root.checkResult = r
      root.checkAt = Date.now()
      root.checkRunning = false
      if (r.done && r.fail > 0) {
        root.notify("Torrent tunnel check failed", r.failures[0] + (r.fail > 1 ? " (+" + (r.fail - 1) + " more)" : ""), true)
      }
    }
  }

  Process {
    id: torrentToggleProcess
    command: []
    stderr: StdioCollector { id: torrentToggleStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.torrentBusy = false
      root.actionStatus = ""
      if (exitCode !== 0) {
        root.lastError = Model.elideStatus(torrentToggleStderr.text || "Torrent tunnel command failed")
        root.notify("Torrent tunnel", root.lastError, true)
      }
      torrentRecheck.restart()
    }
  }

  FileView {
    id: torrentStatusFile
    path: "/run/pvpn-torrent/status"
    watchChanges: true
    printErrors: false
    onLoaded: root.torrentStatus = Model.parseTorrentStatus(text())
    onLoadFailed: root.torrentStatus = ({})
    onFileChanged: reload()
  }

  // Every 5s: take/renew the leader lease and, as leader, sample the live
  // network state (cheap, no keyring). The CLI only runs when that sample
  // says something changed, or on a slower schedule; see applyQuick.
  Timer {
    id: stateTimer
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      // Every instance (leader or not) needs to know the CLI exists and to
      // read the settings once; only the leader runs status polling.
      if (!root.installed && !whichProcess.running) {
        whichProcess.command = ["which", "protonvpn"]
        whichProcess.running = true
      }
      if (root.installed && !root._settingsLoaded) {
        root._settingsLoaded = true
        root.refreshSettings()
      }
      root.isLeader = Model.claimLeader(root._iid, Date.now(), 20000)
      if (root.isLeader) root.runQuick()
    }
  }

  // Every 1s, no processes: a follower copies the leader's published state,
  // and every instance mirrors the shared connect/disconnect action so both
  // monitors' icons pulse together.
  Timer {
    id: syncTimer
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      if (!root.isLeader) root.syncFromShared()
      root._sharedConnect = Model.actionKind(Date.now()) === "connect"
    }
  }

  Timer {
    id: delayedRefresh
    interval: 800
    repeat: false
    onTriggered: root.refresh(true)
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: uptimeTimer
    interval: 1000
    repeat: true
    running: root.connected
    onTriggered: root.connectedUptime = root.formatUptime()
  }

  Timer {
    id: trafficTimer
    interval: 1500
    repeat: true
    running: root.connected && root.tunnelDevice !== ""
    triggeredOnStart: true
    onTriggered: root.sampleTraffic()
  }

  Timer {
    id: pollWatchdog
    interval: 30000
    repeat: false
    onTriggered: {
      if (statusProcess.running) statusProcess.running = false
      if (deviceIpProcess.running) deviceIpProcess.running = false
      if (toggleProcess.running) toggleProcess.running = false
      root.refreshing = false
      root.toggling = false
      root.connecting = false
      Model.endAction()
    }
  }

  Process {
    id: whichProcess
    command: []
    onExited: function(exitCode) {
      installed = exitCode === 0
      if (!installed) {
        root.backendState = "Unavailable"
        root.statusText = "Proton CLI not found"
      } else if (root.isLeader) {
        root.refresh(true)
      }
    }
  }

  Process {
    id: countryProcess
    command: []
    stdout: StdioCollector { id: countryStdout; waitForEnd: true; onStreamFinished: root._countryOutput = text }
    onExited: function(exitCode) {
      if (exitCode === 0) root._countryNames = Model.parseCountriesOutput(String(countryStdout.text || root._countryOutput || ""))
      root.applyServerList()
    }
  }

  Process {
    id: exitIpProcess
    command: []
    stdout: StdioCollector { id: exitIpStdout; waitForEnd: true }
    onExited: function() {
      var ip = String(exitIpStdout.text || "").trim()
      if (/^[0-9a-fA-F:.]{3,45}$/.test(ip)) root.exitIp = ip
      else { root.exitIp = ""; root._exitIpFor = "" }
    }
  }

  Process {
    id: quickProcess
    command: ["sh", "-c", "export LC_ALL=C; echo '##dev'; nmcli -t -f DEVICE,TYPE,STATE dev status 2>/dev/null; echo '##con'; nmcli -t -f NAME,TYPE con show --active 2>/dev/null; echo '##route'; ip route get 1.1.1.1 2>/dev/null | head -1; echo '##gw'; ip -4 route show default 2>/dev/null | head -1; echo '##addr'; ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}' | head -1; echo '##dns'; resolvectl dns 2>/dev/null; echo '##rx'; for d in /sys/class/net/proton* /sys/class/net/pvpn*; do [ -d \"$d\" ] && echo \"$(basename $d) $(cat $d/statistics/rx_bytes 2>/dev/null)\"; done; echo '##wifi'; nmcli -t -f ACTIVE,SSID,SIGNAL dev wifi 2>/dev/null | grep '^yes' | head -1; echo '##ts'; [ -d /sys/class/net/tailscale0 ] && echo up; true"]
    stdout: StdioCollector { id: quickStdout; waitForEnd: true }
    onExited: function(exitCode) { root.applyQuick(String(quickStdout.text || ""), false) }
  }

  Process {
    id: statusProcess
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) {
        root.applyStatus(stdout)
        Model.publishShared(stdout, root._lastQuickText, Date.now())
      } else {
        var wasConnected = root._lastConnected
        root.refreshing = false
        root.connected = false
        root._desiredConnected = -1
        root._lastConnected = false
        root.backendState = "Unavailable"
        root.statusText = "CLI status failed"
        root.lastError = Model.elideStatus(stderr || stdout || "Could not read Proton VPN status")
        if (!root.toggling) root.connecting = false
        if (root._stateKnown && wasConnected) {
          root.notify("Proton VPN connection lost", root.lastError, true)
        }
        root._stateKnown = true
      }
    }
  }

  Process {
    id: deviceIpProcess
    command: []
    stdout: StdioCollector { id: deviceIpStdout; waitForEnd: true; onStreamFinished: root._deviceIpOutput = text }
    onExited: function() {
      root.tunnelIp = Model.parseDeviceIp(String(deviceIpStdout.text || root._deviceIpOutput || ""))
    }
  }

  Process {
    id: netProcess
    command: []
    stdout: StdioCollector { id: netStdout; waitForEnd: true; onStreamFinished: root._netDevOutput = text }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyNetDev(String(netStdout.text || root._netDevOutput || ""))
    }
  }

  Process {
    id: toggleProcess
    command: []
    stdout: StdioCollector { id: toggleStdout; waitForEnd: true; onStreamFinished: root._toggleOutput = text }
    stderr: StdioCollector { id: toggleStderr; waitForEnd: true; onStreamFinished: root._toggleError = text }
    onExited: function(exitCode) {
      root.toggling = false
      Model.endAction()
      // On success keep the acquiring icon until a status poll confirms the
      // tunnel (applyStatus clears it); on failure drop it now.
      if (exitCode !== 0) root.connecting = false
      var stdout = String(toggleStdout.text || root._toggleOutput || "")
      var stderr = String(toggleStderr.text || root._toggleError || "")
      var wasAuto = root._autoAttempt
      root._autoAttempt = false
      if (exitCode === 0) {
        root.lastError = ""
        root.actionStatus = ""
        root._aoFailed = false
      } else {
        if (wasAuto) root._aoFailed = true
        root.lastError = Model.elideStatus(stderr || stdout || "Proton VPN command failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
        root.notify("Proton VPN action failed", root.lastError, true)
        // The toggle failed — drop any optimistic state so the switch snaps
        // back to the real connection state.
        root._desiredConnected = -1
      }
      delayedRefresh.restart()
    }
  }

  FileView {
    id: serverListFile
    path: root.serverListPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root._serverListText = text()
      root.applyServerList()
    }
    onFileChanged: reload()
  }
}
