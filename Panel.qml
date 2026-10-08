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
  moduleName: "tharin.protonvpn"
  ipcTarget: "tharin.protonvpn"
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
  readonly property string heroMeta: service ? (service.connected ? "Connected" : "Disconnected") : "Proton VPN"
  readonly property bool vpnOn: service && service.connected
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
    persistFavorites(next)
    clampSelection()
  }

  function persistFavorites(next) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var settings = service && service.settings ? service.settings : {}
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry.favorites = next
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
  }

  readonly property bool headerHasCursor: cursorActive && focusSection === "header"

  function buildRows() {
    var info = []
    var favs = []
    var countries = []
    var actions = []
    if (serverLabel !== "") info.push({ action: "copyServer", label: "Server", hint: serverLabel })
    if (service && service.tunnelIp !== "") info.push({ action: "copyIp", label: "Tunnel IP", hint: service.tunnelIp })
    if (service && service.rxRate !== "") info.push({ action: "none", label: "Download", hint: service.rxRate })
    if (service && service.txRate !== "") info.push({ action: "none", label: "Upload", hint: service.txRate })
    if (service && service.protocol !== "") info.push({ action: "none", label: "Protocol", hint: service.protocol })
    if (service && service.serverLoad !== "") info.push({ action: "none", label: "Server load", hint: service.serverLoad })
    if (service && service.connectedUptime !== "") info.push({ action: "none", label: "Connected for", hint: service.connectedUptime })

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
        for (var j = 0; j < cities.length; j++) pushCity(row.code, cities[j].name, cities[j].name, cities[j].hint, ind1)
      }

      countries.push({ action: "cycleFilter", value: "", label: "Type", hint: root.filterLabel + "  \u00b7  change" })
      if (searchQuery !== "") {
        var found = service.searchRows(searchQuery)
        for (var a = 0; a < found.countries.length; a++) pushCountry(found.countries[a])
        for (var b = 0; b < found.cities.length; b++) {
          var c = found.cities[b]
          pushCity(c.country, c.name, c.name + ", " + c.countryName, c.hint, "")
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
    actions.push({ action: "refresh", label: "Refresh", hint: "" })
    return { info: info, favs: favs, countries: countries, actions: actions }
  }

  readonly property var allRows: buildRows()
  readonly property var infoRows: allRows.info
  readonly property var favoriteRows: allRows.favs
  readonly property var countryRows: allRows.countries
  readonly property var actionRows: allRows.actions
  readonly property int visibleCountryCount: root.serversExpanded ? countryRows.length : 0
  readonly property int serversOffset: favoriteRows.length
  readonly property int infoOffset: serversOffset + visibleCountryCount
  readonly property int actionsOffset: infoOffset + infoRows.length
  readonly property var cursorRows: {
    var rows = []
    for (var f = 0; f < favoriteRows.length; f++) rows.push(favoriteRows[f])
    for (var c = 0; c < root.visibleCountryCount; c++) rows.push(countryRows[c])
    for (var i = 0; i < infoRows.length; i++) rows.push(infoRows[i])
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

  function moveCursor(delta) {
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
    cursorActive = true
    focusSection = "rows"
    selectedIndex = Math.min(serversOffset + 1, Math.max(0, cursorRowCount - 1))
  }

  function runAction(action, value) {
    if (!service) return
    if (action === "refresh") { service.refresh(); service.refreshServerList() }
    else if (action === "copyIp") service.copyText(service.tunnelIp)
    else if (action === "copyServer") service.copyText(serverLabel)
    else if (action === "connectServer") service.connectServer(value, "", "")
    else if (action === "connectCity") service.connectServer(value.country, value.city, "")
    else if (action === "connectName") service.connectServer("", "", value)
    else if (action === "connectFavorite") connectFavorite(value)
    else if (action === "toggleCountry") { expandedCity = ""; expandedCountry = expandedCountry === value ? "" : value }
    else if (action === "toggleCity") {
      var same = expandedCountry === value.country && expandedCity === value.city
      expandedCountry = same && searchQuery !== "" ? "" : value.country
      expandedCity = same ? "" : value.city
    }
    else if (action === "cycleFilter") service.cycleServerFilter()
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
      expandedCountry = ""
      expandedCity = ""
      searchQuery = ""
      _favoritesLocal = null
      if (service) service.refreshServerList()
      if (Model.consumeSearchRequest(Date.now())) {
        serversExpanded = true
        searchFocusTimer.restart()
      }
    }
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
        else if (t === "/") root.focusSearch()
        else if (t === "r" || t === "R") {
          if (root.service) { root.service.refresh(); root.service.refreshServerList() }
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
              detail: root.vpnOn && root.service && root.service.serverName ? root.service.serverName : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.vpnOn ? 1.0 : 0.5
              iconComponent: Component {
                ProtonIcon {
                  iconSize: Style.font.display
                  color: root.vpnOn ? root.foreground : root.dim
                  badgeColor: root.urgent
                  crossed: !root.vpnOn
                  warning: root.hasError
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
              placeholderText: "Search countries, cities, servers  (/)"
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
      onContainsMouseChanged: if (containsMouse) {
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
