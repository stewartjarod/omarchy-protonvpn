// Proton VPN CLI output parsing helpers.

.pragma library

// Last transition that has already produced a desktop notification. The bar
// mounts one Service per monitor, and every instance polls the same CLI;
// deduping here keeps a connect/disconnect from notifying once per monitor.
var _lastNotifiedTransition = { connected: false, at: 0 }
var _notifyDedupeWindowMs = 45000

function shouldNotifyTransition(connected, now) {
  if (_lastNotifiedTransition.connected === connected && now - _lastNotifiedTransition.at < _notifyDedupeWindowMs) return false
  _lastNotifiedTransition.connected = connected
  _lastNotifiedTransition.at = now
  return true
}

// Parses the official `protonvpn status` output:
//
//   Status: Connected
//   Server: US-FREE#38 in New York, US
//   Load: 42%
//   Protocol: wireguard
function parseCliStatus(text) {
  var result = {
    connected: false,
    serverName: "",
    serverCity: "",
    serverCountry: "",
    load: "",
    protocol: ""
  }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    var status = line.match(/^status\s*:\s*(.+)$/i)
    if (status) {
      result.connected = /^connected$/i.test(status[1].trim())
      continue
    }
    var server = line.match(/^server\s*:\s*(.+?)\s+in\s+(.+)$/i)
    if (server) {
      result.serverName = stripMarkup(server[1].trim())
      var location = server[2].trim().split(/\s*,\s*/)
      result.serverCountry = location.length > 1 ? stripMarkup(location[location.length - 1]) : ""
      result.serverCity = location.length > 1 ? stripMarkup(location.slice(0, -1).join(", ")) : stripMarkup(location[0])
      continue
    }
    var load = line.match(/^load\s*:\s*(.+)$/i)
    if (load) {
      result.load = stripMarkup(load[1].trim())
      continue
    }
    var protocol = line.match(/^protocol\s*:\s*(.+)$/i)
    if (protocol) result.protocol = stripMarkup(protocol[1].trim())
  }
  return result
}

// `nmcli -g IP4.ADDRESS dev show <device>` may print several addresses.
function parseDeviceIp(text) {
  var s = String(text || "").trim()
  var ipv4 = s.match(/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/)
  return ipv4 ? ipv4[1] : ""
}

// Parses `nmcli -t -f DEVICE,TYPE,STATE dev status` and returns the active
// WireGuard device used by the CLI. The app commonly names it proton0, but
// the device name is intentionally discovered instead of hard-coded.
function parseWireguardDevice(text) {
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split(":")
    if (parts.length >= 3 && parts[1] === "wireguard" && /connected/.test(parts[2])) return parts[0]
  }
  return ""
}

// Removes angle-bracket markup from strings that originated from the Proton
// VPN CLI. With Text.PlainText the text is rendered literally, so we only need
// to strip any `<...>` fragments that would otherwise be interpreted as rich
// text under Qt's default Text.AutoText.
function stripMarkup(text) {
  return String(text || "").replace(/<[^>]*>/g, "")
}

function serverLabel(serverName, serverCity, serverCountry, fallback) {
  var parts = []
  if (serverName) parts.push(stripMarkup(serverName))
  if (serverCity) parts.push(stripMarkup(serverCity))
  if (serverCountry && serverCountry !== serverCity) parts.push(stripMarkup(serverCountry))
  if (parts.length === 0 && fallback) parts.push(stripMarkup(fallback))
  return parts.join(" \u00b7 ")
}

function parseCountriesOutput(text) {
  var names = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*(.+?)\s{2,}([A-Z]{2})\s*$/)
    if (match && match[2] !== "CO") names[match[2]] = stripMarkup(match[1].trim())
  }
  return names
}

// Projects Proton's cached logical server list into a compact country list.
// Tier 0 is Proton's Free tier; offline logical servers are omitted.
function freeCountryRows(raw, countryNames) {
  return (serverListRows(raw, countryNames).free) || []
}

// Proton's `Features` bitmask on a logical server.
var FEATURE_SECURE_CORE = 1
var FEATURE_TOR = 2
var FEATURE_P2P = 4
var FEATURE_STREAMING = 8

// Server-type filters offered in the panel. `flag` is the matching
// `protonvpn connect` option, when the CLI has one.
var SERVER_FILTERS = [
  { key: "all", label: "All", flag: "" },
  { key: "free", label: "Free", flag: "" },
  { key: "plus", label: "Plus", flag: "" },
  { key: "p2p", label: "P2P", flag: "--p2p" },
  { key: "streaming", label: "Streaming", flag: "" },
  { key: "securecore", label: "Secure Core", flag: "--securecore" },
  { key: "tor", label: "Tor", flag: "--tor" }
]

