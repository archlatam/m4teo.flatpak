// Pure parsing/filtering helpers for the flatpak bar widget.
//
// Every function here is a total function over a string: no shell, no state,
// no side effects. That keeps the QML side down to "run a command, hand the
// stdout to a parser" and makes each rule testable on its own with node.

// `flatpak list --columns=a,b` and `flatpak remote-ls --columns=a,b` are
// tab-separated, one ref per line, with no header. Older flatpak builds and
// the human-readable `flatpak list` still print a header row, so drop a first
// line whose cells match the requested column names.
function splitRows(raw) {
  var text = String(raw || "").replace(/\r/g, "")
  if (text === "") return []

  var lines = text.split("\n")
  while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()
  if (lines.length === 0) return []

  var first = lines[0].split("\t")
  if (first.length > 1 && /^(application|name|version|branch|origin|ref)$/i.test(first[0].trim())) {
    lines = lines.slice(1)
  }

  var rows = []
  for (var i = 0; i < lines.length; i++) {
    if (lines[i] === "") continue
    rows.push(lines[i].split("\t"))
  }
  return rows
}

function cell(row, index) {
  var value = row[index]
  return value === undefined ? "" : String(value).replace(/^\s+|\s+$/g, "")
}

// Installed apps, from one `flatpak list --app --columns=...` run in a single
// scope. `scope` is "user" or "system" and is stamped here rather than
// inferred later, because the same app id can be installed in both and the
// caller has to be able to tell the two rows apart.
function parseInstalled(raw, scope) {
  var rows = splitRows(raw)
  var apps = []

  for (var i = 0; i < rows.length; i++) {
    var id = cell(rows[i], 0)
    if (id === "") continue
    apps.push({
      id: id,
      name: cell(rows[i], 1) || id,
      version: cell(rows[i], 2),
      branch: cell(rows[i], 3),
      origin: cell(rows[i], 4),
      scope: String(scope || "system"),
      updated: false
    })
  }

  return apps
}

// Updates, from `flatpak remote-ls --updates --columns=application`. The rows
// are plain app ids, so the result is a lookup set the caller intersects with
// the installed list.
function parseUpdates(raw) {
  var rows = splitRows(raw)
  var out = {}

  for (var i = 0; i < rows.length; i++) {
    var id = cell(rows[i], 0)
    if (id === "") continue
    out[id] = true
  }

  return out
}

// A user-scope install shadows a system install of the same id for every
// purpose the panel has (the user can launch and update it without privileges),
// so collapse the two lists onto the id and keep the user row. User rows are
// absorbed first so their ids claim the slot, and they also lead the result:
// the apps a user chose to install privately are the ones they are looking for.
function mergeInstalled(userApps, systemApps) {
  var byId = {}
  var order = []

  function absorb(apps) {
    for (var i = 0; i < apps.length; i++) {
      var app = apps[i]
      if (app.id in byId) continue
      order.push(app.id)
      byId[app.id] = app
    }
  }

  absorb(userApps || [])
  absorb(systemApps || [])

  var out = []
  for (var i = 0; i < order.length; i++) out.push(byId[order[i]])
  return out
}

// The Flathub catalogue, from `flatpak remote-ls flathub --app
// --columns=application,name`. ~3.5k rows; parsed once and cached on the
// panel rather than refetched per keystroke.
function parseCatalog(raw) {
  var rows = splitRows(raw)
  var apps = []

  for (var i = 0; i < rows.length; i++) {
    var id = cell(rows[i], 0)
    if (id === "") continue
    apps.push({ id: id, name: cell(rows[i], 1) || id })
  }

  return apps
}

function normalizeQuery(query) {
  return String(query || "").replace(/^\s+|\s+$/g, "").toLowerCase()
}

// Rank a candidate against the already-tokenized query terms.
//
// Every term must match somewhere, so "spot player" narrows rather than
// widens. Within that, an app id hit is worth more than a display-name hit:
// the id is what a user copies out of a website or a bug report, so typing
// the tail of it should surface the app before a same-named lookalike.
function scoreApp(app, terms) {
  var id = app.id.toLowerCase()
  var name = app.name.toLowerCase()
  var score = 0

  for (var i = 0; i < terms.length; i++) {
    var term = terms[i]
    var idAt = id.indexOf(term)
    var nameAt = name.indexOf(term)

    if (idAt < 0 && nameAt < 0) return -1

    if (idAt === 0) score += 120
    else if (nameAt === 0) score += 100
    else if (idAt > 0) {
      // A match right after a dot or dash is the readable part of an id
      // (com.spotify.Client -> "client"), so it outranks a mid-word hit.
      score += id[idAt - 1] === "." || id[idAt - 1] === "-" ? 60 : 40
    } else {
      score += 30
    }
  }

  if (name === terms.join(" ")) score += 200
  if (id === terms.join(" ")) score += 200

  // Shorter names first among equally good matches: "Jan" before
  // "Janitor Something Professional".
  return score - name.length * 0.1
}

