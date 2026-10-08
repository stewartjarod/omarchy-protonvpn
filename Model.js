// Proton VPN CLI output parsing helpers.

.pragma library

// Last transition that has already produced a desktop notification. The bar
// mounts one Service per monitor, and every instance polls the same CLI;
// deduping here keeps a connect/disconnect from notifying once per monitor.
var _lastNotifiedTransition = { connected: false, at: 0 }
var _notifyDedupeWindowMs = 45000

// "Open straight into search" request from the hotkey. The hotkey arms it
// over IPC, then summons the panel through the shell (which picks the
// focused monitor); the panel that opens consumes it. Expires quickly so a
// later plain click never lands in search.
var _searchRequestAt = 0

function requestSearch(now) {
  _searchRequestAt = now
}

function consumeSearchRequest(now) {
  var armed = _searchRequestAt > 0 && now - _searchRequestAt < 1500
  _searchRequestAt = 0
  return armed
}

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
  return serverListRows(parseServerList(raw), countryNames).free || []
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

// Parses the cached server list once. Callers keep the result and project it
// per filter / country / city on demand.
function parseServerList(raw) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    var maxTier = Number(parsed.MaxTier)
    return { logicals: parsed.LogicalServers || [], maxTier: isFinite(maxTier) ? maxTier : 0 }
  } catch (e) {
    return null
  }
}

// Only servers the account's plan can reach (Tier <= MaxTier) match, except
// Free which is always tier 0.
function filterPredicate(key, maxTier) {
  var reachable = function(s) { return Number(s.Tier) <= maxTier }
  switch (key) {
    case "free": return function(s) { return Number(s.Tier) === 0 }
    case "plus": return function(s) { return Number(s.Tier) >= 1 && reachable(s) }
    case "p2p": return function(s) { return reachable(s) && hasFeature(s, FEATURE_P2P) }
    case "streaming": return function(s) { return reachable(s) && hasFeature(s, FEATURE_STREAMING) }
    case "securecore": return function(s) { return reachable(s) && hasFeature(s, FEATURE_SECURE_CORE) }
    case "tor": return function(s) { return reachable(s) && hasFeature(s, FEATURE_TOR) }
    default: return reachable
  }
}

// One country list per server-type filter.
function serverListRows(parsed, countryNames) {
  var out = {}
  if (!parsed) return out
  for (var i = 0; i < SERVER_FILTERS.length; i++) {
    var key = SERVER_FILTERS[i].key
    out[key] = countryRowsWhere(parsed.logicals, countryNames, filterPredicate(key, parsed.maxTier), key !== "free")
  }
  return out
}

// Cities inside one country for a filter, as rows of { name, count, bestLoad, hint }.
function cityRows(parsed, filterKey, country) {
  if (!parsed) return []
  var pred = filterPredicate(filterKey, parsed.maxTier)
  var byCity = {}
  for (var i = 0; i < parsed.logicals.length; i++) {
    var s = parsed.logicals[i]
    if (!s || Number(s.Status) !== 1 || String(s.ExitCountry || "").toUpperCase() !== country || !pred(s)) continue
    var name = stripMarkup(s.City || "Other")
    var load = Number(s.Load)
    if (!byCity[name]) byCity[name] = { name: name, count: 0, bestLoad: load }
    byCity[name].count += 1
    if (isFinite(load) && load < byCity[name].bestLoad) byCity[name].bestLoad = load
  }
  var rows = []
  for (var n in byCity) {
    var r = byCity[n]
    r.hint = r.count + " server" + (r.count === 1 ? "" : "s") + " \u00b7 " + r.bestLoad + "% load"
    rows.push(r)
  }
  rows.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return rows
}

// Individual servers in a country (and city) for a filter, lowest load first.
function serverRowsIn(parsed, filterKey, country, city) {
  if (!parsed) return []
  var pred = filterPredicate(filterKey, parsed.maxTier)
  var rows = []
  for (var i = 0; i < parsed.logicals.length; i++) {
    var s = parsed.logicals[i]
    if (!s || Number(s.Status) !== 1 || String(s.ExitCountry || "").toUpperCase() !== country || !pred(s)) continue
    if (stripMarkup(s.City || "Other") !== city) continue
    var feats = featureLabels(s)
    rows.push({ name: stripMarkup(s.Name), load: Number(s.Load), hint: s.Load + "%" + (feats.length ? " \u00b7 " + feats.join(", ") : "") })
  }
  rows.sort(function(a, b) { return a.load - b.load })
  return rows
}

