import QtQuick
import qs.Commons
import "LandData.js" as Land

// Offline server map: Natural Earth land outlines plus the cached server
// list's coordinates. No network, no tiles. Dots are server locations for the
// active filter; the connected server is the large accent dot, with a dashed
// entry-to-exit arc when it is a Secure Core route. Click a dot to open its
// country in the list.
Item {
  id: root

  property var points: []          // [{ lat, lon, code, count }]
  property var connectedLoc: null  // { lat, lon }
  property var arcFrom: null       // { lat, lon } Secure Core entry
  property var favoriteCodes: ({})  // { code: true }
  property color foreground: Color.foreground
  property color accent: Color.accent
  signal countryClicked(string code)

  // Latitude window: Arctic circle edge to just above Antarctica's coast.
  readonly property real latTop: 84
  readonly property real latBottom: -58
  implicitHeight: Math.round(width * (latTop - latBottom) / 360)
  height: implicitHeight

  function px(lon) { return (lon + 180) / 360 * width }
  function py(lat) { return (latTop - lat) / (latTop - latBottom) * height }

  onPointsChanged: canvas.requestPaint()
  onConnectedLocChanged: canvas.requestPaint()
  onArcFromChanged: canvas.requestPaint()
  onFavoriteCodesChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var fg = root.foreground
      var ac = root.accent

      // Land
      ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.13)
      ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.30)
      ctx.lineWidth = 0.6
      var land = Land.LAND
      for (var i = 0; i < land.length; i++) {
        var p = land[i]
        ctx.beginPath()
        ctx.moveTo(root.px(p[0]), root.py(p[1]))
        for (var j = 2; j < p.length; j += 2) ctx.lineTo(root.px(p[j]), root.py(p[j + 1]))
        ctx.closePath()
        ctx.fill()
        ctx.stroke()
      }

      // Server dots; favorite countries in the accent colour.
      var pts = root.points || []
      for (var k = 0; k < pts.length; k++) {
        var d = pts[k]
        var fav = root.favoriteCodes[d.code] === true
        ctx.fillStyle = fav ? Qt.rgba(ac.r, ac.g, ac.b, 0.95) : Qt.rgba(fg.r, fg.g, fg.b, 0.55)
        ctx.beginPath()
        ctx.arc(root.px(d.lon), root.py(d.lat), fav ? 2.4 : 1.6, 0, Math.PI * 2)
        ctx.fill()
      }

      // Secure Core: dashed arc from the entry country to the exit.
      var c = root.connectedLoc
      if (c) {
        var x2 = root.px(c.lon), y2 = root.py(c.lat)
        if (root.arcFrom) {
          var x1 = root.px(root.arcFrom.lon), y1 = root.py(root.arcFrom.lat)
          var cx = (x1 + x2) / 2, cy = Math.min(y1, y2) - Math.abs(x2 - x1) * 0.25 - 4
          ctx.strokeStyle = Qt.rgba(ac.r, ac.g, ac.b, 0.9)
          ctx.lineWidth = 1.2
          var steps = 28
          for (var s = 0; s < steps; s += 2) {
            var t0 = s / steps, t1 = (s + 1) / steps
            ctx.beginPath()
            ctx.moveTo((1 - t0) * (1 - t0) * x1 + 2 * (1 - t0) * t0 * cx + t0 * t0 * x2, (1 - t0) * (1 - t0) * y1 + 2 * (1 - t0) * t0 * cy + t0 * t0 * y2)
            ctx.lineTo((1 - t1) * (1 - t1) * x1 + 2 * (1 - t1) * t1 * cx + t1 * t1 * x2, (1 - t1) * (1 - t1) * y1 + 2 * (1 - t1) * t1 * cy + t1 * t1 * y2)
            ctx.stroke()
          }
          ctx.fillStyle = Qt.rgba(ac.r, ac.g, ac.b, 0.9)
          ctx.beginPath()
          ctx.arc(x1, y1, 2.2, 0, Math.PI * 2)
          ctx.fill()
        }
        // Connected server: ring + dot.
        ctx.strokeStyle = Qt.rgba(ac.r, ac.g, ac.b, 0.55)
        ctx.lineWidth = 1.2
        ctx.beginPath()
        ctx.arc(x2, y2, 6, 0, Math.PI * 2)
        ctx.stroke()
        ctx.fillStyle = Qt.rgba(ac.r, ac.g, ac.b, 1)
        ctx.beginPath()
        ctx.arc(x2, y2, 3.2, 0, Math.PI * 2)
        ctx.fill()
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) {
      var best = null, bestD = 9 * 9
      var pts = root.points || []
      for (var i = 0; i < pts.length; i++) {
        var dx = root.px(pts[i].lon) - mouse.x, dy = root.py(pts[i].lat) - mouse.y
        var d2 = dx * dx + dy * dy
        if (d2 < bestD) { bestD = d2; best = pts[i] }
      }
      if (best) root.countryClicked(best.code)
    }
  }
}