// Filter the catalogue down to what the user typed. An empty query returns
// the first `limit` entries unchanged, so the panel has something to show
// before the user types.
function filterApps(catalog, query, limit) {
  var max = limit === undefined ? 50 : limit
  var apps = catalog || []
  var text = normalizeQuery(query)

  if (text === "") return apps.slice(0, max)

  var terms = text.split(/\s+/)
  var scored = []

  for (var i = 0; i < apps.length; i++) {
    var score = scoreApp(apps[i], terms)
    if (score >= 0) scored.push({ app: apps[i], score: score })
  }

  scored.sort(function(a, b) { return b.score - a.score })
  var out = []
  for (var j = 0; j < scored.length && out.length < max; j++) out.push(scored[j].app)
  return out
}

// `flatpak remote-info` is a fixed-field block preceded by the appstream
// title line ("Spotify - Online music streaming service"). The field labels
// are translated, so callers must run this under LC_ALL=C — the title line
// and the two sizes we actually use stay stable either way, but the labels do
// not, and guessing a label per locale is how this silently returns nothing.
function parseRemoteInfo(raw) {
  var text = String(raw || "").replace(/\r/g, "")
  var out = { title: "", summary: "", downloadSize: "", installedSize: "", branch: "", runtime: "" }

  var lines = text.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (line === "") continue
    out.title = line
    // "<name> - <summary>". The name is already known from the catalogue, so
    // only the part after the first separator is worth keeping; an app whose
    // name contains a dash just yields a shorter summary.
    var dash = line.indexOf(" - ")
    if (dash > 0) out.summary = line.slice(dash + 3).replace(/^\s+|\s+$/g, "")
    break
  }

  function field(label) {
    var match = new RegExp("^\\s*" + label + ":\\s*(.+?)\\s*$", "im").exec(text)
    return match ? match[1] : ""
  }

  out.downloadSize = field("Download Size")
  out.installedSize = field("Installed Size")
  out.branch = field("Branch")
  out.runtime = field("Runtime")

  return out
}

// Flatpak's own size strings are localized ("9,8 MB"), so a human reading the
// panel may not parse them, but they are consistent enough to compare and to
// show verbatim. Only the ordering helper below needs to understand them.
function parseSize(value) {
  var match = /^\s*([0-9]+(?:[.,][0-9]+)?)\s*([kKmMgGtT]?)\s*[Bb]?\s*$/.exec(String(value || ""))
  if (!match) return 0

  var number = parseFloat(match[1].replace(",", "."))
  if (isNaN(number)) return 0

  var units = { "": 1, k: 1024, m: 1024 * 1024, g: 1024 * 1024 * 1024, t: 1024 * 1024 * 1024 * 1024 }
  return number * (units[match[2].toLowerCase()] || 1)
}

// A single status line for the bar pill: how many of the installed apps have
// an update waiting, and how many are installed in total.
function summaryText(installed) {
  var apps = installed || []
  if (apps.length === 0) return "No apps"

  var pending = 0
  for (var i = 0; i < apps.length; i++) if (apps[i].updated) pending++

  if (pending === 0) return apps.length + (apps.length === 1 ? " app" : " apps")
  return pending + " / " + apps.length + " updates"
}

// Single-quote a value for `bash -lc`.
//
// App ids and names arrive from flatpak output and are about to be pasted into
// a command line that the bar runs through a shell, so they are quoted rather
// than trusted. Everything is wrapped in single quotes and internal quotes are
// closed, escaped and reopened — the only byte a single-quoted bash string
// cannot carry is a single quote itself.
function shellQuote(value) {
  return "'" + String(value === undefined || value === null ? "" : value)
    .replace(/'/g, "'\\''") + "'"
}

// file:///a/b/c -> /a/b/c, for turning the script's own QML-resolved URL into
// something a shell can execute.
function urlToPath(url) {
  var text = String(url || "")
  if (text.indexOf("file://") !== 0) return text
  try {
    return decodeURIComponent(text.slice("file://".length))
  } catch (e) {
    return text.slice("file://".length)
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    splitRows: splitRows,
    parseInstalled: parseInstalled,
    parseUpdates: parseUpdates,
    parseCatalog: parseCatalog,
    mergeInstalled: mergeInstalled,
    filterApps: filterApps,
    parseRemoteInfo: parseRemoteInfo,
    parseSize: parseSize,
    summaryText: summaryText,
    shellQuote: shellQuote,
    urlToPath: urlToPath
  }
}