function featureLabels(server) {
  var feats = []
  if (hasFeature(server, FEATURE_P2P)) feats.push("P2P")
  if (hasFeature(server, FEATURE_STREAMING)) feats.push("Streaming")
  if (hasFeature(server, FEATURE_SECURE_CORE)) feats.push("Secure Core")
  if (hasFeature(server, FEATURE_TOR)) feats.push("Tor")
  return feats
}

function filterLabel(key) {
  for (var i = 0; i < SERVER_FILTERS.length; i++) if (SERVER_FILTERS[i].key === key) return SERVER_FILTERS[i].label
  return ""
}

function _norm(text) {
  return String(text || "").toLowerCase().replace(/\s+/g, " ").trim()
}

// Free-text search across country names/codes, city names and server names
// (e.g. "nl#12", "zurich", "japan") for the active filter. Returns up to
// `limit` matches per kind; countries reuse the filter's country rows.
function searchRows(parsed, filterKey, query, countries, countryNames, limit) {
  var out = { countries: [], cities: [], servers: [] }
  var q = _norm(query)
  if (!parsed || q === "") return out
  var max = limit || 40
  for (var i = 0; i < (countries || []).length && out.countries.length < max; i++) {
    var c = countries[i]
    if (_norm(c.name).indexOf(q) !== -1 || _norm(c.code) === q) out.countries.push(c)
  }
  var pred = filterPredicate(filterKey, parsed.maxTier)
  var cities = {}
  for (var j = 0; j < parsed.logicals.length; j++) {
    var s = parsed.logicals[j]
    if (!s || Number(s.Status) !== 1 || !pred(s)) continue
    var code = String(s.ExitCountry || "").toUpperCase()
    var city = stripMarkup(s.City || "")
    var load = Number(s.Load)
    if (city && _norm(city).indexOf(q) !== -1) {
      var key = code + "|" + city
      if (!cities[key]) cities[key] = { country: code, name: city, countryName: (countryNames && countryNames[code]) ? stripMarkup(countryNames[code]) : code, count: 0, bestLoad: load }
      cities[key].count += 1
      if (isFinite(load) && load < cities[key].bestLoad) cities[key].bestLoad = load
    }
    if (out.servers.length < max && _norm(s.Name).indexOf(q) !== -1) {
      var feats = featureLabels(s)
      out.servers.push({ name: stripMarkup(s.Name), country: code, city: city || "Other", load: load, hint: s.Load + "%" + (feats.length ? " \u00b7 " + feats.join(", ") : "") })
    }
  }
  for (var k in cities) {
    if (out.cities.length >= max) break
    var r = cities[k]
    r.hint = r.count + " server" + (r.count === 1 ? "" : "s") + " \u00b7 " + r.bestLoad + "% load"
    out.cities.push(r)
  }
  out.cities.sort(function(a, b) { return a.name.localeCompare(b.name) })
  out.servers.sort(function(a, b) { return a.load - b.load })
  return out
}

// Favorites are { kind: "country" | "city" | "server", country, city, name,
// filter }. Country/city favorites remember the type filter they were saved
// under ("P2P in Netherlands"); servers are specific already.
function favoriteKey(fav) {
  if (!fav) return ""
  if (fav.kind === "server") return "server:" + fav.name
  if (fav.kind === "city") return "city:" + fav.country + ":" + fav.city + ":" + (fav.filter || "all")
  return "country:" + fav.country + ":" + (fav.filter || "all")
}

// Label + live hint (current load) for a favorite row.
function describeFavorite(parsed, fav, countryNames) {
  var countryName = countryNames && countryNames[fav.country] ? stripMarkup(countryNames[fav.country]) : (fav.country || "")
  var typeSuffix = fav.filter && fav.filter !== "all" ? filterLabel(fav.filter) + " \u00b7 " : ""
  if (fav.kind === "server") {
    var hint = ""
    if (parsed) {
      for (var i = 0; i < parsed.logicals.length; i++) {
        var s = parsed.logicals[i]
        if (!s || stripMarkup(s.Name) !== fav.name) continue
        hint = Number(s.Status) === 1 ? s.Load + "% \u00b7 " + stripMarkup(s.City || countryName) : "offline"
        break
      }
    }
    return { label: fav.name, hint: hint || countryName }
  }
  if (fav.kind === "city") {
    var cities = cityRows(parsed, fav.filter || "all", fav.country).filter(function(r) { return r.name === fav.city })
    return { label: fav.city + ", " + countryName, hint: typeSuffix + (cities.length ? cities[0].bestLoad + "% load" : "unavailable") }
  }
  return { label: countryName, hint: typeSuffix + "fastest" }
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
    row.hint = row.count + " server" + (row.count === 1 ? "" : "s") + " \u00b7 " + row.bestLoad + "% load"
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
