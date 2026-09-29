import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The whole flatpak UI: what is installed, what is stale, and a Flathub
// browser.
//
// Read-only queries run here as short-lived Processes. Anything that needs
// sudo or a prompt is handed to a script in scripts/ inside an Omarchy
// floating terminal, because this process is a status bar with no terminal to
// prompt on, and a half-answered sudo inside the shell would wedge it. The one
// exception is the pending-update notification, which prompts for nothing and
// is a single fire-and-forget call.
Panel {
  id: root
  moduleName: "io.github.archlatam.flatpak"
  ipcTarget: "io.github.archlatam.flatpak"

  // Injected by BarWidget.qml's injectPanel(), which owns the actual bar
  // button. KeyboardPanel anchors to the bar item rather than to this panel,
  // and `owner` has to be the bar widget so popout routing finds it.
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Nerd Font glyphs, each checked against the font in use:
  // U+F1B2 cube, U+F021 refresh, U+F1F8 trash, U+F019 download, U+F0AD wrench.
  readonly property string glyphCube: ""
  readonly property string glyphRefresh: ""
  readonly property string glyphTrash: ""
  readonly property string glyphDownload: ""
  readonly property string glyphWrench: ""

  // Flatpak's human-readable output is translated, so every parse runs under
  // LC_ALL=C. The --columns output is not localized, but remote-info's field
  // labels are, and the detail line is matched against them.
  readonly property var cEnv: ["env", "LC_ALL=C", "flatpak"]
  readonly property var listColumns: ["--columns=application,name,version,branch,origin"]

  property var userApps: []
  property var systemApps: []
  property var userUpdates: ({})
  property var systemUpdates: ({})

  // ~3.5k rows fetched once. A refresh re-runs it so a newly published Flathub
  // app shows up, but nothing in the panel ever waits on it.
  property var catalog: []
  property bool catalogLoaded: false
  property bool catalogLoading: false

  property string searchText: ""
  property string detailText: ""
  property int cursorIndex: 0
  property bool cursorActive: false
  property string confirmAppId: ""
  property string confirmAppName: ""

  // Whether this session would hide Flatpak apps from the launcher. Flatpak
  // writes desktop entries into <installation>/exports/share, which is not one
  // of the default XDG data dirs, and nothing in a Hyprland session adds it, so
  // an app installed through this plugin can be installed perfectly well and
  // still not appear in the launcher. Asked of the script rather than assumed,
  // because it may already have been fixed.
  property bool launcherPathBroken: false

  // Latches the pending-update notification. Without it a stable count would
  // re-notify on every poll; it is cleared when the count reaches zero, so an
  // app updated today and a new one published tomorrow both warn.
  property bool updatesNotified: false

  // Update state is folded in here rather than set while parsing, because the
  // two outputs arrive at different times: `flatpak remote-ls --updates` knows
  // an app is stale while `flatpak list` for that same app never mentions it.
  // Reading userUpdates/systemUpdates inside the binding is what makes the
  // counts re-evaluate when the update query lands.
  function withUpdates(apps) {
    var sets = { user: userUpdates, system: systemUpdates }
    for (var i = 0; i < apps.length; i++) {
      var set = sets[apps[i].scope]
      apps[i].updated = !!(set && set[apps[i].id])
    }
    return apps
  }

  readonly property var installed: withUpdates(Model.mergeInstalled(userApps, systemApps))
  readonly property int pendingUpdates: countPending(installed)
  readonly property int pendingUser: countScope(installed, "user")
  readonly property int pendingSystem: countScope(installed, "system")

  readonly property bool searching: searchText.replace(/^\s+|\s+$/g, "") !== ""
  readonly property var results: searching ? Model.filterApps(catalog, searchText, 60) : installed

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color rowHover: Style.hoverFillFor(foreground, accent)
  readonly property color rowSelected: Style.selectedFillFor(foreground, accent)

  // Resolved from this file's own URL so the plugin stays relocatable.
  readonly property string scriptsDir: Model.urlToPath(Qt.resolvedUrl("scripts"))

  readonly property string heroMeta: {
    if (installed.length === 0) return "No apps installed"
    var total = installed.length
    if (pendingUpdates === 0) return total + (total === 1 ? " app installed" : " apps installed")

    var where = []
    if (pendingUser > 0) where.push(pendingUser + " user")
    if (pendingSystem > 0) where.push(pendingSystem + " system")
    return pendingUpdates + " update" + (pendingUpdates === 1 ? "" : "s") + " pending · " + where.join(", ")
  }

  function countPending(apps) {
    var n = 0
    for (var i = 0; i < apps.length; i++) if (apps[i].updated) n++
    return n
  }

  // One notification per session, not one per poll. The count is split by scope
  // because the fix differs: a stale user app updates without a password and a
  // stale system one does not, and that is worth knowing before clicking.
  function notifyPendingUpdates() {
    var n = pendingUpdates
    var where = []
    if (pendingUser > 0) where.push(pendingUser + " user")
    if (pendingSystem > 0) where.push(pendingSystem + " system")

    notifyProc.command = [
      "omarchy-notification-send",
      "-g", glyphCube,
      "-u", "normal",
      "Flatpak updates available",
      n + (n === 1 ? " flatpak has" : " flatpaks have") + " an update · " + where.join(", "),
      // A freedesktop stock icon: the cube is a Nerd Font glyph, and a
      // notification daemon has no reason to own that font.
      "-i", "system-software-update",
      "-t", "15000"
    ]
    notifyProc.running = true
  }

  // Driven by the count rather than by any query finishing, so it fires exactly
  // once whether the number arrived from the user list, the system list, or a
  // background poll.
  onPendingUpdatesChanged: {
    if (pendingUpdates === 0) {
      updatesNotified = false
      return
    }
    if (updatesNotified) return
    updatesNotified = true
    notifyPendingUpdates()
  }

  function countScope(apps, scope) {
    var n = 0
    for (var i = 0; i < apps.length; i++) if (apps[i].updated && apps[i].scope === scope) n++
    return n
  }

  function isInstalled(id) {
    for (var i = 0; i < installed.length; i++) if (installed[i].id === id) return true
    return false
  }

  // ------------------------------------------------------------- refreshing

  function refresh() {
    userListProc.running = true
    systemListProc.running = true
    systemUpdatesProc.running = true
    // Re-asked on every refresh rather than once at startup: the fix may land
    // while the panel is closed, and the check is two file stats.
    launcherPathProc.running = true
    // userUpdatesProc is started from userListProc.onExited instead, because
    // whether it can run at all depends on the user list it is waiting for.
    if (searching && !catalogLoaded) loadCatalog()
  }

  // The catalogue is only worth a round trip once the user searches, so it is
  // deliberately not part of refresh().
  function loadCatalog() {
    if (catalogLoading) return
    catalogLoading = true
    catalogProc.running = true
  }

  function openFromHotkey() {
    open()
    refresh()
  }

  onOpenedChanged: {
    if (!opened) return
    refresh()
    // The field is focused on a callLater because it has no active focus yet
    // while onOpenedChanged runs, and focusing it immediately would be a
    // silent no-op. Typing should work without reaching for the mouse first.
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  onSearchTextChanged: {
    cursorIndex = 0
    cursorActive = false
    if (searching) {
      if (!catalogLoaded) loadCatalog()
      else showDetailFor(results[0])
    } else {
      detailText = ""
    }
  }

  onResultsChanged: {
    if (!searching) return
    var index = Math.max(0, Math.min(cursorIndex, results.length - 1))
    showDetailFor(results[index])
  }

  // ------------------------------------------------------------- processes

  Process {
    id: userListProc
    command: root.cEnv.concat(["list", "--user", "--app"]).concat(root.listColumns)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.userApps = Model.parseInstalled(text, "user")
    }
    onExited: {
      // An empty user installation has no flathub remote yet, and asking it
      // for updates fails with "Remote not found" on every single refresh.
      // With no user apps there is nothing to be stale, so skip the query
      // rather than provoke an error that cannot lead anywhere.
      if (root.userApps.length > 0) {
        userUpdatesProc.running = true
      } else {
        root.userUpdates = {}
      }
    }
  }

  Process {
    id: systemListProc
    command: root.cEnv.concat(["list", "--system", "--app"]).concat(root.listColumns)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.systemApps = Model.parseInstalled(text, "system")
    }
  }

  Process {
    id: userUpdatesProc
    command: root.cEnv.concat(["remote-ls", "--updates", "--user", "--columns=application"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.userUpdates = Model.parseUpdates(text)
    }
    // A failed query must read as "nothing to update", never as a stale
    // count left over from a previous refresh.
    onExited: (exitCode) => { if (exitCode !== 0) root.userUpdates = ({}) }
  }

  Process {
    id: systemUpdatesProc
    command: root.cEnv.concat(["remote-ls", "--updates", "--system", "--columns=application"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.systemUpdates = Model.parseUpdates(text)
    }
    // Same reasoning as userUpdatesProc: a failed query must read as "nothing
    // to update" rather than leave a stale count behind that never clears.
    onExited: (exitCode) => { if (exitCode !== 0) root.systemUpdates = ({}) }
  }

  // Reads the one word the script prints, not its exit code. A script that
  // cannot be run at all is then a silent no-op rather than a false warning
  // about a session that is fine.
  Process {
    id: launcherPathProc
    command: [root.scriptsDir + "/ensure-launcher-path"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.launcherPathBroken = text.indexOf("broken") >= 0
    }
  }

  // The panel is loaded with the bar, but nothing asked for the update list
  // until the panel was opened by hand. That left the bar badge empty and no
  // warning at all for a user who never opens it, which is the one case where
  // "an update is pending" has to reach them. Polling fixes that, and the same
  // count drives the badge, the hero and the notification.
  Timer {
    interval: 60 * 60 * 1000
    running: true
    repeat: true
    // At startup as well, so a machine that boots straight into an update does
    // not wait an hour to say so.
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A single fire-and-forget call. It prompts for nothing and touches no
  // configuration, which is why it does not need a floating terminal.
  Process {
    id: notifyProc
    command: []
  }

  Process {
    id: catalogProc
    command: root.cEnv.concat(["remote-ls", "flathub", "--app", "--columns=application,name"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.catalog = Model.parseCatalog(text)
        root.catalogLoaded = root.catalog.length > 0
      }
    }
    onExited: {
      root.catalogLoading = false
      if (root.searching) root.showDetailFor(root.results[0])
    }
  }

  // Resolves the row under the cursor. Restarting the Process cancels the
  // previous run, so scrolling quickly cannot leave one app's summary pinned
  // under another app's name.
  Process {
    id: detailProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var info = Model.parseRemoteInfo(text)
        var parts = []
        if (info.summary !== "") parts.push(info.summary)

        var sizes = []
        if (info.downloadSize !== "") sizes.push(info.downloadSize + " to download")
        if (info.installedSize !== "") sizes.push(info.installedSize + " installed")
        if (sizes.length > 0) parts.push(sizes.join(" · "))
        if (info.runtime !== "") parts.push(info.runtime)

        root.detailText = parts.join("  —  ")
      }
    }
  }

  function showDetailFor(app) {
    detailText = ""
    if (!app || !searching || isInstalled(app.id)) return
    detailProc.command = cEnv.concat(["remote-info", "flathub", app.id])
    detailProc.running = true
  }

  // ---------------------------------------------------------------- actions

  // Runs one of the plugin's scripts in an Omarchy floating terminal: the logo
  // and the "done" mark come from the wrapper and the script owns the prompt
  // and any sudo. The argument is quoted because an app id came out of flatpak
  // output and this string is about to be handed to a shell; the launcher fix
  // passes a flag the same way.
  function runScript(name, argument) {
    if (!bar || typeof bar.run !== "function") return
    var command = "omarchy-launch-floating-terminal-with-presentation "
      + Model.shellQuote(scriptsDir + "/" + name)
    if (argument) command += " " + Model.shellQuote(argument)
    bar.run(command)
  }

  function fixLauncher() {
    runScript("ensure-launcher-path", "--fix")
  }

  function updateAll() {
    runScript("flatpak-update", "")
  }

  // ----------------------------------------------------------------- cursor

  function moveCursor(delta) {
    var count = results.length
    if (count === 0) return
    cursorIndex = (cursorIndex + delta + count) % count
    showDetailFor(results[cursorIndex])
  }

  // Shared by PanelKeyCatcher and by the search field, so that stepping onto
  // the cursor behaves the same wherever the key was pressed: the first press
  // only reveals the cursor and moves nothing.
  function nudgeCursor(delta) {
    if (results.length === 0) return
    if (!cursorActive) {
      cursorActive = true
      showDetailFor(results[cursorIndex])
      return
    }
    moveCursor(delta)
  }

  function activateCursor() {
    if (confirmAppId !== "" || results.length === 0) return
    var app = results[cursorIndex]
    if (!app) return
    if (searching) {
      // An installed app is shown in results so it can be recognised, but
      // pressing enter on it must not start a reinstall behind the user's back.
      if (isInstalled(app.id)) return
      runScript("flatpak-install", app.id)
    } else {
      runScript("flatpak-update", app.id)
    }
  }

  function removeCursor() {
    if (confirmAppId !== "" || searching || results.length === 0) return
    var app = results[cursorIndex]
    if (!app) return
    confirmAppId = app.id
    confirmAppName = app.name
  }

  function rowSubtitle(app, alreadyInstalled) {
    if (searching) {
      return alreadyInstalled ? app.id + "  ·  already installed" : app.id
    }
    var parts = [app.id, app.scope]
    if (app.updated === true) parts.push("update available")
    else if (app.version !== "") parts.push(app.version)
    return parts.join("  ·  ")
  }

  // ------------------------------------------------------------------- tree

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The search field owns the keyboard while focused, so a typed letter
      // goes into the query instead of being read as a shortcut.
      blocked: searchField.activeFocus

      onMoveRequested: function(dx, dy) {
        root.nudgeCursor(dy !== 0 ? dy : dx)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onDeleteRequested: root.removeCursor()
      onTextKey: function(t) {
        if (t === "r") root.refresh()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: "Flatpak"
          meta: root.heroMeta
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              text: root.glyphCube
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: root.pendingUpdates > 0 ? updateAllButton : null
        }

        TextField {
          id: searchField
          width: parent.width
          foreground: root.foreground
          accent: root.accent
          placeholderText: "Search Flathub…"
          selectByMouse: true
          onTextChanged: root.searchText = text

          // PanelKeyCatcher is blocked while this field has focus, so Enter
          // never reaches activateCursor() from the catcher. This is the only
          // place the key can be handled, and without it the search results
          // are inert: typing then pressing Enter did nothing at all.
          onAccepted: {
            root.cursorActive = true
            root.activateCursor()
          }

          // Arrow keys would otherwise be swallowed as text, leaving no way to
          // reach the second, third, ... result once the field is focused.
          Keys.onUpPressed: root.nudgeCursor(-1)
          Keys.onDownPressed: root.nudgeCursor(1)

          Keys.onEscapePressed: {
            if (text !== "") text = ""
            else root.close()
          }
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: root.detailText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }

        // Low-key on purpose: this is a one-time environment gap, not an error,
        // and a red banner about it would outrank the thing the user came to do.
        // Invisible children are excluded from the layout, so this costs no
        // space once the session is fixed.
        RowLayout {
          width: parent.width
          spacing: Style.space(8)
          visible: root.launcherPathBroken

          Text {
            Layout.fillWidth: true
            text: "Apps you install will not show in the launcher: this session does not know where Flatpak keeps its entries."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelActionButton {
            iconText: root.glyphWrench
            tooltipText: "Fix the launcher"
            foreground: root.foreground
            hoverColor: root.accent
            onClicked: root.fixLauncher()
          }
        }

        PanelSectionHeader {
          width: parent.width
          text: root.searching ? "Flathub" : "Installed"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          width: parent.width
          visible: root.searching && root.catalogLoading
          text: "Loading Flathub…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          visible: !root.searching && root.installed.length === 0
          text: "No flatpaks installed. Search above to add one."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.searching && root.catalogLoaded && root.results.length === 0
          text: "Nothing on Flathub matches “" + root.searchText.trim() + "”"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        ListView {
          id: resultList
          width: parent.width
          height: Math.min(contentHeight, Style.space(280))
          visible: count > 0
          clip: true
          spacing: Style.space(2)
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.results
          currentIndex: root.cursorActive ? root.cursorIndex : -1
          onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

          delegate: Item {
            id: wrapper
            required property var modelData
            required property int index
            width: ListView.view.width
            height: row.implicitHeight

            readonly property bool selected: root.cursorActive && root.cursorIndex === index
            // True for every row of the installed list by definition, and a
            // real lookup in search results, so the row's buttons can mean the
            // same thing in both views: install what is missing, and offer
            // update/remove only for what is actually installed.
            readonly property bool installed: root.searching
              ? root.isInstalled(modelData.id)
              : true

            // "Already installed" only carries meaning for a search hit. In
            // the installed list every row is installed, so labelling them
            // all that way would be noise on every single line.
            readonly property bool markedInstalled: root.searching && installed

            CursorSurface {
              id: row
              anchors.fill: parent
              hasCursor: wrapper.selected
              foreground: root.foreground
              fill: root.rowHover
              currentFill: root.rowSelected
              implicitHeight: rowContent.implicitHeight + Style.space(8)

              RowLayout {
                id: rowContent
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                Column {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    text: wrapper.modelData.name
                    color: wrapper.markedInstalled ? root.dim : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: wrapper.modelData.updated === true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: root.rowSubtitle(wrapper.modelData, wrapper.markedInstalled)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Text {
                  visible: wrapper.modelData.updated === true
                  text: "update"
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.alignment: Qt.AlignVCenter
                }

                PanelActionButton {
                  visible: !wrapper.installed
                  iconText: root.glyphDownload
                  tooltipText: "Install " + wrapper.modelData.name
                  foreground: root.foreground
                  hoverColor: root.accent
                  onClicked: root.runScript("flatpak-install", wrapper.modelData.id)
                }

                PanelActionButton {
                  visible: wrapper.installed
                  iconText: root.glyphRefresh
                  tooltipText: "Update " + wrapper.modelData.name
                  foreground: root.foreground
                  hoverColor: root.accent
                  onClicked: root.runScript("flatpak-update", wrapper.modelData.id)
                }

                PanelActionButton {
                  visible: wrapper.installed
                  iconText: root.glyphTrash
                  tooltipText: "Remove " + wrapper.modelData.name
                  foreground: root.foreground
                  hoverColor: root.urgent
                  onClicked: {
                    root.confirmAppId = wrapper.modelData.id
                    root.confirmAppName = wrapper.modelData.name
                  }
                }
              }
            }
          }
        }
      }

      // A Component cannot be built inside the ternary that selects it, so the
      // update-all button is declared here and referenced by id from the hero.
      Component {
        id: updateAllButton
        PanelActionButton {
          iconText: root.glyphRefresh
          tooltipText: "Update all"
          foreground: root.foreground
          hoverColor: root.accent
          onClicked: root.updateAll()
        }
      }

      // Inside the panel, over the content: the bar slot behind it is a
      // different surface and must not be the thing that dims.
      ConfirmDialog {
        id: removeDialog
        anchors.fill: parent
        z: 10
        message: "Remove " + root.confirmAppName + "?"
        confirmText: "Remove"
        cancelText: "Keep"
        background: Color.background
        foreground: root.foreground
        scrim: Util.alpha(Color.background, 0.7)
        fontFamily: root.fontFamily
        onConfirmed: {
          root.runScript("flatpak-remove", root.confirmAppId)
          root.confirmAppId = ""
        }
        onCanceled: root.confirmAppId = ""
      }
    }
  }

  // Driven from confirmAppId so the dialog and the key handlers can never
  // disagree about whether a removal is pending.
  onConfirmAppIdChanged: {
    removeDialog.opened = confirmAppId !== ""
    if (confirmAppId !== "") cursorActive = false
  }

  // The scripts call `omarchy-shell -q io.github.archlatam.flatpak-refresh refresh` once an
  // install, update or removal finishes. This cannot ride on the panel's own
  // target: qs.Ui.Panel already registers an IpcHandler for ipcTarget, and
  // Quickshell keeps only the first handler per target, so a second one here
  // would be registered and then silently dropped. A separate target is the
  // supported way to expose a second function.
  IpcHandler {
    target: "io.github.archlatam.flatpak-refresh"
    function refresh(): string { root.refresh(); return "ok" }
  }
}
