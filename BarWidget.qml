import QtQuick
import qs.Commons
import qs.Ui

// Bar slot for the Flatpak manager. The panel owns all state; this file is
// only the pill plus the lifecycle the bar host needs in order to route
// shell.summon/hide/toggle at it.
BarWidget {
  id: root
  moduleName: "io.github.archlatam.flatpak"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Actions that need a terminal (sudo, gum prompts) are delegated to the
  // panel, which knows the plugin's own script directory.
  function runScript(name, argument) {
    if (panelLoader.item && panelLoader.item.runScript) panelLoader.item.runScript(name, argument)
  }

  // A pending update is the one piece of state worth showing before the panel
  // is ever opened, so the pill carries the count. Everything else waits.
  readonly property int pendingUpdates: panelLoader.item ? panelLoader.item.pendingUpdates : 0
  readonly property string label: pendingUpdates > 0 ? pendingUpdates + " " + root.glyph : root.glyph

  // Nerd Font glyph requested for the bar (U+F1B2).
  readonly property string glyph: ""

  visible: panelLoader.item !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    // Reserve room for the count only while there is one, so the bar does not
    // reflow every time an update is installed or a new one appears.
    slotSize: root.vertical
      ? Style.bar.iconSlot
      : Style.bar.iconSlot + (root.pendingUpdates > 0 ? button.badgeWidth : 0)
    tooltipText: ""

    readonly property real badgeWidth: root.pendingUpdates > 0
      ? Math.ceil(root.pendingUpdates.toString().length * Style.font.bodySmall * 0.62) + Style.space(6)
      : 0

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.runScript("flatpak-install", "")
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
