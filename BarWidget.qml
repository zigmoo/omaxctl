import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// OmaXCtl bar icon and host for the control panel. Left click opens the panel.
// Every action goes through `x_tool following`; the shell never clicks X.
BarWidget {
  id: root
  moduleName: "moo.omaxctl"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Shape contract for shell summon/hide routing and the open-panel dot.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property bool running: panelLoader.item ? panelLoader.item.runActive === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onStatusChanged: if (status === Loader.Error) console.warn("OmaXCtl: Panel.qml failed to load")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  ShellIpc {
    target: "moo.omaxctl"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰀕"
    active: root.running
    tooltipText: root.running ? strings.t("tooltip.running") : strings.t("tooltip")
    onPressed: function(mouseButton) { root.togglePanel() }
  }
}
