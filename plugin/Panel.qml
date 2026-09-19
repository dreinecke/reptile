import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Ui

// Reptile (re-tile — Dave's name, 2026-09-03, a pair with Barbarian): every desk's recording
// on one panel. Pick a desk along the top and its recording is drawn as blocks the way the
// desk looks — one block per window, sized by the recorded shares. Drag a block onto another
// to swap them, drag the line between two blocks to change the share, × takes a window out of
// the recording, + adds one (something open on the desk but not recorded, or an app Reptile
// knows how to launch) beside a block of your choice. Every change is written to the
// recording at once — there is no apply step and nothing to cancel — and a desk edited here
// is put back (ws-layout restore) the next time you switch to it, once; the arrow in the
// header does it right now. Nothing can be arranged on a desk that is not on screen, so
// "next visit" is as background as it gets.
//
// The panel never touches a recording file itself: it reads `ws-layout desks` and sends
// every change through `ws-layout edit`, so the recording format has exactly one writer.
//
// The widget draws NOTHING on the bar (zero width) — it exists so the shell loads this panel
// and gives it an IPC target. HYPER+L toggles it (bindings.lua).
Panel {
  id: root

  moduleName: "tinkerbell.reptile"
  ipcTarget: "tinkerbell.reptile"

  readonly property string tool: "\"$HOME/.config/omarchy/workspace-layout/ws-layout\""

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Material Design's coiled snake (nf-md-snake, U+F150E) — looked up in the Nerd Fonts glyph
  // list, not guessed: the first guess at a codepoint drew a sliced circle (2026-09-03).
  readonly property string iconHero: "󱔎"
  readonly property string iconCheck: ""
  readonly property string iconX: ""
  readonly property string iconRestore: ""
  readonly property string iconSave: ""

  // The hero's subtitle: one pun per opening, cycling through the lot, as Barbarian does.
  // A long-list for Dave to cut down (2026-09-03), starting somewhere random.
  readonly property var mottos: [
    "Re-tile", "Re-tile therapy", "Tile cracker", "Crocodile Dundee",
    "See you later, alligator", "In a while, crocodile", "Snakes on a plane",
    "Snakes and ladders", "Komodo desktop", "Iguana be free", "Cold-blooded layout",
    "Shedding windows", "The Lizard of Oz", "Chameleon karma", "Gecko blaster",
    "Turtle power", "Tiled and tested", "Reptile dysfunction", "Scales of justice",
    "A window in the grass", "Hiss and make up", "Python-powered", "Slither in",
    "Basking in the layout", "Rattle and hum", "Tile it like it's hot"
  ]
  property int motto: Math.floor(Math.random() * 9973)

  // Nothing on the bar: the panel is the whole widget.
  implicitWidth: 0
  implicitHeight: 0

  // What `ws-layout desks` said last: the screen's size and corner rounding, the desks, each
  // with its recording drawn in the unit square, what is open there but unrecorded, and the
  // apps a recording can name.
  property var model: ({ "active": 1, "screen": [16, 9], "rounding": 0, "desks": [], "apps": [] })
  property int desk: 0
  // Desks edited here and not yet put back — restored once, the next time one is entered.
  property var dirtyList: []
  property string loadError: ""
  // The add flow: the picker replaces the board; a pick becomes `adding` and waits for the
  // block it should sit beside (a desk with nothing recorded skips the wait).
  property bool picking: false
  property var adding: null
  property int addAnchor: -1
  property bool busy: false
  // Which tab is showing: 0 the desks, 1 the quick apps.
  property int tab: 0

  readonly property var cur: deskFor(desk)
  readonly property var wins: cur ? cur.windows : []
  readonly property var splits: cur ? cur.splits : []
  readonly property var extra: cur ? cur.extra : []
  readonly property string deskName: cur ? cur.name : ""

  function deskFor(n) {
    var ds = model.desks || []
    for (var i = 0; i < ds.length; i++) if (ds[i].ws === n) return ds[i]
    return null
  }

  function quickAppsLoad() { quickApps.load() }

  function isDirty(n) { return dirtyList.indexOf(n) >= 0 }
  function markDirty(n) { if (!isDirty(n)) dirtyList = dirtyList.concat([n]) }
  function clearDirty(n) { dirtyList = dirtyList.filter(function(x) { return x !== n }) }

  // Shell-quote for the `sh -c` strings below (classes have dots and dashes, titles anything).
  function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

  function load() {
    if (readProc.running) return
    readProc.command = ["sh", "-c", tool + " desks"]
    readProc.running = true
  }

  function takeModel(text) {
    try {
      model = JSON.parse(text)
      loadError = ""
    } catch (e) {
      loadError = "Could not read the desk recordings."
      return
    }
    if (desk === 0 || !deskFor(desk)) desk = model.active
  }

  // One change to the selected desk's recording. The tool writes it and answers with the
  // whole model again, so the board redraws from what is actually on disk.
  function edit(args) {
    if (busy || desk === 0) return
    busy = true
    var cmd = tool + " edit " + desk
    for (var i = 0; i < args.length; i++) cmd += " " + q(args[i])
    editProc.command = ["sh", "-c", cmd]
    editProc.running = true
    markDirty(desk)
  }

  function removeAt(i) { edit(["remove", String(i)]) }
  function swapWith(i, j) { if (i !== j) edit(["swap", String(i), String(j)]) }
  function setShare(i, share) {
    share = Math.max(0.1, Math.min(0.9, share))
    edit(["share", String(i), share.toFixed(3)])
  }

  function pickApp(klass, title, label) {
    picking = false
    if (wins.length === 0) {
      edit(["add", klass, "", "", title || ""])
      return
    }
    adding = { "klass": klass, "title": title || "", "label": label }
    addAnchor = -1
  }
  function placeAdding(side) {
    if (!adding || addAnchor < 0) return
    edit(["add", adding.klass, String(addAnchor), side, adding.title])
    adding = null
    addAnchor = -1
  }
  function cancelAdding() { adding = null; addAnchor = -1 }

  function selectDesk(n) {
    if (n === desk) return
    desk = n
    cancelAdding()
    picking = false
  }
  function stepDesk(delta) {
    var ds = model.desks || []
    for (var i = 0; i < ds.length; i++) {
      if (ds[i].ws !== desk) continue
      var j = i + delta
      if (j >= 0 && j < ds.length) selectDesk(ds[j].ws)
      return
    }
  }

  // The arrow: go to the desk and put it back now. Cleared from the dirty list FIRST — the
  // restore focuses that desk, which is the very event the next-visit watcher acts on.
  function applyNow() {
    if (desk === 0) return
    clearDirty(desk)
    actProc.command = ["sh", "-c", tool + " restore " + desk]
    actProc.running = true
  }
  // The floppy: record the desk as it is right now (HYPER+S from here), then redraw.
  function saveNow() {
    if (desk === 0 || busy) return
    busy = true
    clearDirty(desk)
    editProc.command = ["sh", "-c", tool + " snapshot --quiet " + desk + " >/dev/null 2>&1; " + tool + " desks"]
    editProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      motto++
      picking = false
      cancelAdding()
      load()
      root.quickAppsLoad()
    }
  }

  Process {
    id: readProc
    stdout: StdioCollector {
      onStreamFinished: root.takeModel(text)
    }
  }

  Process {
    id: editProc
    stdout: StdioCollector {
      onStreamFinished: { root.takeModel(text); root.busy = false }
    }
    onRunningChanged: if (!running) root.busy = false
  }

  // Restores and focus changes — each tool call toasts for itself, nothing is echoed here.
  Process {
    id: actProc
  }

  Process {
    id: visitProc
  }

  // The next-visit watcher: a desk edited here is put back the first time Dave switches to
  // it. `workspacev2` carries "id,name"; the plain `workspace` event carries only the name.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || event.name !== "workspacev2") return
      var id = parseInt(String(event.data).split(",")[0], 10)
      if (isNaN(id) || !root.isDirty(id) || visitProc.running) return
      root.clearDirty(id)
      visitProc.command = ["sh", "-c", root.tool + " restore " + id]
      visitProc.running = true
    }
  }

  // ---- "Reptile is laying out your Webscape workspace" -------------------------------------
  // The card ws-layout puts up while it opens a desk's windows one after another, and takes
  // down when the desk is done (Dave, 2026-09-03, on seeing the launcher's "Launching ZapZap…"
  // toast: "chill, Reptile is just getting this workspace ready"). Drawn here rather than sent
  // to the shell's own OSD because that one cuts a message off at about twenty characters —
  // "Reptile is laying out…" was all that survived — and a volume key would replace it
  // mid-desk. Otherwise the same card: bottom centre, the popups border, the snake at display
  // size, bold title text. `omarchy-shell tinkerbell.reptile laying "<message>"` shows it (or
  // re-words it), `… laid` takes it down — never before it has had a moment and a half on
  // screen, so a desk that needed nothing still shows that HYPER+R was heard — and it takes
  // itself down after three minutes in case ws-layout died with a desk half open. Since
  // 2026-09-03 this card is Reptile's ONLY voice: Dave saw the notify-send it used to send in the
  // corner and asked for it to stop.
  property bool layingOpen: false
  property string layingMessage: ""
  property double layingSince: 0

  function laying(message) {
    layingMessage = String(message || "Reptile is laying out your workspace")
    layingOpen = true
    layingSince = Date.now()
    layingHold.stop()
    layingGuard.restart()
  }
  function laid() {
    var left = 1500 - (Date.now() - layingSince)
    if (left <= 0) {
      layingOpen = false
      layingGuard.stop()
    } else {
      layingHold.interval = left
      layingHold.restart()
    }
  }

  Timer { id: layingGuard; interval: 180000; onTriggered: root.layingOpen = false }
  Timer { id: layingHold; onTriggered: { root.layingOpen = false; layingGuard.stop() } }

  // The Panel's own IPC handler is switched off so the two extra calls can share its target.
  manageIpc: false
  IpcHandler {
    target: "tinkerbell.reptile"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function laying(message: string): string { root.laying(message); return "ok" }
    function laid(): string { root.laid(); return "ok" }
    // quick-app pings here every time one of its keys is used, so the tick beside a row
    // appears while the panel is on screen rather than the next time it is opened.
    function pinged(name: string): string { root.quickAppsLoad(); return "ok" }
  }

  TextMetrics {
    id: layingIconMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.displayLarge
    text: root.iconHero
  }
  TextMetrics {
    id: layingTextMetrics
    font.family: Style.font.family
    font.bold: true
    font.pixelSize: Style.font.title
    text: root.layingMessage
  }

  PanelWindow {
    id: layingWindow
    visible: root.layingOpen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "reptile-laying"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Visual only: an empty input region, so the card never takes a click meant for the desk.
    mask: Region {}

    readonly property int pad: Style.space(16)
    // The OSD's own spacing: a glyph beside text reads airier than it measures.
    readonly property int gap: Math.round(Style.space(16) * 2 / 3)
    readonly property int iconInk: Math.ceil(layingIconMetrics.tightBoundingRect.width)
    readonly property int textWidth: Math.min(Math.ceil(layingTextMetrics.advanceWidth), Style.space(560))

    BorderSurface {
      id: layingCard
      width: layingCard.borderLeft + layingWindow.pad + layingWindow.iconInk + layingWindow.gap
             + layingWindow.textWidth + layingWindow.pad + layingCard.borderRight
      height: layingCard.borderTop + layingWindow.pad + Style.font.displayLarge + layingWindow.pad + layingCard.borderBottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(67)
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      Row {
        anchors.fill: parent
        anchors.topMargin: layingCard.borderTop + layingWindow.pad
        anchors.rightMargin: layingCard.borderRight + layingWindow.pad
        anchors.bottomMargin: layingCard.borderBottom + layingWindow.pad
        anchors.leftMargin: layingCard.borderLeft + layingWindow.pad
        spacing: layingWindow.gap

        Item {
          width: layingWindow.iconInk
          height: parent.height
          Text {
            // The glyph's ink flush in its column, whatever its side bearing.
            x: -layingIconMetrics.tightBoundingRect.x
            anchors.verticalCenter: parent.verticalCenter
            text: root.iconHero
            textFormat: Text.PlainText
            font: layingIconMetrics.font
            color: Color.popups.text
          }
        }
        Text {
          width: layingWindow.textWidth
          anchors.verticalCenter: parent.verticalCenter
          text: root.layingMessage
          textFormat: Text.PlainText
          font: layingTextMetrics.font
          color: Color.popups.text
          elide: Text.ElideRight
          maximumLineCount: 1
        }
      }
    }
  }

  // A row in the add picker: a glyph slot, a name, a dim title — the same card the
  // Barbarian lists wear.
  component QuickField: Rectangle {
    property alias text: quickInput.text
    property string placeholder: ""
    property string accessibleName: ""
    property string accessibleDescription: ""

    function focusInput() { quickInput.forceActiveFocus() }

    height: quickInput.implicitHeight + Style.space(8)
    radius: Style.space(4)
    color: "transparent"
    border.width: 1
    border.color: Qt.darker(qa.foreground, 1.8)

    TextInput {
      id: quickInput
      anchors.fill: parent
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      verticalAlignment: TextInput.AlignVCenter
      color: qa.foreground
      font.family: qa.fontFamily
      font.pixelSize: Style.font.body
      clip: true
      activeFocusOnTab: true
      Accessible.role: Accessible.EditableText
      Accessible.name: parent.accessibleName
      Accessible.description: parent.accessibleDescription
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      visible: quickInput.text === ""
      text: parent.placeholder
      color: qa.muted
      font.family: qa.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  // ---- QUICK APPS ------------------------------------------------------------------------------
  //
  // ⚠️ THE TAB LIVES IN THIS FILE, AS AN INLINE COMPONENT, AND THAT IS NOT A PREFERENCE. It was
  //    written as QuickApps.qml beside this one and Quickshell could not resolve it — "QuickApps is
  //    not a type", which fails the WHOLE widget, so HYPER+L stopped opening at all. A plugin's own
  //    directory is not on the QML import path, `import "."` does not add it, a Loader on
  //    Qt.resolvedUrl() did not help either, and the engine caches the failure so even a corrected
  //    file keeps reporting it. Verified on Voyager, 2026-09-06. Inline components in this file do
  //    work — PickRow below has since 2026-09-03.
  component QuickAppsTab: Column {
    id: qa

    readonly property string tool: "\"$HOME/.config/omarchy/workspace-layout/quick-app\""
    readonly property color foreground: root.foreground
    readonly property color accent: root.accent
    readonly property color muted: root.muted
    readonly property string fontFamily: root.fontFamily
    readonly property color line: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

    property var model: ({ "apps": [], "hide_on_close": true, "reserved": "SUPER + W" })
    property var apps: []
    property string note: ""
    property string appsError: ""
    property bool busy: false
    property bool appsLoading: false

    // The add card is always on screen, so there is always a draft. The app itself is selected
    // from the machine's launchers: its command and window match are not user-entered fields.
    property var draft: ({ "name": "", "label": "", "key": "", "match": "", "launch": "" })
    property bool chosen: false
    property bool editing: false
    property bool capturing: false
    property bool keyListing: false
    property var manualModifiers: []
    property string queuedConflict: ""
    property string checkingConflict: ""
    property string openMenu: ""

    readonly property var appOptions: {
      var configured = model.apps || []
      var options = apps.filter(function (app) {
        if (app.launch === draft.launch) return true
        for (var i = 0; i < configured.length; i++) {
          if (configured[i].launch === app.launch || configured[i].match === app.match) return false
        }
        return true
      }).map(function (app) {
        return { "value": app.launch, "label": app.label }
      })
      if (draft.launch && !options.some(function (option) { return option.value === draft.launch }))
        options.unshift({ "value": draft.launch, "label": draft.label })
      return options
    }
    readonly property string formHelp: appsLoading ? "Loading installed apps…"
      : appsError !== "" ? appsError
      : !chosen ? "Choose an installed app."
      : !shortcutComplete ? (keyListing ? "Choose modifiers and type the key."
                                           : "Press or enter the shortcut you want to use.")
      : ""
    readonly property bool shortcutComplete: hasCompleteShortcut(draft.key)

    spacing: Style.space(8)

    function openAppPicker() { appPicker.open() }

    Keys.onPressed: function (event) {
      if (event.key !== Qt.Key_Escape || appPicker.popupOpen || capturing) return
      root.close()
      event.accepted = true
    }

    function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    function load() {
      if (!listProc.running) {
        listProc.command = ["sh", "-c", tool + " list"]
        listProc.running = true
      }
      if (!appsProc.running) {
        appsLoading = true
        appsError = ""
        appsProc.command = ["sh", "-c", tool + " apps"]
        appsProc.running = true
      }
    }

    function run(args) {
      if (busy) return
      busy = true
      var cmd = tool
      for (var i = 0; i < args.length; i++) cmd += " " + q(args[i])
      runProc.command = ["sh", "-c", cmd + " 2>&1"]
      runProc.running = true
    }

    function blank() {
      return { "name": "", "label": "", "key": "", "match": "", "launch": "" }
    }

    function reset() {
      draft = blank()
      chosen = false
      editing = false
      capturing = false
      keyListing = false
      manualModifiers = []
      queuedConflict = ""
      checkingConflict = ""
      note = ""
    }

    // Picking a launcher settles the command and the window it opens; neither is ever asked for.
    function choose(app) {
      draft = { "name": app.name || "", "label": app.label, "key": draft.key,
                "match": app.match, "launch": app.launch, "icon": app.icon }
      chosen = true
      note = ""
    }

    function chooseLaunch(launch) {
      for (var i = 0; i < apps.length; i++) {
        if (apps[i].launch === launch) { choose(apps[i]); return }
      }
      chosen = false
      note = "That app is no longer installed. Choose another one."
    }

    function editRow(app) {
      draft = { "name": app.name, "label": app.label, "key": app.key, "match": app.match,
                "launch": app.launch, "icon": app.icon }
      chosen = true
      editing = true
      openMenu = ""
      note = "Editing " + app.label + " — change the shortcut, then save."
    }

    function save() {
      if (!chosen || !draft.launch) { note = "Choose an installed app first."; return }
      if (!hasCompleteShortcut(draft.key)) { note = "Finish the shortcut by adding its key."; return }
      var d = draft
      if (!d.name) {
        d.name = String(d.label).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
      }
      run(["set", JSON.stringify(d)])
    }

    function remove(name) { openMenu = ""; run(["remove", name]) }

    // ---- taking a shortcut -----------------------------------------------------------------------

    function isModifier(part) {
      var upper = String(part).toUpperCase()
      return upper === "SUPER" || upper === "CTRL" || upper === "ALT"
          || upper === "SHIFT" || upper === "HYPER"
    }

    function hasCompleteShortcut(shortcut) {
      var parts = String(shortcut).split(" + ").filter(function (part) {
        return String(part).trim() !== ""
      })
      return parts.length > 0 && !isModifier(parts[parts.length - 1])
    }

    function setShortcut(shortcut) {
      var d = draft
      draft = { "name": d.name, "label": d.label, "key": shortcut,
                "match": d.match, "launch": d.launch, "icon": d.icon }
    }

    function queueConflictCheck(shortcut) {
      if (!hasCompleteShortcut(shortcut)) {
        queuedConflict = ""
        return
      }
      queuedConflict = shortcut
      if (!conflictProc.running) runConflictCheck()
    }

    function runConflictCheck() {
      if (!queuedConflict) return
      checkingConflict = queuedConflict
      queuedConflict = ""
      conflictProc.command = ["sh", "-c", tool + " conflicts " + q(checkingConflict)]
      conflictProc.running = true
    }

    function startCapture() {
      capturing = true
      keyListing = false
      queuedConflict = ""
      checkingConflict = ""
      note = "Press the shortcut now. Escape cancels."
      captureArea.forceActiveFocus()
    }

    function stopCapture() {
      capturing = false
      shortcutButton.forceActiveFocus()
    }

    function startManualEntry() {
      capturing = false
      keyListing = true

      var parts = String(draft.key).split(" + ").filter(function (part) {
        return String(part).trim() !== ""
      })
      var finalPart = parts.length ? parts[parts.length - 1] : ""
      var key = isModifier(finalPart) ? "" : finalPart
      manualModifiers = parts.filter(function (part) { return qa.isModifier(part) })
      if (manualModifiers.indexOf("HYPER") >= 0)
        manualModifiers = ["CTRL", "ALT", "SHIFT", "SUPER"]
      manualKeyField.text = key
      note = "Choose modifiers, then type the key."
      Qt.callLater(function () { manualKeyField.focusInput() })
    }

    function updateManualShortcut() {
      var parts = manualModifiers.slice()
      var key = String(manualKeyField.text).trim()
      if (key) parts.push(key)
      setShortcut(parts.join(" + "))
      note = ""
      queueConflictCheck(draft.key)
    }

    function toggleManualModifier(modifier) {
      var all = ["CTRL", "ALT", "SHIFT", "SUPER"]
      var mods = manualModifiers.slice()
      if (modifier === "HYPER") {
        var allSelected = all.every(function (item) { return mods.indexOf(item) >= 0 })
        mods = allSelected ? [] : all
      } else if (mods.indexOf(modifier) >= 0) {
        mods = mods.filter(function (item) { return item !== modifier })
      } else {
        mods.push(modifier)
      }
      manualModifiers = mods
      updateManualShortcut()
    }

    function manualModifierSelected(modifier) {
      if (modifier !== "HYPER") return manualModifiers.indexOf(modifier) >= 0
      return ["CTRL", "ALT", "SHIFT", "SUPER"].every(function (item) {
        return qa.manualModifiers.indexOf(item) >= 0
      })
    }

    readonly property var keyNames: ({
      44: "comma", 46: "period", 47: "slash", 59: "semicolon", 39: "apostrophe",
      45: "minus", 61: "equal", 91: "bracketleft", 93: "bracketright", 92: "backslash",
      96: "grave", 60: "less", 62: "greater", 63: "question", 32: "space"
    })

    function keyNameFor(event) {
      var k = event.key
      if (k >= 0x41 && k <= 0x5a) return String.fromCharCode(k)
      if (k >= 0x30 && k <= 0x39) return String.fromCharCode(k)
      if (k >= 0x01000030 && k <= 0x0100003b) return "F" + (k - 0x01000030 + 1)
      if (keyNames[k] !== undefined) return keyNames[k]
      if (event.text && event.text.length === 1 && event.text.charCodeAt(0) > 32) return event.text
      return ""
    }

    function chordFor(event) {
      var key = keyNameFor(event)
      if (!key) return ""
      var all = (event.modifiers & Qt.MetaModifier) && (event.modifiers & Qt.ShiftModifier)
             && (event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.AltModifier)
      if (all) return "CTRL + ALT + SHIFT + SUPER + " + key
      var mods = []
      if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
      if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
      if (event.modifiers & Qt.AltModifier) mods.push("ALT")
      if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")
      return mods.concat([key]).join(" + ")
    }

    Item {
      id: captureArea
      width: 0; height: 0
      Keys.onPressed: function (event) {
        event.accepted = true
        if (!qa.capturing) return
        if (event.key === Qt.Key_Escape) {
          qa.stopCapture()
          qa.note = "Shortcut capture canceled."
          return
        }
        if (event.key === Qt.Key_Shift || event.key === Qt.Key_Control
            || event.key === Qt.Key_Alt || event.key === Qt.Key_Meta) return
        var chord = qa.chordFor(event)
        if (!chord) return
        qa.setShortcut(chord)
        qa.stopCapture()
        qa.queueConflictCheck(chord)
      }
    }

    Process {
      id: listProc
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          try { qa.model = JSON.parse(text) } catch (e) { qa.note = "Could not read the app list." }
        }
      }
    }

    Process {
      id: appsProc
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          try {
            var found = JSON.parse(text)
            if (!Array.isArray(found)) throw new Error("not a list")
            qa.apps = found
            qa.appsError = found.length ? "" : "No installed apps were found."
          } catch (e) {
            qa.apps = []
            qa.appsError = "Could not load installed apps."
          }
        }
      }
      onExited: function (exitCode) {
        qa.appsLoading = false
        if (exitCode !== 0) qa.appsError = "Could not load installed apps."
      }
    }

    Process {
      id: runProc
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var out = String(text).trim()
          if (out) qa.note = out.replace(/^quick-app:\s*/, "")
          else qa.reset()
          qa.busy = false
          qa.load()
        }
      }
      onRunningChanged: if (!running) qa.busy = false
    }

    Process {
      id: conflictProc
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          if (qa.checkingConflict !== qa.draft.key) return
          try {
            var c = JSON.parse(text)
            qa.note = c.conflict
              ? c.label + " is currently " + c.conflict + ". Take it and it comes back if you free it."
              : ""
          } catch (e) { qa.note = "" }
        }
      }
      onExited: function () {
        qa.checkingConflict = ""
        qa.runConflictCheck()
      }
    }

    // ---- one card per app -------------------------------------------------------------------------

    Repeater {
      model: qa.model.apps || []

      delegate: Rectangle {
        width: qa.width
        height: rowBody.implicitHeight + Style.space(20)
        radius: Style.space(8)
        color: "transparent"
        border.width: 1
        border.color: qa.line

        Column {
          id: rowBody
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(14)
          spacing: Style.space(8)

          Item {
            width: parent.width
            height: Style.space(40)

            Rectangle {
              id: appIcon
              width: Style.space(38); height: width
              radius: Style.space(8)
              color: Qt.rgba(qa.foreground.r, qa.foreground.g, qa.foreground.b, 0.06)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              clip: true

              Image {
                anchors.fill: parent
                anchors.margins: Style.space(4)
                source: modelData.icon ? "file://" + encodeURI(modelData.icon) : ""
                fillMode: Image.PreserveAspectFit
                smooth: true
                asynchronous: true
                visible: status === Image.Ready
              }

              Text {
                anchors.centerIn: parent
                visible: !modelData.icon
                text: String(modelData.label).charAt(0).toUpperCase()
                color: qa.muted
                font.family: qa.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            Text {
              anchors.left: appIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: keyPill.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.label
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: qa.foreground
              font.family: qa.fontFamily
              font.pixelSize: Style.font.body
            }

            Rectangle {
              id: keyPill
              anchors.right: rowMenu.left
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(190)
              height: Style.space(30)
              radius: height / 2
              color: "transparent"
              border.width: 1
              border.color: Qt.rgba(qa.accent.r, qa.accent.g, qa.accent.b, 0.55)

              Text {
                anchors.centerIn: parent
                text: String(modelData.key_label).toUpperCase()
                textFormat: Text.PlainText
                color: qa.accent
                font.family: qa.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { qa.editRow(modelData); qa.startCapture() }
              }
            }

            Text {
              id: rowMenu
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "···"
              color: qa.openMenu === modelData.name ? qa.accent : qa.muted
              font.family: qa.fontFamily
              font.pixelSize: Style.font.body
              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                cursorShape: Qt.PointingHandCursor
                onClicked: qa.openMenu = (qa.openMenu === modelData.name ? "" : modelData.name)
              }
            }
          }

          Row {
            visible: qa.openMenu === modelData.name
            width: parent.width
            spacing: Style.space(16)

            Text {
              text: "change shortcut"
              color: qa.foreground
              font.family: qa.fontFamily
              font.pixelSize: Style.font.caption
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { qa.editRow(modelData); qa.startCapture() }
              }
            }

            Text {
              text: "remove"
              color: qa.foreground
              font.family: qa.fontFamily
              font.pixelSize: Style.font.caption
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: qa.remove(modelData.name)
              }
            }

            Text {
              width: parent.width - Style.space(200)
              visible: !!modelData.displaced
              text: modelData.key_label + " was " + modelData.displaced
                  + " — it comes back if you free the key."
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: qa.muted
              font.family: qa.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    // ---- add a new app ----------------------------------------------------------------------------

    Rectangle {
      width: qa.width
      height: addBody.implicitHeight + Style.space(28)
      radius: Style.space(8)
      color: "transparent"
      border.width: 1
      border.color: qa.line

      Column {
        id: addBody
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: Style.space(14)
        anchors.leftMargin: Style.space(14)
        anchors.rightMargin: Style.space(14)
        spacing: Style.space(12)
        Accessible.role: Accessible.Form
        Accessible.name: qa.editing ? "Change app shortcut" : "Add a new quick app"

        Row {
          width: parent.width
          spacing: Style.space(12)

          Rectangle {
            width: Style.space(30); height: width
            radius: Style.space(7)
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(qa.accent.r, qa.accent.g, qa.accent.b, 0.6)
            Text {
              anchors.centerIn: parent
              text: "+"
              color: qa.accent
              font.family: qa.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: qa.editing ? "Change " + qa.draft.label + "’s shortcut" : "Add a new app"
            textFormat: Text.PlainText
            color: qa.foreground
            font.family: qa.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(14)

          Text {
            id: appLabel
            width: Style.space(70)
            anchors.verticalCenter: parent.verticalCenter
            text: "App"
            textFormat: Text.PlainText
            color: qa.muted
            font.family: qa.fontFamily
            font.pixelSize: Style.font.caption
            Accessible.labelFor: appPicker
          }

          SearchableDropdown {
            id: appPicker
            width: parent.width - Style.space(70) - parent.spacing
            height: Style.space(34)
            showLabel: false
            enabled: !qa.editing && !qa.appsLoading && qa.appsError === ""
            opacity: enabled ? 1 : 0.65
            value: qa.chosen ? qa.draft.launch : ""
            options: qa.appOptions
            triggerLabel: qa.appsLoading ? "Loading installed apps…" : "Choose an app…"
            placeholderText: "Search installed apps…"
            emptyText: qa.appsError !== "" ? qa.appsError : "No matching apps"
            foreground: qa.foreground
            accent: qa.accent
            fontFamily: qa.fontFamily
            Accessible.role: Accessible.ComboBox
            Accessible.name: "Installed app"
            Accessible.description: "Choose one installed app. Type to filter the list."
            onChanged: function (launch) { qa.chooseLaunch(launch) }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(14)

          Text {
            id: shortcutLabel
            width: Style.space(70)
            anchors.verticalCenter: parent.verticalCenter
            text: "Shortcut"
            textFormat: Text.PlainText
            color: qa.muted
            font.family: qa.fontFamily
            font.pixelSize: Style.font.caption
            Accessible.labelFor: shortcutButton
          }

          Button {
            id: shortcutButton
            width: Style.space(230)
            height: Style.space(34)
            text: qa.capturing ? "press it now…" : (qa.draft.key ? qa.draft.key : "Press shortcut…")
            iconText: "󰌌"
            bordered: true
            selected: qa.capturing
            focusable: true
            foreground: qa.draft.key && !qa.capturing ? qa.foreground : qa.muted
            background: root.bar ? root.bar.background : Color.background
            accent: qa.accent
            fontFamily: qa.fontFamily
            fontSize: Style.font.caption
            iconSize: Style.font.iconSmall
            Accessible.role: Accessible.HotkeyField
            Accessible.name: "Shortcut"
            Accessible.description: "Press to capture the shortcut that opens or hides this app."
            onClicked: qa.startCapture()
          }

          Button {
            id: manualButton
            text: qa.keyListing ? "Record instead" : "Enter manually"
            tooltipText: qa.keyListing ? "Press the shortcut instead."
                                       : "Use this when pressing the shortcut opens something else."
            bordered: true
            focusable: true
            foreground: qa.muted
            background: root.bar ? root.bar.background : Color.background
            accent: qa.accent
            fontFamily: qa.fontFamily
            fontSize: Style.font.caption
            Accessible.role: Accessible.Button
            Accessible.name: text
            Accessible.description: qa.keyListing
              ? "Capture a shortcut by pressing it."
              : "Use this when pressing the shortcut opens something else."
            onClicked: qa.keyListing ? qa.startCapture() : qa.startManualEntry()
          }

          Item {
            width: Math.max(0, parent.width - shortcutLabel.width - shortcutButton.width
                            - manualButton.width - cancelButton.width - saveButton.width
                            - parent.spacing * 4)
            height: 1
          }

          Button {
            id: cancelButton
            text: "Cancel"
            bordered: true
            focusable: true
            foreground: qa.muted
            background: root.bar ? root.bar.background : Color.background
            accent: qa.accent
            fontFamily: qa.fontFamily
            fontSize: Style.font.body
            Accessible.role: Accessible.Button
            Accessible.name: "Cancel adding app"
            onClicked: qa.reset()
          }

          Button {
            id: saveButton
            text: qa.busy ? "Saving…" : "Save app"
            selected: true
            focusable: true
            enabled: qa.chosen && qa.shortcutComplete && !qa.busy
            foreground: qa.foreground
            background: root.bar ? root.bar.background : Color.background
            accent: qa.accent
            fontFamily: qa.fontFamily
            fontSize: Style.font.body
            Accessible.role: Accessible.Button
            Accessible.name: qa.busy ? "Saving app" : "Save app"
            onClicked: qa.save()
          }
        }

        // Manual entry is explicit because Hyprland may intercept an existing shortcut before the
        // panel can capture it. Silence alone is never treated as proof of a conflict.
        Row {
          visible: qa.keyListing
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: ["SUPER", "CTRL", "ALT", "SHIFT", "HYPER"]
            delegate: Button {
              text: modelData
              bordered: true
              selected: qa.manualModifierSelected(modelData)
              focusable: true
              foreground: qa.foreground
              background: root.bar ? root.bar.background : Color.background
              accent: qa.accent
              fontFamily: qa.fontFamily
              fontSize: Style.font.caption
              Accessible.role: Accessible.Button
              Accessible.name: modelData + " modifier"
              Accessible.description: selected ? "Selected. Press to remove." : "Press to add."
              onClicked: qa.toggleManualModifier(modelData)
            }
          }

          QuickField {
            id: manualKeyField
            width: Style.space(110)
            placeholder: "e.g. W"
            accessibleName: "Shortcut key"
            accessibleDescription: "Type the final key after choosing any modifiers."
            onTextChanged: if (qa.keyListing) qa.updateManualShortcut()
          }
        }

        Text {
          visible: qa.note !== "" || qa.formHelp !== ""
          width: parent.width
          text: qa.note !== "" ? qa.note : qa.formHelp
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: qa.note !== "" || qa.appsError !== "" ? qa.accent : qa.foreground
          opacity: qa.note !== "" || qa.appsError !== "" ? 1 : 0.7
          font.family: qa.fontFamily
          font.pixelSize: Style.font.caption
          Accessible.role: qa.note !== "" || qa.appsError !== ""
            ? Accessible.AlertMessage : Accessible.StaticText
          Accessible.name: text
        }
      }
    }

    // ---- the footer -------------------------------------------------------------------------------

    Item {
      width: qa.width
      height: Style.space(34)

      Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "󰌌"
          color: qa.muted
          font.family: qa.fontFamily
          font.pixelSize: Style.font.iconSmall
        }

        Rectangle {
          width: keyCapText.implicitWidth + Style.space(16)
          height: Style.space(24)
          radius: Style.space(5)
          color: "transparent"
          border.width: 1
          border.color: qa.line
          anchors.verticalCenter: parent.verticalCenter
          Text {
            id: keyCapText
            anchors.centerIn: parent
            text: "SUPER"
            color: qa.foreground
            font.family: qa.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "+"
          color: qa.muted
          font.family: qa.fontFamily
          font.pixelSize: Style.font.caption
        }

        Rectangle {
          width: Style.space(30)
          height: Style.space(24)
          radius: Style.space(5)
          color: "transparent"
          border.width: 1
          border.color: qa.line
          anchors.verticalCenter: parent.verticalCenter
          Text {
            anchors.centerIn: parent
            text: "W"
            color: qa.foreground
            font.family: qa.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: qa.model.hide_on_close ? "Hides these apps instead of closing them"
                                      : "Closes these apps — click to hide them instead"
          textFormat: Text.PlainText
          color: qa.muted
          font.family: qa.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: qa.run(["option", "hide_on_close", qa.model.hide_on_close ? "false" : "true"])
      }
    }
  }

  component PickRow: Item {
    property string label: ""
    property string sub: ""
    property string klass: ""
    property string title: ""
    width: parent.width
    height: Style.space(34)

    Rectangle {
      width: parent.width
      height: Style.space(30)
      y: Style.space(2)
      radius: Style.cornerRadius
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                     rowArea.containsMouse ? 0.10 : 0.04)

      Text {
        id: rowPlus
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: "+"
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        color: root.foreground
        opacity: rowArea.containsMouse ? 0.85 : 0.4
      }

      Text {
        id: rowLabel
        anchors.left: rowPlus.right
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: label
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        color: root.foreground
      }

      Text {
        anchors.left: rowLabel.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: sub
        textFormat: Text.PlainText
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.foreground
        opacity: 0.45
      }
    }

    MouseArea {
      id: rowArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.pickApp(klass, title, label)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(780))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.tab === 1 && !activeFocus
      // Escape backs out of a pick or a placement first; with nothing pending it closes.
      // Everything is saved as it happens, so there is nothing to cancel.
      onCloseRequested: {
        if (root.adding) root.cancelAdding()
        else if (root.picking) root.picking = false
        else root.close()
      }
      onTabRequested: {
        root.tab = 1
        root.quickAppsLoad()
        Qt.callLater(function () { quickApps.openAppPicker() })
      }
      onActivateRequested: root.close()
      // h/l (dx) walk the desks.
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.stepDesk(dx) }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(6)

        // The hero: icon, title, a pun — Barbarian's heading layout — with the desk
        // actions riding its trailing edge.
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, headerActions.height)

          Text {
            id: heroIcon
            text: root.iconHero
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Reptile"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.mottos[root.motto % root.mottos.length].toUpperCase()
              textFormat: Text.PlainText
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PanelActionButton {
              iconText: root.iconSave
              tooltipText: "Record " + root.deskName + " as it is now (HYPER+S there)"
              foreground: root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.iconSmall
              onClicked: root.saveNow()
            }

            PanelActionButton {
              iconText: root.iconRestore
              tooltipText: "Go to " + root.deskName + " and put it back now (HYPER+R there)"
              foreground: root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.iconSmall
              onClicked: root.applyNow()
            }

            PanelActionButton {
              iconText: root.iconX
              tooltipText: "Close"
              foreground: root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.iconSmall
              onClicked: root.close()
            }
          }
        }

        Item { width: 1; height: Style.space(8) }

        // Two tabs: the desks, and the quick apps. Nothing else in the panel changes between
        // them — the hero and its actions belong to the desks, and stay put.
        Row {
          id: tabStrip
          width: parent.width
          spacing: Style.space(6)

          readonly property real chipWidth: (width - spacing) / 2

          Repeater {
            model: ["Desks", "Quick apps"]

            delegate: Rectangle {
              width: tabStrip.chipWidth
              height: tabLabel.implicitHeight + Style.space(14)
              radius: Style.space(4)
              color: root.tab === index ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.15)
                                        : "transparent"
              border.width: 1
              border.color: root.tab === index ? root.accent : Qt.darker(root.foreground, 1.8)

              Row {
                anchors.centerIn: parent
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  // Material Design glyphs, from the same block as the panel's own snake — the
                  // Font Awesome pair tried first drew nothing at all (seen on screen 2026-09-06).
                  text: index === 0 ? "󰕰" : "󱓞"
                  color: root.tab === index ? root.accent : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.iconSmall
                }

                Text {
                  id: tabLabel
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData
                  textFormat: Text.PlainText
                  color: root.tab === index ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: root.tab === index
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.tab = index; if (index === 1) root.quickAppsLoad() }
              }
            }
          }
        }

        Item { width: 1; height: Style.space(8) }

        // ⚠️ Everything from here to the close of this Column is the DESKS tab. It was wrapped
        // rather than moved into a file of its own: the board reads a dozen properties off the
        // panel root, and a move would have turned a tab into a rewrite.
        Column {
          id: desksTab
          width: parent.width
          spacing: Style.space(6)
          visible: root.tab === 0

          // The desks, one chip each. Selected = the desk drawn below; a dot marks the desk
          // on screen; accent lettering marks a desk edited here and not yet put back.
          Row {
            id: deskRow
            width: parent.width
            spacing: Style.space(6)

            readonly property int n: Math.max(1, (root.model.desks || []).length)
            readonly property real chipWidth: (width - spacing * (n - 1)) / n

            Repeater {
              model: root.model.desks || []

              delegate: Button {
                required property var modelData
                width: deskRow.chipWidth
                text: modelData.name + (modelData.ws === root.model.active ? " •" : "")
                bordered: true
                selected: modelData.ws === root.desk
                foreground: root.isDirty(modelData.ws) ? root.accent : root.foreground
                background: bar ? bar.background : Color.background
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                opacity: modelData.recorded || modelData.ws === root.desk ? 1 : 0.55
                onClicked: root.selectDesk(modelData.ws)
              }
            }
          }

          Item { width: 1; height: Style.space(8) }

          PanelSeparator { width: parent.width; foreground: root.accent; strength: 0.18 }

          Item {
            width: parent.width
            height: root.loadError !== "" ? errText.implicitHeight + Style.space(6) : 0
            visible: root.loadError !== ""

            Text {
              id: errText
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              text: root.loadError
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: bar ? bar.urgent : Color.urgent
            }
          }

          Item { width: 1; height: Style.space(6) }

          // THE BOARD: the desk's recording as blocks, in the screen's own proportions and with
          // the desk's own gaps — each block sits in its cell exactly where Hyprland would put
          // the window, as ws-layout measured it, so the margins here are the desk's at scale.
          Item {
            id: board
            visible: !root.picking
            width: parent.width
            height: Math.round(width * root.model.screen[1] / Math.max(1, root.model.screen[0]))

            // One of the screen's pixels, on the board.
            readonly property real px: width / Math.max(1, root.model.screen[0])
            // A split handle stops this short of its cell's ends — decoration, not geometry.
            readonly property int lineInset: Style.space(6)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
              border.width: 1
              border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
            }

            // Nothing recorded: say so, in the middle of the empty board.
            Text {
              anchors.centerIn: parent
              visible: root.wins.length === 0
              width: parent.width - Style.space(40)
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              text: root.cur && root.cur.recorded
                ? "Recorded as empty — going there closes every window.\nPress + to add one."
                : "No recording yet.\nPress + to build one here, or HYPER+S on the desk itself."
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: root.muted
            }

            // One block per recorded window.
            Repeater {
              model: root.wins

              delegate: Item {
                id: cell
                required property var modelData
                required property int index

                x: Math.round(modelData.x * board.width)
                y: Math.round(modelData.y * board.height)
                width: Math.round(modelData.w * board.width)
                height: Math.round(modelData.h * board.height)
                z: dragArea.drag.active ? 10 : 1

                readonly property bool anchorHere: root.adding !== null && root.addAnchor === cell.index

                // The block inside the cell: the window as Hyprland places it, gaps and all.
                readonly property int blockX: Math.round(modelData.block[0] * board.width) - cell.x
                readonly property int blockY: Math.round(modelData.block[1] * board.height) - cell.y
                readonly property int blockW: Math.round(modelData.block[2] * board.width)
                readonly property int blockH: Math.round(modelData.block[3] * board.height)

                Rectangle {
                  id: card
                  x: cell.blockX
                  y: cell.blockY
                  width: cell.blockW
                  height: cell.blockH
                  // The desk's own rounding at the board's scale — full-size corners on blocks
                  // this small would eat into the gaps they are meant to show.
                  radius: Math.round(root.model.rounding * board.px)
                  color: dragArea.drag.active
                    ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
                    : dragArea.containsMouse
                      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
                      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                  border.width: cell.anchorHere ? 2 : 0
                  border.color: root.accent

                  Behavior on color { ColorAnimation { duration: 80 } }

                  Column {
                    anchors.centerIn: parent
                    width: parent.width - Style.space(16)
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      text: cell.modelData.label
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      color: root.foreground
                      // Faded = recorded here but not open on the desk right now.
                      opacity: cell.modelData.open ? 1 : 0.4
                    }

                    Text {
                      width: parent.width
                      visible: cell.modelData.title !== "" && card.height > Style.space(56)
                      horizontalAlignment: Text.AlignHCenter
                      text: cell.modelData.title
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.foreground
                      opacity: cell.modelData.open ? 0.5 : 0.25
                    }

                    Text {
                      width: parent.width
                      visible: !cell.modelData.open
                      horizontalAlignment: Text.AlignHCenter
                      text: cell.modelData.launchable ? "not open — opens on restore" : "not open, and cannot be opened from here"
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.muted
                    }

                    // Placing a new window: which side of this block it goes on.
                    Row {
                      visible: cell.anchorHere
                      anchors.horizontalCenter: parent.horizontalCenter
                      spacing: Style.space(6)
                      topPadding: Style.space(4)

                      Button {
                        text: "→ right"
                        bordered: true
                        foreground: root.foreground
                        background: bar ? bar.background : Color.background
                        accent: root.accent
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        onClicked: root.placeAdding("r")
                      }
                      Button {
                        text: "↓ below"
                        bordered: true
                        foreground: root.foreground
                        background: bar ? bar.background : Color.background
                        accent: root.accent
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        onClicked: root.placeAdding("d")
                      }
                    }
                  }

                  // × in the corner takes the window out of the recording (it stays open
                  // until the desk is next put back). Clicked through the drag area's hit
                  // test below, as Barbarian's eye is.
                  Text {
                    id: cross
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(6)
                    text: root.iconX
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    opacity: dragArea.containsMouse ? 0.7 : 0.3
                  }
                }

                MouseArea {
                  id: dragArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: root.adding ? Qt.PointingHandCursor
                    : drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                  drag.target: root.adding ? null : card
                  drag.axis: Drag.XAndYAxis

                  onClicked: function(mouse) {
                    if (root.adding) { root.addAnchor = cell.index; return }
                    var p = dragArea.mapToItem(cross, mouse.x, mouse.y)
                    if (p.x > -Style.space(8) && p.x < cross.width + Style.space(8)
                        && p.y > -Style.space(8) && p.y < cross.height + Style.space(8))
                      root.removeAt(cell.index)
                  }
                  onReleased: {
                    // Dropped on another block? Swap the two. Either way the card snaps home;
                    // the redraw after the edit puts everything where the recording says.
                    var c = card.mapToItem(board, card.width / 2, card.height / 2)
                    var ws = root.wins
                    for (var j = 0; j < ws.length; j++) {
                      if (j === cell.index) continue
                      var w = ws[j]
                      if (c.x >= w.x * board.width && c.x <= (w.x + w.w) * board.width
                          && c.y >= w.y * board.height && c.y <= (w.y + w.h) * board.height) {
                        root.swapWith(cell.index, j)
                        break
                      }
                    }
                    card.x = cell.blockX; card.y = cell.blockY
                  }
                  onCanceled: { card.x = cell.blockX; card.y = cell.blockY }
                }
              }
            }

            // One handle per split: the gap between the two sides, dragged along its axis
            // within the cell it divides. Releasing writes the new share. Nothing is drawn at
            // rest (Dave, 2026-09-12: the gap itself shows the split); a line appears only while
            // the handle is being dragged, so the drag has something to follow.
            Repeater {
              model: root.splits

              delegate: Item {
                id: line
                required property var modelData

                readonly property bool vertical: modelData.axis === "v"
                readonly property int grab: Style.space(10)
                readonly property real cellX: modelData.cx * board.width
                readonly property real cellY: modelData.cy * board.height
                readonly property real cellW: modelData.cw * board.width
                readonly property real cellH: modelData.ch * board.height

                x: vertical ? Math.round(modelData.pos * board.width) - grab / 2 : Math.round(cellX)
                y: vertical ? Math.round(cellY) : Math.round(modelData.pos * board.height) - grab / 2
                width: vertical ? grab : Math.round(cellW)
                height: vertical ? Math.round(cellH) : grab
                z: 5

                Item {
                  id: handle
                  width: line.width
                  height: line.height

                  Rectangle {
                    anchors.centerIn: parent
                    width: line.vertical ? 2 : parent.width - board.lineInset * 2
                    height: line.vertical ? parent.height - board.lineInset * 2 : 2
                    radius: 1
                    color: root.accent
                    visible: lineArea.drag.active
                    opacity: 0.9
                  }

                  MouseArea {
                    id: lineArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: line.vertical ? Qt.SizeHorCursor : Qt.SizeVerCursor
                    drag.target: handle
                    drag.axis: line.vertical ? Drag.XAxis : Drag.YAxis
                    // A side keeps at least a tenth of the cell, as ws-layout clamps it.
                    drag.minimumX: line.vertical ? (line.cellX + line.cellW * 0.1) - line.x : 0
                    drag.maximumX: line.vertical ? (line.cellX + line.cellW * 0.9) - line.x : 0
                    drag.minimumY: line.vertical ? 0 : (line.cellY + line.cellH * 0.1) - line.y
                    drag.maximumY: line.vertical ? 0 : (line.cellY + line.cellH * 0.9) - line.y
                    onReleased: {
                      var share = line.vertical
                        ? ((line.x + handle.x + line.grab / 2) - line.cellX) / line.cellW
                        : ((line.y + handle.y + line.grab / 2) - line.cellY) / line.cellH
                      handle.x = 0; handle.y = 0
                      root.setShare(line.modelData.i, share)
                    }
                    onCanceled: { handle.x = 0; handle.y = 0 }
                  }
                }
              }
            }
          }

          // THE ADD PICKER, in the board's place: what is open on the desk but not recorded,
          // then every app a recording can name. A click picks and hands back to the board.
          Column {
            visible: root.picking
            width: parent.width
            spacing: 0

            Item {
              width: parent.width
              height: pickHead.implicitHeight

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "‹ back"
                textFormat: Text.PlainText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.muted
                opacity: backArea.containsMouse ? 1 : 0.6

                MouseArea {
                  id: backArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.picking = false
                }
              }

              Text {
                id: pickHead
                width: parent.width
                text: "ADD TO " + root.deskName.toUpperCase()
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
                topPadding: 0
                bottomPadding: Style.space(8)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                color: root.muted
              }
            }

            Rectangle {
              width: parent.width
              height: 1
              color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
            }

            Item { width: 1; height: Style.space(6) }

            Text {
              visible: root.extra.length > 0
              width: parent.width
              text: "OPEN ON THIS DESK, NOT RECORDED"
              textFormat: Text.PlainText
              topPadding: Style.space(4)
              bottomPadding: Style.space(4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.muted
            }

            Repeater {
              model: root.extra
              delegate: PickRow {
                required property var modelData
                label: modelData.label
                sub: modelData.title
                klass: modelData["class"]
                title: modelData.title
              }
            }

            Text {
              width: parent.width
              text: "APPS REPTILE CAN OPEN"
              textFormat: Text.PlainText
              topPadding: Style.space(8)
              bottomPadding: Style.space(4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.muted
            }

            Repeater {
              model: root.model.apps || []
              delegate: PickRow {
                required property var modelData
                label: modelData.label
                sub: ""
                klass: modelData["class"]
                title: ""
              }
            }
          }

          Item { width: 1; height: Style.space(6) }

          // Under the board: the + chip, and what the panel is waiting for, if anything.
          Row {
            visible: !root.picking
            width: parent.width
            spacing: Style.space(10)

            Button {
              text: root.adding ? "× cancel adding" : "+ add a window"
              bordered: true
              foreground: root.foreground
              background: bar ? bar.background : Color.background
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              onClicked: { if (root.adding) root.cancelAdding(); else root.picking = true }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - parent.children[0].width - parent.spacing
              text: root.adding
                ? "Adding " + root.adding.label + ": click the window it should sit beside, then pick a side."
                : root.isDirty(root.desk)
                  ? "Changed here — put back the next time you go to " + root.deskName + ", or now with the arrow."
                  : ""
              textFormat: Text.PlainText
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.adding ? root.accent : root.muted
            }
          }

          Text {
            visible: !root.picking
            width: parent.width
            topPadding: Style.space(8)
            horizontalAlignment: Text.AlignHCenter
            text: "drag onto another to swap  ·  drag the gap to resize  ·  × removes  ·  saved as you go  ·  h/l walk the desks"
            textFormat: Text.PlainText
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.muted
          }
        }

        QuickAppsTab {
          id: quickApps
          width: parent.width
          visible: root.tab === 1
        }

      }
    }
  }
}