function filterFlag(key) {
  for (var i = 0; i < SERVER_FILTERS.length; i++) if (SERVER_FILTERS[i].key === key) return SERVER_FILTERS[i].flag
  return ""
}

function hasFeature(server, bit) {
  return (Number(server.Features) & bit) !== 0
}

// Parses the cached server list once and projects it into one country list
// per server-type filter. Only servers the account's plan can reach
// (Tier <= MaxTier from the same file) are listed, except Free which is
// always tier 0.
function serverListRows(raw, countryNames) {
  var out = {}
  var parsed
  try {
    parsed = JSON.parse(String(raw || ""))
  } catch (e) {
    return out
  }
  var logicals = parsed.LogicalServers || []
  var maxTier = Number(parsed.MaxTier)
  if (!isFinite(maxTier)) maxTier = 0
  var reachable = function(s) { return Number(s.Tier) <= maxTier }
  var preds = {
    all: reachable,
    free: function(s) { return Number(s.Tier) === 0 },
    plus: function(s) { return Number(s.Tier) >= 1 && reachable(s) },
    p2p: function(s) { return reachable(s) && hasFeature(s, FEATURE_P2P) },
    streaming: function(s) { return reachable(s) && hasFeature(s, FEATURE_STREAMING) },
    securecore: function(s) { return reachable(s) && hasFeature(s, FEATURE_SECURE_CORE) },
    tor: function(s) { return reachable(s) && hasFeature(s, FEATURE_TOR) }
  }
  for (var key in preds) out[key] = countryRowsWhere(logicals, countryNames, preds[key], key !== "free")
  return out
}

function countryRowsWhere(logicals, countryNames, predicate, sortByName) {
  var result = {}
  try {
    for (var i = 0; i < logicals.length; i++) {
      var server = logicals[i]
      if (!server || Number(server.Status) !== 1 || !predicate(server)) continue
      var code = String(server.ExitCountry || "").toUpperCase()
      if (!code) continue
      if (!result[code]) {
        result[code] = {
          code: code,
          name: countryNames && countryNames[code] ? stripMarkup(countryNames[code]) : code,
          count: 0,
          bestLoad: Number(server.Load)
        }
      }
      result[code].count += 1
      var load = Number(server.Load)
      if (isFinite(load) && load < result[code].bestLoad) result[code].bestLoad = load
    }
  } catch (e) {
    return []
  }
  var rows = []
  for (var code in result) {
    var row = result[code]
    row.hint = row.count + " server" + (row.count === 1 ? "" : "s") + " \u00b7 " + row.bestLoad + "% best load"
    rows.push(row)
  }
  rows.sort(function(a, b) {
    if (!sortByName && a.bestLoad !== b.bestLoad) return a.bestLoad - b.bestLoad
    return a.name.localeCompare(b.name)
  })
  return rows
}

function elideStatus(text) {
  var value = stripMarkup(String(text || "").replace(/\s+/g, " ").trim())
  return value.length > 140 ? value.substring(0, 137) + "\u2026" : value
}

// Formats a millisecond duration as a compact "1h 23m" / "45s" string.
function formatUptime(ms) {
  var total = Math.max(0, Math.floor(Number(ms) / 1000))
  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var seconds = total % 60
  if (hours > 0) return hours + "h " + minutes + "m"
  if (minutes > 0) return minutes + "m " + seconds + "s"
  return seconds + "s"
}

// Extracts rx/tx byte counters for a specific interface from `cat /proc/net/dev`.
function parseNetDev(text, device) {
  if (!device) return null
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var colon = lines[i].indexOf(":")
    if (colon < 1) continue
    var name = lines[i].substring(0, colon).replace(/\s/g, "")
    if (name !== device) continue
    var fields = lines[i].substring(colon + 1).trim().split(/\s+/)
    if (fields.length < 9) return null
    return { rx: Number(fields[0]) || 0, tx: Number(fields[8]) || 0 }
  }
  return null
}

// Formats bytes per second as a compact "1.2 MiB/s" / "340 KiB/s" string.
function formatRate(bytes, seconds) {
  var bps = seconds > 0 ? Math.max(0, bytes / seconds) : 0
  var units = ["B", "KiB", "MiB", "GiB"]
  var u = 0
  var v = bps
  while (v >= 1024 && u < units.length - 1) { v /= 1024; u++ }
  return (v >= 100 ? v.toFixed(0) : v.toFixed(1)) + " " + units[u] + "/s"
}
