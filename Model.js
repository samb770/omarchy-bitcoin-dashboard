// Pure helpers: API response parsing, number/date formatting, and the
// Bitcoin holiday calendar. Kept free of QML types so it can be unit-reasoned
// about and reused between BarWidget.qml and Panel.qml.

// ---- parsing -------------------------------------------------------------

// CoinGecko /api/v3/coins/markets?vs_currency=usd&ids=bitcoin&price_change_percentage=7d
function parseMarket(raw) {
  try {
    var data = JSON.parse(String(raw || "[]"))
    var row = data && data[0]
    if (!row) return null
    return {
      price: Number(row.current_price),
      change24h: Number(row.price_change_percentage_24h),
      change7d: Number(row.price_change_percentage_7d_in_currency),
      marketCap: Number(row.market_cap),
      ath: Number(row.ath)
    }
  } catch (e) {
    return null
  }
}

// CoinGecko /api/v3/global
function parseDominance(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var pct = data && data.data && data.data.market_cap_percentage && data.data.market_cap_percentage.btc
    return isFinite(pct) ? Number(pct) : null
  } catch (e) {
    return null
  }
}

// mempool.space /api/blocks/tip/height — plain integer text.
function parseBlockHeight(raw) {
  var value = parseInt(String(raw || "").trim(), 10)
  return isFinite(value) ? value : null
}

// mempool.space /api/v1/mining/hashrate/3d -> { currentHashrate, currentDifficulty, ... }
function parseHashrate(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    var hps = Number(data.currentHashrate)
    return isFinite(hps) ? hps : null
  } catch (e) {
    return null
  }
}

// mempool.space /api/v1/difficulty-adjustment
function parseDifficultyAdjustment(raw) {
  try {
    var data = JSON.parse(String(raw || "{}"))
    return {
      progressPercent: Number(data.progressPercent),
      remainingBlocks: Number(data.remainingBlocks),
      difficultyChange: Number(data.difficultyChange),
      estimatedRetargetDate: Number(data.estimatedRetargetDate)
    }
  } catch (e) {
    return null
  }
}

// ---- formatting -----------------------------------------------------------

