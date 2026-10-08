import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Proton VPN details panel: hero with connection state + on/off switch,
// tunnel info rows, and quick actions. Keyboard-cursor navigable like the
// other bar panels (j/k move, enter activates, t toggles, esc closes).
Panel {
  id: root
  moduleName: "jarod.protonvpn"
  ipcTarget: "jarod.protonvpn"
  manageIpc: false // BarWidget.qml owns the single IpcHandler this target permits

  property var service: null
  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so the popout coordinator compares against the host widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property bool hasError: service && service.lastError !== ""
  readonly property string heroMeta: service
    ? (service.protection === "blocked" ? "Blocked \u00b7 kill switch"
        : service.protection === "leaking" ? "Connected \u00b7 not protected"
        : service.protection === "stale" ? "Connected \u00b7 no traffic"
        : service.connected ? "Connected" : "Disconnected")
      + (service.torrentState === "ok" ? " \u00b7 torrents on" : service.torrentState === "error" ? " \u00b7 torrent problem" : "")
    : "Proton VPN"
  readonly property bool vpnOn: service && service.connected
  // Connected: the server. Disconnected: where the switch / enter will go.
  readonly property string heroDetail: {
    if (!service) return ""
    if (vpnOn) return service.serverName
    var d = service.describeTarget(service.lastTarget)
    return d ? "\u23ce " + d.label : ""
  }
  readonly property string statusText: {
    if (!service) return ""
    if (service.actionStatus !== "") return service.actionStatus
    if (service.busy) return "Working\u2026"
    return ""
  }
  readonly property string serverLabel: service
    ? Model.serverLabel(service.serverName, service.serverCity, service.serverCountry, "")
    : ""

  // ---- cursor model ------------------------------------------------------

  property string focusSection: "header"
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool serversExpanded: false
  property string expandedCountry: ""
  property string expandedCity: ""
  property bool settingsExpanded: false
  property bool mapExpanded: false
  property string searchQuery: ""

  // Favorites persist in this widget's shell.json entry (settings.favorites),
  // the same way the tailscale panel keeps recent Mullvad regions. The local
  // copy makes a toggle show instantly while the shell writes the entry.
  property var _favoritesLocal: null
  readonly property var favorites: {
    if (_favoritesLocal) return _favoritesLocal
    // Settings arrive as a list type that fails Array.isArray, so copy any
    // array-like value into a plain JS array.
    var f = service && service.settings ? service.settings.favorites : null
    if (!f || typeof f.length !== "number") return []
    var out = []
    for (var i = 0; i < f.length; i++) if (f[i] && f[i].kind) out.push({ kind: f[i].kind, country: f[i].country, city: f[i].city, name: f[i].name, filter: f[i].filter })
    return out
  }
  readonly property var favoriteKeys: {
    var keys = {}
    for (var i = 0; i < favorites.length; i++) keys[Model.favoriteKey(favorites[i])] = true
    return keys
  }

  function isFavorite(fav) { return !!fav && favoriteKeys[Model.favoriteKey(fav)] === true }

  function toggleFavorite(fav) {
    if (!fav) return
    var key = Model.favoriteKey(fav)
    var next = []
    var removed = false
    for (var i = 0; i < favorites.length; i++) {
      if (Model.favoriteKey(favorites[i]) === key) removed = true
      else next.push(favorites[i])
    }
    if (!removed) next.push(fav)
    // Favorites sit above every other row, so keep the cursor on the same
    // row when that section grows or shrinks underneath it.
    if (focusSection === "rows" && selectedIndex >= favorites.length)
      selectedIndex += next.length - favorites.length
    _favoritesLocal = next
    persistState()
    clampSelection()
  }

  // Writes favorites and the last connect target together so one save can't
  // roll back the other before the shell has re-read the entry.
  function persistState() {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var settings = service && service.settings ? service.settings : {}
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.favorites = favorites
    if (service && service.lastTarget) entry.lastTarget = service.lastTarget
    if (service) entry.alwaysOn = service.alwaysOn
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function connectFavorite(fav) {
    if (!service || !fav) return
    if (fav.kind === "server") service.connectServer("", "", fav.name)
    else if (fav.kind === "city") service.connectServer(fav.country, fav.city, "", fav.filter || "all")
    else service.connectServer(fav.country, "", "", fav.filter || "all")
  }
  readonly property string filterLabel: {
    if (!service) return ""
    var list = Model.SERVER_FILTERS
    for (var i = 0; i < list.length; i++) if (list[i].key === service.serverFilter) return list[i].label
    return ""
  }

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onFilterChanged() { root.expandedCountry = ""; root.expandedCity = "" }
    function onConnectSucceeded() { root.showTunnel() }
    function onTargetUsed(target) { root.persistState() }
    function onAlwaysOnToggled() { root.persistState() }
  }

  readonly property bool headerHasCursor: cursorActive && focusSection === "header"

  // Live tunnel info (uptime, rates) changes every second; keep it in its own
  // binding so the server list isn't rebuilt (and its rows re-created under
  // the pointer) on every tick.
  function buildInfoRows() {
    var info = []
    if (service && (service.connected || service.protection === "blocked")) {
      var pi = service.protectionInfo
      if (pi.state === "protected") info.push({ action: "none", label: "Protection", hint: "\u2713 protected" })
      else if (pi.state !== "off") {
        info.push({ action: "none", label: "Protection", hint: "! " + pi.short })
        info.push({ action: "none", label: pi.reason, hint: "" })
      }
    }
    if (serverLabel !== "") info.push({ action: "copyServer", label: "Server", hint: serverLabel })
    if (service && service.tunnelIp !== "") info.push({ action: "copyIp", label: "Tunnel IP", hint: service.tunnelIp })
    if (service && service.rxRate !== "") info.push({ action: "none", label: "Download", hint: service.rxRate })
    if (service && service.txRate !== "") info.push({ action: "none", label: "Upload", hint: service.txRate })
    if (service && service.protocol !== "") info.push({ action: "none", label: "Protocol", hint: service.protocol })
    if (service && service.serverLoad !== "") info.push({ action: "none", label: "Server load", hint: service.serverLoad })
    if (service && service.connectedUptime !== "") info.push({ action: "none", label: "Connected for", hint: service.connectedUptime })
    if (service && service.connected && service.exitIp !== "") info.push({ action: "copyText", value: service.exitIp, label: "Exit IP", hint: service.exitIp })
    return info
  }

  function buildListRows() {
    var favs = []
    var countries = []
    if (service) {
      for (var f = 0; f < favorites.length; f++) {
        var d = service.describeFavorite(favorites[f])
        favs.push({ action: "connectFavorite", value: favorites[f], label: d.label, hint: d.hint, fav: favorites[f] })
      }
    }

    if (service && service.serverRows && service.serverRows.all && service.serverRows.all.length > 0) {
      var filter = service.serverFilter
      var ind1 = "\u2003"
      var ind2 = "\u2003\u2003"
      var pushServers = function(code, cityName, indent) {
        countries.push({ action: "connectCity", value: { country: code, city: cityName }, label: indent + "Fastest in " + cityName, hint: "" })
        var servers = service.serverRowsIn(code, cityName)
        for (var k = 0; k < servers.length; k++)
          countries.push({ action: "connectName", value: servers[k].name, label: indent + servers[k].name, hint: servers[k].hint, fav: { kind: "server", name: servers[k].name, country: code } })
      }
      var pushCity = function(code, cityName, label, hint, indent) {
        var open = expandedCountry === code && expandedCity === cityName
        countries.push({ action: "toggleCity", value: { country: code, city: cityName }, label: indent + (open ? "\u25be " : "\u25b8 ") + label, hint: hint, fav: { kind: "city", country: code, city: cityName, filter: filter } })
        if (open) pushServers(code, cityName, indent + ind1)
      }
      var pushCountry = function(row) {
        var open = expandedCountry === row.code
        countries.push({ action: "toggleCountry", value: row.code, label: (open ? "\u25be " : "\u25b8 ") + row.name, hint: row.hint, fav: { kind: "country", country: row.code, filter: filter } })
        if (!open) return
        countries.push({ action: "connectServer", value: row.code, label: ind1 + "Fastest in " + row.name, hint: "" })
        var cities = service.cityRows(row.code)
        for (var j = 0; j < cities.length; j++)
          pushCity(row.code, cities[j].name, cities[j].name + (cities[j].region ? ", " + cities[j].region : ""), cities[j].hint, ind1)
      }

      countries.push({ action: "cycleFilter", value: "", label: "Type", hint: root.filterLabel + "  \u00b7  change" })
      if (searchQuery !== "") {
        var found = service.searchRows(searchQuery)
        for (var a = 0; a < found.countries.length; a++) pushCountry(found.countries[a])
        for (var b = 0; b < found.cities.length; b++) {
          var c = found.cities[b]
          pushCity(c.country, c.name, c.name + ", " + (c.regionName || c.countryName), c.hint, "")
        }
        for (var n = 0; n < found.servers.length; n++) {
          var sv = found.servers[n]
          countries.push({ action: "connectName", value: sv.name, label: sv.name, hint: sv.hint, fav: { kind: "server", name: sv.name, country: sv.country } })
        }
        if (countries.length === 1) countries.push({ action: "none", label: "No matches", hint: "" })
      } else {
        var rows = service.serverRows[filter] || []
        var anyOk = filter !== "free" && filter !== "plus" && filter !== "streaming"
        if (anyOk) countries.push({ action: "connectServer", value: "", label: "Fastest " + root.filterLabel + " server", hint: "any country" })
        for (var i = 0; i < rows.length; i++) pushCountry(rows[i])
      }
    }
    return { favs: favs, countries: countries }
  }

  readonly property var listRows: buildListRows()
  readonly property var infoRows: buildInfoRows()
  readonly property var favoriteRows: listRows.favs
  readonly property var countryRows: listRows.countries
  readonly property var actionRows: [{ action: "refresh", label: "Refresh", hint: "" }]
  readonly property int visibleCountryCount: root.serversExpanded ? countryRows.length : 0
  readonly property int serversOffset: favoriteRows.length
  readonly property int infoOffset: serversOffset + visibleCountryCount
  readonly property int torrentOffset: infoOffset + infoRows.length
  readonly property int networkOffset: torrentOffset + torrentRows.length
  readonly property int settingsOffset: networkOffset + networkRows.length
  readonly property int actionsOffset: settingsOffset + visibleSettingsCount

  // Proton settings (cycle a row to change it). Kill-switch note: it blocks
  // Tailscale and, with the torrent tunnel, relies on the tunnel's fwmark
  // bypass; see README.
  function buildSettingsRows() {
    var rows = []
    if (!service || !service.installed) return rows
    var defs = Model.PROTON_SETTINGS
    for (var i = 0; i < defs.length; i++) {
      var d = defs[i]
      var v = service.protonSettingValue(d)
      var hint = Model.showSettingValue(d, v)
      if (d.key === "protocol" && service.connected) hint += " \u00b7 next connect"
      if (d.key === "always-on" && !service.alwaysOn && !service.connected) hint = "off \u00b7 turning on connects now"
      rows.push({ action: "cycleSetting", value: d, label: d.label, hint: hint })
    }
    return rows
  }
  readonly property var settingsRows: buildSettingsRows()
  readonly property int visibleSettingsCount: settingsExpanded ? settingsRows.length : 0

  // Local network context, plus a Tailscale note: Proton's kill switch blocks
  // tailnet traffic and MagicDNS while it is armed.
  function buildNetworkRows() {
    var rows = []
    if (!service) return rows
    var q = service.quick
    if (q.wifi) rows.push({ action: "none", label: "Wi\u2011Fi", hint: q.wifi.ssid + " \u00b7 " + q.wifi.signal + "%" })
    else if (q.local) rows.push({ action: "none", label: "Interface", hint: q.local.device })
    if (q.local) rows.push({ action: "copyText", value: q.local.addr, label: "Local IP", hint: q.local.addr })
    if (q.gateway) rows.push({ action: "copyText", value: q.gateway, label: "Gateway", hint: q.gateway })
    var dns = q.tunnelDns.length > 0 ? q.tunnelDns : (q.localDns.length > 0 ? q.localDns : q.globalDns)
    if (dns.length > 0) rows.push({ action: "none", label: q.tunnelDns.length > 0 ? "DNS (tunnel)" : "DNS", hint: dns.join(", ") })
    if (q.tailscale && q.killSwitch) rows.push({ action: "none", label: "Tailscale", hint: "kill switch may block it" })
    return rows
  }
  readonly property var networkRows: buildNetworkRows()

  // Torrent tunnel rows; empty (section hidden) until system/install.sh ran.
  function buildTorrentRows() {
    var rows = []
    if (!service || !service.torrentInstalled) return rows
    var st = service.torrentStatus || {}
    var server = st.server || ""
    var tunnelHint = service.torrentBusy ? "\u2026" : (service.torrentUp ? "On" + (server ? " \u00b7 " + server : "") : "Off")
    var health = service.torrentHealth || {}
    if (health.state === "ok") rows.push({ action: "none", label: "Status", hint: "\u2713 working" })
    else if (health.state === "error") rows.push({ action: "none", label: "Status", hint: "! " + health.short })
    rows.push({ action: "toggleTorrent", label: "Torrent tunnel", hint: tunnelHint })
    if (service.torrentUp) {
      var portHint = st.port_ok === "1" && st.port
        ? st.port + (st.qbt_port === st.port ? " \u00b7 in qBittorrent" : "")
        : (st.port_error ? "unavailable" : "requesting\u2026")
      rows.push({ action: st.port ? "copyPort" : "none", label: "Forwarded port", hint: portHint })
      rows.push({ action: "none", label: "Handshake", hint: Model.formatAgo(st.handshake, Date.now()) })
    }
    if (service.torrentUp && st.exit_ip) rows.push({ action: "copyText", value: st.exit_ip, label: "Exit IP", hint: st.exit_ip })
    var q = service.qbtState
    // Inside the namespace with the tunnel off = no network at all (it comes
    // back on its own when the tunnel does).
    var qbtHint = q === "inside" ? (service.torrentUp ? "running in tunnel" : "offline \u00b7 tunnel off")
      : q === "outside" ? "OUTSIDE tunnel \u2014 click to move"
      : q === "stale" ? "no network \u2014 click to restart"
      : (service.torrentUp ? "open" : "tunnel off")
    rows.push({ action: "openQbt", label: "qBittorrent", hint: qbtHint })
    if (service.otherOutside && service.otherOutside.length > 0)
      rows.push({ action: "none", label: "Other clients", hint: service.otherOutside.join(", ") + " outside tunnel" })

    var cr = service.checkResult
    var checkHint = service.checkRunning ? "running\u2026"
      : !cr ? "run now"
      : !cr.done ? "could not run"
      : (cr.fail > 0 ? "! " + cr.fail + " failed" : "\u2713 " + cr.pass + " passed") + (cr.warn > 0 ? " \u00b7 " + cr.warn + " warning" + (cr.warn > 1 ? "s" : "") : "") + " \u00b7 " + Model.formatAgo(service.checkAt / 1000, Date.now())
    if (!service.checkAvailable) {
      rows.push({ action: "none", label: "Check for leaks", hint: "re-run system/install.sh to enable" })
      return rows
    }
    rows.push({ action: "runCheck", label: "Check for leaks", hint: checkHint })
    if (cr && cr.done) {
      for (var f = 0; f < cr.failures.length; f++) rows.push({ action: "none", label: "\u2717 " + cr.failures[f], hint: "" })
      for (var w = 0; w < cr.warnings.length; w++) rows.push({ action: "none", label: "! " + cr.warnings[w], hint: "" })
      rows.push({ action: "openReports", label: "Open saved reports", hint: "" })
    }
    return rows
  }
  readonly property var torrentRows: buildTorrentRows()
  readonly property var cursorRows: {
    var rows = []
    for (var f = 0; f < favoriteRows.length; f++) rows.push(favoriteRows[f])
    for (var c = 0; c < root.visibleCountryCount; c++) rows.push(countryRows[c])
    for (var i = 0; i < infoRows.length; i++) rows.push(infoRows[i])
    for (var t = 0; t < torrentRows.length; t++) rows.push(torrentRows[t])
    for (var n = 0; n < networkRows.length; n++) rows.push(networkRows[n])
    for (var g = 0; g < visibleSettingsCount; g++) rows.push(settingsRows[g])
    for (var j = 0; j < actionRows.length; j++) rows.push(actionRows[j])
    return rows
  }
  readonly property int cursorRowCount: cursorRows.length

  function rowSelected(rowIndex) {
    return cursorActive && focusSection === "rows" && selectedIndex === rowIndex
  }

  function focusHeader() {
    cursorActive = true
    focusSection = "header"
    selectedIndex = 0
  }

  // Set while the cursor moves by keyboard so the selected row scrolls into
  // view; pointer-driven selection leaves the scroll position alone.
  property bool _keyboardCursor: false

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function moveCursor(delta) {
    pointerGate.reset()
    _keyboardCursor = true
    if (!cursorActive) { cursorActive = true; return }
    if (focusSection === "header") {
      if (delta > 0 && cursorRowCount > 0) {
        focusSection = "rows"
        selectedIndex = 0
      }
      return
    }
    if (cursorRowCount === 0) { focusSection = "header"; return }
    var idx = selectedIndex + (delta > 0 ? 1 : -1)
    if (idx < 0) { focusSection = "header"; selectedIndex = 0; return }
    if (idx >= cursorRowCount) { selectedIndex = cursorRowCount - 1; return }
    selectedIndex = idx
  }

  function activateCursor() {
    if (!cursorActive) return
    if (focusSection === "header") {
      if (service) service.toggle()
      return
    }
    var row = cursorRows[selectedIndex]
    if (row) runAction(row.action, row.value)
  }

  function favoriteCursor() {
    if (!cursorActive || focusSection !== "rows") return
    var row = cursorRows[selectedIndex]
    if (row && row.fav) toggleFavorite(row.fav)
  }

  function focusSearch() {
    serversExpanded = true
    Qt.callLater(function() { if (serverSearch) serverSearch.forceActiveFocus() })
  }

  // Search results start after the Type row; put the cursor on the first.
  function selectFirstResult() {
    _keyboardCursor = true
    cursorActive = true
    focusSection = "rows"
    selectedIndex = Math.min(serversOffset + 1, Math.max(0, cursorRowCount - 1))
  }

  function runAction(action, value) {
    if (!service) return
    if (action === "connectServer" || action === "connectCity" || action === "connectName" || action === "connectFavorite") {
      runConnect(action, value)
      return
    }
    if (action === "refresh") { service.refresh(true); service.refreshServerList() }
    else if (action === "copyIp") service.copyText(service.tunnelIp)
    else if (action === "copyServer") service.copyText(serverLabel)
    else if (action === "copyText") service.copyText(String(value || ""))
    else if (action === "toggleTorrent") service.setTorrentTunnel(!service.torrentUp)
    else if (action === "copyPort") service.copyText(String((service.torrentStatus || {}).port || ""))
    else if (action === "openQbt") service.openQbittorrent()
    else if (action === "runCheck") service.runLeakCheck()
    else if (action === "cycleSetting") service.cycleSetting(value)
    else if (action === "openReports") service.openReports()
    else if (action === "toggleCountry") { expandedCity = ""; expandedCountry = expandedCountry === value ? "" : value }
    else if (action === "toggleCity") {
      var same = expandedCountry === value.country && expandedCity === value.city
      expandedCountry = same && searchQuery !== "" ? "" : value.country
      expandedCity = same ? "" : value.city
    }
    else if (action === "cycleFilter") service.cycleServerFilter()
  }

  // After connecting, clear the search and fold the server list away so the
  // tunnel details are what's on screen.
  function showTunnel() {
    if (!opened) return
    searchQuery = ""
    expandedCountry = ""
    expandedCity = ""
    serversExpanded = false
    cursorActive = false
    focusSection = "header"
    selectedIndex = 0
    if (serverSearch && serverSearch.activeFocus) keyCatcher.forceActiveFocus()
    if (panelFlick) panelFlick.contentY = 0
  }

  // Connecting from the list folds it away right away; the status line shows
  // progress (or the error) above the tunnel details.
  function runConnect(action, value) {
    if (action === "connectServer") service.connectServer(value, "", "")
    else if (action === "connectCity") service.connectServer(value.country, value.city, "")
    else if (action === "connectName") service.connectServer("", "", value)
    else connectFavorite(value)
    showTunnel()
  }

  function toggleMap() {
    mapExpanded = !mapExpanded
  }

  // A map dot was clicked: open its country in the list and put the cursor
  // on it.
  function showCountry(code) {
    searchQuery = ""
    serversExpanded = true
    expandedCountry = code
    expandedCity = ""
    Qt.callLater(function() {
      for (var i = 0; i < countryRows.length; i++) {
        if (countryRows[i].action === "toggleCountry" && countryRows[i].value === code) {
          _keyboardCursor = true
          cursorActive = true
          focusSection = "rows"
          selectedIndex = serversOffset + i
          return
        }
      }
    })
  }

  function toggleSettings() {
    settingsExpanded = !settingsExpanded
    if (settingsExpanded && service) service.refreshSettings()
    clampSelection()
  }

  function toggleServers() {
    serversExpanded = !serversExpanded
  }

  onServersExpandedChanged: clampSelection()

  function clampSelection() {
    if (focusSection === "rows" && selectedIndex >= cursorRowCount)
      selectedIndex = Math.max(0, cursorRowCount - 1)
  }

  onOpenedChanged: {
    if (opened) {
      focusSection = "header"
      selectedIndex = 0
      cursorActive = false
      serversExpanded = false
      settingsExpanded = false
      mapExpanded = false
      expandedCountry = ""
      expandedCity = ""
      searchQuery = ""
      _favoritesLocal = null
      if (service) service.refreshServerList()
      var mode = Model.consumeOpenMode(Date.now())
      if (mode === "search") {
        serversExpanded = true
        searchFocusTimer.restart()
      } else if (mode === "toggle") {
        // Cursor on the on/off switch: enter connects to the last target or
        // disconnects.
        cursorActive = true
        focusSection = "header"
      }
    }
  }

  // Only real pointer movement moves the cursor; rows re-created under a
  // still pointer (list rebuilds, expansion) must not steal the selection.
  PointerMoveGate {
    id: pointerGate
    referenceItem: column
  }

  // KeyboardPanel focuses the key catcher just after opening; take focus
  // for the search field once that has happened.
  Timer {
    id: searchFocusTimer
    interval: 120
    onTriggered: if (root.opened && serverSearch) serverSearch.forceActiveFocus()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Let the search field receive keys itself while it's focused.
      blocked: serverSearch.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "t" || t === "T") { if (root.service) root.service.toggle() }
        else if (t === "c" || t === "C") { if (root.service) root.service.copyText(root.service.tunnelIp) }
        else if (t === "s" || t === "S") root.toggleServers()
        else if (t === "f" || t === "F") { if (root.service) root.service.cycleServerFilter() }
        else if (t === "b" || t === "B") root.favoriteCursor()
        else if (t === "g" || t === "G") root.toggleSettings()
        else if (t === "m" || t === "M") root.toggleMap()
        else if (t === "/") root.focusSearch()
        else if (t === "r" || t === "R") {
          if (root.service) { root.service.refresh(true); root.service.refreshServerList() }
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.focusHeader() }

            PanelHero {
              id: hero
              width: parent.width
              title: "Proton VPN"
              meta: root.heroMeta
              detail: root.heroDetail
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.vpnOn ? 1.0 : 0.5
              iconComponent: Component {
                VpnIcon {
                  iconSize: Style.font.display
                  color: root.foreground
                  connected: root.vpnOn
                  connecting: root.service ? root.service.connectingAny : false
                  torrentState: root.service ? root.service.torrentState : "off"
                  badgeColor: root.urgent
                  warning: root.hasError || (root.service && (root.service.protection === "leaking" || root.service.protection === "stale" || root.service.protection === "blocked"))
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: root.service ? root.service.switchOn : false
                  busy: root.service ? root.service.busy : false
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: { if (root.service) root.service.toggle() }
                }
              }
            }
          }

          Text {
            id: statusLine
            width: parent.width
            visible: root.statusText !== ""
            text: root.statusText
            textFormat: Text.PlainText
            color: root.hasError ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.service && root.service.mapPointsFor(root.service.serverFilter).length > 0

            Item {
              width: parent.width
              implicitHeight: mapHeader.implicitHeight + Style.space(4)

              PanelSectionHeader {
                id: mapHeader
                anchors.left: parent.left
                anchors.right: parent.right
                text: (root.mapExpanded ? "\u25be " : "\u25b8 ") + "MAP"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleMap()
              }
            }

            MapView {
              visible: root.mapExpanded
              width: parent.width
              foreground: root.foreground
              accent: Color.accent
              points: root.mapExpanded && root.service ? root.service.mapPointsFor(root.service.serverFilter) : []
              connectedLoc: root.service ? root.service.connectedLocation : null
              arcFrom: root.service ? root.service.secureCoreEntry : null
              favoriteCodes: {
                var out = {}
                for (var i = 0; i < root.favorites.length; i++) if (root.favorites[i].country) out[root.favorites[i].country] = true
                return out
              }
              onCountryClicked: function(code) { root.showCountry(code) }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.favoriteRows.length > 0

            PanelSectionHeader {
              text: "FAVORITES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.favoriteRows

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: cursorRow.implicitHeight

                CursorRow {
                  id: cursorRow
                  width: parent.width
                  label: modelData.label
                  hint: modelData.hint
                  rowIndex: index
                  actionName: modelData.action
                  actionValue: modelData.value
                  fav: modelData.fav
                }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            visible: root.countryRows.length > 0

            Item {
              id: freeHeader
              width: parent.width
              implicitHeight: Math.max(freeChevron.implicitHeight, freeLabel.implicitHeight, freeCount.implicitHeight) + Style.space(4)

              Text {
                id: freeChevron
                anchors.left: parent.left
                anchors.leftMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                text: root.serversExpanded ? "\u25be" : "\u25b8"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                id: freeLabel
                anchors.left: freeChevron.right
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: "SERVERS"
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                topPadding: Math.ceil(Style.font.caption * 0.15)
              }

              Text {
                id: freeCount
                anchors.right: parent.right
                anchors.rightMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                text: root.filterLabel
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                id: freeHeaderMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleServers()
              }
            }

            TextField {
              id: serverSearch
              visible: root.serversExpanded
              width: parent.width
              foreground: root.foreground
              placeholderText: "Search countries, states, cities, servers  (/)"
              text: root.searchQuery
              onTextChanged: {
                if (root.searchQuery === text) return
                root.searchQuery = text
                root.expandedCountry = ""
                root.expandedCity = ""
                root.selectFirstResult()
              }
              onAccepted: {
                if (!(root.cursorActive && root.focusSection === "rows")) root.selectFirstResult()
                root.activateCursor()
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Down) { root.moveCursor(1); event.accepted = true; return }
                if (event.key === Qt.Key_Up) { root.moveCursor(-1); event.accepted = true; return }
                // Esc hands keys back to the list but keeps the query, so
                // results can be walked with j/k, starred with b, opened
                // with enter. A second Esc closes the panel as usual.
                if (event.key === Qt.Key_Escape) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
            }

            Repeater {
              model: root.serversExpanded ? root.countryRows : []

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: cursorRow.implicitHeight

                CursorRow {
                  id: cursorRow
                  width: parent.width
                  label: modelData.label
                  hint: modelData.hint
                  rowIndex: root.serversOffset + index
                  actionName: modelData.action
                  actionValue: modelData.value
                  fav: modelData.fav
                }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.infoRows.length > 0
            PanelSectionHeader {
              text: "TUNNEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.infoRows

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: cursorRow.implicitHeight

                CursorRow {
                  id: cursorRow
                  width: parent.width
                  label: modelData.label
                  hint: modelData.hint
                  rowIndex: root.infoOffset + index
                  actionName: modelData.action
                }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.torrentRows.length > 0

            PanelSectionHeader {
              text: "TORRENTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.torrentRows

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: cursorRow.implicitHeight

                CursorRow {
                  id: cursorRow
                  width: parent.width
                  label: modelData.label
                  hint: modelData.hint
                  rowIndex: root.torrentOffset + index
                  actionName: modelData.action
                }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.networkRows.length > 0

            PanelSectionHeader {
              text: "NETWORK"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.networkRows

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: cursorRow.implicitHeight

                CursorRow {
                  id: cursorRow
                  width: parent.width
                  label: modelData.label
                  hint: modelData.hint
                  rowIndex: root.networkOffset + index
                  actionName: modelData.action
                  actionValue: modelData.value
                }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.settingsRows.length > 0

            Item {
              width: parent.width
              implicitHeight: settingsHeaderText.implicitHeight + Style.space(4)

              PanelSectionHeader {
                id: settingsHeaderText
                anchors.left: parent.left
                anchors.right: parent.right
                text: (root.settingsExpanded ? "\u25be " : "\u25b8 ") + "SETTINGS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleSettings()
              }
            }

            Repeater {
              model: root.settingsExpanded ? root.settingsRows : []

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: cursorRow.implicitHeight

                CursorRow {
                  id: cursorRow
                  width: parent.width
                  label: modelData.label
                  hint: modelData.hint
                  rowIndex: root.settingsOffset + index
                  actionName: modelData.action
                  actionValue: modelData.value
                }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            PanelSectionHeader {
              text: "ACTIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.actionRows

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: cursorRow.implicitHeight

                CursorRow {
                  id: cursorRow
                  width: parent.width
                  label: modelData.label
                  hint: modelData.hint
                  rowIndex: root.actionsOffset + index
                  actionName: modelData.action
                  actionValue: modelData.value
                }
              }
            }
          }
        }
      }
    }
  }

  component CursorRow: CursorSurface {
    id: row
    required property string label
    required property string hint
    required property int rowIndex
    required property string actionName
    property var actionValue: undefined
    property var fav: undefined
    readonly property bool starred: root.isFavorite(fav)

    readonly property bool rowSelected: root.rowSelected(rowIndex)
    onRowSelectedChanged: if (rowSelected && root._keyboardCursor) root.scrollItemIntoView(row)

    hasCursor: rowSelected
    foreground: root.foreground
    accent: Color.accent
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: Math.max(Style.spacing.popupRowHeight + Style.space(8), rowContent.implicitHeight + Style.spacing.rowPaddingX)

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onPositionChanged: function(mouse) {
        if (!pointerGate.moved(rowMouse, mouse)) return
        root._keyboardCursor = false
        root.cursorActive = true
        root.focusSection = "rows"
        root.selectedIndex = row.rowIndex
      }
      onClicked: root.runAction(row.actionName, row.actionValue)
    }

    Row {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        id: rowLabel
        width: Math.min(implicitWidth, rowContent.width - (rowHint.visible ? rowHint.implicitWidth + rowContent.spacing : 0) - (rowStar.visible ? rowStar.width + rowContent.spacing : 0) - rowContent.spacing - 1)
        text: row.label
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Item {
        width: Math.max(1, rowContent.width - rowLabel.width - (rowHint.visible ? rowHint.implicitWidth + rowContent.spacing : 0) - (rowStar.visible ? rowStar.width + rowContent.spacing : 0) - rowContent.spacing)
        height: 1
      }

      Text {
        id: rowHint
        visible: row.hint !== ""
        text: row.hint
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }

      // Favorite toggle. Always reserves its width on favoritable rows so
      // hover doesn't shift the hint; the outline star shows on hover/cursor.
      Text {
        id: rowStar
        visible: row.fav !== undefined && row.fav !== null
        width: Style.font.body * 1.2
        horizontalAlignment: Text.AlignHCenter
        text: row.starred ? "\u2605" : "\u2606"
        textFormat: Text.PlainText
        color: row.starred ? Color.accent : root.dim
        opacity: row.starred || rowMouse.containsMouse || starMouse.containsMouse || row.rowSelected ? 1 : 0
        font.family: root.fontFamily
        font.pixelSize: Style.font.body

        MouseArea {
          id: starMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toggleFavorite(row.fav)
        }
      }
    }
  }
}
