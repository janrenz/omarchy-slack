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
  //          [{ id, summary, body }].
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
      send(String(fresh.length) + " " + plural, lines.join("\n"))
      return
    }
    // Oldest first, so the newest is the one left on top of the stack.
    for (var f = fresh.length - 1; f >= 0; f--) send(fresh[f].summary, fresh[f].body)
  }

  // Queued rather than fired at once: one Process cannot run two commands, and
  // three arriving together is the ordinary case rather than the odd one.
  property var queue: []

  function send(summary, body) {
    var next = queue.slice()
    next.push({ summary: String(summary || ""), body: String(body || "") })
    queue = next
    pump()
  }

  function pump() {
    if (proc.running || queue.length === 0) return
    var item = queue[0]
    // Everything after -- is text. A subject line beginning with a dash is a
    // subject line, not an option.
    proc.command = ["notify-send", "-a", root.appName, "--", item.summary, item.body]
    proc.running = true
  }

  property Process proc: Process {
    running: false
    onExited: {
      root.queue = root.queue.slice(1)
      root.pump()
    }
  }
}
