import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Quick apps — the second tab of the Reptile panel (HYPER+L).
//
// A quick app is a window with a key of its own: the key opens it if it is not running, brings it
// to the desk you are looking at if it is running elsewhere, and hides it if it is the window you
// are typing in. Hiding parks it on a hidden workspace rather than closing it, so the next press
// brings the same page back with no reload.
//
// This tab is only an editor. Every change goes through `quick-app`, which owns the list file, the
// generated Hyprland bindings and the summoning itself — the same rule the desk recordings live
// under: the format has exactly one writer.
//
// ⚠️ A KEY CANNOT SIMPLY BE LISTENED FOR. Hyprland swallows a chord that is already bound before
//    any window sees it, so pressing a key that already does something never reaches this panel —
//    and that is exactly the case the clash warning exists for. So: press it, and if nothing
//    arrives within two seconds, say so and offer the explicit list instead. The message is the
//    true one, which teaches the clash rather than hiding it.
Column {
  id: qa

  // The Panel root: colours, fonts, and somewhere to hand focus back to.
  property var host
  property var keyCatcher

  readonly property string tool: "\"$HOME/.config/omarchy/workspace-layout/quick-app\""
  readonly property color foreground: host ? host.foreground : Color.foreground
  readonly property color accent: host ? host.accent : Color.accent
  readonly property color muted: host ? host.muted : Color.muted
  readonly property string fontFamily: host ? host.fontFamily : Style.font.family

  property var model: ({ "apps": [], "hide_on_close": true, "reserved": "SUPER + W" })
  property string note: ""
  property bool busy: false

  // Editing state. `draft` is the row being added or changed; null when the list is just a list.
  property var draft: null
  property bool capturing: false
  property bool keyListing: false
  property var windows: []
  property bool pickingWindow: false

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

  // A web app needs a name and an address and nothing else: Chromium names an --app window
  // "chrome-<host>__<path>-<profile>", so the host alone identifies every window it opens.
  function hostOf(url) {
    var m = String(url).match(/^\s*(?:https?:\/\/)?([^\/\s]+)/i)
    return m ? m[1].toLowerCase() : ""
  }

  function newWebApp() {
    draft = { "name": "", "label": "", "key": "", "url": "", "match": "", "launch": "", "web": true }
    capturing = false; keyListing = false; note = ""
  }

  function editRow(app) {
    draft = { "name": app.name, "label": app.label, "key": app.key, "match": app.match,
              "launch": app.launch, "url": "", "web": false }
    capturing = false; keyListing = false; note = ""
  }

  function shapeDraft() {
    if (!draft) return
    if (draft.web) {
      var h = hostOf(draft.url)
      draft.match = h ? "chrome-" + h + "__" : ""
      draft.launch = draft.url ? "omarchy-launch-webapp " + draft.url : ""
    }
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
    if (keyCatcher) keyCatcher.forceActiveFocus()
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
          text: modelData.fired ? (host ? host.iconCheck : "*") : ""
          color: qa.accent
          font.family: qa.fontFamily
          font.pixelSize: Style.font.iconSmall
        }

        Text {
          text: host ? host.iconX : "x"
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

    component Field: Rectangle {
      property alias text: input.text
      property string placeholder: ""
      width: qa.width
      height: input.implicitHeight + Style.space(8)
      radius: Style.space(4)
      color: "transparent"
      border.width: 1
      border.color: Qt.darker(qa.foreground, 1.8)

      TextInput {
        id: input
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
        visible: input.text === ""
        text: parent.placeholder
        color: qa.muted
        font.family: qa.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    Field {
      id: labelField
      placeholder: "Name, as you want to see it"
      text: qa.draft ? qa.draft.label : ""
      onTextChanged: if (qa.draft) { qa.draft.label = text }
    }

    Field {
      id: addressField
      visible: qa.draft && qa.draft.web
      placeholder: "Web address, e.g. claude.ai/new"
      text: qa.draft ? qa.draft.url : ""
      onTextChanged: if (qa.draft) { qa.draft.url = text }
    }

    Field {
      id: commandField
      visible: qa.draft && !qa.draft.web
      placeholder: "Command that opens it"
      text: qa.draft ? qa.draft.launch : ""
      onTextChanged: if (qa.draft) { qa.draft.launch = text }
    }

    Field {
      id: matchField
      visible: qa.draft && !qa.draft.web
      placeholder: "Start of its window class"
      text: qa.draft ? qa.draft.match : ""
      onTextChanged: if (qa.draft) { qa.draft.match = text }
    }

    Row {
      width: parent.width
      spacing: Style.space(10)

      Button {
        text: qa.draft && qa.draft.key ? "Key: " + qa.draft.key : "Press a key"
        bordered: true
        foreground: qa.foreground
        background: host && host.bar ? host.bar.background : Color.background
        accent: qa.accent
        fontFamily: qa.fontFamily
        fontSize: Style.font.body
        onClicked: qa.startCapture()
      }

      Button {
        text: "Save"
        bordered: true
        foreground: qa.foreground
        background: host && host.bar ? host.bar.background : Color.background
        accent: qa.accent
        fontFamily: qa.fontFamily
        fontSize: Style.font.body
        onClicked: { qa.shapeDraft(); qa.save() }
      }

      Button {
        text: "Cancel"
        bordered: true
        foreground: qa.muted
        background: host && host.bar ? host.bar.background : Color.background
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
          background: host && host.bar ? host.bar.background : Color.background
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

      Field {
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

  Column {
    visible: qa.pickingWindow
    width: parent.width
    spacing: Style.space(4)

    Repeater {
      model: qa.windows
      delegate: Text {
        width: qa.width
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
                         "match": modelData.klass, "launch": modelData.klass,
                         "url": "", "web": false }
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
      text: "+ add a web app"
      bordered: true
      foreground: qa.foreground
      background: host && host.bar ? host.bar.background : Color.background
      accent: qa.accent
      fontFamily: qa.fontFamily
      fontSize: Style.font.body
      onClicked: qa.newWebApp()
    }

    Button {
      text: qa.pickingWindow ? "× cancel" : "+ add an open window"
      bordered: true
      foreground: qa.foreground
      background: host && host.bar ? host.bar.background : Color.background
      accent: qa.accent
      fontFamily: qa.fontFamily
      fontSize: Style.font.body
      onClicked: {
        qa.pickingWindow = !qa.pickingWindow
        if (qa.pickingWindow) {
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
