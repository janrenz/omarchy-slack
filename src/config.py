#!/usr/bin/env python3
"""Read and write this plugin's widget entry in ~/.config/omarchy/shell.json.

The window is one per plugin while the bar widget owns the configuration, so
the window has no settings of its own - it reads and writes the widget's.

There is no shell-provided settings form to defer to: a manifest schema is
declared but nothing in the shell renders one for a third-party widget, so the
plugin brings its own. Writing is deliberately narrow - this widget is
allowMultiple: false, so there is exactly one entry, and anything else is
refused rather than guessed at. The file is rewritten through a temp file and
a rename, so a failed write cannot leave the shell without a config.
"""

import argparse
import json
import os
import stat
import sys

DEFAULT_SHELL_JSON = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "omarchy",
    "shell.json",
)
SECTIONS = ("left", "center", "right")


def out(payload):
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(0)


def fail(code, message):
    out({"ok": False, "error": {"code": code, "message": message}})


def list_widgets(args):
    try:
        with open(args.shell_json, "r", encoding="utf-8") as handle:
            config = json.load(handle)
    except OSError as error:
        fail("no_config", "Could not read %s: %s" % (args.shell_json, error))
    except ValueError as error:
        fail("bad_config", "%s is not valid JSON: %s" % (args.shell_json, error))

    layout = (config.get("bar") or {}).get("layout") or {}
    widgets = []
    for section in SECTIONS:
        entries = layout.get(section) or []
        if not isinstance(entries, list):
            continue
        for index, entry in enumerate(entries):
            if not isinstance(entry, dict) or entry.get("id") != args.plugin_id:
                continue
            widgets.append({
                "section": section,
                "index": index,
                "settings": {k: v for k, v in entry.items() if k != "id"},
            })
    out({"ok": True, "widgets": widgets})


def entries_for(config, plugin_id):
    """(section, index) for every layout entry belonging to this plugin."""
    layout = (config.get("bar") or {}).get("layout") or {}
    found = []
    for section in SECTIONS:
        rows = layout.get(section) or []
        if not isinstance(rows, list):
            continue
        for index, entry in enumerate(rows):
            if isinstance(entry, dict) and entry.get("id") == plugin_id:
                found.append((section, index))
    return found


def save_settings(args):
    """Apply a patch to this plugin's one widget entry.

    An empty string removes a key, so clearing a field in the form puts the
    plugin's own default back rather than pinning an empty value.
    """
    try:
        updates = json.loads(args.updates)
    except ValueError as error:
        fail("bad_json", "Could not parse --set: %s" % error)
    if not isinstance(updates, dict):
        fail("bad_json", "--set must be a JSON object")

    try:
        with open(args.shell_json, "r", encoding="utf-8") as handle:
            config = json.load(handle)
    except OSError as error:
        fail("no_config", "Could not read %s: %s" % (args.shell_json, error))
    except ValueError as error:
        fail("bad_config", "%s is not valid JSON: %s" % (args.shell_json, error))

    found = entries_for(config, args.plugin_id)
    if not found:
        fail("not_found", "This widget is not in the bar layout")
    if len(found) > 1:
        # allowMultiple is false, so this should not happen - and if it has,
        # writing to whichever came first would be a guess.
        fail("ambiguous", "There is more than one of this widget in the bar; "
                          "remove the spare before changing settings")

    section, index = found[0]
    entry = config["bar"]["layout"][section][index]
    for key, value in updates.items():
        if key == "id":
            continue
        if value == "":
            entry.pop(key, None)
        else:
            entry[key] = value

    directory = os.path.dirname(os.path.abspath(args.shell_json))
    tmp = args.shell_json + ".tmp"
    try:
        handle = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
                         stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(config, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
        os.replace(tmp, args.shell_json)
    except OSError as error:
        fail("write_failed", "Could not write %s: %s" % (args.shell_json, error))
    out({"ok": True, "settings": {k: v for k, v in entry.items() if k != "id"}})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-id", default="janrenz.omarchy.slack")
    parser.add_argument("--list", dest="listing", action="store_true",
                        help="print this plugin's widget entries")
    parser.add_argument("--set", dest="updates", default="",
                        help="keys to write into the entry, as JSON; \"\" removes a key")
    parser.add_argument("--shell-json", default=DEFAULT_SHELL_JSON)
    args = parser.parse_args()
    if args.updates:
        save_settings(args)
    elif args.listing:
        list_widgets(args)
    else:
        fail("bad_args", "Give either --list or --set")


if __name__ == "__main__":
    main()
