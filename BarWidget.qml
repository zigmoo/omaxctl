import QtQuick
import qs.Commons
import qs.Ui

// OmaXCtl bar icon. The control panel (account selector, filters, rows,
// Unfollow countdown and History) arrives in the next commits; every action
// goes through `x_tool following`, never by clicking X from the shell.
BarWidget {
  id: root
  moduleName: "moo.omaxctl"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰀕"
    tooltipText: strings.t("tooltip")
  }
}
