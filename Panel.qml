import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// OmaXCtl control window. Account selector, filter form, selected count,
// Unfollow (a countdown with Cancel while a batch runs), compact inspectable
// rows, and a History tab of the backup taken before each batch.
//
// A real floating window (like WebcamTuner), so it can be dragged by its title
// bar and stays open while the operator works elsewhere.
//
// All data and actions come from `x_tool following ...` as JSON. Commands are
// argv arrays, never shell strings, so no value is ever interpolated into a shell.
Item {
  id: root
  readonly property string moduleName: "moo.omaxctl"
  property QtObject bar: null
  property var settings: ({})
  property var anchorItem: null
  property var hostWidget: null
  readonly property bool opened: window.visible
  readonly property bool popoutSwitchClosing: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string xTool: Quickshell.env("HOME") + "/dil/toolbox/bin/x_tool"
  readonly property string reviewer: "OmaXCtl:" + (Quickshell.env("USER") || "operator")

  readonly property color fg: Commons.Color.popups.text
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- State
  property var accounts: []
  property string accountId: setting("accountId", "")
  property string scanId: setting("scanId", "")
  property var view: null
  property var rows: []
  property string tab: "accounts"
  property real windowValue: setting("windowValue", 6)
  property string windowUnit: setting("windowUnit", "months")
  property int minFollowers: setting("minFollowers", 0)
  property bool verified: setting("verified", true)
  property bool likely: setting("likely", false)
  property bool onlySelected: false
  property string expandedId: ""
  property var run: null
  property var audit: null
  property var history: []
  property var backup: null
  property bool armed: false
  property string message: ""
  property bool failed: false
  property bool loading: false

  readonly property var unitDays: ({ days: 1, weeks: 7, months: 30 })
  readonly property real inactiveDays: Math.round(windowValue * unitDays[windowUnit])
  readonly property var account: accounts.find(function(a) { return a.id === accountId }) || null
  readonly property bool runActive: !!run && ["starting", "running", "cancelling"].indexOf(run.state) !== -1
  readonly property bool auditActive: !!audit && ["starting", "running", "cancelling"].indexOf(audit.state) !== -1
  readonly property int selectedCount: view ? view.counts.selected : 0
  readonly property var shownRows: onlySelected ? rows.filter(function(r) { return r.eligible }) : rows

  // Handles and names come from X. Strip markup before they reach any
  // Omarchy-owned component whose text format this plugin cannot set.
  function plain(value) { return String(value === undefined || value === null ? "" : value).replace(/[<>&]/g, "") }
  function t(key) { return strings.t(key) }

  function persist(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function filterArgs() {
    var args = ["--inactive-days", String(inactiveDays), "--min-followers", String(minFollowers)]
    if (likely) args.push("--likely-inactive")
    if (!verified) args.push("--no-verified-inactive")
    return args
  }

  function run_(proc, args) {
    if (proc.running) return false
    proc.command = [root.xTool, "following"].concat(args)
    proc.running = true
    return true
  }

  function refreshAccounts() { run_(accountsProc, ["accounts"]) }
  function refreshView() {
    if (!scanId || !(verified || likely)) return
    loading = true
    run_(viewProc, ["accounts", "--scan-id", scanId, "--account-id", accountId].concat(filterArgs()))
  }
  function refreshStatus() {
    if (!accountId) return
    run_(statusProc, ["prune-status", "--account-id", accountId, "--tail", "5"])
    run_(auditProc, ["audit-status", "--account-id", accountId])
  }
  function refreshHistory() { if (accountId) run_(historyProc, ["backups", "--account-id", accountId]) }
  function showBackup(id) { run_(backupProc, ["backup-show", "--account-id", accountId, "--backup-id", id]) }

  function chooseAccount(id) {
    var found = accounts.find(function(a) { return a.id === id })
    if (!found) return
    accountId = found.id
    scanId = found.default_scan_id
    persist({ accountId: accountId, scanId: scanId })
    view = null; rows = []; run = null; audit = null; history = []; backup = null
    refreshView(); refreshStatus(); refreshHistory()
  }

  function filtersChanged() {
    armed = false
    persist({ windowValue: windowValue, windowUnit: windowUnit, minFollowers: minFollowers, verified: verified, likely: likely })
    viewDebounce.restart()
  }

  function unfollow() {
    if (runActive || selectedCount === 0) return
    if (!armed) { armed = true; return }
    armed = false
    message = t("status.starting"); failed = false
    run_(actionProc, ["prune-run", "--scan-id", scanId, "--account-id", accountId]
      .concat(filterArgs())
      .concat(["--target-id", "new", "--reviewer", reviewer, "--max-actions", String(Math.min(selectedCount, 1000))]))
  }
  function cancelRun() { if (run) run_(actionProc, ["prune-cancel", "--run-id", run.run_id]) }
  function startAudit() {
    if (!account) return
    message = t("status.auditStarting"); failed = false
    run_(actionProc, ["audit-run", "--scan-id", scanId, "--account-id", accountId, "--account-handle", account.handle, "--target-id", "new"])
  }
  function stopAudit() { if (audit) run_(actionProc, ["audit-cancel", "--audit-id", audit.audit_id]) }
  function setKeep(row, keep) {
    run_(actionProc, ["whitelist", "--account-id", accountId, keep ? "--add" : "--remove", row.id, "--reason", "OmaXCtl keep list"])
  }

  function ageText(days) {
    if (days === null || days === undefined) return "—"
    if (days >= 365) return strings.t("age.years").arg(Commons.I18n.formatNumber(days / 365, 1))
    if (days >= 60) return strings.t("age.months").arg(Commons.I18n.formatNumber(Math.floor(days / 30)))
    return strings.t("age.days").arg(Commons.I18n.formatNumber(Math.floor(days)))
  }
  function flags(row) {
    var out = []
    if (row.follows_you) out.push("󰁔")      // mutual
    if (row.kept) out.push("󰌾")             // keep list
    if (row.protected) out.push("󰍁")        // protected
    if (row.unfollowed_at) out.push("󰀍")    // already unfollowed
    if (row.evidence === "likely") out.push("~")
    else if (row.activity_status !== "complete") out.push("?")
    return out.join(" ")
  }
  function reasonText(reasons) {
    return reasons.map(function(r) { var s = strings.t("reason." + r); return s === "reason." + r ? r : s }).join(", ")
  }
  function dateText(iso) {
    if (!iso) return "—"
    return new Date(iso).toLocaleString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat)
  }

  // Window sizing, following WebcamTuner: open at a remembered size, fit it to
  // the monitor it lands on, and scale the content down rather than clip it.
  readonly property size openingSize: Qt.size(720, 640)
  readonly property size compactLayoutSize: Qt.size(860, 660)
  property int expandedWidth: setting("windowWidth", openingSize.width)
  property int expandedHeight: setting("windowHeight", openingSize.height)
  // Interface zoom, 50..150%, Ctrl+= / Ctrl+-; starts at 70% like WebcamTuner.
  property int scalePercent: Math.max(50, Math.min(150, setting("scalePercent", 70)))
  readonly property real fit: scalePercent / 100 * Math.min(1,
    window.width > 0 ? window.width / (compactLayoutSize.width * scalePercent / 100) : 1,
    window.height > 0 ? (window.height - titleBar.height) / (compactLayoutSize.height * scalePercent / 100) : 1)
  function setScale(percent) {
    scalePercent = Math.max(50, Math.min(150, percent))
    persist({ scalePercent: scalePercent })
  }

  // Per-account context menu (right click): Open profile, Keep, Unfollow now.
  property var menuRow: null
  property point menuAt: Qt.point(0, 0)
  property bool menuConfirm: false
  function openMenu(row, item, x, y) {
    menuRow = row
    menuConfirm = false
    menuAt = item.mapToItem(content, x, y)
  }
  function unfollowNow(row) {
    menuRow = null
    if (runActive) { failed = true; message = t("menu.busy"); return }
    message = strings.t("status.unfollowOne").arg(row.handle); failed = false
    run_(actionProc, ["prune-run", "--scan-id", scanId, "--account-id", accountId, "--ids", row.id,
      "--max-actions", "1", "--target-id", "new", "--reviewer", reviewer].concat(filterArgs()))
  }

  function rememberSize() {
    if (window.width <= 0 || window.height <= 0) return
    expandedWidth = window.width
    expandedHeight = window.height
    persist({ windowWidth: expandedWidth, windowHeight: expandedHeight })
  }

  function open() { refreshAccounts(); window.visible = true }
  function close() { armed = false; menuRow = null; rememberSize(); window.visible = false }
  function toggle() { if (root.opened) root.close(); else root.open() }
  function closeForPopoutSwitch() {}

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---- Commands
  Process {
    id: accountsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.accounts = JSON.parse(text).accounts || []
          if (!root.account && root.accounts.length) root.chooseAccount(root.accounts[0].id)
          else { root.refreshView(); root.refreshStatus(); root.refreshHistory() }
        } catch (e) { root.failed = true; root.message = root.t("error.accounts") }
      }
    }
  }
  Process {
    id: viewProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        try {
          var data = JSON.parse(text)
          root.view = data
          root.rows = data.rows || []
          if (data.active_run) root.run = data.active_run
        } catch (e) { root.failed = true; root.message = root.t("error.view") }
      }
    }
    stderr: StdioCollector { id: viewErr; waitForEnd: true }
  }
  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var was = root.runActive
          root.run = JSON.parse(text).run
          if (was && !root.runActive) { root.refreshView(); root.refreshHistory() }
        } catch (e) {}
      }
    }
  }
  Process {
    id: auditProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.audit = JSON.parse(text).audit } catch (e) {} }
    }
  }
  Process {
    id: historyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.history = JSON.parse(text).backups || [] } catch (e) {} }
    }
  }
  Process {
    id: backupProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { try { root.backup = JSON.parse(text) } catch (e) {} }
    }
  }
  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(code) {
      if (code === 0) { root.failed = false; root.message = "" }
      else { root.failed = true; root.message = String(actionErr.text).replace(/^ERR \| x_tool following \| /, "").trim() }
      root.refreshStatus(); root.refreshView(); root.refreshHistory()
    }
  }

  Timer { id: viewDebounce; interval: 350; onTriggered: root.refreshView() }
  // Polls only while the panel is open: fast while a batch counts down,
  // slower while the audit is still filling in the list.
  Timer {
    interval: root.runActive ? 3000 : 20000
    repeat: true
    running: root.opened && !!root.accountId
    onTriggered: {
      root.refreshStatus()
      if (root.auditActive || !root.runActive) root.refreshView()
    }
  }

  // ---- View
  // A compact switch with its label beside it, one line tall.
  component CheckRow: Row {
    id: check
    property string label: ""
    property string help: ""
    property bool checked: false
    property bool locked: false
    signal toggled()
    spacing: Style.space(6)
    opacity: locked ? 0.7 : 1
    ToggleSwitch {
      anchors.verticalCenter: parent.verticalCenter
      checked: check.checked
      interactive: !check.locked
      cursorRing: false
      foreground: root.fg
      accent: root.accent
      onToggled: check.toggled()
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      text: check.label
      MouseArea {
        anchors.fill: parent
        enabled: !check.locked
        hoverEnabled: true
        onClicked: check.toggled()
        PanelToolTip { visible: parent.containsMouse && check.help !== ""; text: check.help }
      }
    }
  }

  component MenuItem: MouseArea {
    id: item
    property string text: ""
    property bool danger: false
    signal activated()
    width: parent ? parent.width : 0
    height: Style.space(30)
    hoverEnabled: true
    onClicked: if (enabled) activated()
    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: item.containsMouse && item.enabled ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22) : "transparent"
    }
    Text {
      anchors { left: parent.left; leftMargin: Style.space(8); verticalCenter: parent.verticalCenter }
      textFormat: Text.PlainText
      text: item.text
      color: !item.enabled ? root.dim : item.danger ? root.accent : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: item.danger
    }
  }

  component Label: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  FloatingWindow {
    id: window
    visible: false
    title: "OmaXCtl"
    implicitWidth: root.expandedWidth
    implicitHeight: root.expandedHeight
    color: Commons.Color.popups.background

    onVisibleChanged: if (visible) floatWindow.restart()

    Shortcut { sequences: ["Ctrl++", "Ctrl+="]; enabled: window.visible; onActivated: root.setScale(root.scalePercent + 10) }
    Shortcut { sequence: "Ctrl+-"; enabled: window.visible; onActivated: root.setScale(root.scalePercent - 10) }
    Shortcut { sequence: "Ctrl+0"; enabled: window.visible; onActivated: root.setScale(70) }

    // A FloatingWindow's size preference does not resize an existing native
    // window, so once Hyprland has placed it: float it, cap it at 92% of the
    // usable area of its own monitor (scale, rotation and bars accounted for),
    // and center it.
    Timer {
      id: floatWindow
      interval: 100
      onTriggered: {
        if (!window.visible || Quickshell.env("QT_QPA_PLATFORM").indexOf("offscreen") !== -1) return
        Hyprland.dispatch('(function() local w=hl.get_window("title:^OmaXCtl$"); if not w then return hl.dsp.no_op() end; '
          + 'local m=w.monitor; if not m then return hl.dsp.no_op() end; '
          + 'local width,height=m.width/m.scale,m.height/m.scale; '
          + 'if (m.transform or 0)%2==1 then width,height=height,width end; '
          + 'local r=m.reserved or {}; width=width-(r.left or 0)-(r.right or 0); '
          + 'height=height-(r.top or 0)-(r.bottom or 0); '
          + 'hl.dispatch(hl.dsp.window.float({action="on",window=w})); '
          + 'hl.dispatch(hl.dsp.window.resize({window=w,relative=false,x=math.max(1,math.min('
          + root.expandedWidth + ',math.floor(width*0.92))),y=math.max(1,math.min('
          + root.expandedHeight + ',math.floor(height*0.92)))})); '
          + 'return hl.dsp.window.center({window=w}) end)()')
      }
    }

    // Title bar: drag anywhere on it to move the window; × closes.
    Rectangle {
      id: titleBar
      anchors { top: parent.top; left: parent.left; right: parent.right }
      height: Style.space(36)
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)

      MouseArea {
        anchors.fill: parent
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        onPressed: window.startSystemMove()
      }
      Label {
        anchors { left: parent.left; leftMargin: Style.space(12); verticalCenter: parent.verticalCenter }
        text: "⠿  OmaXCtl"
        font.bold: true
      }
      PanelActionButton {
        anchors { right: parent.right; rightMargin: Style.space(6); verticalCenter: parent.verticalCenter }
        iconText: "󰅖"
        foreground: root.fg
        tooltipText: root.t("window.close")
        onClicked: root.close()
      }
    }

    // Content is laid out at no less than the compact size and scaled to fit.
    Item {
      id: content
      x: Style.space(14) * root.fit
      y: titleBar.height + Style.space(14) * root.fit
      width: window.width / root.fit - Style.space(28)
      height: (window.height - titleBar.height) / root.fit - Style.space(28)
      transform: Scale { xScale: root.fit; yScale: root.fit }
      focus: true
      Keys.onEscapePressed: { if (root.menuRow) root.menuRow = null; else root.close() }

      // Click outside the context menu closes it.
      MouseArea {
        anchors.fill: parent
        z: 50
        visible: !!root.menuRow
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.menuRow = null
      }
      Rectangle {
        id: contextMenu
        z: 51
        visible: !!root.menuRow
        x: Math.min(root.menuAt.x, content.width - width)
        y: Math.min(root.menuAt.y, content.height - height)
        width: Style.space(280)
        height: menuColumn.implicitHeight + Style.space(12)
        color: Commons.Color.popups.background
        border.color: Commons.Color.popups.border
        border.width: 1
        radius: Style.cornerRadius
        Column {
          id: menuColumn
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(6) }
          Label {
            width: parent.width
            leftPadding: Style.space(8)
            color: root.dim
            font.pixelSize: Style.font.caption
            text: root.menuRow ? "@" + root.menuRow.handle : ""
          }
          MenuItem {
            text: root.t("row.openProfile")
            onActivated: { var row = root.menuRow; root.menuRow = null; Qt.openUrlExternally("https://x.com/" + row.handle) }
          }
          MenuItem {
            text: root.menuRow && root.menuRow.kept ? root.t("row.unkeep") : root.t("row.keep")
            onActivated: { var row = root.menuRow; root.menuRow = null; root.setKeep(row, !row.kept) }
          }
          MenuItem {
            readonly property string block: !root.menuRow ? "" : root.menuRow.kept ? root.t("menu.blockKept")
              : root.menuRow.follows_you ? root.t("menu.blockMutual") : root.menuRow.protected ? root.t("menu.blockProtected")
              : root.menuRow.unfollowed_at ? root.t("menu.blockDone") : ""
            enabled: block === "" && !root.runActive
            text: block !== "" ? strings.t("menu.unfollowBlocked").arg(block)
              : root.menuConfirm ? strings.t("menu.unfollowConfirm").arg(root.menuRow ? root.menuRow.handle : "") : root.t("menu.unfollowNow")
            danger: root.menuConfirm
            onActivated: { if (!root.menuConfirm) root.menuConfirm = true; else root.unfollowNow(root.menuRow) }
          }
        }
      }

      Column {
        id: body
        anchors.fill: parent
        spacing: Style.space(8)

        // Header: title, account selector, audit
        Row {
          width: parent.width
          spacing: Style.space(12)

          Dropdown {
            width: Style.space(220)
            showLabel: false
            value: root.accountId
            options: root.accounts.map(function(a) { return { value: a.id, label: "@" + root.plain(a.handle) } })
            onChanged: function(value) { root.chooseAccount(value) }
          }
          Label {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(400)
            color: root.dim
            font.pixelSize: Style.font.caption
            text: root.audit
              ? strings.t("audit.line").arg(root.t("audit.state." + root.audit.state)).arg(Commons.I18n.formatNumber(root.audit.known_following))
                  .arg(Commons.I18n.formatNumber(root.account && root.account.profile_counts ? root.account.profile_counts.following : 0))
                  .arg(Commons.I18n.formatNumber(root.audit.profiles_done))
              : root.t("audit.none")
          }
          Button {
            anchors.verticalCenter: parent.verticalCenter
            bordered: true
            text: root.auditActive ? root.t("audit.stop") : root.t("audit.start")
            enabled: !!root.account
            onClicked: root.auditActive ? root.stopAudit() : root.startAudit()
          }
        }

        ButtonGroup {
          options: [{ value: "accounts", label: root.t("tab.accounts") }, { value: "history", label: root.t("tab.history") }, { value: "about", label: root.t("tab.about") }]
          value: root.tab
          onChanged: function(value) { root.tab = value; if (value === "history") root.refreshHistory() }
        }

        // ---- Accounts tab
        Column {
          id: accountsTab
          visible: root.tab === "accounts"
          width: parent.width
          height: body.height - y
          spacing: Style.space(8)

          Row {
            spacing: Style.space(12)
            Label { anchors.verticalCenter: parent.verticalCenter; width: Style.space(170); text: root.t("filter.inactive") }
            PanelSlider {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(300)
              bar: root.bar
              minimum: 1; maximum: root.windowUnit === "days" ? 90 : (root.windowUnit === "weeks" ? 52 : 36)
              step: 1; integer: true
              value: root.windowValue
              onMoved: function(v) { root.windowValue = v }
              onReleased: function(v) { root.windowValue = v; root.filtersChanged() }
            }
            Label { anchors.verticalCenter: parent.verticalCenter; width: Style.space(50); text: Commons.I18n.formatNumber(root.windowValue) }
            ButtonGroup {
              anchors.verticalCenter: parent.verticalCenter
              options: [{ value: "days", label: root.t("unit.days") }, { value: "weeks", label: root.t("unit.weeks") }, { value: "months", label: root.t("unit.months") }]
              value: root.windowUnit
              onChanged: function(value) {
                root.windowValue = Math.max(1, Math.round(root.inactiveDays / root.unitDays[value]))
                root.windowUnit = value
                root.filtersChanged()
              }
            }
          }

          Row {
            spacing: Style.space(12)
            Label { anchors.verticalCenter: parent.verticalCenter; width: Style.space(170); text: root.t("filter.minFollowers") }
            PanelSlider {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(300)
              bar: root.bar
              minimum: 0; maximum: 5000; step: 50; integer: true
              value: root.minFollowers
              onMoved: function(v) { root.minFollowers = v }
              onReleased: function(v) { root.minFollowers = v; root.filtersChanged() }
            }
            Label { anchors.verticalCenter: parent.verticalCenter; text: Commons.I18n.formatNumber(root.minFollowers) }
          }

          Row {
            spacing: Style.space(22)
            CheckRow {
              label: root.t("filter.verified")
              help: root.t("filter.verifiedHelp")
              checked: root.verified
              onToggled: { if (root.verified && !root.likely) return; root.verified = !root.verified; root.filtersChanged() }
            }
            CheckRow {
              label: root.t("filter.likely")
              help: root.t("filter.likelyHelp")
              checked: root.likely
              onToggled: { if (root.likely && !root.verified) return; root.likely = !root.likely; root.filtersChanged() }
            }
            CheckRow { label: root.t("filter.mutuals"); help: root.t("filter.locked"); checked: true; locked: true }
            CheckRow { label: root.t("filter.keep"); help: root.t("filter.locked"); checked: true; locked: true }
          }

          // Count and Unfollow / countdown
          Row {
            width: parent.width
            spacing: Style.space(12)

            Column {
              width: parent.width - unfollowRow.width - Style.space(12)
              Label {
                width: parent.width
                font.pixelSize: Style.font.subtitle
                font.bold: true
                text: root.view
                  ? strings.tn("count.selected", root.selectedCount).arg(Commons.I18n.formatNumber(root.selectedCount)).arg(Commons.I18n.formatNumber(root.view.counts.following_known))
                  : (root.loading ? root.t("status.loading") : root.t("status.noData"))
              }
              Label {
                width: parent.width
                color: root.dim
                font.pixelSize: Style.font.caption
                visible: !!root.view
                text: root.view ? strings.t("count.detail")
                  .arg(Commons.I18n.formatNumber(root.view.counts.selected_verified))
                  .arg(Commons.I18n.formatNumber(root.view.counts.selected_likely))
                  .arg(Commons.I18n.formatNumber(root.view.counts.follows_you))
                  .arg(Commons.I18n.formatNumber(root.view.counts.kept))
                  .arg(Commons.I18n.formatNumber(root.view.counts.activity_unknown)) : ""
              }
            }

            Row {
              id: unfollowRow
              spacing: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              Button {
                bordered: true
                active: root.armed || root.runActive
                enabled: root.runActive || root.selectedCount > 0
                text: root.runActive
                  ? strings.t("run.countdown").arg(Commons.I18n.formatNumber(root.run.remaining)).arg(Commons.I18n.formatNumber(root.run.total))
                  : (root.armed ? strings.t("run.confirm").arg(Commons.I18n.formatNumber(root.selectedCount)) : strings.t("run.unfollow").arg(Commons.I18n.formatNumber(root.selectedCount)))
                tooltipText: root.runActive && root.run.current ? "@" + root.plain(root.run.current.handle) : root.t("run.backupNote")
                onClicked: if (!root.runActive) root.unfollow()
              }
              Button {
                bordered: true
                visible: root.runActive || root.armed
                text: root.t("run.cancel")
                onClicked: root.runActive ? root.cancelRun() : (root.armed = false)
              }
            }
          }

          Label {
            width: parent.width
            visible: !!root.run && !root.runActive
            color: root.dim
            font.pixelSize: Style.font.caption
            text: root.run ? strings.t("run.last").arg(root.t("run.state." + root.run.state))
              .arg(Commons.I18n.formatNumber(root.run.confirmed)).arg(Commons.I18n.formatNumber(root.run.skipped))
              .arg(Commons.I18n.formatNumber(root.run.failed)).arg(root.run.halt_reason ? root.plain(root.run.halt_reason) : "") : ""
          }
          Label {
            width: parent.width
            visible: root.message !== ""
            color: root.failed ? root.accent : root.dim
            wrapMode: Text.Wrap
            text: root.message
          }

          PanelSeparator { width: parent.width }

          Row {
            spacing: Style.space(10)
            PanelSectionHeader { anchors.verticalCenter: parent.verticalCenter; text: root.t("rows.header"); foreground: root.fg }
            CheckRow {
              anchors.verticalCenter: parent.verticalCenter
              label: root.t("rows.onlySelected")
              checked: root.onlySelected
              onToggled: root.onlySelected = !root.onlySelected
            }
            Label { anchors.verticalCenter: parent.verticalCenter; color: root.dim; font.pixelSize: Style.font.caption
              text: strings.t("rows.count").arg(Commons.I18n.formatNumber(root.shownRows.length)) + "  ·  " + root.t("rows.legend") }
          }

          ListView {
            id: list
            width: parent.width
            height: Math.max(Style.space(120), accountsTab.height - y)
            clip: true
            model: root.shownRows
            boundsBehavior: Flickable.StopAtBounds
            Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AlwaysOn }
            delegate: Column {
              required property var modelData
              width: list.width
              readonly property bool open: root.expandedId === modelData.id

              MouseArea {
                width: parent.width - Style.space(14)
                height: Style.space(22)
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(mouse) {
                  if (mouse.button === Qt.RightButton) root.openMenu(modelData, this, mouse.x, mouse.y)
                  else root.expandedId = parent.open ? "" : modelData.id
                }
                Rectangle { anchors.fill: parent; color: parent.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08) : "transparent" }
                Row {
                  anchors.fill: parent
                  spacing: Style.space(8)
                  Label { width: Style.space(18); text: modelData.eligible ? "●" : "○"; color: modelData.eligible ? root.accent : root.dim; font.pixelSize: Style.font.caption }
                  Label { width: Style.space(170); text: "@" + modelData.handle; font.pixelSize: Style.font.caption }
                  Label { width: Style.space(220); text: modelData.name; color: root.dim; font.pixelSize: Style.font.caption }
                  Label { width: Style.space(80); horizontalAlignment: Text.AlignRight; font.pixelSize: Style.font.caption
                    text: modelData.followers === null ? "—" : Commons.I18n.formatNumber(modelData.followers) }
                  Label { width: Style.space(90); horizontalAlignment: Text.AlignRight; font.pixelSize: Style.font.caption; text: root.ageText(modelData.inactive_days) }
                  Label { width: Style.space(90); font.pixelSize: Style.font.caption; text: root.flags(modelData) }
                }
              }
              Column {
                visible: parent.open
                width: parent.width
                leftPadding: Style.space(26)
                spacing: Style.space(4)
                Label { width: parent.width - Style.space(26); wrapMode: Text.Wrap; font.pixelSize: Style.font.caption; color: root.dim
                  text: strings.t("row.detail").arg(root.dateText(modelData.last_activity_at)).arg(root.t("evidence." + (modelData.evidence || "unknown")))
                    .arg(root.dateText(modelData.profile_observed_at || modelData.observed_at)) }
                Label { width: parent.width - Style.space(26); wrapMode: Text.Wrap; font.pixelSize: Style.font.caption; color: root.dim
                  visible: modelData.reasons.length > 0
                  text: strings.t("row.reasons").arg(root.reasonText(modelData.reasons)) }
                Row {
                  spacing: Style.space(8)
                  Button { bordered: true; text: root.t("row.openProfile"); onClicked: Qt.openUrlExternally("https://x.com/" + modelData.handle) }
                  Button { bordered: true; text: modelData.kept ? root.t("row.unkeep") : root.t("row.keep"); onClicked: root.setKeep(modelData, !modelData.kept) }
                }
              }
            }
          }
        }

        // ---- About tab: what OmaXCtl and x_tool do, and how.
        Flickable {
          id: aboutTab
          visible: root.tab === "about"
          width: parent.width
          height: body.height - y
          clip: true
          contentHeight: aboutColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

          Column {
            id: aboutColumn
            width: aboutTab.width - Style.space(18)
            spacing: Style.space(6)
            Repeater {
              model: ["intro", "audit", "filters", "unfollow", "now", "safety", "history", "keys", "data", "risk"]
              Column {
                required property string modelData
                width: aboutColumn.width
                spacing: Style.space(2)
                topPadding: modelData === "intro" ? 0 : Style.space(8)
                Label {
                  width: parent.width
                  visible: modelData !== "intro"
                  font.bold: true
                  text: root.t("about." + modelData + ".title")
                }
                Label {
                  width: parent.width
                  wrapMode: Text.Wrap
                  elide: Text.ElideNone
                  color: modelData === "intro" ? root.fg : root.dim
                  font.pixelSize: Style.font.body
                  lineHeight: 1.15
                  text: root.t("about." + modelData + ".body")
                }
              }
            }
          }
        }

        // ---- History tab
        Row {
          visible: root.tab === "history"
          width: parent.width
          spacing: Style.space(12)

          ListView {
            id: historyList
            width: Style.space(330)
            height: Style.space(520)
            clip: true
            model: root.history
            delegate: MouseArea {
              required property var modelData
              width: historyList.width
              height: Style.space(48)
              hoverEnabled: true
              onClicked: root.showBackup(modelData.backup_id)
              Rectangle {
                anchors.fill: parent
                color: root.backup && root.backup.backup_id === modelData.backup_id ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                  : (parent.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08) : "transparent")
              }
              Column {
                anchors.fill: parent
                anchors.margins: Style.space(4)
                Label { width: parent.width; font.pixelSize: Style.font.caption; font.bold: true; text: root.dateText(modelData.created_at) }
                Label { width: parent.width; font.pixelSize: Style.font.caption; color: root.dim
                  text: strings.t("history.line").arg(Commons.I18n.formatNumber(modelData.selected_count)).arg(Commons.I18n.formatNumber(modelData.following_count))
                    .arg(modelData.run ? root.t("run.state." + modelData.run.state) : "—").arg(modelData.run ? Commons.I18n.formatNumber(modelData.run.confirmed) : "0") }
              }
            }
            Label { visible: root.history.length === 0; text: root.t("history.empty"); color: root.dim }
          }

          Column {
            width: parent.width - historyList.width - Style.space(12)
            spacing: Style.space(6)
            Label {
              width: parent.width
              font.bold: true
              text: root.backup ? strings.t("backup.title").arg(root.dateText(root.backup.created_at)).arg(root.backup.hash_ok ? root.t("backup.hashOk") : root.t("backup.hashBad")) : root.t("backup.pick")
            }
            Label {
              width: parent.width
              visible: !!root.backup
              color: root.dim
              font.pixelSize: Style.font.caption
              text: root.backup ? strings.t("backup.filters").arg(Commons.I18n.formatNumber(root.backup.filters.inactive_days))
                .arg(Commons.I18n.formatNumber(root.backup.filters.min_followers)).arg(Commons.I18n.formatNumber(root.backup.keep_list.length)) : ""
            }
            ListView {
              id: backupRows
              width: parent.width
              height: Style.space(460)
              clip: true
              model: root.backup ? root.backup.rows : []
              delegate: Row {
                required property var modelData
                width: backupRows.width
                height: Style.space(20)
                spacing: Style.space(8)
                Label { width: Style.space(18); font.pixelSize: Style.font.caption; text: modelData.selected ? "●" : "○"; color: modelData.selected ? root.accent : root.dim }
                Label { width: Style.space(170); font.pixelSize: Style.font.caption; text: "@" + modelData.handle }
                Label { width: Style.space(80); font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignRight
                  text: modelData.followers === null ? "—" : Commons.I18n.formatNumber(modelData.followers) }
                Label { width: parent.width - Style.space(310); font.pixelSize: Style.font.caption; color: root.dim
                  text: modelData.result ? root.t("result." + modelData.result) + (modelData.result_reason ? " · " + root.plain(modelData.result_reason) : "") : "" }
              }
            }
          }
        }
      }
    }
  }
}