function thousands(n) {
  var s = String(Math.round(n))
  return s.replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

function formatPrice(n) {
  if (!isFinite(n)) return "—"
  return "$" + thousands(n)
}

function formatPercent(n) {
  if (!isFinite(n)) return "—"
  var sign = n > 0 ? "+" : ""
  return sign + n.toFixed(2) + "%"
}

function formatCompact(n) {
  if (!isFinite(n)) return "—"
  var abs = Math.abs(n)
  if (abs >= 1e12) return "$" + (n / 1e12).toFixed(2) + "T"
  if (abs >= 1e9) return "$" + (n / 1e9).toFixed(2) + "B"
  if (abs >= 1e6) return "$" + (n / 1e6).toFixed(2) + "M"
  return formatPrice(n)
}

function formatHashrate(hps) {
  if (!isFinite(hps)) return "—"
  return (hps / 1e18).toFixed(1) + " EH/s"
}

// Days (and hours below one day) until a future Date, English short form.
function formatCountdown(target, now) {
  var ms = target.getTime() - now.getTime()
  if (ms <= 0) return "today"
  var days = Math.floor(ms / 86400000)
  if (days >= 1) return "in " + days + (days === 1 ? " day" : " days")
  var hours = Math.max(1, Math.floor(ms / 3600000))
  return "in " + hours + (hours === 1 ? " hour" : " hours")
}

function formatDate(date) {
  return Qt.formatDate(date, "d. MMMM")
}

function formatDateWithYear(date) {
  return Qt.formatDate(date, "d. MMMM yyyy")
}

// ---- halving ---------------------------------------------------------------

var BLOCKS_PER_HALVING = 210000
var SECONDS_PER_BLOCK = 600

function nextHalving(height, now) {
  if (!isFinite(height)) return null
  var nextBlock = (Math.floor(height / BLOCKS_PER_HALVING) + 1) * BLOCKS_PER_HALVING
  var remaining = nextBlock - height
  var estimate = new Date(now.getTime() + remaining * SECONDS_PER_BLOCK * 1000)
  return { block: nextBlock, remainingBlocks: remaining, estimatedDate: estimate }
}

// ---- holiday calendar -------------------------------------------------------

// Fixed annual Bitcoin dates. Returns the next upcoming occurrence (this
// year if not yet passed, otherwise next year) for each, plus the dynamic
// halving entry when height is known.
function upcomingHolidays(now, height) {
  var fixed = [
    { name: "Genesis Block Day", month: 0, day: 3 },
    { name: "Pizza Day", month: 4, day: 22 },
    { name: "Whitepaper Day", month: 9, day: 31 },
    { name: "HODL Day", month: 11, day: 18 }
  ]

  var entries = fixed.map(function(h) {
    var year = now.getFullYear()
    var date = new Date(year, h.month, h.day)
    if (date.getTime() < stripTime(now).getTime()) date = new Date(year + 1, h.month, h.day)
    return { name: h.name, date: date }
  })

  var halving = nextHalving(height, now)
  if (halving) {
    entries.push({ name: "Halving (Block " + halving.block + ")", date: halving.estimatedDate })
  }

  entries.sort(function(a, b) { return a.date.getTime() - b.date.getTime() })
  // Show only the next 3 upcoming events. Since dates are always resolved
  // relative to `now` (rolling into next year once passed), the soonest
  // event drops off this list automatically once it's behind us, and the
  // next one in line takes its place.
  return entries.slice(0, 3)
}

function stripTime(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

// ---- stack sats ---------------------------------------------------------

// Trims a BTC amount to at most 8 decimals with no trailing zeros, e.g.
// 0.25000000 -> "0.25", 1.00000000 -> "1".
function formatBtc(n) {
  if (!isFinite(n)) return "0"
  var s = n.toFixed(8)
  s = s.replace(/0+$/, "").replace(/\.$/, "")
  return s === "" ? "0" : s
}

function sumBtc(positions) {
  var total = 0
  for (var i = 0; i < positions.length; i++) total += Number(positions[i].amount) || 0
  return total
}

// ---- vault (encrypted stack sats) ---------------------------------------

// Marker stored inside the ciphertext. openssl reports "bad decrypt" for a
// wrong password, but CBC padding validates by chance roughly 1 in 256, so
// the decrypted payload must also prove itself by carrying this magic.
var VAULT_MAGIC = "sam.bitcoin.vault.v1"

// Both scripts read the password as the first stdin line and the data as the
// second, so neither ever appears in argv (visible to any process via ps).
// The password reaches openssl through fd 3 rather than a temp file.
// The vault is attacked offline, not online: whoever copies shell.json gets
// unlimited guesses. PBKDF2 is not memory-hard, so the iteration count is the
// only brake — 1M costs ~0.4s per unlock here and ~35x more per guess than the
// 300k an interactive login would use.
var VAULT_ITERATIONS = 1000000

var vaultEncryptScript = [
  "set -eu",
  "IFS= read -r iter",
  "IFS= read -r pw",
  "IFS= read -r data",
  "case $iter in \'\'|*[!0-9]*) exit 2;; esac",
  "ct=$(printf '%s' \"$data\" | openssl enc -aes-256-cbc -md sha512 -pbkdf2 -iter \"$iter\" -salt -a -A -pass fd:3 3< <(printf '%s' \"$pw\"))",
  "[ -n \"$ct\" ] || exit 4",
  "printf '%s:%s' \"$(printf '%s' \"$ct\" | sha256sum | cut -d\" \" -f1)\" \"$ct\""
].join("\n")

// Exit 3 means the checksum failed, which is a corrupted vault rather than a
// wrong password. Checked before openssl runs so the two never get confused.
var vaultDecryptScript = [
  "set -eu",
  "IFS= read -r iter",
  "IFS= read -r sum",
  "IFS= read -r pw",
  "IFS= read -r data",
  "case $iter in \'\'|*[!0-9]*) exit 2;; esac",
  "[ \"$(printf '%s' \"$data\" | sha256sum | cut -d\" \" -f1)\" = \"$sum\" ] || exit 3",
  "printf '%s' \"$data\" | openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter \"$iter\" -a -A -pass fd:3 3< <(printf '%s' \"$pw\")"
].join("\n")

// Stored form is "<sha256 of ciphertext>:<base64 ciphertext>". The checksum is
// unkeyed and is not an authenticity guarantee — forgery is already infeasible
// because decryption cannot produce the magic without the key. What it buys is
// telling "this file was damaged" apart from "you mistyped", so a truncated or
// half-synced vault never gets mistaken for a forgotten password and deleted.
function vaultEnvelope(raw) {
  var text = String(raw || "").trim()
  var split = text.indexOf(":")
  if (split !== 64) return null
  var sum = text.substring(0, split)
  var body = text.substring(split + 1)
  if (!/^[0-9a-f]{64}$/.test(sum) || body === "") return null
  return { sum: sum, body: body }
}

// Reads this plugin's vault straight out of a raw shell.json. The panel is
// instantiated once per monitor and each copy caches its own settings, so the
// file is the only authoritative view of what the other copies have written.
function readVault(configText, moduleName) {
  try {
    var parsed = JSON.parse(String(configText || ""))
  } catch (e) {
    return null
  }
  var found = null
  var seen = []
  var walk = function (node) {
    if (found !== null || node === null || typeof node !== "object") return
    if (seen.indexOf(node) !== -1) return
    seen.push(node)
    if (!Array.isArray(node) && node.id === moduleName) {
      found = typeof node.vault === "string" ? node.vault : ""
      return
    }
    for (var key in node) walk(node[key])
  }
  walk(parsed)
  return found
}

var hardenScript = [
  "set -eu",
  "f=\"${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json\"",
  "[ -f \"$f\" ] && chmod 600 \"$f\""
].join("\n")

function vaultPayload(positions) {
  return JSON.stringify({ magic: VAULT_MAGIC, positions: positions || [] })
}

// Returns the positions array on success, or null if the password was wrong
// (garbage output, unparseable JSON, or a missing/incorrect magic).
function parseVault(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || data.magic !== VAULT_MAGIC) return null
    return Array.isArray(data.positions) ? data.positions : []
  } catch (e) {
    return null
  }
}

