import QtQuick
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

// Easy Effects companion for the Omarchy bar.
//   left click    open Easy Effects
//   right click   toggle Easy Effects' global bypass (all effects on/off)
//   scroll        previous / next output preset
//
// Preset and bypass state come from the easyeffects CLI. Each call costs about
// 0.2 s, so the badge refreshes on events (clicks, scrolls, output changes,
// hovering) plus a slow fallback timer instead of polling.
//
// Invoking the CLI while Easy Effects is stopped does not fail: the call
// becomes the main instance and never exits. So every call checks pgrep
// first, and holds a shared lock that scripts/match-theme takes exclusively
// while it restarts Easy Effects.
BarWidget {
  id: root
  moduleName: "io.github.mr-dragon9.easyeffects"

  readonly property bool showBattery: setting("showBattery", true)
  readonly property bool showPreset: setting("showPreset", false)
  readonly property bool onlyBluetooth: setting("onlyBluetooth", false)
  readonly property int lowBattery: setting("lowBattery", 20)
  readonly property bool matchTheme: setting("matchTheme", false)

  property bool eeRunning: false
  property bool bypassed: false
  property string preset: ""
  property var presets: []
  property bool refreshQueued: false
  property real wheelAccum: 0

  // The default sink stays the hardware device while Easy Effects runs (it
  // moves streams to its own sink instead), so this is the real output.
  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var sinkProps: sink && sink.ready && sink.properties ? sink.properties : ({})
  readonly property string sinkAddress: String(sinkProps["api.bluez5.address"] || "").toUpperCase()
  readonly property bool onBluetooth: sinkAddress !== ""

  readonly property var btDevice: {
    if (!onBluetooth) return null
    var devs = Bluetooth.devices ? Bluetooth.devices.values : []
    for (var i = 0; i < devs.length; i++) {
      if (devs[i] && String(devs[i].address || "").toUpperCase() === sinkAddress) return devs[i]
    }
    return null
  }

  readonly property int percent: btDevice && btDevice.batteryAvailable ? Math.round(btDevice.battery * 100) : -1
  readonly property bool low: percent >= 0 && percent <= lowBattery
  readonly property string outputName: btDevice
    ? (btDevice.name || btDevice.deviceName || "")
    : String(sinkProps["node.description"] || (sink ? sink.description : "") || "")

  readonly property string glyph: {
    if (!onBluetooth) return "󰙪"
    var kind = String((btDevice && btDevice.icon) || sinkProps["device.icon_name"] || "").toLowerCase()
    return kind.indexOf("head") !== -1 ? "󰋋" : "󰓃"
  }

  readonly property string label: {
    var parts = []
    if (showPreset && preset !== "") parts.push(preset)
    if (showBattery && percent >= 0) parts.push(percent + "%")
    return parts.join(" · ")
  }

  readonly property string cliGuard:
    "exec 9>\"${XDG_RUNTIME_DIR:-/tmp}/omarchy-easyeffects-theme.lock\"; flock -s -w 20 9 || exit 0; "
    + "pgrep -x easyeffects >/dev/null || exit 0; "
    // Children must not inherit the lock fd, or one that became the main
    // instance would hold it for good.
    + "ee() { easyeffects \"$@\" 9>&-; }; "

  readonly property string themeScript:
    decodeURIComponent(String(Qt.resolvedUrl("scripts/match-theme")).replace(/^file:\/\//, ""))

  visible: !onlyBluetooth || onBluetooth
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function sh(command) {
    if (root.bar) root.bar.run(command)
  }

  // The bar facade handed to third-party widgets has no shellQuote.
  function sq(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function refresh() {
    if (stateProc.running) root.refreshQueued = true
    else stateProc.running = true
  }

  function parseState(out) {
    var lines = String(out || "").split("\n")
    if (lines[0] !== "running") {
      root.eeRunning = false
      root.bypassed = false
      root.preset = ""
      root.presets = []
      return
    }
    root.eeRunning = true
    root.bypassed = String(lines[1] || "").trim() === "1"
    root.preset = String(lines[2] || "").trim()

    var list = []
    var inOutput = false
    for (var i = 3; i < lines.length; i++) {
      if (/^Output presets:/.test(lines[i])) { inOutput = true; continue }
      if (!inOutput) continue
      var m = lines[i].match(/^\d+\t(.+)$/)
      if (!m) break
      list.push(m[1])
    }
    root.presets = list
  }

  function openWindow() {
    sh("if command -v uwsm-app >/dev/null; then uwsm-app -- easyeffects; else easyeffects; fi")
  }

  function toggleBypass() {
    if (!root.eeRunning) return
    sh(root.cliGuard + "ee --bypass-toggle")
    root.bypassed = !root.bypassed
    settleTimer.restart()
  }

  function stepPreset(direction) {
    var count = root.presets.length
    if (!root.eeRunning || count < 2) return
    var index = root.presets.indexOf(root.preset)
    var next = index < 0
      ? root.presets[direction > 0 ? 0 : count - 1]
      : root.presets[(index + direction + count) % count]
    sh(root.cliGuard + "ee -l " + sq(next))
    root.preset = next
    settleTimer.restart()
  }

  // Touchpads send many small deltas; act once per notch and briefly ignore
  // the rest so one flick does not skip through every preset.
  function wheel(delta) {
    root.wheelAccum += delta
    if (wheelCooldown.running || Math.abs(root.wheelAccum) < 120) return
    stepPreset(root.wheelAccum > 0 ? -1 : 1)
    root.wheelAccum = 0
    wheelCooldown.restart()
  }

  onSinkAddressChanged: outputSettle.restart()
  onSinkChanged: outputSettle.restart()
  onMatchThemeChanged: if (matchTheme) themeSettle.restart()
  Component.onCompleted: {
    refresh()
    if (matchTheme) themeSettle.restart()
  }

  PwObjectTracker { objects: root.sink ? [root.sink] : [] }

  // For keybindings, e.g. omarchy-shell io.github.mr-dragon9.easyeffects toggle
  IpcHandler {
    target: "io.github.mr-dragon9.easyeffects"

    function toggle(): void { root.toggleBypass() }
    function next(): void { root.stepPreset(1) }
    function previous(): void { root.stepPreset(-1) }
    function open(): void { root.openWindow() }
    function refresh(): void { root.refresh() }
    function state(): string {
      return JSON.stringify({
        running: root.eeRunning, bypassed: root.bypassed, preset: root.preset, presets: root.presets,
        output: root.outputName, bluetooth: root.onBluetooth, battery: root.percent, visible: root.visible
      })
    }
  }

  Process {
    id: stateProc
    command: ["bash", "-c",
      root.cliGuard + "echo running; ee -b 3; ee -a output; ee -p"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseState(text) }
    onExited: function(exitCode) {
      if (root.refreshQueued) {
        root.refreshQueued = false
        stateProc.running = true
      }
    }
  }

  Process {
    id: themeProc
    command: ["bash", root.themeScript]
    onExited: function(exitCode) { settleTimer.restart() }
  }

  // Let an action land before reading state back.
  Timer { id: settleTimer; interval: 500; onTriggered: root.refresh() }
  // Easy Effects autoloads a preset shortly after the output changes.
  Timer { id: outputSettle; interval: 1500; onTriggered: root.refresh() }
  Timer { id: wheelCooldown; interval: 300; onTriggered: root.wheelAccum = 0 }
  Timer { interval: 60000; running: true; repeat: true; onTriggered: root.refresh() }
  // Backstop for the remaining race (Easy Effects quit between the pgrep and
  // the call): a CLI call that became the main instance never returns. Ending
  // it matches what the user asked for, Easy Effects being stopped.
  Timer {
    interval: 30000
    running: stateProc.running
    onTriggered: if (stateProc.running) stateProc.running = false
  }
  // Theme switches update several colors in a row; react once they settle.
  Timer {
    id: themeSettle
    interval: 1500
    onTriggered: if (root.matchTheme && !themeProc.running) themeProc.running = true
  }

  Connections {
    target: Color
    function onAccentChanged() { if (root.matchTheme) themeSettle.restart() }
    function onBackgroundChanged() { if (root.matchTheme) themeSettle.restart() }
    function onForegroundChanged() { if (root.matchTheme) themeSettle.restart() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

    active: root.low
    dimmed: !root.eeRunning || root.bypassed

    text: root.vertical
      ? (root.showBattery && root.percent >= 0 ? String(root.percent) : root.glyph)
      : (root.label !== "" ? root.glyph + "  " + root.label : root.glyph)

    tooltipText: {
      var lines = []
      if (!root.eeRunning) lines.push("Easy Effects is not running")
      else lines.push("Easy Effects: " + (root.preset || "no preset") + (root.bypassed ? " (bypassed)" : ""))
      if (root.outputName !== "")
        lines.push(root.outputName + (root.percent >= 0 ? ": " + root.percent + "% battery" : ""))
      lines.push("Left: open · Right: effects on/off · Scroll: preset")
      return lines.join("\n")
    }

    onTooltipHoveredChanged: if (tooltipHovered) root.refresh()

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleBypass()
      else if (b === Qt.LeftButton) root.openWindow()
    }

    onWheelMoved: function(delta) { root.wheel(delta) }
  }
}
