pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Bar entry point for joegeary.on-air: the ON AIR pill plus the
// control panel behind it. Instantiated once per monitor, so it owns no
// Process, Timer or IpcHandler — every action is a call into the single
// Service instance, reached through bar.shell.serviceFor(moduleName) and
// null-guarded at every access (it is transiently null during load and
// after each hot reload).
Panel {
  id: root

  // The service registers the "on-air" IPC target; the Panel base must not
  // register a second one per monitor.
  ipcTarget: ""
  manageIpc: false

  readonly property var service: bar && bar.shell && moduleName ? bar.shell.serviceFor(moduleName) : null

  // ---- service state, always defined so the UI never reads a null -------
  readonly property string airState: service ? service.state : "OFF_AIR"
  readonly property bool onAir: service ? service.onAir : false
  readonly property bool paused: service ? service.paused : false
  readonly property bool stuck: service ? service.stuckOnAir : false
  readonly property bool degraded: !service || service.degraded
  readonly property bool configured: service ? service.configured : false
  readonly property bool manualOnAir: service ? service.manualOnAir : false
  readonly property var apps: service ? service.activeApps : []
  readonly property var detected: service ? service.detectedApps : []
  readonly property var ignored: service ? service.ignoreApps : []
  readonly property var targetRows: service ? service.targetRows : []
  readonly property string elapsed: service ? service.elapsedText : ""
  readonly property string lastError: service ? service.lastError : ""
  readonly property string colorHex: service ? service.onAirColor : "#ff0000"
  readonly property int brightness: service ? service.brightnessPercent : 100
  readonly property int riseSeconds: service ? service.riseSeconds : 8
  readonly property int clearSeconds: service ? service.clearSeconds : 8

  readonly property bool showWhenIdle: setting("showWhenIdle", true) !== false
  readonly property bool pending: airState === "PENDING"
  readonly property bool pillMode: onAir || paused || stuck
  // A paused widget must stay visible or it could never be un-paused.
  readonly property bool shown: pillMode || pending || showWhenIdle

  // ---- theme -----------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color barDim: Qt.darker(barForeground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)

  readonly property var colorPresets: ["#ff0000", "#ff6a00", "#a020f0"]

  // ---- bar visuals -----------------------------------------------------
  readonly property string pillText: {
    if (root.stuck) return "STUCK"
    if (root.paused) return "PAUSED"
    return "ON AIR"
  }
  readonly property color pillFill: {
    if (root.paused) return "transparent"
    if (root.degraded) return root.barDim
    return root.urgent
  }
  readonly property color pillForeground: root.paused ? root.urgent : Color.background
  readonly property real pillWidth: Math.round(pillMetrics.width) + Style.space(30)

  readonly property string lightSummary: {
    var result = root.service ? root.service.lastResult : null
    if (!result) return root.configured ? "no light result yet" : "no lights configured"
    var failed = result.failed instanceof Array ? result.failed : []
    if (failed.length > 0) return String((failed[0] || {}).error || "light error")
    var ok = result.ok instanceof Array ? result.ok : []
    return ok.length + (ok.length === 1 ? " light set" : " lights set")
  }

  readonly property string tooltip: {
    if (!root.service) return "On Air — service not loaded"
    if (root.stuck) return "On Air — light stuck on-air: " + (root.lastError || "retrying")
    var who = root.apps.length > 0 ? root.apps.join(", ") : "meeting"
    if (root.paused) return "On Air — paused (" + who + ")"
    if (root.onAir) {
      var line = "On Air — " + who
      if (root.elapsed !== "") line += " · " + root.elapsed
      if (!root.degraded) line += " · " + root.lightSummary
      return line
    }
    if (root.pending) return "On Air — starting…"
    if (root.degraded) return "On Air — bin/on-air missing, tracking only"
    return "On Air — off air"
  }

  // ---- hero ------------------------------------------------------------
  readonly property string heroMeta: {
    if (!root.service) return "Service not loaded"
    if (root.stuck) return "Light stuck on-air"
    if (root.paused) return root.elapsed !== "" ? "Paused · " + root.elapsed : "Paused"
    if (root.onAir) {
      var who = root.apps.length > 0 ? root.apps.join(", ") : (root.manualOnAir ? "Manual" : "Meeting")
      return root.elapsed !== "" ? "On air · " + who + " · " + root.elapsed : "On air · " + who
    }
    if (root.pending) return "Starting…"
    if (root.degraded) return "No light control"
    return "Off air"
  }
  readonly property string toggleHint: {
    if (root.paused) return "Resume"
    if (root.onAir) return "Pause for this meeting"
    return "Go on air now"
  }

  // ---- panel cursor ----------------------------------------------------
  property bool cursorActive: false
  property int cursorIndex: 0
  property int swatchIndex: -1

  // Flat navigation model: one entry per actionable row, rebuilt whenever
  // the detected/ignored app lists change.
  readonly property var nav: root.buildNav()

  function buildNav() {
    // Order must match the visual order in the panel: the action row sits
    // directly under the hero, above the light and app sections.
    var items = [{ kind: "hero", value: "" }, { kind: "wizard", value: "" }, { kind: "test", value: "" }, { kind: "swatch", value: "" }, { kind: "brightness", value: "" }, { kind: "rise", value: "" }, { kind: "clear", value: "" }]
    var list = root.detected
    for (var i = 0; i < list.length; i++) {
      if (list[i].ignored !== true) items.push({ kind: "ignore-add", value: String(list[i].binary) })
    }
    var ignoredList = root.ignored
    for (var j = 0; j < ignoredList.length; j++) {
      items.push({ kind: "ignore-remove", value: String(ignoredList[j]) })
    }
    return items
  }

  function navIndex(kind, value) {
    var items = root.nav
    for (var i = 0; i < items.length; i++) {
      if (items[i].kind === kind && items[i].value === String(value || "")) return i
    }
    return -1
  }

  function hasCursorAt(kind, value) {
    if (!root.cursorActive) return false
    var index = root.navIndex(kind, value)
    return index >= 0 && index === root.cursorIndex
  }

  function currentNav() {
    var items = root.nav
    if (items.length === 0) return null
    return items[Math.max(0, Math.min(items.length - 1, root.cursorIndex))]
  }

  function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value))
  }

  function moveCursor(dx, dy) {
    root.cursorActive = true
    var items = root.nav
    if (items.length === 0) return
    if (dy !== 0) {
      root.cursorIndex = root.clamp(root.cursorIndex + dy, 0, items.length - 1)
      return
    }
    if (dx === 0) return
    // Horizontal movement edits the value the cursor is sitting on.
    var item = root.currentNav()
    if (!item) return
    if (item.kind === "swatch") root.swatchIndex = root.clamp((root.swatchIndex < 0 ? 0 : root.swatchIndex) + dx, 0, root.colorPresets.length - 1)
    else if (item.kind === "brightness") root.applyBrightness(root.clamp(root.brightness + dx * 5, 1, 100))
    else if (item.kind === "rise") root.applySeconds("riseSeconds", root.clamp(root.riseSeconds + dx, 0, 600))
    else if (item.kind === "clear") root.applySeconds("clearSeconds", root.clamp(root.clearSeconds + dx, 0, 600))
  }

  function activateCursor() {
    var item = root.currentNav()
    if (!item || !root.service) return
    if (item.kind === "hero") root.service.toggleManual()
    // First Enter picks up the swatch cursor, the second applies it — a
    // stray Enter must never rewrite the colour.
    else if (item.kind === "swatch") {
      if (root.swatchIndex < 0) root.swatchIndex = 0
      else swatchRow.applyHighlighted()
    }
    else if (item.kind === "ignore-add") root.service.addIgnore(item.value)
    else if (item.kind === "ignore-remove") root.service.removeIgnore(item.value)
    else if (item.kind === "wizard") root.launchWizard()
    else if (item.kind === "test") root.service.runTestFlash()
  }

  function setCursor(kind, value) {
    var index = root.navIndex(kind, value)
    if (index < 0) return
    root.cursorActive = true
    root.cursorIndex = index
    if (kind !== "swatch") root.swatchIndex = -1
  }

  // ---- actions (all of them land in the service) ------------------------
  function applyColor(hex) {
    if (root.service) root.service.setConfigValue("onAir.color", JSON.stringify(String(hex)))
  }

  function applyBrightness(percent) {
    if (root.service) root.service.setConfigValue("onAir.brightnessPercent", JSON.stringify(Math.round(percent)))
  }

  function applySeconds(key, seconds) {
    if (root.service) root.service.setConfigValue(key, JSON.stringify(Math.round(seconds)))
  }

  function launchWizard() {
    if (!root.service) return
    root.service.openWizard()
    root.close()
  }

  // The popup is anchored to `button`, so the widget has to stay on screen for
  // as long as the panel is open: hiding it underneath (showWhenIdle=false and
  // the meeting ends while the panel is up) would leave the popup hanging off
  // a zero-width invisible anchor.
  readonly property bool visibleInBar: root.shown || root.opened
  visible: root.visibleInBar
  implicitWidth: root.visibleInBar ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    swatchIndex = -1
    if (panelFlick) panelFlick.contentY = 0
    if (service) service.refresh()
    Qt.callLater(function () {
      keyCatcher.forceActiveFocus()
    })
  }

  TextMetrics {
    id: pillMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.2
    text: root.pillText
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.tooltip
    slotSize: root.pillMode ? root.pillWidth : Style.bar.iconSlot
    opticalSize: root.pillMode ? root.pillWidth : Style.bar.iconCanvas

    iconComponent: Component {
      Item {
        anchors.fill: parent

        // ON AIR / PAUSED / STUCK pill.
        BorderSurface {
          anchors.centerIn: parent
          visible: root.pillMode
          implicitWidth: root.pillWidth
          implicitHeight: Math.round(pillMetrics.height) + Style.space(6)
          radius: Style.cornerRadius > 0 ? implicitHeight / 2 : 0
          color: root.pillFill
          borderSpec: root.paused
            ? Border.flat(root.urgent, Math.max(1, Style.space(1)))
            : Border.none()

          Row {
            anchors.centerIn: parent
            spacing: Style.space(5)

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(6)
              height: width
              radius: width / 2
              color: root.pillForeground
              opacity: root.paused ? 0.6 : 1.0
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.pillText
              color: root.pillForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
          }
        }

        // PENDING: a dim dot that pulses until the rise window elapses.
        Rectangle {
          id: pendingDot
          anchors.centerIn: parent
          visible: !root.pillMode && root.pending
          width: Style.space(7)
          height: width
          radius: width / 2
          color: root.barDim

          SequentialAnimation on opacity {
            running: pendingDot.visible
            loops: Animation.Infinite
            NumberAnimation { to: 0.25; duration: 620; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 620; easing.type: Easing.InOutQuad }
          }
        }

        // Idle and degraded render the same neutral glyph; degraded (service
        // unreachable) is the only state that dims it.
        Text {
          anchors.centerIn: parent
          visible: !root.pillMode && !root.pending
          text: "󰦔"
          color: root.degraded ? root.barDim : root.barForeground
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
        }
      }
    }

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (root.service) root.service.pauseResume()
        return
      }
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Inline editors own the keyboard while focused.
      blocked: swatchRow.editing || riseField.field.activeFocus || clearField.field.activeFocus
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          return
        }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) {
        root.switchPanel(direction)
      }
      onTextKey: function (text) {
        if (text === "p" || text === "P") {
          if (root.service) root.service.pauseResume()
        } else if (text === "t" || text === "T") {
          if (root.service) root.service.runTestFlash()
        } else if (text === "r" || text === "R") {
          if (root.service) root.service.refresh()
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ------------------------------------------------------- hero
          Item {
            id: heroWrap
            width: parent.width
            implicitHeight: hero.implicitHeight

            // The hero's trailingControl resolves `root` to PanelHero, so
            // panel state is reached through this wrapper instead.
            readonly property bool ringVisible: root.hasCursorAt("hero", "")
            readonly property bool switchChecked: root.onAir && !root.paused
            readonly property string hint: root.toggleHint
            function focusHero() {
              root.setCursor("hero", "")
            }
            function activate() {
              if (root.service) root.service.toggleManual()
            }

            PanelHero {
              id: hero
              width: parent.width
              title: "On Air"
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.onAir ? 1.0 : 0.5

              iconComponent: Component {
                Rectangle {
                  implicitWidth: Style.font.display
                  implicitHeight: Style.font.display
                  radius: width / 2
                  color: root.onAir && !root.paused ? root.urgent : "transparent"
                  border.width: Math.max(1, Style.space(2))
                  border.color: root.onAir ? root.urgent : root.dim
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: airSwitch
                  checked: heroWrap.switchChecked
                  hasCursor: heroWrap.ringVisible
                  foreground: hero.foreground
                  onHovered: function (on) {
                    if (on) heroWrap.focusHero()
                  }
                  onToggled: heroWrap.activate()

                  PanelToolTip {
                    visible: airSwitch.containsMouse
                    text: heroWrap.hint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            text: {
              if (!root.service) return "The On Air service is not loaded."
              if (root.degraded) return "bin/on-air is missing or not executable — meetings are tracked, lights are not."
              if (!root.configured) return "No lights configured yet — run the setup wizard."
              return root.lastError
            }
            color: root.stuck || root.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------------------------------------------------- actions
          // Directly under the hero: setup is the first thing a new user
          // needs, and anything below the fold went unnoticed.
          PanelSeparator { foreground: root.foreground }

          Row {
            width: column.width
            spacing: Style.space(8)
            leftPadding: Style.space(10)

            Button {
              text: "Run setup wizard"
              iconText: "󰒓"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: !root.degraded
              opacity: enabled ? 1.0 : 0.4
              hasCursor: root.hasCursorAt("wizard", "")
              onHovered: function (on) {
                if (on) root.setCursor("wizard", "")
              }
              onClicked: root.launchWizard()
            }

            Button {
              text: "Test flash"
              iconText: "󰄬"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: !root.degraded && root.configured
              opacity: enabled ? 1.0 : 0.4
              hasCursor: root.hasCursorAt("test", "")
              onHovered: function (on) {
                if (on) root.setCursor("test", "")
              }
              onClicked: if (root.service) root.service.runTestFlash()
            }
          }

          // ----------------------------------------------------- status
          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "LIGHTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.targetRows.length === 0
            width: parent.width
            text: "No targets configured."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.targetRows

            TargetRow {
              required property var modelData
              width: column.width
              row: modelData
            }
          }

          Text {
            width: parent.width
            visible: root.apps.length > 0
            text: "Detected: " + root.apps.join(", ")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // --------------------------------------------------- settings
          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "ON-AIR LIGHT"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ColorSwatchRow {
            id: swatchRow
            width: column.width
            presets: root.colorPresets
            selected: root.colorHex
            highlightIndex: root.hasCursorAt("swatch", "") ? root.swatchIndex : -1
            hasCursor: root.hasCursorAt("swatch", "")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onPicked: function (hex) {
              root.applyColor(hex)
            }
            onHoveredRow: root.setCursor("swatch", "")
            onHoveredSwatch: function (index) {
              root.setCursor("swatch", "")
              root.swatchIndex = index
            }
          }

          CursorSurface {
            id: brightnessRow
            width: column.width
            hasCursor: root.hasCursorAt("brightness", "")
            foreground: root.foreground
            implicitHeight: brightnessInner.implicitHeight + Style.spacing.rowPaddingX

            RowLayout {
              id: brightnessInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              Text {
                text: "Brightness"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                Layout.alignment: Qt.AlignVCenter
              }

              PanelSlider {
                id: brightnessSlider
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                bar: root.bar
                minimum: 1
                maximum: 100
                step: 5
                integer: true
                value: root.brightness
                onMoved: root.setCursor("brightness", "")
                onReleased: function (value) {
                  root.applyBrightness(value)
                }
              }

              Text {
                text: Math.round(brightnessSlider.liveValue) + "%"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                Layout.alignment: Qt.AlignVCenter
              }
            }
          }

          Row {
            width: column.width
            spacing: Style.space(16)
            leftPadding: Style.space(10)

            NumberField {
              id: riseField
              label: "On-air delay (s)"
              from: 0
              to: 600
              value: root.riseSeconds
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.hasCursorAt("rise", "")
              onHovered: function (on) {
                if (on) root.setCursor("rise", "")
              }
              onModified: function (value) {
                root.applySeconds("riseSeconds", value)
              }
            }

            NumberField {
              id: clearField
              label: "Off-air delay (s)"
              from: 0
              to: 600
              value: root.clearSeconds
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.hasCursorAt("clear", "")
              onHovered: function (on) {
                if (on) root.setCursor("clear", "")
              }
              onModified: function (value) {
                root.applySeconds("clearSeconds", value)
              }
            }
          }

          Text {
            width: column.width - Style.space(20)
            x: Style.space(10)
            text: "How long a meeting must run before the light changes, and how long after it ends before the light goes back. Keeps mic checks and mute blips from flickering the light."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ----------------------------------------------------- ignore
          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "APPS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.detected

            AppRow {
              required property var modelData
              width: column.width
              visible: modelData.ignored !== true
              binary: String(modelData.binary)
              label: String(modelData.label)
              detail: String(modelData.kind) === "video" ? "camera" : "microphone"
              ignoring: false
            }
          }

          Repeater {
            model: root.ignored

            AppRow {
              required property var modelData
              width: column.width
              binary: String(modelData)
              label: String(modelData)
              detail: "ignored"
              ignoring: true
            }
          }

        }
      }
    }
  }

  // ------------------------------------------------------------ rows
  component TargetRow: CursorSurface {
    id: targetRow

    property var row: null
    readonly property bool reachable: targetRow.row && targetRow.row.ok === true
    readonly property bool unknown: !targetRow.row || targetRow.row.ok === null || targetRow.row.ok === undefined
    readonly property string error: targetRow.row ? String(targetRow.row.error || "") : ""

    foreground: root.foreground
    implicitHeight: targetInner.implicitHeight + Style.spacing.rowPaddingX

    RowLayout {
      id: targetInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: Style.space(8)
        implicitHeight: Style.space(8)
        radius: width / 2
        color: targetRow.unknown ? root.dim : (targetRow.reachable ? root.foreground : root.urgent)
        opacity: targetRow.unknown ? 0.5 : 1.0
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: targetRow.row ? String(targetRow.row.id || targetRow.row.driver || "target") : "target"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: targetRow.error !== ""
            ? targetRow.error
            : (targetRow.unknown ? "not probed yet" : (targetRow.reachable ? "reachable" : "unreachable"))
          color: targetRow.error !== "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component AppRow: CursorSurface {
    id: appRow

    property string binary: ""
    property string label: ""
    property string detail: ""
    property bool ignoring: false

    readonly property string navKind: appRow.ignoring ? "ignore-remove" : "ignore-add"

    hasCursor: root.hasCursorAt(appRow.navKind, appRow.binary)
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: appInner.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor(appRow.navKind, appRow.binary)
    }

    RowLayout {
      id: appInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: appRow.label
          color: appRow.ignoring ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: appRow.binary === appRow.label ? appRow.detail : appRow.binary + " · " + appRow.detail
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        iconText: appRow.ignoring ? "󰄬" : "󰅙"
        tooltipText: appRow.ignoring ? "Trigger for this app again" : "Never trigger for this app"
        foreground: root.foreground
        hoverColor: appRow.ignoring ? root.foreground : root.urgent
        fontFamily: root.fontFamily
        onHovered: function (on) {
          if (on) root.setCursor(appRow.navKind, appRow.binary)
        }
        onClicked: {
          if (!root.service) return
          if (appRow.ignoring) root.service.removeIgnore(appRow.binary)
          else root.service.addIgnore(appRow.binary)
        }
      }
    }
  }
}