// ---- custody risk -------------------------------------------------------

// Answers a position must carry before it can be graded. Used to tell "the
// user answered and it's fine" apart from "never asked", so a position with
// gaps shows as unassessed rather than silently scoring green.
//
// The set depends on the answers already given, not only on the custody type:
// a follow-up made meaningless by an earlier answer must not be demanded
// ("is your backup in two places?" when there is no backup), and one unlocked
// by it must not be skipped (the backup medium was previously never required,
// so leaving it blank scored green).
function riskFields(p) {
  if (!p) return []
  if (p.custody !== "self") return ["exchange2fa"]

  var f = []
  if (p.selfType === "multisig") {
    f = ["descriptorBackup", "seedBackups", "keysGeo", "hwVendors"]
  } else {
    f = ["seedBackup"]
    if (p.seedBackup === "yes") f = f.concat(["backupMedium", "geoRedundant"])
    if (p.selfType === "singlesig_pp") {
      f.push("ppBackup")
      if (p.ppBackup === "written") f.push("ppSeparate")
    }
  }
  f.push("heirAccess")
  return f
}

// Grades a position's custody setup.
// Returns { level: "red"|"amber"|"green"|"unknown", flags: [string] }.
// Red flags are setups where a single failure loses the coins; amber flags
// are survivable weaknesses worth fixing.
function riskReport(p) {
  if (!p) return { level: "unknown", flags: [] }

  var required = riskFields(p)
  for (var i = 0; i < required.length; i++) {
    if (!p[required[i]]) return { level: "unknown", flags: ["Not assessed"] }
  }

  var red = []
  var amber = []

  if (p.custody !== "self") {
    if (p.exchange2fa === "none") red.push("No 2FA")
    else if (p.exchange2fa === "sms") amber.push("SMS 2FA — SIM-swappable")
    amber.push("Custodial — not your keys")
    if (red.length) return { level: "red", flags: red.concat(amber) }
    return { level: "amber", flags: amber }
  }

  if (p.selfType === "multisig") {
    var m = p.multisigM, n = p.multisigN
    // m === n means losing any one key loses the coins — the exact failure
    // multisig is bought to avoid. m === 1 means any one key spends alone.
    if (m >= n) red.push(m + "-of-" + n + " — no key-loss tolerance")
    else if (m === 1) amber.push("1-of-" + n + " — any key spends alone")
    if (p.descriptorBackup === "no") red.push("No descriptor backup")
    if (p.seedBackups === "none") red.push("No seed backups")
    else if (p.seedBackups === "some") amber.push("Partial seed backups")
    if (p.keysGeo === "no") red.push("Keys in one place")
    if (p.hwVendors === "same") amber.push("Single hardware vendor")
  } else {
    if (p.seedBackup === "no") red.push("No seed backup")
    else {
      if (p.backupMedium === "paper") amber.push("Paper backup")
      if (p.geoRedundant === "no") red.push("Backup in one place")
    }
    if (p.selfType === "singlesig_pp") {
      if (p.ppBackup === "none") red.push("No passphrase backup")
      else if (p.ppBackup === "memorized") amber.push("Passphrase memorized only")
      else if (p.ppSeparate === "no") red.push("Passphrase stored with seed")
    }
  }

  if (p.heirAccess === "no") amber.push("No heir access")
  if (p.wallet === "hot") amber.push("Hot wallet")

  if (red.length) return { level: "red", flags: red.concat(amber) }
  if (amber.length) return { level: "amber", flags: amber }
  return { level: "green", flags: [] }
}

// Compact one-line description of how a position is held, e.g.
// "Exchange" or "Self · Multisig 2/3 · Cold".
function custodyLabel(p) {
  if (p.custody !== "self") return "Exchange"
  var typeLabel = p.selfType === "multisig"
      ? ("Multisig " + p.multisigM + "/" + p.multisigN + (p.keyholders === "shared" ? " shared" : ""))
    : p.selfType === "singlesig_pp" ? "Single sig+PP"
    : "Single sig"
  var walletLabel = p.wallet === "cold" ? "Cold" : "Hot"
  return "Self · " + typeLabel + " · " + walletLabel
}
