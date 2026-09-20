import QtQuick
import qs.Ui

// Bar button that opens the App Placement settings overlay.
BarWidget {
  id: root
  moduleName: "ioiohori.app-placement"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰕰"
    horizontalMargin: 7.5
    onPressed: function(mouseButton) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle ioiohori.app-placement '{}'")
    }
  }
}
