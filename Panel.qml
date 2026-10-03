import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "sam.bitcoin"
  ipcTarget: "sam.bitcoin"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() { open() }

  function close() {
    root.controller.hide()
    root.lockVault()
  }

  function toggle() {
    if (root.opened) close()
    else open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---- live data --------------------------------------------------------

  // Seeded from the last successfully fetched values (persisted to
  // shell.json) so a price shows immediately after a shell restart instead
  // of blanking to "—" until the first fetch of the new process completes.
  property var market: setting("cachedMarket", null)     // { price, change24h, change7d, marketCap, ath }
  property var dominance: null       // number (percent)
  property var blockHeight: null     // number
  property var hashrate: null        // H/s
  property var difficulty: null      // { progressPercent, remainingBlocks, difficultyChange, estimatedRetargetDate }
  property string errorText: ""

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    // Every save rewrites the whole entry from this instance's cached settings,
    // which go stale the moment another monitor's panel — or this one's own
    // vault write — touches the file. Without this the 90s market-cache save
    // happily resurrects an old vault and destroys the current one. root.vault
    // tracks the file itself, so it is the only trustworthy source here.
    if (values.vault === undefined) entry.vault = root.vault
    entry.positions = []

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  readonly property real change24h: market ? market.change24h : null
  readonly property string priceLabel: market ? ("₿ " + Model.formatPrice(market.price)) : "₿ —"

  readonly property var holidays: Model.upcomingHolidays(new Date(), blockHeight || 0)
  readonly property var halvingInfo: blockHeight ? Model.nextHalving(blockHeight, new Date()) : null

  // ---- stack sats ---------------------------------------------------------

  // Holdings are { amount, custody: "exchange"|"self", selfType?, multisigM?,
  // multisigN?, wallet?, plus the custody risk answers }.
  //
  // Persisted as an openssl-encrypted blob; the plaintext holdings only ever
  // exist in memory while the panel is unlocked. Losing the password means
  // losing the data — resetVault() is the documented way out.
  property string vault: setting("vault", "")
  readonly property bool hasVault: root.vault !== ""

  property var positions: []
  property bool unlocked: false
  property string sessionPassword: ""
  property string pwInput: ""
  property string pwInput2: ""
  property string vaultError: ""
  property bool resetConfirm: false
  property bool vaultFieldFocus: false

  readonly property real stackTotalBtc: Model.sumBtc(root.positions)

  readonly property alias autoLockTimer: autoLockTimer

  // The shell rewrites shell.json with atomicWrites, so every save lands as a
  // fresh 0644 file and the vault would sit world-readable between writes.
  function hardenSettingsFile() { hardenTimer.restart() }

  function lockVault() {
    autoLockTimer.stop()
    // A decrypt started before the lock would otherwise complete afterwards and
    // quietly put the holdings back on screen.
    if (decryptProc.running) decryptProc.stale = true
    decryptProc.pendingPassword = ""
    decryptProc.resyncPending = false
    root.unlocked = false
    root.sessionPassword = ""
    root.positions = []
    root.pwInput = ""
    root.pwInput2 = ""
    // onTextChanged assigns pwInput imperatively, which breaks the text
    // binding, so the typed password lingers in the field unless cleared here.
    root.clearPasswordFields()
    root.vaultError = ""
    root.resetConfirm = false
    root.closeForm()
  }

  // Forgotten password: the ciphertext is unrecoverable, so the only option
  // is to discard it and start over with a new password.
  function resetVault() {
    root.vault = ""
    root.resetConfirm = false
    root.lockVault()
    persistSettings({ vault: "", positions: [] })
  }

  function createVault() {
    if (root.pwInput === "") { root.vaultError = "Password required"; return }
    if (root.pwInput !== root.pwInput2) { root.vaultError = "Passwords differ"; return }
    // Adopt any holdings saved before encryption existed, then drop the
    // plaintext copy as part of the first encrypted write.
    var legacy = setting("positions", [])
    root.positions = Array.isArray(legacy) ? legacy : []
    root.sessionPassword = root.pwInput
    root.unlocked = true
    root.pwInput = ""
    root.pwInput2 = ""
    root.clearPasswordFields()
    root.vaultError = ""
    autoLockTimer.restart()
    root.saveVault()
  }

  function clearPasswordFields() {
    if (typeof unlockField !== "undefined" && unlockField) unlockField.text = ""
    if (typeof newPwField !== "undefined" && newPwField) newPwField.text = ""
    if (typeof repeatPwField !== "undefined" && repeatPwField) repeatPwField.text = ""
  }

  function unlockVault() {
    if (root.pwInput === "") return
    decryptProc.stale = false
    if (Model.vaultEnvelope(root.vault) === null) { root.vaultError = "Vault corrupted"; return }
    root.vaultError = ""
    decryptProc.pendingPassword = root.pwInput
    decryptProc.running = true
  }

  // A write that lands while openssl is still busy would be dropped, so the
  // latest payload is queued and re-run once the current process exits.
  function saveVault() {
    if (!root.unlocked || root.sessionPassword === "") return
    encryptProc.payload = Model.vaultPayload(root.positions)
    if (encryptProc.running) { encryptProc.saveQueued = true; return }
    encryptProc.running = true
  }

  // The panel is instantiated once per monitor, so another instance may have
  // re-encrypted the vault. Pull its changes in rather than overwriting them
  // from this instance's now-stale copy, which would silently drop whatever
  // the other instance added.
  function resyncVault() {
    if (!root.unlocked || root.sessionPassword === "") return
    if (root.vault === "" || root.vault === encryptProc.lastWritten) return
    if (decryptProc.running) { decryptProc.resyncPending = true; return }
    decryptProc.pendingPassword = root.sessionPassword
    decryptProc.running = true
  }

  onVaultChanged: root.resyncVault()

  // Holdings plus the custody answers are a map of what to steal and how it is
  // guarded, so leaving them on screen is the whole shoulder-surfing attack.
  Timer {
    id: autoLockTimer
    interval: 300000
    repeat: false
    onTriggered: root.lockVault()
  }

  Timer {
    id: hardenTimer
    interval: 250
    repeat: false
    onTriggered: if (!hardenProc.running) hardenProc.running = true
  }

  Process {
    id: hardenProc
    command: ["bash", "-c", Model.hardenScript]
  }

  // Each monitor gets its own panel with its own cached settings, and
  // persistSettings() only refreshes the copy that wrote it. Watching the file
  // keeps every instance honest about which ciphertext is current.
  FileView {
    id: settingsFile
    path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      var current = Model.readVault(text(), root.moduleName)
      if (current !== null) root.vault = current
      // Every rewrite of the file — including the 90s market-cache save —
      // restores the default mode, so re-tighten it whenever it changes.
      if (root.vault !== "") root.hardenSettingsFile()
    }
    onFileChanged: reload()
  }

  Process {
    id: encryptProc
    property string payload: ""
    property string lastWritten: ""
    property bool saveQueued: false
    stdinEnabled: true
    command: ["bash", "-c", Model.vaultEncryptScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var ciphertext = String(text).trim()
        if (Model.vaultEnvelope(ciphertext) === null) { root.vaultError = "Encryption failed"; return }
        encryptProc.lastWritten = ciphertext
        root.vault = ciphertext
        root.vaultError = ""
        root.persistSettings({ vault: ciphertext, positions: [] })
        root.hardenSettingsFile()
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: {
      if (!encryptProc.saveQueued) return
      encryptProc.saveQueued = false
      encryptProc.running = true
    }
    onStarted: write(Model.VAULT_ITERATIONS + "\n" + root.sessionPassword + "\n" + payload + "\n")
  }

  Process {
    id: decryptProc
    property string pendingPassword: ""
    property bool resyncPending: false
    property bool stale: false
    stdinEnabled: true
    command: ["bash", "-c", Model.vaultDecryptScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (decryptProc.stale) { decryptProc.stale = false; decryptProc.pendingPassword = ""; return }
        var parsed = Model.parseVault(text)
        if (parsed === null) {
          root.vaultError = "Wrong password"
        } else {
          root.positions = parsed
          root.sessionPassword = decryptProc.pendingPassword
          root.unlocked = true
          root.pwInput = ""
          root.clearPasswordFields()
          root.vaultError = ""
          root.autoLockTimer.restart()
        }
        decryptProc.pendingPassword = ""
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    // Exit 3 is the checksum check failing, which means the stored blob was
    // damaged rather than the password mistyped. Saying so keeps the user from
    // reaching for "Forgot", which would destroy a vault they could still own.
    onExited: function(code, status) {
      if (code === 3 && !decryptProc.stale) root.vaultError = "Vault corrupted"
      if (decryptProc.resyncPending) {
        decryptProc.resyncPending = false
        Qt.callLater(root.resyncVault)
      }
    }
    onStarted: {
      var envelope = Model.vaultEnvelope(root.vault)
      write(Model.VAULT_ITERATIONS + "\n" + (envelope ? envelope.sum : "")
        + "\n" + pendingPassword + "\n" + (envelope ? envelope.body : "") + "\n")
    }
  }



  property bool addOpen: false
  // -1 while adding, otherwise the index of the position being edited.
  property int editIndex: -1
  property string newAmountText: ""
  property string newCustody: "exchange"
  property string newSelfType: "singlesig"
  property int newMultisigM: 2
  property int newMultisigN: 3
  property string newWallet: "hot"

  // Custody risk answers. Empty means "not answered yet" — such positions
  // are stored without the key and render as unassessed rather than scoring
  // as if the user had confirmed a safe setup.
  property string newSeedBackup: ""
  property string newBackupMedium: ""
  property string newGeoRedundant: ""
  property string newPpBackup: ""
  property string newPpSeparate: ""
  property string newDescriptorBackup: ""
  property string newSeedBackups: ""
  property string newKeysGeo: ""
  property string newHwVendors: ""
  property string newKeyholders: ""
  property string newHeirAccess: ""
  property string newExchange2fa: ""

  readonly property color riskRed: Color.urgent
  readonly property color riskAmber: "#d79921"
  readonly property color riskGreen: "#89b482"

  function riskColor(level) {
    return level === "red" ? root.riskRed
      : level === "amber" ? root.riskAmber
      : level === "green" ? root.riskGreen
      : Color.muted
  }

  function resetRiskAnswers() {
    root.newSeedBackup = ""
    root.newBackupMedium = ""
    root.newGeoRedundant = ""
    root.newPpBackup = ""
    root.newPpSeparate = ""
    root.newDescriptorBackup = ""
    root.newSeedBackups = ""
    root.newKeysGeo = ""
    root.newHwVendors = ""
    root.newKeyholders = ""
    root.newHeirAccess = ""
    root.newExchange2fa = ""
  }

  function closeForm() {
    root.addOpen = false
    root.editIndex = -1
    root.newAmountText = ""
    root.resetRiskAnswers()
  }

  // Loads an existing position back into the add form. Answers the position
  // does not carry are reset rather than left over from the form's previous
  // contents, so an untouched question stays unanswered.
  function editPosition(index) {
    var p = root.positions[index]
    if (!p) return
    autoLockTimer.restart()
    root.resetRiskAnswers()
    root.newAmountText = Model.formatBtc(p.amount)
    root.newCustody = p.custody || "exchange"
    root.newExchange2fa = p.exchange2fa || ""
    root.newSelfType = p.selfType || "singlesig"
    root.newMultisigM = p.multisigM || 2
    root.newMultisigN = p.multisigN || 3
    root.newWallet = p.wallet || "hot"
    root.newSeedBackup = p.seedBackup || ""
    root.newBackupMedium = p.backupMedium || ""
    root.newGeoRedundant = p.geoRedundant || ""
    root.newPpBackup = p.ppBackup || ""
    root.newPpSeparate = p.ppSeparate || ""
    root.newDescriptorBackup = p.descriptorBackup || ""
    root.newSeedBackups = p.seedBackups || ""
    root.newKeysGeo = p.keysGeo || ""
    root.newHwVendors = p.hwVendors || ""
    root.newKeyholders = p.keyholders || ""
    root.newHeirAccess = p.heirAccess || ""
    root.editIndex = index
    root.addOpen = true
  }

  function updatePosition(index, pos) {
    autoLockTimer.restart()
    var list = root.positions.slice()
    if (index < 0 || index >= list.length) return
    list[index] = pos
    root.positions = list
    saveVault()
  }

  function addPosition(pos) {
    autoLockTimer.restart()
    var list = root.positions.slice()
    list.push(pos)
    root.positions = list
    saveVault()
  }

  function removePosition(index) {
    autoLockTimer.restart()
    // Keep the open form pointing at the same position, or close it if that
    // position is the one going away.
    if (root.editIndex === index) root.closeForm()
    else if (root.editIndex > index) root.editIndex -= 1
    var list = root.positions.slice()
    list.splice(index, 1)
    root.positions = list
    saveVault()
  }

  function commitAddPosition() {
    var amt = parseFloat(root.newAmountText)
    if (!isFinite(amt) || amt <= 0) return
    var pos = { amount: amt, custody: root.newCustody }
    if (root.newCustody !== "self") {
      if (root.newExchange2fa) pos.exchange2fa = root.newExchange2fa
    } else {
      pos.selfType = root.newSelfType
      if (root.newSelfType === "multisig") {
        pos.multisigM = root.newMultisigM
        pos.multisigN = Math.max(root.newMultisigN, root.newMultisigM)
        if (root.newDescriptorBackup) pos.descriptorBackup = root.newDescriptorBackup
        if (root.newSeedBackups) pos.seedBackups = root.newSeedBackups
        if (root.newKeysGeo) pos.keysGeo = root.newKeysGeo
        if (root.newHwVendors) pos.hwVendors = root.newHwVendors
        if (root.newKeyholders) pos.keyholders = root.newKeyholders
      } else {
        if (root.newSeedBackup) pos.seedBackup = root.newSeedBackup
        // Questions the user never saw must not be saved, or a stale answer
        // from an earlier selection would be graded as if it still applied.
        if (root.newSeedBackup === "yes") {
          if (root.newBackupMedium) pos.backupMedium = root.newBackupMedium
          if (root.newGeoRedundant) pos.geoRedundant = root.newGeoRedundant
        }
        if (root.newSelfType === "singlesig_pp") {
          if (root.newPpBackup) pos.ppBackup = root.newPpBackup
          if (root.newPpBackup === "written" && root.newPpSeparate) pos.ppSeparate = root.newPpSeparate
        }
      }
      if (root.newHeirAccess) pos.heirAccess = root.newHeirAccess
      pos.wallet = root.newWallet
    }
    if (root.editIndex >= 0) root.updatePosition(root.editIndex, pos)
    else root.addPosition(pos)
    root.closeForm()
  }

  function refresh() {
    marketRetryTimer.stop()
    marketRetryCount = 0
    marketProc.running = true
    dominanceProc.running = true
    heightProc.running = true
    hashrateProc.running = true
    difficultyProc.running = true
  }

  // A labelled row of mutually-exclusive risk chips. Options are
  // { value, label, risk } where risk is "red", "amber" or "" — the chip
  // paints in that color once selected, so a dangerous answer is visible
  // at a glance without any explanatory text.
  component RiskRow: Row {
    id: riskRow

    property string label: ""
    property var options: []
    property string value: ""
    property color foreground: Color.foreground
    property color accentNormal: Color.accent
    property color redColor: Color.urgent
    property color amberColor: "#d79921"
    property string fontFamily: Style.font.family

    signal changed(string value)

    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: riskRow.label
      width: Style.space(120)
      height: chips.height
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
      color: Qt.darker(riskRow.foreground, 1.2)
      font.family: riskRow.fontFamily
      font.pixelSize: Style.font.caption
    }

    Row {
      id: chips
      spacing: Style.space(4)

      Repeater {
        model: riskRow.options

        delegate: Button {
          required property var modelData

          readonly property bool isChosen: String(modelData.value) === riskRow.value
          readonly property string riskLevel: modelData.risk ? String(modelData.risk) : ""
          readonly property color riskTint: riskLevel === "red" ? riskRow.redColor
            : riskLevel === "amber" ? riskRow.amberColor
            : riskRow.foreground

          text: modelData.label
          bordered: true
          focusable: true
          // Themes pin the kit's selected-state color (shell.toml
          // [controls] selected-color), so it ignores per-instance colors.
          // A chosen risky answer therefore opts out of `selected` and
          // paints its own warning tint via foreground + background.
          selected: isChosen && riskLevel === ""
          foreground: (isChosen && riskLevel !== "") ? riskTint : riskRow.foreground
          background: (isChosen && riskLevel !== "")
            ? Qt.rgba(riskTint.r, riskTint.g, riskTint.b, 0.22)
            : "transparent"
          fontFamily: riskRow.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(7)
          verticalPadding: Style.space(3)
          onClicked: riskRow.changed(String(modelData.value))
        }
      }
    }
  }

  Timer {
    // Prices and network stats move slowly enough that a 90s cadence stays
    // current without hammering the public APIs. triggeredOnStart means the
    // bar pill shows real data immediately after shell start/plugin reload,
    // not just once the panel is first opened.
    interval: 90000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // CoinGecko's anonymous tier occasionally answers with 429 (rate limit),
  // which curl -f turns into an empty response. Rather than waiting for the
  // next full 90s tick, retry a few times with a short, increasing delay so
  // a transient block clears quickly instead of leaving the price stuck.
  property int marketRetryCount: 0
  readonly property var marketRetryDelays: [5000, 15000, 30000]

  Timer {
    id: marketRetryTimer
    repeat: false
    onTriggered: { marketProc.running = true }
  }

  Process {
    id: marketProc
    command: ["curl", "-fsS", "--max-time", "6",
      "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=bitcoin&price_change_percentage=7d"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseMarket(text)
        if (parsed) {
          root.marketRetryCount = 0
          root.market = parsed
          persistSettings({ cachedMarket: parsed })
        } else if (root.marketRetryCount < root.marketRetryDelays.length) {
          marketRetryTimer.interval = root.marketRetryDelays[root.marketRetryCount]
          root.marketRetryCount += 1
          marketRetryTimer.start()
        }
      }
    }
  }

  Process {
    id: dominanceProc
    command: ["curl", "-fsS", "--max-time", "6", "https://api.coingecko.com/api/v3/global"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseDominance(text)
        if (parsed !== null) root.dominance = parsed
      }
    }
  }

  Process {
    id: heightProc
    command: ["curl", "-fsS", "--max-time", "6", "https://mempool.space/api/blocks/tip/height"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseBlockHeight(text)
        if (parsed !== null) root.blockHeight = parsed
      }
    }
  }

  Process {
    id: hashrateProc
    command: ["curl", "-fsS", "--max-time", "6", "https://mempool.space/api/v1/mining/hashrate/3d"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseHashrate(text)
        if (parsed !== null) root.hashrate = parsed
      }
    }
  }

  Process {
    id: difficultyProc
    command: ["curl", "-fsS", "--max-time", "6", "https://mempool.space/api/v1/difficulty-adjustment"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseDifficultyAdjustment(text)
        if (parsed) root.difficulty = parsed
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Freeze global shortcuts/nav while an inline editor has focus so the
      // typed characters reach the field instead of triggering panel keys.
      blocked: root.addOpen || root.vaultFieldFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r") root.refresh() }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        // ---- Market -----------------------------------------------------
        PanelSectionHeader { text: "MARKET" }

        Text {
          id: priceLabel
          textFormat: Text.PlainText
          text: root.market ? Model.formatPrice(root.market.price) : "—"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }

        Row {
          width: parent.width
          spacing: Style.space(16)

          Text {
            textFormat: Text.PlainText
            text: "24h " + (root.market ? Model.formatPercent(root.market.change24h) : "—")
            color: root.market && root.market.change24h < 0 ? Color.urgent : Color.accent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            textFormat: Text.PlainText
            text: "7d " + (root.market ? Model.formatPercent(root.market.change7d) : "—")
            color: root.market && root.market.change7d < 0 ? Color.urgent : Color.accent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(16)
          Text {
            textFormat: Text.PlainText
            text: "Market cap " + (root.market ? Model.formatCompact(root.market.marketCap) : "—")
            color: Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            textFormat: Text.PlainText
            text: "Dominance " + (root.dominance !== null ? root.dominance.toFixed(1) + "%" : "—")
            color: Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---- Network ------------------------------------------------------
        PanelSectionHeader { text: "NETWORK" }

        Grid {
          width: parent.width
          columns: 2
          columnSpacing: Style.space(12)
          rowSpacing: Style.space(6)

          Text {
            text: "Block height"; color: Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
          }
          Text {
            text: root.blockHeight !== null ? Model.thousands(root.blockHeight) : "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
          }

          Text {
            text: "Hashrate"; color: Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
          }
          Text {
            text: root.hashrate !== null ? Model.formatHashrate(root.hashrate) : "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
          }

          Text {
            text: "Next halving"; color: Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
          }
          Text {
            text: root.halvingInfo ? (Model.thousands(root.halvingInfo.remainingBlocks) + " blocks · est. " + Model.formatDateWithYear(root.halvingInfo.estimatedDate)) : "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---- Calendar -----------------------------------------------------
        PanelSectionHeader { text: "BITCOIN CALENDAR" }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.holidays

            Item {
              required property var modelData
              width: column.width
              height: Math.max(nameLabel.implicitHeight, dateLabel.implicitHeight)

              Text {
                id: nameLabel
                textFormat: Text.PlainText
                text: modelData.name
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.left: parent.left
                anchors.right: dateLabel.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
              }
              Text {
                id: dateLabel
                textFormat: Text.PlainText
                text: Model.formatDate(modelData.date) + " · " + Model.formatCountdown(modelData.date, new Date())
                color: Qt.darker(root.bar.foreground, 1.2)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---- Stack sats ---------------------------------------------------
        PanelSectionHeader { text: "STACK SATS" }

        // Vault setup — no password chosen yet.
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.hasVault && !root.unlocked

          Text {
            textFormat: Text.PlainText
            text: "Set a password to encrypt your holdings"
            color: Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: newPwField
            width: parent.width
            password: true
            placeholderText: "Password"
            text: root.pwInput
            foreground: root.bar.foreground
            onTextChanged: root.pwInput = text
            onAccepted: repeatPwField.forceActiveFocus()
            onActiveFocusChanged: root.vaultFieldFocus = activeFocus
          }
          TextField {
            id: repeatPwField
            width: parent.width
            password: true
            placeholderText: "Repeat password"
            text: root.pwInput2
            foreground: root.bar.foreground
            onTextChanged: root.pwInput2 = text
            onAccepted: root.createVault()
            onActiveFocusChanged: root.vaultFieldFocus = activeFocus
          }

          Text {
            textFormat: Text.PlainText
            visible: root.vaultError !== ""
            text: root.vaultError
            color: root.riskRed
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            text: "No recovery — a lost password means starting over"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            text: "Create"
            bordered: true
            focusable: true
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.createVault()
          }
        }

        // Locked — vault exists, waiting for the password.
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.hasVault && !root.unlocked

          TextField {
            id: unlockField
            width: parent.width
            visible: !root.resetConfirm
            password: true
            placeholderText: "Password"
            text: root.pwInput
            foreground: root.bar.foreground
            onTextChanged: root.pwInput = text
            onAccepted: root.unlockVault()
            onActiveFocusChanged: root.vaultFieldFocus = activeFocus
          }

          Text {
            textFormat: Text.PlainText
            visible: root.vaultError !== "" && !root.resetConfirm
            text: root.vaultError
            color: root.riskRed
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.space(6)
            visible: !root.resetConfirm

            Button {
              text: "Unlock"
              bordered: true
              focusable: true
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.unlockVault()
            }
            Button {
              text: "Forgot"
              bordered: true
              focusable: true
              foreground: Qt.darker(root.bar.foreground, 1.4)
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: { root.resetConfirm = true; root.vaultError = "" }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.resetConfirm
            text: "Delete all holdings and set a new password?"
            color: root.riskRed
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.space(6)
            visible: root.resetConfirm

            Button {
              text: "Cancel"
              bordered: true
              focusable: true
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.resetConfirm = false
            }
            Button {
              text: "Delete"
              bordered: true
              focusable: true
              foreground: root.riskRed
              background: Qt.rgba(root.riskRed.r, root.riskRed.g, root.riskRed.b, 0.22)
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.resetVault()
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(16)
          visible: root.unlocked && root.positions.length > 0

          Text {
            textFormat: Text.PlainText
            text: Model.formatBtc(root.stackTotalBtc) + " BTC"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            text: root.market ? Model.formatPrice(root.stackTotalBtc * root.market.price) : "—"
            color: Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.unlocked && root.positions.length === 0
          text: "No positions yet"
          color: Qt.darker(root.bar.foreground, 1.2)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.unlocked && root.positions.length > 0

          Repeater {
            model: root.positions

            Item {
              required property var modelData
              required property int index
              width: parent.width
              height: Math.max(amountLabel.implicitHeight, removeLabel.implicitHeight, editLabel.implicitHeight)

              readonly property var risk: Model.riskReport(modelData)

              Text {
                id: riskDot
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: parent.risk.level === "unknown" ? "✕" : "●"
                color: root.riskColor(parent.risk.level)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  id: riskHover
                  anchors.fill: parent
                  anchors.margins: Style.space(-3)
                  hoverEnabled: true
                }
                QQC.ToolTip {
                  visible: riskHover.containsMouse && riskDot.parent.risk.flags.length > 0
                  text: riskDot.parent.risk.flags.join("\n")
                  delay: 300
                }
              }

              Text {
                id: amountLabel
                textFormat: Text.PlainText
                anchors.left: riskDot.right
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: Model.formatBtc(modelData.amount) + " BTC · "
                  + (root.market ? Model.formatPrice(modelData.amount * root.market.price) : "—")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                textFormat: Text.PlainText
                anchors.left: amountLabel.right
                anchors.leftMargin: Style.space(6)
                anchors.right: editLabel.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: "· " + Model.custodyLabel(modelData)
                color: Qt.darker(root.bar.foreground, 1.2)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                id: editLabel
                textFormat: Text.PlainText
                anchors.right: removeLabel.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: "✎"
                color: root.editIndex === index
                  ? root.bar.foreground
                  : Qt.darker(root.bar.foreground, 1.2)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: Style.space(-4)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (root.editIndex === index) root.closeForm()
                    else { root.editPosition(index); Qt.callLater(amountField.forceActiveFocus) }
                  }
                }
              }
              Text {
                id: removeLabel
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "×"
                color: Qt.darker(root.bar.foreground, 1.2)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: Style.space(-4)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.removePosition(index)
                }
              }
            }
          }
        }

        Row {
          spacing: Style.space(6)
          visible: root.unlocked

          Button {
            text: root.editIndex >= 0 ? "− Cancel edit" : root.addOpen ? "− Close" : "+ Add position"
            bordered: true
            focusable: true
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: {
              if (root.addOpen) root.closeForm()
              else { root.addOpen = true; Qt.callLater(amountField.forceActiveFocus) }
            }
          }
          Button {
            text: "Lock"
            bordered: true
            focusable: true
            foreground: Qt.darker(root.bar.foreground, 1.4)
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.lockVault()
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.unlocked && root.addOpen

          TextField {
            id: amountField
            width: parent.width
            placeholderText: "BTC amount"
            text: root.newAmountText
            validator: RegularExpressionValidator { regularExpression: /^\d{0,8}(\.\d{0,8})?$/ }
            foreground: root.bar.foreground
            onTextChanged: root.newAmountText = text
            onAccepted: root.commitAddPosition()
            Keys.onEscapePressed: root.closeForm()

            onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
          }

          ButtonGroup {
            options: [{ value: "exchange", label: "Exchange" }, { value: "self", label: "Self-custody" }]
            value: root.newCustody
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onChanged: function(v) { root.newCustody = v }
          }

          ButtonGroup {
            visible: root.newCustody === "self"
            options: [{ value: "singlesig", label: "Single sig" }, { value: "singlesig_pp", label: "Single+PP" }, { value: "multisig", label: "Multisig" }]
            value: root.newSelfType
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onChanged: function(v) { root.newSelfType = v }
          }

          Row {
            visible: root.newCustody === "self" && root.newSelfType === "multisig"
            spacing: Style.space(6)

            NumberField {
              value: root.newMultisigM
              from: 1
              to: 15
              fieldWidth: Style.space(56)
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              onModified: function(v) { root.newMultisigM = v; if (root.newMultisigN < v) root.newMultisigN = v }
            }
            Text {
              text: "of"
              height: Style.spacing.controlHeight
              verticalAlignment: Text.AlignVCenter
              color: Qt.darker(root.bar.foreground, 1.2)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            NumberField {
              value: root.newMultisigN
              from: 1
              to: 15
              fieldWidth: Style.space(56)
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              onModified: function(v) { root.newMultisigN = v; if (root.newMultisigM > v) root.newMultisigM = v }
            }
          }

          ButtonGroup {
            visible: root.newCustody === "self"
            options: [{ value: "hot", label: "Hot" }, { value: "cold", label: "Cold" }]
            value: root.newWallet
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onChanged: function(v) { root.newWallet = v }
          }

          // Custody risk questions. Only the ones relevant to the selected
          // self-custody type are shown; unanswered rows are simply omitted
          // from the saved position and grade as unassessed.
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.newCustody === "self"

            RiskRow {
              visible: root.newSelfType !== "multisig"
              label: "Seed backup"
              options: [{ value: "no", label: "No", risk: "red" }, { value: "yes", label: "Yes", risk: "" }]
              value: root.newSeedBackup
              foreground: root.bar.foreground
              redColor: root.riskRed
              amberColor: root.riskAmber
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.newSeedBackup = v }
            }
            RiskRow {
              visible: root.newSelfType !== "multisig" && root.newSeedBackup === "yes"
              label: "Medium"
              options: [{ value: "paper", label: "Paper", risk: "amber" }, { value: "steel", label: "Steel", risk: "" }]
              value: root.newBackupMedium
              foreground: root.bar.foreground
              redColor: root.riskRed
              amberColor: root.riskAmber
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.newBackupMedium = v }
            }
            RiskRow {
              visible: root.newSelfType !== "multisig" && root.newSeedBackup === "yes"
              label: "Backup 2+ places"
              options: [{ value: "no", label: "No", risk: "red" }, { value: "yes", label: "Yes", risk: "" }]
              value: root.newGeoRedundant
              foreground: root.bar.foreground
              redColor: root.riskRed
              amberColor: root.riskAmber
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.newGeoRedundant = v }
            }

            RiskRow {
              visible: root.newSelfType === "singlesig_pp"
              label: "PP backup"
              options: [{ value: "none", label: "None", risk: "red" }, { value: "memorized", label: "Memorized", risk: "amber" }, { value: "written", label: "Written", risk: "" }]
              value: root.newPpBackup
              foreground: root.bar.foreground
              redColor: root.riskRed
              amberColor: root.riskAmber
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.newPpBackup = v }
            }
            RiskRow {
              visible: root.newSelfType === "singlesig_pp" && root.newPpBackup === "written"
              label: "PP kept apart"
              options: [{ value: "no", label: "No", risk: "red" }, { value: "yes", label: "Yes", risk: "" }]
              value: root.newPpSeparate
              foreground: root.bar.foreground
              redColor: root.riskRed
              amberColor: root.riskAmber
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.newPpSeparate = v }
            }

            RiskRow {
              visible: root.newSelfType === "multisig"
              label: "Descriptor backup"
              options: [{ value: "no", label: "No", risk: "red" }, { value: "yes", label: "Yes", risk: "" }]
              value: root.newDescriptorBackup
              foreground: root.bar.foreground
              redColor: root.riskRed
              amberColor: root.riskAmber
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.newDescriptorBackup = v }
            }
            RiskRow {
              visible: root.newSelfType === "multisig"
              label: "Seed backups"
              options: [{ value: "none", label: "None", risk: "red" }, { value: "some", label: "Some", risk: "amber" }, { value: "all", label: "All", risk: "" }]
              value: root.newSeedBackups
              foreground: root.bar.foreground
              redColor: root.riskRed
              amberColor: root.riskAmber
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.newSeedBackups = v }
            }
            RiskRow {
              visible: root.newSelfType === "multisig"
              label: "Keys 2+ places"
              options: [{ value: "no", label: "No", risk: "red" }, { value: "yes", label: "Yes", risk: "" }]
              value: root.newKeysGeo
              foreground: root.bar.foreground
              redColor: root.riskRed
              amberColor: root.riskAmber
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.newKeysGeo = v }
            }
            RiskRow {
              visible: root.newSelfType === "multisig"
              label: "HW vendors"
              options: [{ value: "same", label: "Same", risk: "amber" }, { value: "mixed", label: "Mixed", risk: "" }]
              value: root.newHwVendors
              foreground: root.bar.foreground
              redColor: root.riskRed
              amberColor: root.riskAmber
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.newHwVendors = v }
            }
            RiskRow {
              visible: root.newSelfType === "multisig"
              label: "Keyholders"
              options: [{ value: "solo", label: "Solo", risk: "" }, { value: "shared", label: "Shared", risk: "" }]
              value: root.newKeyholders
              foreground: root.bar.foreground
              redColor: root.riskRed
              amberColor: root.riskAmber
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.newKeyholders = v }
            }

            RiskRow {
              label: "Heir access"
              options: [{ value: "no", label: "No", risk: "amber" }, { value: "yes", label: "Yes", risk: "" }]
              value: root.newHeirAccess
              foreground: root.bar.foreground
              redColor: root.riskRed
              amberColor: root.riskAmber
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.newHeirAccess = v }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.newCustody !== "self"

            RiskRow {
              label: "2FA"
              options: [{ value: "none", label: "None", risk: "red" }, { value: "sms", label: "SMS", risk: "amber" }, { value: "app", label: "App/Key", risk: "" }]
              value: root.newExchange2fa
              foreground: root.bar.foreground
              redColor: root.riskRed
              amberColor: root.riskAmber
              fontFamily: root.bar.fontFamily
              onChanged: function(v) { root.newExchange2fa = v }
            }
          }

          Button {
            text: root.editIndex >= 0 ? "Save" : "Add"
            bordered: true
            focusable: true
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.commitAddPosition()
          }
        }
      }
    }
  }
}
