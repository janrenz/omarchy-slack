import QtQuick
import Quickshell.Io

// Desktop notifications for things that have just arrived.
//
// What counts as "just arrived" is decided here rather than by the helper,
// because it means "since this shell started watching" and not "since the
// account was last read". The first answer after a sign-in - or after a laptop
// wakes up to a morning of messages - is an entire backlog at once, and announcing
// all of it is exactly the behaviour that makes people turn notifications off
// for good. So the first round through a scope primes it silently, and only
// what turns up after that is announced.
//
// Scopes keep one workspace's first round from being taken as another's second:
// a service watching two of them primes each on its own.
QtObject {
  id: root

  property bool enabled: true
  // The sending application, as the notification will name it.
  property string appName: "Omarchy"
  // The Nerd Font glyph the toast is drawn with, so a stack of them is
  // readable at a glance. Omarchy's own toasts all carry one.
  property string glyph: ""
  // Argv that omarchy's notification service runs when the toast is clicked,
  // as [program, arg, ...]. The item's own `exec` wins over this; this is what
  // a digest ("4 new messages") uses, since a digest is about no single one.
  property var defaultExec: []
  // Past this many at once it is a digest rather than a stack. Twenty
  // notifications arriving together are twenty things to dismiss.
  property int maxAtOnce: 3
  // How a digest counts them: "4 new messages".
  property string plural: "new messages"

  // {scope: {id: true}} - what has been announced. Pruned every round to what
  // is still there, so it cannot grow without bound. Pruning is against
  // everything present, not just what was announceable, so a message going
  // from unread to read does not drop out of the set and get announced again
  // the moment the server is slow to agree it was read.
  property var known: ({})
  // {scope: true} - scopes that have had their silent first round.
  property var primed: ({})

  // A different account, or signed out. What was known belonged to the old
  // one, and the next round should prime rather than announce a whole workspace.
  function forget(scope) {
    if (scope === undefined) {
      known = ({})
      primed = ({})
      return
    }
    var nextKnown = {}
    for (var k in known) if (k !== scope) nextKnown[k] = known[k]
    var nextPrimed = {}
    for (var p in primed) if (p !== scope) nextPrimed[p] = primed[p]
    known = nextKnown
    primed = nextPrimed
  }

  // items:   what would be worth announcing, newest first, as
  //          [{ id, summary, body, exec, replaceKey }]. `exec` is the argv the
  //          toast runs when clicked and `replaceKey` groups toasts that
  //          should update in place instead of stacking - both optional.
  // present: every id in view including the ones not worth announcing, so the
  //          set can be pruned without forgetting them. Optional; the items
  //          themselves are used when it is left out.
  // silent: prime and record as usual, but say nothing. A scope whose
  // notifications are switched off still has to be watched, or switching them
  // back on would announce everything waiting as if it had just arrived.
  function observe(scope, items, present, silent) {
    var name = String(scope || "")
    var seen = known[name] || {}
    var ids = present || items.map(function(item) { return item.id })

    var next = {}
    for (var i = 0; i < ids.length; i++) {
      var id = String(ids[i] || "")
      if (id !== "") next[id] = true
    }
    var fresh = []
    for (var j = 0; j < items.length; j++) {
      var itemId = String(items[j].id || "")
      if (itemId === "" || seen[itemId]) continue
      next[itemId] = true
      fresh.push(items[j])
    }

    var wasPrimed = primed[name] === true
    var nextKnown = {}
    for (var k in known) nextKnown[k] = known[k]
    nextKnown[name] = next
    known = nextKnown
    if (!wasPrimed) {
      var nextPrimed = {}
      for (var p in primed) nextPrimed[p] = primed[p]
      nextPrimed[name] = true
      primed = nextPrimed
    }

    if (!enabled || silent === true || !wasPrimed || fresh.length === 0) return

    if (fresh.length > maxAtOnce) {
      var lines = []
      for (var l = 0; l < maxAtOnce; l++) lines.push(fresh[l].summary)
      lines.push("and " + String(fresh.length - maxAtOnce) + " more")
      // A digest replaces the scope's last digest rather than stacking beside
      // it: while a backlog lands in batches, "4 new messages" becoming "9 new
      // messages" is one thing to read, not two.
      send(String(fresh.length) + " " + plural, lines.join("\n"),
           defaultExec, name + "/digest")
      return
    }
    // Oldest first, so the newest is the one left on top of the stack.
    for (var f = fresh.length - 1; f >= 0; f--)
      send(fresh[f].summary, fresh[f].body, fresh[f].exec, fresh[f].replaceKey)
  }

  // Queued rather than fired at once: one Process cannot run two commands, and
  // three arriving together is the ordinary case rather than the odd one.
  property var queue: []

  // replaceKey -> the id the service gave that toast, so the next one for the
  // same key updates it in place. Ids are only worth keeping while the toast
  // may still be on screen, but a stale one is harmless: replacing a toast
  // that is already gone posts a new one.
  property var replaceIds: ({})

  function send(summary, body, exec, replaceKey) {
    var next = queue.slice()
    next.push({
      summary: String(summary || ""),
      body: String(body || ""),
      exec: Array.isArray(exec) ? exec : [],
      replaceKey: String(replaceKey || "")
    })
    queue = next
    pump()
  }

  // omarchy-notification-send takes the headline as the first positional, and
  // it has no `--` to end its options - so a subject line that is exactly one
  // of its flags would be read as that flag. Only an exact match can be, since
  // anything unrecognised ends option parsing, and a leading space is both
  // enough to stop it and invisible in the toast.
  readonly property var optionLike: ["-g", "--glyph", "-u", "--urgency", "--app-name",
                                     "-i", "--icon", "--image", "-r", "--replace-id",
                                     "-t", "--expire-time", "-p", "--print-id", "--exec"]

  function asText(value) {
    var text = String(value || "")
    if (optionLike.indexOf(text) !== -1) return " " + text
    if (text.indexOf("--") === 0 && text.indexOf("=") !== -1) return " " + text
    return text
  }

  function pump() {
    if (proc.running || queue.length === 0) return
    var item = queue[0]

    // omarchy's own sender rather than notify-send: it carries the glyph, and
    // it carries the click action as a hint (omarchy-exec-argv) rather than as
    // a live libnotify action, which is what makes the toast still clickable
    // after the shell has been restarted under it.
    var command = ["omarchy-notification-send", "--app-name", root.appName]
    if (root.glyph !== "") command = command.concat(["-g", root.glyph])
    // Not `known`: that is the announced-ids property, and shadowing it here
    // would read as this function touching it.
    var lastId = item.replaceKey !== "" ? root.replaceIds[item.replaceKey] : 0
    if (lastId > 0) command = command.concat(["-r", String(lastId)])
    // -p prints the id the service assigned, which is the only way to learn
    // what to pass to -r next time.
    if (item.replaceKey !== "") command.push("-p")
    command.push(asText(item.summary))
    command.push(asText(item.body))
    // Last, and as separate words: the sender refuses one quoted string, and
    // every word after --exec is one argument that is never re-parsed. A
    // subject inside it can therefore never become a command.
    if (item.exec.length > 0) {
      command.push("--exec")
      for (var i = 0; i < item.exec.length; i++) command.push(String(item.exec[i]))
    }
    proc.command = command
    proc.running = true
  }

  property Process proc: Process {
    running: false
    stdout: StdioCollector { id: sendOut; waitForEnd: true }
    onExited: function(exitCode) {
      var item = root.queue.length > 0 ? root.queue[0] : null
      if (item && item.replaceKey !== "" && exitCode === 0) {
        var id = parseInt(String(sendOut.text).trim(), 10)
        if (id > 0) {
          var next = ({})
          for (var k in root.replaceIds) next[k] = root.replaceIds[k]
          next[item.replaceKey] = id
          root.replaceIds = next
        }
      }
      // A failed send is the one place worth a word in the log: the toast is
      // the whole point of the round, and losing it silently looks like the
      // fetch having found nothing.
      if (exitCode !== 0 && item)
        console.warn("slack: could not post a notification:", item.summary)
      root.queue = root.queue.slice(1)
      root.pump()
    }
  }
}

