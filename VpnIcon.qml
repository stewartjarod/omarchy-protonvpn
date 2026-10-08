import QtQuick
import QtQuick.Shapes
import qs.Commons

// Adwaita's network-vpn / network-vpn-acquiring symbolic icons, drawn from
// their SVG path data so the theme owns the color. Faded when disconnected,
// full strength when connected; while connecting the acquiring variant shows
// with its three dots pulsing in sequence.
Item {
  id: root

  property real iconSize: 24
  property color color: "#cacccc"
  property color badgeColor: "#a55555"
  property bool connected: false
  property bool connecting: false
  property bool warning: false
  // Torrent tunnel up: small download-arrow badge in the top-right corner.
  property bool torrentOn: false
  property color torrentColor: Color.accent
  property real disconnectedOpacity: 0.4

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  property int _phase: 0

  Timer {
    interval: 280
    repeat: true
    running: root.connecting
    onTriggered: root._phase = (root._phase + 1) % 3
    onRunningChanged: root._phase = 0
  }

  function dotOpacity(i) { return root._phase === i ? 1.0 : 0.35 }

  Item {
    width: 16
    height: 16
    scale: root.iconSize / 16
    transformOrigin: Item.TopLeft

    // network-vpn-symbolic: shield + plug.
    Shape {
      anchors.fill: parent
      visible: !root.connecting
      opacity: root.connected ? 1.0 : root.disconnectedOpacity
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        strokeWidth: -1
        fillColor: root.color
        PathSvg { path: "m 1.996094 1.140625 v 4.484375 c 0 2.214844 1.199218 4.253906 3.132812 5.335938 l 2.867188 1.605468 l 2.871094 -1.605468 c 1.933593 -1.082032 3.128906 -3.121094 3.128906 -5.335938 v -4.484375 l -6 -1.1992188 z m 10.804687 1.800781 l -0.804687 -0.980468 v 3.664062 c 0 1.492188 -0.800782 2.863281 -2.105469 3.589844 l -2.382813 1.332031 h 0.976563 l -2.378906 -1.332031 c -1.304688 -0.726563 -2.109375 -2.097656 -2.109375 -3.589844 v -3.664062 l -0.800782 0.980468 l 5 -1 h -0.394531 z m 0 0" }
      }
      ShapePath {
        strokeWidth: -1
        fillColor: root.color
        PathSvg { path: "m 6.996094 12.257812 c -0.292969 0.171876 -0.535156 0.414063 -0.710938 0.703126 h -3.285156 c -0.550781 0 -1 0.449218 -1 1 c 0 0.550781 0.449219 1 1 1 h 3.25 c 0.351562 0.640624 1.019531 1.035156 1.75 1.039062 c 0.730469 -0.003906 1.402344 -0.398438 1.75 -1.039062 h 3.261719 c 0.550781 0 1 -0.449219 1 -1 c 0 -0.550782 -0.449219 -1 -1 -1 h -3.292969 c -0.175781 -0.289063 -0.417969 -0.53125 -0.710938 -0.703126 c -0.675781 -0.398437 -1.347656 -0.398437 -2.011718 0 z m 1.003906 0.730469 c 0.554688 0 1.007812 0.449219 1.007812 1.003907 c 0 0.558593 -0.453124 1.007812 -1.007812 1.007812 s -1.007812 -0.449219 -1.003906 -1.007812 c -0.003906 -0.554688 0.449218 -1.003907 1.003906 -1.003907 z m 0 0" }
      }
    }

    // network-vpn-acquiring-symbolic: faded shield top + plug, three dots.
    Shape {
      anchors.fill: parent
      visible: root.connecting
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        strokeWidth: -1
        fillColor: Qt.rgba(root.color.r, root.color.g, root.color.b, 0.35)
        PathSvg { path: "m 8 -0.0585938 l -6 1.1992188 v 3.859375 h 2 v -2.21875 l 3.996094 -0.800781 l 4.003906 0.800781 v 2.21875 h 2 v -3.859375 z m -2.800781 11.0585938 l 2.03125 1.136719 c -0.078125 0.035156 -0.15625 0.078125 -0.234375 0.125 c -0.292969 0.167969 -0.535156 0.410156 -0.710938 0.699219 h -3.285156 c -0.550781 0 -1 0.449218 -1 1 c 0 0.550781 0.449219 1 1 1 h 3.25 c 0.351562 0.640624 1.019531 1.035156 1.75 1.039062 c 0.730469 -0.003906 1.402344 -0.398438 1.75 -1.039062 h 3.261719 c 0.550781 0 1 -0.449219 1 -1 c 0 -0.550782 -0.449219 -1 -1 -1 h -3.292969 c -0.175781 -0.289063 -0.417969 -0.53125 -0.710938 -0.699219 c -0.082031 -0.050781 -0.160156 -0.089844 -0.238281 -0.125 l 2.027344 -1.136719 z m 2.800781 1.988281 c 0.554688 0 1.007812 0.449219 1.007812 1.003907 c 0 0.558593 -0.453124 1.007812 -1.007812 1.007812 s -1.007812 -0.449219 -1.003906 -1.007812 c -0.003906 -0.554688 0.449218 -1.003907 1.003906 -1.003907 z m 0 0" }
      }
      ShapePath {
        strokeWidth: -1
        fillColor: Qt.rgba(root.color.r, root.color.g, root.color.b, root.dotOpacity(0))
        PathSvg { path: "m 3 6 c -1.105469 0 -2 0.894531 -2 2 s 0.894531 2 2 2 s 2 -0.894531 2 -2 s -0.894531 -2 -2 -2 z" }
      }
      ShapePath {
        strokeWidth: -1
        fillColor: Qt.rgba(root.color.r, root.color.g, root.color.b, root.dotOpacity(1))
        PathSvg { path: "m 8 6 c -1.105469 0 -2 0.894531 -2 2 s 0.894531 2 2 2 s 2 -0.894531 2 -2 s -0.894531 -2 -2 -2 z" }
      }
      ShapePath {
        strokeWidth: -1
        fillColor: Qt.rgba(root.color.r, root.color.g, root.color.b, root.dotOpacity(2))
        PathSvg { path: "m 13 6 c -1.105469 0 -2 0.894531 -2 2 s 0.894531 2 2 2 s 2 -0.894531 2 -2 s -0.894531 -2 -2 -2 z" }
      }
    }
  }

  Rectangle {
    visible: root.torrentOn
    width: Math.max(7, parent.width * 0.46)
    height: width
    radius: width / 2
    color: root.torrentColor
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: -width * 0.25
    anchors.topMargin: -width * 0.2

    Text {
      anchors.centerIn: parent
      text: "\u2193"
      color: Color.background
      font.pixelSize: Math.max(6, parent.height * 0.8)
      font.bold: true
    }
  }

  Rectangle {
    visible: root.warning && !root.connecting
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom

    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
