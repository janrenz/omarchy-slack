import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The plugin's settings, in the window.
//
// The manifest declares a schema, and nothing in the shell renders one for a
// third-party widget - the only reference to it anywhere in the shell is the
// line that writes it into the registry. So the plugin brings its own form,
// the way the Teams and Office 365 plugins do.
//
// Edits are collected and written on Save rather than applied as they are
// typed: every keystroke in the workspace name would otherwise be a write to
// the file the whole shell reads, and a half-typed name would send the service
// off to poll as nobody.
//
// The token is the one thing on this page that is NOT a setting. It never goes
// near shell.json - that file is world-readable and holds the bar layout. It
// goes to slack.py over stdin and lives in a file only this user can read.
Column {
  id: root

  property var service: null

  // What has been changed but not yet saved.
  property var pending: ({})
  readonly property bool dirty: Object.keys(pending).length > 0

  signal closeRequested()

  spacing: Style.spacing.lg

  function current(key, fallback) {
    if (pending[key] !== undefined) return pending[key]
    if (!service) return fallback
    var value = service.settings ? service.settings[key] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function change(key, value) {
    var next = {}
    for (var k in pending) next[k] = pending[k]
    next[key] = value
    pending = next
  }

  function discard() {
    pending = ({})
    root.closeRequested()
  }

  function save() {
    if (!service || !dirty) { root.closeRequested(); return }
    if (service.saveSettings(pending)) awaitingSave = true
  }

  // A sign-in pressed before the name was saved, waiting for it. "" | "browser"
  // | "token".
  //
  // The two halves of this form read the workspace name from different places:
  // `current()` shows what has been typed, and the service derives `alias` -
  // and `configured` with it - from what is written in shell.json. So a name
  // typed into the box above and not saved is a name the sign-in cannot see,
  // and pressing Sign in went to a service that still knew no workspace. The
  // press now writes the name first and signs in when it comes back.
  property string signInAfter: ""
  // Whether the save the service is answering is this form's. `p` saves too,
  // through the same service, and its answer used to clear whatever had been
  // typed here and not saved yet, and close the form.
  property bool awaitingSave: false

  function signInNow(what) {
    if (!service) return
    if (pending["account"] === undefined) {
      if (what === "browser") service.signInWithBrowser()
      else service.signIn(root.tokenText)
      return
    }
    signInAfter = what
    if (service.saveSettings(pending)) awaitingSave = true
  }

  Connections {
    target: root.service
    // Cleared only once the write has actually landed, so a failed save keeps
    // what was typed rather than throwing it away and saying so.
    function onSettingsSaved() {
      if (!root.awaitingSave) return
      root.awaitingSave = false
      root.pending = ({})
      // A queued sign-in stays here rather than closing: the name still has to
      // be read back off the file before the service can see it, and this is
      // where the sign-in reports.
      if (root.signInAfter === "") root.closeRequested()
    }

    function onSavingChanged() {
      if (!root.service.saving && root.service.saveError !== "") root.awaitingSave = false
    }

    // The name has come back from the file. `configured` is derived from it, so
    // this is the first moment a queued sign-in can be anything but refused.
    function onConfiguredChanged() {
      if (root.signInAfter === "" || !root.service.configured) return
      var what = root.signInAfter
      root.signInAfter = ""
      if (what === "browser") root.service.signInWithBrowser()
      else root.service.signIn(root.tokenText)
      if (root.service.signingIn) {
        root.tokenText = ""
        tokenField.field.text = ""
      }
    }

    // A save that failed is never read back, so a sign-in waiting on one would
    // wait for good - and then fire on some later, unrelated save.
    function onSaveErrorChanged() {
      if (root.service.saveError !== "") root.signInAfter = ""
    }
  }

  // ---------------- the workspace ----------------

  PanelSectionHeader { width: parent.width; text: "Workspace" }

  LabeledField {
    width: parent.width
    label: "Workspace name"
    placeholder: "work"
    hint: "A short name for this sign-in. It names the token file on disk, not the Slack workspace. Letters, numbers, dot, dash and underscore."
    value: String(root.current("account", ""))
    onEdited: function(value) { root.change("account", value) }
  }

  // `signedIn` alone is too broad to gate this on: it is false for a workspace
  // nobody has ever signed into and equally false for the half-second after a
  // sign-in worked, while the first poll is still out - so the whole form went
  // on offering a sign-in to somebody who had just completed one.
  Column {
    width: parent.width
    spacing: Style.spacing.sm
    visible: !!root.service && !root.service.signedIn && !root.service.signedInWaiting

    Text {
      width: parent.width
      text: "Sign in through your browser: Slack asks which workspace and what this may "
            + "do, and hands the answer back to this machine. Nothing is pasted and no "
            + "app of your own is needed."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Row {
      spacing: Style.spacing.sm

      // Not disabled on a missing workspace name: the kit's Button draws a
      // disabled one exactly like a live one, so that read as a button that
      // does nothing rather than as a step still to do. It stays pressable and
      // the service says what is missing, under the buttons where every other
      // sign-in complaint already appears.
      Button {
        enabled: !!root.service && !root.service.signingIn
        text: root.service && root.service.browserSignIn ? "Waiting for Slack…" : "Sign in with Slack"
        bordered: true
        foreground: Color.accent
        fontFamily: Style.font.family
        fontSize: Style.font.caption
        onClicked: root.signInNow("browser")
      }

      Button {
        visible: !!root.service && root.service.browserSignIn
        text: "Cancel"
        bordered: true
        foreground: Color.foreground
        fontFamily: Style.font.family
        fontSize: Style.font.caption
        onClicked: if (root.service) root.service.cancelBrowserSignIn()
      }
    }

    LabeledField {
      width: parent.width
      label: "Slack app client id"
      placeholder: "optional"
      hint: "Leave empty to sign in through the app this plugin ships. Fill it in to use an app of your own instead - the client id is on its Basic Information page."
      value: String(root.current("clientId", ""))
      onEdited: function(value) { root.change("clientId", value) }
    }

    Text {
      width: parent.width
      text: "Or paste a token: create a Slack app for yourself, install it into your "
            + "workspace, and paste its User OAuth Token here. The plugin's README has "
            + "the manifest to paste in and the list of scopes."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    LabeledField {
      id: tokenField
      width: parent.width
      label: "User OAuth Token"
      placeholder: "xoxp-…"
      password: true
      hint: "Never written to shell.json. It goes straight to the helper and into a file only you can read."
      value: ""
      onEdited: function(value) { root.tokenText = value }
    }

    Row {
      spacing: Style.spacing.sm

      Button {
        enabled: !!root.service && !root.service.signingIn && root.tokenText.trim() !== ""
        text: root.service && root.service.signingIn ? "Checking…" : "Sign in"
        bordered: true
        foreground: Color.accent
        fontFamily: Style.font.family
        fontSize: Style.font.caption
        // Cleared only once the token is actually on its way to the helper,
        // for the same reason the settings are: a refusal that also emptied
        // the box would cost somebody the paste as well as the attempt.
        onClicked: {
          root.signInNow("token")
          if (root.service && root.service.signingIn) {
            root.tokenText = ""
            tokenField.field.text = ""
          }
        }
      }

      Button {
        text: "Open Slack's app page"
        tooltipText: "api.slack.com/apps - where the token is"
        bordered: true
        foreground: Color.foreground
        fontFamily: Style.font.family
        fontSize: Style.font.caption
        onClicked: if (root.service) root.service.openUrl("https://api.slack.com/apps")
      }
    }
  }

  // Held only until the button is pressed, and cleared the moment it is.
  property string tokenText: ""

  Row {
    spacing: Style.spacing.sm
    visible: !!root.service && root.service.signedIn

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.service
        ? ("Signed in to " + (root.service.view.team || "Slack")
           + " as " + (root.service.view.displayName || root.service.view.userName))
        : ""
      textFormat: Text.PlainText
      color: Qt.darker(Color.foreground, 1.4)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Button {
      text: "Sign out"
      tooltipText: "Forgets the token and everything cached about this workspace"
      bordered: true
      foreground: Color.foreground
      fontFamily: Style.font.family
      fontSize: Style.font.caption
      onClicked: if (root.service) root.service.signOut()
    }
  }

  Text {
    width: parent.width
    visible: !!root.service
             && (root.service.signInError !== "" || root.service.signInMessage !== "")
    text: root.service
      ? (root.service.signInError !== "" ? root.service.signInError : root.service.signInMessage)
      : ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.service && root.service.signInError !== "" ? Color.urgent
                                                           : Qt.darker(Color.foreground, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  // What this install did not get. Said as a list rather than as a surprise
  // later on: a token missing search:read is a search that cannot work, and
  // this is where somebody would go to find out why.
  Text {
    width: parent.width
    visible: !!root.service && root.service.signedIn && root.service.missingScopes.length > 0
    text: "Scopes this token does not have: "
          + (root.service ? root.service.missingScopes.join(", ") : "")
          + ". Add them to your Slack app, reinstall it, and paste the new token."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.darker(Color.foreground, 1.4)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  PanelSeparator { width: parent.width }

  // ---------------- what it shows ----------------

  PanelSectionHeader { width: parent.width; text: "Appearance" }

  Dropdown {
    width: Math.min(Style.space(260), parent.width)
    label: "Spacing"
    options: Model.densityNames()
    value: String(root.current("density", "cosy"))
    onValueChanged: if (value !== root.current("density", "cosy")) root.change("density", value)
  }

  Dropdown {
    width: Math.min(Style.space(260), parent.width)
    label: "Order the sidebar by"
    options: Model.sortNames()
    value: String(root.current("sort", "recent"))
    onValueChanged: if (value !== root.current("sort", "recent")) root.change("sort", value)
  }

  Toggle {
    width: parent.width
    label: "Show avatars"
    description: "Pictures are fetched by the helper, cached on disk, and never fetched by the window itself."
    checked: root.current("avatars", true) !== false
    onClicked: root.change("avatars", !(root.current("avatars", true) !== false))
  }

  Toggle {
    width: parent.width
    label: "Show who is around"
    description: "A dot on each direct message. Needs the users:read scope, and costs one request per person on screen - asked about the rows the sidebar is drawing, and kept for five minutes."
    checked: root.current("presence", true) !== false
    onClicked: root.change("presence", !(root.current("presence", true) !== false))
  }

  PanelSeparator { width: parent.width }

  // ---------------- what it fetches ----------------

  PanelSectionHeader { width: parent.width; text: "Keeping up" }

  NumberField {
    label: "Read-state checks per poll"
    from: 5
    to: 120
    stepSize: 5
    value: parseInt(String(root.current("conversations", 40)), 10) || 40
    onValueChanged: if (value !== parseInt(String(root.current("conversations", 40)), 10))
      root.change("conversations", value)
  }

  Text {
    width: parent.width
    text: "Slack allows an app that is not in its Marketplace one request a minute to read "
          + "a conversation, so this plugin never reads one to build the list: the previews "
          + "and what is new come from a single search across the whole workspace. This is "
          + "only the second half - how many conversations may then be asked how much of "
          + "them you have read."
          + (root.service && Model.coverageLabel(root.service.view) !== ""
             ? "  Right now: " + Model.coverageLabel(root.service.view) + "." : "")
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.darker(Color.foreground, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  NumberField {
    label: "Refresh every (seconds)"
    from: 30
    to: 3600
    stepSize: 30
    value: parseInt(String(root.current("refreshIntervalSec", 120)), 10) || 120
    onValueChanged: if (value !== parseInt(String(root.current("refreshIntervalSec", 120)), 10))
      root.change("refreshIntervalSec", value)
  }

  Toggle {
    width: parent.width
    label: "Stop polling while you are away"
    description: "A poll costs a search against Slack's rate limit whether or not anybody is at the machine. Nothing is asked of the server while the screen has been idle five minutes or the machine has no network, and a fetch goes out the moment you come back or reconnect. Anything you ask for by hand still goes out. On battery the interval is doubled, and tripled in the power-saver profile."
    checked: root.current("pausePolling", true) !== false
    onClicked: root.change("pausePolling", !(root.current("pausePolling", true) !== false))
  }

  // The same setting p flips from the dropdown and the window. Here too,
  // because a pause somebody has forgotten about is found in settings first.
  Toggle {
    width: parent.width
    label: "Pause fetching"
    description: "Nothing goes to Slack on its own until you switch this off again - no poll, no presence, no conversation following the list - whether or not you are at the machine. What was last fetched stays on screen and the bar icon dims. Refresh, r, opening a conversation and sending still go out. p does the same from the dropdown and the window."
    checked: root.current("paused", false) === true
    onClicked: root.change("paused", !(root.current("paused", false) === true))
  }

  PanelSeparator { width: parent.width }

  // ---------------- the bar ----------------

  PanelSectionHeader { width: parent.width; text: "In the bar" }

  LabeledField {
    width: Math.min(Style.space(260), parent.width)
    label: "Bar label"
    placeholder: "leave empty for the icon"
    hint: "Short text shown in the bar instead of the glyph."
    value: String(root.current("label", ""))
    onEdited: function(value) { root.change("label", value) }
  }

  Toggle {
    width: parent.width
    label: "Highlight the bar icon when something is unread"
    checked: root.current("tintOnUnread", true) !== false
    onClicked: root.change("tintOnUnread", !(root.current("tintOnUnread", true) !== false))
  }

  Toggle {
    width: parent.width
    label: "Show the unread count in the bar"
    description: "The number of conversations waiting, beside the icon."
    checked: root.current("showCount", false) === true
    onClicked: root.change("showCount", !(root.current("showCount", false) === true))
  }

  Toggle {
    width: parent.width
    label: "Notify when a message arrives"
    description: "A desktop notification per conversation with something new in it. What was already waiting when the shell started is not announced, and neither is anything you sent yourself."
    checked: root.current("notify", true) !== false
    onClicked: root.change("notify", !(root.current("notify", true) !== false))
  }

  Toggle {
    width: parent.width
    label: "Hand a conversation to your coding agent"
    description: "The a key and the Ask agent button, which open the agent you chose with `omarchy default agent` on the conversation you are reading. It is told which conversation to read and reads it through slack.py; no message text is put on a command line. Off also refuses a draft an agent tries to hand back."
    checked: root.current("agentHandover", true) !== false
    onClicked: root.change("agentHandover", !(root.current("agentHandover", true) !== false))
  }

  PanelSeparator { width: parent.width }

  // ---------------- saving ----------------

  Text {
    width: parent.width
    visible: !!root.service && root.service.saveError !== ""
    text: root.service ? root.service.saveError : ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Row {
    spacing: Style.spacing.sm

    Button {
      enabled: root.dirty && !(root.service && root.service.saving)
      text: root.service && root.service.saving ? "Saving…" : "Save"
      bordered: true
      foreground: root.dirty ? Color.accent : Qt.darker(Color.foreground, 1.6)
      fontFamily: Style.font.family
      fontSize: Style.font.caption
      onClicked: root.save()
    }

    Button {
      text: root.dirty ? "Discard" : "Close"
      bordered: true
      foreground: Color.foreground
      fontFamily: Style.font.family
      fontSize: Style.font.caption
      onClicked: root.discard()
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.dirty
      text: Object.keys(root.pending).length + " unsaved"
      textFormat: Text.PlainText
      color: Qt.darker(Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
