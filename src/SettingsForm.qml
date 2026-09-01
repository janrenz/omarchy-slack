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
    service.saveSettings(pending)
  }

  Connections {
    target: root.service
    // Cleared only once the write has actually landed, so a failed save keeps
    // what was typed rather than throwing it away and saying so.
    function onSettingsSaved() {
      root.pending = ({})
      root.closeRequested()
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

  Column {
    width: parent.width
    spacing: Style.spacing.sm
    visible: !!root.service && !root.service.signedIn

    Text {
      width: parent.width
      text: "Create a Slack app for yourself, install it into your workspace, and paste "
            + "its User OAuth Token here. The plugin's README has the manifest to paste "
            + "in and the list of scopes."
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
                 && String(root.current("account", "")).trim() !== ""
        text: root.service && root.service.signingIn ? "Checking…" : "Sign in"
        bordered: true
        foreground: Color.accent
        fontFamily: Style.font.family
        fontSize: Style.font.caption
        onClicked: {
          if (root.service) root.service.signIn(root.tokenText)
          root.tokenText = ""
          tokenField.field.text = ""
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
    visible: !!root.service && root.service.signInError !== ""
    text: root.service ? root.service.signInError : ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
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
    description: "A dot on each direct message. Needs the users:read scope, and costs one request per person in view."
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
