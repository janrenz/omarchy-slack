import QtQuick
import Quickshell.Networking
import Quickshell.Services.UPower
import Quickshell.Wayland

// Whether it is worth asking the server at all right now.
//
// A poll is never free. It is a token refresh, a round trip, and on a metered
// API it is part of a budget - and a plugin that polls on a fixed timer spends
// all of that while the laptop is locked in a bag with no network. The three
// things the compositor and the system bus already know are enough to stop:
//
//   away     nobody has touched the machine for `idleSeconds`. Inhibitors are
//            respected, so a full-screen video call - which holds one - counts
//            as being at the machine even with no input.
//   offline  NetworkManager says there is no connectivity. Only a flat "none"
//            counts: a captive portal or a limited link may still carry a
//            tenant's traffic, and guessing wrong here means a mailbox that
//            never refreshes.
//   battery  on battery the cadence is stretched rather than stopped, and
//            stretched further in the power-saver profile, because the user
//            asking the system for less power is asking us too.
//
// Slack's rate limits make this more than housekeeping here: a poll costs a
// search against a budget of roughly one conversations.history a minute, and
// spending it on a locked laptop is spending it on nobody.
//
// Both signals arrive late: for the first second or two of a shell's life
// UPower has no devices, NetworkManager reports Unknown connectivity, and
// `canCheckConnectivity` is false. Every default here therefore means "go
// ahead" - a gate that fails closed would swallow the first fetch after every
// shell start, which is the one fetch that fills an empty panel.
QtObject {
  id: root

  // How long without input counts as away. Zero switches the idle gate off.
  property int idleSeconds: 300
  property bool pauseWhenAway: true
  property bool pauseWhenOffline: true
  property bool slowOnBattery: true

  readonly property bool away: pauseWhenAway && idleSeconds > 0 && idle.isIdle
  readonly property bool offline: pauseWhenOffline
                                 && Networking.canCheckConnectivity
                                 && Networking.connectivity === NetworkConnectivity.None
  readonly property bool paused: away || offline

  // What to multiply a poll interval by. Whole numbers, so a mailbox asked for
  // every three minutes lands on six or nine rather than something unreadable
  // in a log.
  readonly property int intervalScale: {
    if (!slowOnBattery || !UPower.onBattery) return 1
    return PowerProfiles.profile === PowerProfile.PowerSaver ? 3 : 2
  }

  // For a host that wants to say why the panel is not moving. Empty when it is.
  readonly property string reason: {
    if (offline) return "offline"
    if (away) return "paused while you are away"
    return ""
  }

  // The monitor is only armed while the gate is meant to use it, so a plugin
  // that turns the idle gate off does not hold an idle-notification object for
  // no reason.
  property IdleMonitor idle: IdleMonitor {
    enabled: root.pauseWhenAway && root.idleSeconds > 0
    timeout: Math.max(60, root.idleSeconds)
    respectInhibitors: true
  }
}
