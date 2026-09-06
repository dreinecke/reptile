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

  // What `ws-layout desks` said last: the desks, each with its recording drawn in the unit
  // square, what is open there but unrecorded, and the apps a recording can name.
  property var model: ({ "active": 1, "aspect": 1.78, "desks": [], "apps": [] })
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

    property var model: ({ "apps": [], "hide_on_close": true, "reserved": "SUPER + W" })
    property string note: ""
    property bool busy: false

    // Editing state. `draft` is the row being added or changed; null when the list is just a list.
    property var draft: null
    property bool capturing: false
    property bool keyListing: false
    property var windows: []
    property bool pickingWindow: false
    property var apps: []
    property bool pickingApp: false
    property string filter: ""

    // ⚠️ A LIST OF EVERY APP ON THE MACHINE IS A HUNDRED ROWS. Drawn as a plain column it ran off
    //    the bottom of the panel with no scroll and no way to narrow it (Dave, 2026-09-06: "They go
    //    off the screen. It does not scroll. There is no search bar."). Both pickers are capped,
    //    scrollable and searchable now.
    readonly property var shownApps: {
      var f = filter.toLowerCase().trim()
      if (!f) return apps
      return apps.filter(function (a) { return a.label.toLowerCase().indexOf(f) >= 0 })
    }
    readonly property var shownWindows: {
      var f = filter.toLowerCase().trim()
      if (!f) return windows
      return windows.filter(function (w) {
        return (w.klass + " " + w.title).toLowerCase().indexOf(f) >= 0
      })
    }

    spacing: Style.space(6)

    function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    function load() {
      if (listProc.running) return
      listProc.command = ["sh", "-c", tool + " list"]
      listProc.running = true
    }

    function run(args) {
      if (busy) return
      busy = true
      var cmd = tool
      for (var i = 0; i < args.length; i++) cmd += " " + q(args[i])
      runProc.command = ["sh", "-c", cmd + " 2>&1"]
      runProc.running = true
    }

    function save() {
      if (!draft) return
      run(["set", JSON.stringify(draft)])
    }

    function remove(name) { run(["remove", name]) }

    // ⚠️ REPTILE DOES NOT MAKE APPS, IT GIVES THEM KEYS. Omarchy already installs a web app
    //    properly — its menu, Install → Web app — with a launcher and an icon, in the app menu and
    //    in search. Asking for a name and an address here as well was the same job done worse, and
    //    Dave said so (2026-09-06). Everything with a launcher is offered instead.
    function pickApps() {
      pickingApp = !pickingApp
      pickingWindow = false
      filter = ""
      appSearch.text = ""
      if (!pickingApp) return
      note = ""
      appSearch.forceActiveFocus()
      appsProc.command = ["sh", "-c", tool + " apps"]
      appsProc.running = true
    }

    function draftFrom(app) {
      pickingApp = false
      pickingWindow = false
      draft = { "name": app.name || "", "label": app.label, "key": "",
                "match": app.match, "launch": app.launch }
      capturing = false; keyListing = false
      note = "Now give " + app.label + " a key."
    }

    function editRow(app) {
      draft = { "name": app.name, "label": app.label, "key": app.key, "match": app.match,
                "launch": app.launch }
      capturing = false; keyListing = false; note = ""
    }

    function shapeDraft() {
      if (!draft) return
      if (!draft.name) {
        draft.name = String(draft.label).toLowerCase().replace(/[^a-z0-9]+/g, "-")
          .replace(/^-+|-+$/g, "")
      }
      draft = draft   // QML: reassign so the bindings see it
    }

    // ---- taking a key -----------------------------------------------------------------------------

    function startCapture() {
      capturing = true
      keyListing = false
      note = "Press the key you want."
      captureArea.forceActiveFocus()
      captureTimer.restart()
    }

    function stopCapture(fellThrough) {
      capturing = false
      captureTimer.stop()
      keyCatcher.forceActiveFocus()
      if (fellThrough) {
        keyListing = true
        note = "Nothing arrived, which means that key already does something — Hyprland took it "
             + "before this window saw it. Build it below to take it anyway."
      }
    }

    // Qt reports the key the layout actually produces, so shift+comma arrives as Less. Both names
    // are carried through to Hyprland as-is rather than guessed at.
    readonly property var keyNames: ({
      44: "comma", 46: "period", 47: "slash", 59: "semicolon", 39: "apostrophe",
      45: "minus", 61: "equal", 91: "bracketleft", 93: "bracketright", 92: "backslash",
      96: "grave", 60: "less", 62: "greater", 63: "question", 32: "space"
    })

    function keyNameFor(event) {
      var k = event.key
      if (k >= 0x41 && k <= 0x5a) return String.fromCharCode(k)                 // A–Z
      if (k >= 0x30 && k <= 0x39) return String.fromCharCode(k)                 // 0–9
      if (k >= 0x01000030 && k <= 0x0100003b) return "F" + (k - 0x01000030 + 1) // F1–F12
      if (keyNames[k] !== undefined) return keyNames[k]
      if (event.text && event.text.length === 1 && event.text.charCodeAt(0) > 32) return event.text
      return ""
    }

    function chordFor(event) {
      var key = keyNameFor(event)
      if (!key) return ""
      var mods = []
      // Caps Lock is a Hyper modifier here (keyd), so all four at once reads as one key.
      var all = (event.modifiers & Qt.MetaModifier) && (event.modifiers & Qt.ShiftModifier)
             && (event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.AltModifier)
      if (all) return "CTRL + ALT + SHIFT + SUPER + " + key
      if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
      if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
      if (event.modifiers & Qt.AltModifier) mods.push("ALT")
      if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")
      return mods.concat([key]).join(" + ")
    }

    Timer {
      id: captureTimer
      interval: 2000
      onTriggered: qa.stopCapture(true)
    }

    Item {
      id: captureArea
      width: 0; height: 0
      Keys.onPressed: function (event) {
        event.accepted = true
        if (!qa.capturing) return
        if (event.key === Qt.Key_Escape) { qa.stopCapture(false); qa.note = ""; return }
        // A modifier on its own is half a chord; keep waiting for the key it belongs to.
        if (event.key === Qt.Key_Shift || event.key === Qt.Key_Control
            || event.key === Qt.Key_Alt || event.key === Qt.Key_Meta) { captureTimer.restart(); return }
        var chord = qa.chordFor(event)
        if (!chord || !qa.draft) return
        qa.draft.key = chord
        qa.draft = qa.draft
        qa.stopCapture(false)
        conflictProc.command = ["sh", "-c", qa.tool + " conflicts " + qa.q(chord)]
        conflictProc.running = true
      }
    }

    // ---- talking to the tool ------------------------------------------------------------------------

    Process {
      id: listProc
      stdout: StdioCollector {
        onStreamFinished: {
          try { qa.model = JSON.parse(text) } catch (e) { qa.note = "Could not read the app list." }
        }
      }
    }

    Process {
      id: runProc
      stdout: StdioCollector {
        onStreamFinished: {
          var out = String(text).trim()
          // The tool prints nothing when it worked, and one sentence saying why when it did not.
          if (out) qa.note = out.replace(/^quick-app:\s*/, "")
          else { qa.note = ""; qa.draft = null }
          qa.busy = false
          qa.load()
        }
      }
      onRunningChanged: if (!running) qa.busy = false
    }

    Process {
      id: conflictProc
      stdout: StdioCollector {
        onStreamFinished: {
          try {
            var c = JSON.parse(text)
            qa.note = c.conflict
              ? c.label + " is currently " + c.conflict
                + ". Take it and it comes back if you free the key again."
              : ""
          } catch (e) { qa.note = "" }
        }
      }
    }

    Process {
      id: appsProc
      stdout: StdioCollector {
        onStreamFinished: {
          try { qa.apps = JSON.parse(text) } catch (e) { qa.apps = []; qa.note = "Could not read the app list." }
        }
      }
    }

    Process {
      id: windowsProc
      stdout: StdioCollector {
        onStreamFinished: {
          try {
            var seen = {}, out = []
            var all = JSON.parse(text)
            for (var i = 0; i < all.length; i++) {
              var k = all[i]["class"]
              if (!k || seen[k]) continue
              seen[k] = true
              out.push({ "klass": k, "title": all[i].title || "" })
            }
            qa.windows = out
          } catch (e) { qa.windows = [] }
        }
      }
    }

    // ---- the rows -------------------------------------------------------------------------------

    Repeater {
      model: qa.model.apps || []

      delegate: Column {
        width: qa.width
        spacing: Style.space(2)

        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: Math.round(parent.width * 0.28)
            text: modelData.label
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: qa.foreground
            font.family: qa.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Rectangle {
            width: Math.round(parent.width * 0.24)
            height: keyText.implicitHeight + Style.space(4)
            radius: Style.space(4)
            color: "transparent"
            border.width: 1
            border.color: Qt.darker(qa.foreground, 1.8)

            Text {
              id: keyText
              anchors.centerIn: parent
              text: modelData.key_label
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: qa.foreground
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
            width: parent.width - Math.round(parent.width * 0.52) - Style.space(70)
            text: modelData.launch.replace(/^omarchy-launch-webapp\s+https?:\/\//, "")
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: qa.muted
            font.family: qa.fontFamily
            font.pixelSize: Style.font.caption
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: qa.editRow(modelData)
            }
          }

          Text {
            text: modelData.fired ? (root.iconCheck) : ""
            color: qa.accent
            font.family: qa.fontFamily
            font.pixelSize: Style.font.iconSmall
          }

          Text {
            text: root.iconX
            color: qa.muted
            font.family: qa.fontFamily
            font.pixelSize: Style.font.iconSmall
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: qa.remove(modelData.name)
            }
          }
        }

        // What this key used to do, kept as a standing reminder of what was given up. It is read
        // from the list, not from Hyprland: once the key is taken the old binding is gone and
        // cannot be looked up any more.
        Text {
          visible: !!modelData.displaced
          width: parent.width
          text: "  ⚠ " + modelData.key_label + " was " + modelData.displaced
              + " — it comes back if you free the key."
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: qa.muted
          font.family: qa.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Item { width: 1; height: Style.space(6) }

    // ---- the draft ------------------------------------------------------------------------------

    Column {
      visible: !!qa.draft
      width: parent.width
      spacing: Style.space(6)

      // ⚠️ EVERY FIELD SETS ITS OWN WIDTH. QuickField has none of its own, and a field with no
      //    width is invisible while still taking up its height — the form looked empty on
      //    2026-09-06 (Dave: "cannot see where to enter or choose which web app").
      Text {
        width: parent.width
        topPadding: Style.space(6)
        text: qa.draft ? (qa.draft.key ? "Editing " + qa.draft.label
                                       : qa.draft.label + " — give it a key") : ""
        textFormat: Text.PlainText
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        width: parent.width
        text: "Name"
        textFormat: Text.PlainText
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      QuickField {
        id: labelField
        width: parent.width
        placeholder: "Claude"
        text: qa.draft ? qa.draft.label : ""
        onTextChanged: if (qa.draft) { qa.draft.label = text }
      }

      Text {
        width: parent.width
        text: "Command that opens it"
        textFormat: Text.PlainText
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      QuickField {
        id: commandField
        width: parent.width
        placeholder: "uwsm-app -- obsidian"
        text: qa.draft ? qa.draft.launch : ""
        onTextChanged: if (qa.draft) { qa.draft.launch = text }
      }

      Text {
        width: parent.width
        text: "Start of its window name (leave as it is unless two apps clash)"
        textFormat: Text.PlainText
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      QuickField {
        id: matchField
        width: parent.width
        placeholder: "obsidian"
        text: qa.draft ? qa.draft.match : ""
        onTextChanged: if (qa.draft) { qa.draft.match = text }
      }

      Text {
        width: parent.width
        text: "Key"
        textFormat: Text.PlainText
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        spacing: Style.space(10)

        Button {
          text: qa.draft && qa.draft.key ? "Key: " + qa.draft.key : "Press a key"
          bordered: true
          foreground: qa.foreground
          background: root.bar ? root.bar.background : Color.background
          accent: qa.accent
          fontFamily: qa.fontFamily
          fontSize: Style.font.body
          onClicked: qa.startCapture()
        }

        Button {
          text: "Save"
          bordered: true
          foreground: qa.foreground
          background: root.bar ? root.bar.background : Color.background
          accent: qa.accent
          fontFamily: qa.fontFamily
          fontSize: Style.font.body
          onClicked: { qa.shapeDraft(); qa.save() }
        }

        Button {
          text: "Cancel"
          bordered: true
          foreground: qa.muted
          background: root.bar ? root.bar.background : Color.background
          accent: qa.accent
          fontFamily: qa.fontFamily
          fontSize: Style.font.body
          onClicked: { qa.draft = null; qa.note = ""; qa.stopCapture(false) }
        }
      }

      // The fallback when a key was swallowed: build the chord by hand instead of pressing it.
      Row {
        visible: qa.keyListing
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: ["SUPER", "CTRL", "ALT", "SHIFT", "HYPER"]
          delegate: Button {
            text: modelData
            bordered: true
            foreground: qa.foreground
            background: root.bar ? root.bar.background : Color.background
            accent: qa.accent
            fontFamily: qa.fontFamily
            fontSize: Style.font.caption
            onClicked: {
              if (!qa.draft) return
              var parts = String(qa.draft.key).split(" + ").filter(function (p) { return p !== "" })
              var key = parts.length ? parts[parts.length - 1] : ""
              var mods = parts.slice(0, Math.max(0, parts.length - 1))
              if (modelData === "HYPER") mods = ["CTRL", "ALT", "SHIFT", "SUPER"]
              else if (mods.indexOf(modelData) >= 0) mods = mods.filter(function (m) { return m !== modelData })
              else mods.push(modelData)
              qa.draft.key = mods.concat([key]).join(" + ")
              qa.draft = qa.draft
            }
          }
        }

        QuickField {
          width: Style.space(120)
          placeholder: "key"
          text: {
            if (!qa.draft) return ""
            var parts = String(qa.draft.key).split(" + ")
            return parts.length ? parts[parts.length - 1] : ""
          }
          onTextChanged: {
            if (!qa.draft) return
            var parts = String(qa.draft.key).split(" + ")
            parts[Math.max(0, parts.length - 1)] = text
            qa.draft.key = parts.join(" + ")
            qa.draft = qa.draft
          }
        }
      }
    }

    // ---- picking an open window -----------------------------------------------------------------

    // Everything with a launcher: Omarchy's web apps and native apps alike. Nothing is typed twice —
    // the name, the command and the window it opens all come from the launcher.
    Column {
      visible: qa.pickingApp
      width: parent.width
      spacing: Style.space(6)

      QuickField {
        id: appSearch
        width: parent.width
        placeholder: "Search — type a few letters of the name"
        onTextChanged: qa.filter = text
      }

      Text {
        width: parent.width
        text: qa.shownApps.length + " of " + qa.apps.length + " apps"
              + "   ·   not here? install it once from the Omarchy menu (Install → Web app)"
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: qa.muted
        font.family: qa.fontFamily
        font.pixelSize: Style.font.caption
      }

      ListView {
        width: parent.width
        height: Math.min(contentHeight, Style.space(220))
        model: qa.shownApps
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        delegate: Text {
          width: ListView.view.width
          text: "  " + modelData.label + (modelData.web ? "   ·  web app" : "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: qa.foreground
          font.family: qa.fontFamily
          font.pixelSize: Style.font.body
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: qa.draftFrom(modelData)
          }
        }
      }
    }

    Column {
      visible: qa.pickingWindow
      width: parent.width
      spacing: Style.space(6)

      QuickField {
        id: windowSearch
        width: parent.width
        placeholder: "Search the windows that are open now"
        onTextChanged: qa.filter = text
      }

      ListView {
        width: parent.width
        height: Math.min(contentHeight, Style.space(220))
        model: qa.shownWindows
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        delegate: Text {
          width: ListView.view.width
          text: "  " + modelData.klass + (modelData.title ? "  ·  " + modelData.title : "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: qa.foreground
          font.family: qa.fontFamily
          font.pixelSize: Style.font.caption
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              qa.pickingWindow = false
              qa.draft = { "name": "", "label": modelData.klass, "key": "",
                           "match": modelData.klass, "launch": modelData.klass }
              qa.note = "Check the command opens it, then give it a key."
            }
          }
        }
      }
    }

    // ---- the bottom row -------------------------------------------------------------------------

    Row {
      width: parent.width
      spacing: Style.space(10)

      Button {
        text: qa.pickingApp ? "× cancel" : "+ add an app"
        bordered: true
        foreground: qa.foreground
        background: root.bar ? root.bar.background : Color.background
        accent: qa.accent
        fontFamily: qa.fontFamily
        fontSize: Style.font.body
        onClicked: qa.pickApps()
      }

      Button {
        text: qa.pickingWindow ? "× cancel" : "+ add an open window"
        bordered: true
        foreground: qa.foreground
        background: root.bar ? root.bar.background : Color.background
        accent: qa.accent
        fontFamily: qa.fontFamily
        fontSize: Style.font.body
        onClicked: {
          qa.pickingWindow = !qa.pickingWindow
          qa.pickingApp = false
          qa.filter = ""
          windowSearch.text = ""
          if (qa.pickingWindow) {
            windowSearch.forceActiveFocus()
            windowsProc.command = ["sh", "-c", "hyprctl clients -j"]
            windowsProc.running = true
          }
        }
      }
    }

    Row {
      width: parent.width
      spacing: Style.space(8)

      Text {
        text: (qa.model.hide_on_close ? "[x] " : "[ ] ") + "SUPER + W hides these instead of closing them"
        textFormat: Text.PlainText
        color: qa.foreground
        font.family: qa.fontFamily
        font.pixelSize: Style.font.caption
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: qa.run(["option", "hide_on_close", qa.model.hide_on_close ? "false" : "true"])
        }
      }
    }

    Text {
      visible: qa.note !== ""
      width: parent.width
      text: qa.note
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: qa.accent
      font.family: qa.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      topPadding: Style.space(8)
      horizontalAlignment: Text.AlignHCenter
      text: "click a key to change it  ·  ✓ means it has been pressed and arrived  ·  × removes"
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: qa.muted
      font.family: qa.fontFamily
      font.pixelSize: Style.font.caption
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
      // Escape backs out of a pick or a placement first; with nothing pending it closes.
      // Everything is saved as it happens, so there is nothing to cancel.
      onCloseRequested: {
        if (root.adding) root.cancelAdding()
        else if (root.picking) root.picking = false
        else root.close()
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
              height: tabLabel.implicitHeight + Style.space(8)
              radius: Style.space(4)
              color: root.tab === index ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.15)
                                        : "transparent"
              border.width: 1
              border.color: root.tab === index ? root.accent : Qt.darker(root.foreground, 1.8)

              Text {
                id: tabLabel
                anchors.centerIn: parent
                text: modelData
                textFormat: Text.PlainText
                color: root.tab === index ? root.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: root.tab === index
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

          // THE BOARD: the desk's recording as blocks, in the screen's own proportions.
          Item {
            id: board
            visible: !root.picking
            width: parent.width
            height: Math.round(width / Math.max(1, root.model.aspect || 1.78))

            readonly property int gap: Style.space(3)

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

                Rectangle {
                  id: card
                  x: board.gap
                  y: board.gap
                  width: cell.width - board.gap * 2
                  height: cell.height - board.gap * 2
                  radius: Style.cornerRadius
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
                    card.x = board.gap; card.y = board.gap
                  }
                  onCanceled: { card.x = board.gap; card.y = board.gap }
                }
              }
            }

            // One handle per split: the line between the two sides, dragged along its axis
            // within the cell it divides. Releasing writes the new share.
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
                    width: line.vertical ? 2 : parent.width - board.gap * 4
                    height: line.vertical ? parent.height - board.gap * 4 : 2
                    radius: 1
                    color: root.accent
                    opacity: lineArea.drag.active ? 0.9 : lineArea.containsMouse ? 0.7 : 0.3
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
            text: "drag onto another to swap  ·  drag the line to resize  ·  × removes  ·  saved as you go  ·  h/l walk the desks"
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
