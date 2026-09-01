#!/usr/bin/env python3
"""Slack for the Omarchy shell: channels, DMs, threads, and answering them.

Everything that holds a token lives in this file. The QML above it never sees
one - it runs this and reads JSON, the same arrangement the Teams and Office
365 plugins use, and for the same reason: a shell process that renders other
people's messages should not also be the thing holding the credentials.

Standard library only.

There is no default client id and no OAuth redirect. Slack will not send a
browser back to a desktop that has no https address to be sent to, so the
sign-in is the one Slack itself offers for a personal integration: create an
app, install it into your workspace, and paste the user token. What the token
may do is read back off the API rather than assumed - every response carries an
`x-oauth-scopes` header naming what was actually granted - so the window can
say "this token cannot search" rather than offering a search that 403s.
See README.md.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import stat
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import emoji as emoji_table  # noqa: E402

API = "https://slack.com/api"
USER_AGENT = "omarchy-slack-plugin/1.0"

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "omarchy", "slack",
)
CACHE_DIR = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
    "omarchy", "slack",
)

# A sidebar nobody can read is not worth the requests it costs.
CONVERSATION_CAP = 120
# Listed separately, and capped separately, because one kind must not be able
# to crowd the other out. A single call for both types on an account with four
# hundred group DMs returned four hundred rows of which forty-two were the
# channels - and on the next such account the truncation would have taken the
# channels instead, silently, since there is nothing in the answer that says it
# was cut short.
CHANNEL_LIST_CAP = 300
DM_LIST_CAP = 800
# How many direct messages are worth drawing. An account that has been on Slack
# for years has hundreds of group DMs that were one conversation in 2023, and a
# sidebar is not an archive - the quick switcher reaches every one of them.
DM_ROWS = 30
LIST_CAP = 400
MESSAGE_CAP = 60
DIRECTORY_CAP = 2000
PRESENCE_CAP = 20
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
# Slack's own limits are per method and per minute; Tier 3 is fifty. Six at a
# time keeps a poll of twenty-five conversations under two seconds without
# ever having fifty in flight.
WORKERS = 6

# How long a name or a channel list is worth believing before it is read again.
USER_TTL = 7 * 24 * 3600
CHANNEL_TTL = 6 * 3600
# The sidebar's own list. Which channels you are in changes when you join one,
# which is a thing this plugin knows about and refreshes for - so between those
# moments it is worth believing for a while. Two paged calls cost a second and
# a fifth of every poll, for an answer that changes about weekly.
LIST_TTL = 15 * 60
# A finished snapshot, so a shell that has just started draws the sidebar it
# had rather than a blank one for the length of a poll. Also what keeps the bar
# and the window from being two pollers: whichever one is not the timekeeper
# reads what the other just wrote.
SNAPSHOT_MAX_AGE = 15 * 60

# What a token has to carry for each thing the window offers. Read from the
# API rather than from what was requested: an app can be installed with fewer
# scopes than its manifest asks for, and a feature that 403s on every click is
# worse than a feature that says why it is not there.
CAPABILITIES = {
    "read": ("channels:history", "groups:history", "im:history", "mpim:history"),
    "post": ("chat:write",),
    "react": ("reactions:write",),
    "seeReactions": ("reactions:read",),
    "markRead": ("channels:write", "groups:write", "im:write", "mpim:write"),
    "search": ("search:read",),
    "presence": ("users:read",),
    "openDm": ("im:write",),
    "join": ("channels:write",),
    "files": ("files:read",),
    "upload": ("files:write",),
    "people": ("users:read",),
}

# Everything a full install asks for, in the order the README lists them. Kept
# here so the README, the settings form and the error messages cannot drift
# apart - the window asks for this list rather than repeating it.
WANTED_SCOPES = [
    "channels:history", "channels:read", "channels:write",
    "groups:history", "groups:read", "groups:write",
    "im:history", "im:read", "im:write",
    "mpim:history", "mpim:read", "mpim:write",
    "chat:write", "reactions:read", "reactions:write",
    "users:read", "files:read", "files:write", "search:read", "emoji:read",
]


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------


def out(payload):
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(0)


def fail(code, message, **extra):
    out({"ok": False, "error": dict({"code": code, "message": message}, **extra)})


class AccountError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def alias_problem(alias):
    """Why this alias may not be used as a filename, or None."""
    if not alias:
        return "A workspace needs a name"
    if not re.match(r"^[A-Za-z0-9._-]{1,64}$", alias) or alias in (".", ".."):
        return "Workspace names may use letters, numbers, dot, dash and underscore only"
    return None


def state_path(alias):
    problem = alias_problem(alias)
    if problem:
        raise AccountError("bad_alias", problem)
    return os.path.join(STATE_DIR, alias + ".json")


def cache_path(alias, name):
    problem = alias_problem(alias)
    if problem:
        raise AccountError("bad_alias", problem)
    return os.path.join(CACHE_DIR, alias, name)


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def write_json(path, data, private=False):
    """Write a JSON file, atomically.

    `private` sets the mode on the temp file before anything is written into
    it, so there is never a moment where a token sits on disk world-readable.
    """
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    if private:
        os.chmod(directory, stat.S_IRWXU)
    tmp = path + ".tmp"
    mode = stat.S_IRUSR | stat.S_IWUSR if private else 0o644
    handle = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(handle, "w", encoding="utf-8") as stream:
        json.dump(data, stream)
    os.replace(tmp, path)


def read_capped(response, limit=MAX_RESPONSE_BYTES):
    """Read a response body, refusing one that will not fit in memory twice."""
    body = response.read(limit + 1)
    if len(body) > limit:
        raise AccountError("response_too_large", "Slack sent more than this plugin will read")
    return body


# --------------------------------------------------------------------------
# the Slack Web API
# --------------------------------------------------------------------------


class Slack:
    """One token's worth of Slack, and what that token turned out to be allowed.

    Shared between threads during a fetch: every method makes its own request
    and the only mutable state is the scope string, which every response
    repeats identically.
    """

    # A burst comes back 429 with a Retry-After, and whatever lost that race
    # quietly has no answer - so the calls are paced, and a refusal is retried
    # once at the moment Slack asked for. Paced rather than merely retried,
    # because a burst that is retried is still a burst.
    #
    # Per method, because that is how Slack counts: every method has its own
    # bucket and its own tier, so a queue shared between them makes each one
    # wait for the others' turns for no reason at all. Seven conversations.info
    # calls across six threads took 1.75s behind one global gate - seven times
    # the interval, exactly - where the requests themselves overlap in about
    # one. Measured: that endpoint answers ten calls a second without a
    # refusal, and history answers one a minute whatever anybody does.
    MIN_INTERVAL = 0.25
    METHOD_INTERVAL = {
        "conversations.info": 0.1,
        "users.getPresence": 0.1,
        "users.info": 0.1,
        # Restricted to one a minute for an app outside the Marketplace, and
        # only ever called one at a time - pacing buys nothing here, so this is
        # only a guard against firing the same request twice.
        "conversations.history": 0.4,
        "conversations.replies": 0.4,
    }
    MAX_BACKOFF = 8.0

    def __init__(self, token):
        self.token = str(token or "")
        self.scopes = ""
        self.rate_limited = False
        self._gate = threading.Lock()
        self._next_at = {}

    def _pace(self, method):
        """Wait until this method's turn. Held across threads."""
        with self._gate:
            now = time.monotonic()
            wait = self._next_at.get(method, 0.0) - now
            if wait > 0:
                # Inside the lock on purpose: the point is that the callers
                # take their turns rather than all sleeping the same wait and
                # then going at once.
                time.sleep(wait)
                now = time.monotonic()
            self._next_at[method] = now + self.METHOD_INTERVAL.get(method, self.MIN_INTERVAL)

    def call(self, method, params=None, timeout=20, retries=1):
        """(ok, payload). A refusal comes back as ok=False with Slack's own code."""
        self._pace(method)
        body = urllib.parse.urlencode(
            {k: v for k, v in (params or {}).items() if v not in (None, "")}).encode()
        request = urllib.request.Request(
            API + "/" + method,
            data=body,
            method="POST",
            headers={
                "User-Agent": USER_AGENT,
                "Authorization": "Bearer " + self.token,
                "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                self._remember_scopes(response)
                payload = json.loads(read_capped(response) or b"{}")
        except urllib.error.HTTPError as error:
            self._remember_scopes(error)
            if error.code == 429:
                # Slack says how long to wait, and it is usually a second or
                # two. Worth waiting for once - the alternative is a
                # conversation with no preview and no unread mark for the rest
                # of the interval. A long wait is not: the shell is polling on
                # a timer and the next poll will find it open again.
                try:
                    wait = float(error.headers.get("Retry-After", "") or 1)
                except (TypeError, ValueError):
                    wait = 1.0
                if retries > 0 and wait <= self.MAX_BACKOFF:
                    time.sleep(wait)
                    return self.call(method, params, timeout, retries - 1)
                self.rate_limited = True
                return False, {"error": "ratelimited", "retry_after": str(wait)}
            return False, {"error": "http_%d" % error.code}
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
            return False, {"error": "unreachable", "detail": str(error)}

        if not isinstance(payload, dict):
            return False, {"error": "bad_response"}
        return payload.get("ok") is True, payload

    def _remember_scopes(self, response):
        # Every response says what this token may do. Reading it here means a
        # user who reinstalls their app with one more scope gets the feature
        # at the next poll, without signing in again or being asked to.
        granted = ""
        try:
            granted = response.headers.get("x-oauth-scopes", "") or ""
        except AttributeError:
            granted = ""
        if granted:
            self.scopes = granted

    def paged(self, method, params, key, cap):
        """Every page of a cursor-paginated method, up to a cap."""
        rows = []
        cursor = ""
        problem = ""
        for _ in range(12):
            ok, payload = self.call(method, dict(params, cursor=cursor, limit=200))
            if not ok:
                problem = payload.get("error", "unknown")
                break
            rows.extend(payload.get(key) or [])
            cursor = ((payload.get("response_metadata") or {}).get("next_cursor") or "")
            if not cursor or len(rows) >= cap:
                break
        return rows[:cap], problem


# Slack answers some refusals with a code and nothing else. Passing that
# straight to the user tells them nothing they can act on.
PLAIN_ENGLISH = {
    "invalid_auth": "That token is not valid any more - paste a new one.",
    "not_authed": "No token yet. Paste one in settings.",
    "token_revoked": "That token has been revoked - install the app again and paste the new one.",
    "token_expired": "That token has expired - paste a new one.",
    "account_inactive": "That Slack account is deactivated.",
    "missing_scope": "This token was not given the permission that needs.",
    "not_allowed_token_type": "That is the wrong kind of token: this plugin wants the User OAuth token, the one starting xoxp.",
    "no_permission": "This token is not allowed to do that.",
    "channel_not_found": "That conversation is not there, or this token cannot see it.",
    "not_in_channel": "You are not in that channel - join it first.",
    "is_archived": "That channel is archived.",
    "msg_too_long": "That message is longer than Slack will take.",
    "rate_limited": "Slack is rate-limiting this token; it will catch up shortly.",
    "ratelimited": "Slack is rate-limiting this token; it will catch up shortly.",
    "unreachable": "Could not reach Slack.",
    "invalid_name": "Slack does not know that emoji.",
    "already_reacted": "You have already reacted with that.",
    "no_reaction": "That reaction was not yours to take off.",
    "user_not_found": "Slack does not know that person.",
    "cannot_dm_bot": "Slack will not open a DM with that app.",
    "restricted_action": "Your workspace does not allow that.",
    "fetch_members_failed": "Slack could not list who is in that conversation.",
}


def friendly(code, extra=""):
    """Slack's code as a sentence, with the code kept for anyone who wants it."""
    key = str(code or "").strip()
    known = PLAIN_ENGLISH.get(key.lower())
    if known:
        return known + (("  (%s)" % extra) if extra else "")
    return ("Slack said: %s" % key) if key else "Something went wrong"


def scope_error(needed):
    return "This token is missing %s. Add the scope to your Slack app, reinstall it, and paste the new token." % (
        " or ".join(needed))


# --------------------------------------------------------------------------
# the account
# --------------------------------------------------------------------------


def load_account(alias):
    account = read_json(state_path(alias))
    if not account or not account.get("token"):
        raise AccountError("auth_required", "Not signed in")
    return account


def granted(account, capability):
    """Whether this token carries any of the scopes that capability needs.

    Unknown means no. Offering something and failing on every click is worse
    than not offering it, and the window says which scope would fix it.
    """
    have = set(str((account or {}).get("scopes", "")).replace(" ", "").split(","))
    return any(scope in have for scope in CAPABILITIES.get(capability, ()))


def capability_flags(account):
    return {name: granted(account, name) for name in CAPABILITIES}


def missing_scopes(account):
    """The wanted scopes this install did not get, in the README's order."""
    have = set(str((account or {}).get("scopes", "")).replace(" ", "").split(","))
    return [scope for scope in WANTED_SCOPES if scope not in have]


def token_problem(token, scopes):
    """Why this token cannot be used for this, or "".

    Slack hands out four things that all look like tokens and only one of them
    is the one this wants, so the wrong one is the ordinary mistake rather than
    the odd one. Worse, `auth.test` accepts every one of them - it answers with
    the workspace and the user for a token that cannot read a single message -
    so a sign-in that only checked whether the token worked would report
    success and then fail on everything afterwards, which is exactly what it
    did. The scopes are what tell them apart, and every response carries them.
    """
    have = set(str(scopes or "").replace(" ", "").split(",")) - {""}
    text = str(token or "")

    if have & {"app_configurations:read", "app_configurations:write"}:
        return ("That is an App Configuration Token - the pair at the bottom of the Your Apps "
                "page, which exists to edit app manifests and can do nothing else. The one this "
                "needs is on your own app's page under OAuth & Permissions, after the app is "
                "installed to the workspace: User OAuth Token, starting xoxp-.")
    if text.startswith("xoxe."):
        return ("That token rotates, and this plugin cannot refresh it - it would stop working in "
                "twelve hours. Turn token rotation off in your app's settings, reinstall the app, "
                "and paste the User OAuth Token, which then starts xoxp-.")
    if text.startswith("xoxb-"):
        return ("That is the Bot User OAuth Token. This plugin reads the conversations you are in "
                "and posts as you, so it wants the User OAuth Token above it on the same page, "
                "starting xoxp-.")
    if have and not have & set(CAPABILITIES["read"]):
        return ("That token was granted no history scopes at all, so it cannot read a single "
                "conversation. It has: %s. Add the scopes from the plugin's README to your app, "
                "reinstall it, and paste the new token." % ", ".join(sorted(have)))
    return ""


def remember_scopes(alias, account, api):
    """Persist what the API said this token may do, when it has changed.

    Costs nothing - the scopes arrive on responses we already made - and means
    reinstalling the app with one more permission is picked up by the next
    poll rather than needing a new token pasted.
    """
    if not api.scopes or api.scopes == account.get("scopes"):
        return account
    account = dict(account, scopes=api.scopes)
    write_json(state_path(alias), account, private=True)
    return account


# --------------------------------------------------------------------------
# who people are
#
# Slack sends ids. A message is from U024BE7LH, a DM is with U024BE7LH, and a
# mention in the middle of a sentence is <@U024BE7LH>. Turning those into names
# is one request per person, so they are cached on disk for a week and only
# the ones nobody has heard of are ever asked about.
# --------------------------------------------------------------------------


def load_users(alias):
    data = read_json(cache_path(alias, "users.json"), None) or {}
    return data.get("users") or {}, float(data.get("listedAt") or 0)


def save_users(alias, users, listed_at=None):
    write_json(cache_path(alias, "users.json"),
               {"users": users, "listedAt": listed_at if listed_at is not None else 0})


def user_row(person):
    profile = person.get("profile") or {}
    display = (profile.get("display_name") or "").strip()
    real = (profile.get("real_name") or person.get("real_name") or "").strip()
    return {
        "id": person.get("id", ""),
        "name": display or real or person.get("name", "") or person.get("id", ""),
        "handle": person.get("name", ""),
        "real": real,
        "title": (profile.get("title") or "").strip(),
        "avatar": profile.get("image_72") or profile.get("image_48") or "",
        "bot": bool(person.get("is_bot")),
        "deleted": bool(person.get("deleted")),
        "at": time.time(),
    }


def resolve_users(api, alias, ids, users=None):
    """Names for a batch of ids: cache first, then one request each for the rest."""
    known = users if users is not None else load_users(alias)[0]
    wanted = [str(i) for i in dict.fromkeys(ids) if str(i or "")]
    stale = [i for i in wanted
             if i not in known or time.time() - float(known[i].get("at") or 0) > USER_TTL]

    if stale:
        def one(user_id):
            ok, payload = api.call("users.info", {"user": user_id})
            return user_id, (user_row(payload.get("user") or {}) if ok else None)

        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            for user_id, row in pool.map(one, stale[:PRESENCE_CAP * 4]):
                if row and row.get("id"):
                    known[user_id] = row
                elif user_id not in known:
                    # Deactivated, or in another workspace on a shared
                    # channel. Remembering the id as its own name keeps the
                    # transcript readable and stops it being asked for again
                    # on every poll.
                    known[user_id] = {"id": user_id, "name": user_id, "handle": "",
                                      "real": "", "title": "", "avatar": "",
                                      "bot": False, "deleted": True, "at": time.time()}
        save_users(alias, known)
    return known


def display_name(users, user_id, fallback=""):
    row = (users or {}).get(str(user_id or ""))
    if row and row.get("name"):
        return row["name"]
    return fallback or str(user_id or "")


# --------------------------------------------------------------------------
# what has been read
#
# Slack knows, but only per conversation: there is no one call that says what
# is unread across a workspace. conversations.info will say when this user last
# read a channel, so it is asked - but only about conversations whose newest
# message is newer than the answer we already have. Steady state is therefore
# one request per conversation for the preview and nothing else; something new
# arriving costs one more, once, until it is read.
# --------------------------------------------------------------------------


def load_marks(alias):
    data = read_json(cache_path(alias, "marks.json"), None) or {}
    return data.get("marks") or {}, data.get("seen") or {}


def save_marks(alias, marks, seen):
    # Bounded: a workspace can have thousands of conversations over the years
    # and this file is only worth what it saves on the next poll.
    write_json(cache_path(alias, "marks.json"),
               {"marks": dict(list(marks.items())[-500:]),
                "seen": dict(list(seen.items())[-500:])})


def newer(left, right):
    """Slack timestamps compare as numbers, not as strings.

    "1712345678.000200" against "999999999.000100" sorts the wrong way round
    as text, which is every message sent before September 2001 - and, more to
    the point, is the kind of comparison that silently stops working.
    """
    try:
        return float(left or 0) > float(right or 0)
    except (TypeError, ValueError):
        return str(left or "") > str(right or "")


# --------------------------------------------------------------------------
# pictures
#
# Avatars and inline images are fetched by this helper and never by the window.
# The token is attached for files.slack.com, which is the only host that needs
# it and the only one it may be sent to: an <img> in a message is written by
# whoever sent the message, and a crafted one must not be able to collect a
# token that can read this workspace.
# --------------------------------------------------------------------------

TOKEN_HOSTS = ("files.slack.com",)
# Where a file may be *sent*. Slack hands back an upload URL, and this is
# checked before the bytes go anywhere: the URL arrives in an API response
# rather than in a message, but it is still a host named by somebody else, and
# what would be posted to it is the user's own file.
UPLOAD_HOSTS = ("files.slack.com",)
# What this plugin will put in memory to send. Slack's own limit is a thousand
# times this; a shell plugin that reads a gigabyte into a Python string to hand
# it to a QML window is not a feature anybody asked for, and the error says so.
UPLOAD_CAP = 25 * 1024 * 1024
IMAGE_HOSTS = ("files.slack.com", "avatars.slack-edge.com", "a.slack-edge.com",
               "secure.gravatar.com", "ca.slack-edge.com", "emoji.slack-edge.com")
IMAGE_CAP = 12 * 1024 * 1024
MEDIA_DIR = os.path.join(CACHE_DIR, "media")
IMAGE_TYPES = {
    "image/png": ".png", "image/jpeg": ".jpg", "image/jpg": ".jpg",
    "image/gif": ".gif", "image/webp": ".webp", "image/bmp": ".bmp",
    "image/svg+xml": ".svg",
}


def media_path_for(url):
    return os.path.join(MEDIA_DIR, hashlib.sha256(
        str(url or "").encode("utf-8")).hexdigest()[:32])


def cached_media(url):
    """Where this picture already is, or ""."""
    base = media_path_for(url)
    for extension in set(IMAGE_TYPES.values()) | {".bin"}:
        path = base + extension
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return path
    return ""


def fetch_media(url, token, limit=IMAGE_CAP, timeout=30):
    """Download one picture, and say where it landed.

    The host is checked before the token is attached, and again before
    anything is fetched at all: a URL out of a message is not somewhere this
    plugin will go just because it was asked to.
    """
    parsed = urllib.parse.urlsplit(str(url or ""))
    if parsed.scheme != "https" or parsed.hostname not in IMAGE_HOSTS:
        raise AccountError("bad_image_host",
                           "Refusing to fetch an image from %s" % (parsed.hostname or "nowhere"))

    cached = cached_media(url)
    if cached:
        return cached, True

    headers = {"User-Agent": USER_AGENT}
    if parsed.hostname in TOKEN_HOSTS:
        headers["Authorization"] = "Bearer " + str(token or "")

    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read(limit + 1)
            if len(body) > limit:
                raise AccountError("image_too_large",
                                   "That image is larger than this plugin will read")
            content_type = response.headers.get("Content-Type", "").split(";")[0].strip().lower()
    except urllib.error.HTTPError as error:
        raise AccountError("image_failed", "Could not read that image (HTTP %d)" % error.code)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise AccountError("image_failed", "Could not read that image: %s" % error)

    if not content_type.startswith("image/"):
        # A token that has expired gets an HTML sign-in page rather than a
        # picture, with a perfectly cheerful 200 on it.
        raise AccountError("not_an_image",
                           "That link is %s, not an image" % (content_type or "of unknown type"))

    os.makedirs(MEDIA_DIR, exist_ok=True)
    path = media_path_for(url) + IMAGE_TYPES.get(content_type, ".bin")
    tmp = path + ".tmp"
    with open(tmp, "wb") as handle:
        handle.write(body)
    os.replace(tmp, path)
    return path, False


def cache_avatars(token, urls):
    """Make sure these avatars are on disk, and say where. {url: path}.

    Only the ones missing are fetched, so this costs nothing after the first
    poll, and a failure is silent: a missing picture is a row without a
    picture, not an error anybody needs to read.
    """
    wanted = [u for u in dict.fromkeys(urls) if u]
    found = {}
    missing = []
    for url in wanted:
        path = cached_media(url)
        if path:
            found[url] = path
        else:
            missing.append(url)

    def one(url):
        try:
            path, _ = fetch_media(url, token, timeout=10)
            return url, path
        except AccountError:
            return url, ""

    if missing:
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            for url, path in pool.map(one, missing[:40]):
                if path:
                    found[url] = path
    return found


# --------------------------------------------------------------------------
# what was said
#
# A Slack message is mrkdwn, which is not Markdown: links are `<url|words>`,
# a mention is `<@U024BE7LH>`, a channel is `<#C024BE7LK|general>` and an
# emoji is `:tada:`. None of it is HTML, and nothing here renders markup - the
# message comes out as the words in it, with the links kept as offsets into
# those words rather than as tags, so the side that draws them builds the only
# markup there is.
# --------------------------------------------------------------------------

# Where a link sat, carried through the substitutions so the offsets that come
# out are offsets into the finished text. These three are C0 controls: Slack
# does not send them, and anything arriving with one has it removed before this
# starts, so a message cannot forge a span of its own.
LINK_OPEN, LINK_SEP, LINK_CLOSE = "\x00", "\x01", "\x02"
LINK_MARKS = re.compile(r"[\x00\x01\x02]")

ENTITY = re.compile(r"<([^<>\n]{1,3000})>")

# Only somewhere to go, never something to run. A javascript: or data: link is
# left as the words it was.
LINK_SCHEMES = ("http://", "https://", "mailto:")

SYSTEM_SUBTYPES = {
    "channel_join", "channel_leave", "channel_topic", "channel_purpose",
    "channel_name", "channel_archive", "channel_unarchive", "group_join",
    "group_leave", "group_topic", "group_purpose", "group_name",
    "pinned_item", "unpinned_item", "bot_add", "bot_remove", "reminder_add",
    "channel_posting_permissions", "sh_room_created",
}


def decode_escapes(text):
    """Slack escapes exactly three characters. Put them back."""
    return (str(text or "").replace("&lt;", "<").replace("&gt;", ">")
            .replace("&amp;", "&"))


def readable(text):
    """A piece of prose as a reader should see it: escapes decoded, emoji drawn."""
    return emoji_table.expand(decode_escapes(text))


def safe_link(target):
    """The address to follow, or "" when it is not one to follow."""
    url = decode_escapes(str(target or "").strip())
    return url if url.lower().startswith(LINK_SCHEMES) else ""


def entity_text(inner, users, channels):
    """One `<...>` entity as the words it stands for.

    A link comes back marked so that its address survives the rest of the
    flattening as something other than words; everything else is words.
    """
    body = str(inner or "")
    target, _, label = body.partition("|")
    target = target.strip()

    if target.startswith("@"):
        # <@U024BE7LH> or <@U024BE7LH|handle>. The label is what the sender's
        # client wrote; the directory is fresher, so it wins.
        return "@" + display_name(users, target[1:], label or target[1:])
    if target.startswith("#"):
        # <#C024BE7LK|general>. The id after the hash is the channel.
        channel_id = target[1:]
        return "#" + (channels.get(channel_id) or label or channel_id)
    if target.startswith("!"):
        special = target[1:].lower()
        if special in ("here", "channel", "everyone"):
            return "@" + special
        if special.startswith("subteam^"):
            return label or "@group"
        if special.startswith("date^"):
            # <!date^1392734382^{date} at {time}|18 Feb 2014 at 06:39> - the
            # fallback after the pipe is already written out for exactly this.
            return label or ""
        return label or ""

    url = safe_link(target)
    if url:
        return LINK_OPEN + url + LINK_SEP + (label or target) + LINK_CLOSE
    # Not a scheme worth following - a bare <foo> somebody typed. The words,
    # then, and nothing that could be clicked.
    return label or target


def take_marks(text):
    """The marked-up text split back into finished prose and the spans in it.

    The prose goes through `readable` here, at the last moment, so the offsets
    are offsets into the string the window will actually draw - and so an
    address inside a mark is never mistaken for a shortcode and expanded.
    """
    parts = []
    links = []
    at = 0
    length = 0
    while True:
        start = text.find(LINK_OPEN, at)
        if start == -1:
            break
        separator = text.find(LINK_SEP, start)
        end = text.find(LINK_CLOSE, start)
        if separator == -1 or end == -1 or separator > end:
            # A mark without its partner: drop the mark, keep the words.
            prose = readable(text[at:start])
            parts.append(prose)
            length += len(prose)
            at = start + 1
            continue
        href = text[start + 1:separator]
        label = readable(text[separator + 1:end])
        prose = readable(text[at:start])
        parts.append(prose)
        length += len(prose)
        parts.append(label)
        if label and href:
            links.append({"href": href, "start": length, "end": length + len(label)})
        length += len(label)
        at = end + 1
    parts.append(readable(text[at:]))
    return "".join(parts), links


def text_and_links(raw, users=None, channels=None):
    """A message as text, and where the links in it are."""
    text = LINK_MARKS.sub("", str(raw or ""))
    text = ENTITY.sub(
        lambda match: entity_text(match.group(1), users or {}, channels or {}), text)
    text, links = take_marks(text)
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return text, links


def plain_text(raw, users=None, channels=None):
    """One line of a message: what a preview, a notification and the bar want."""
    return re.sub(r"\s+", " ", text_and_links(raw, users, channels)[0]).strip()


# ---- blocks --------------------------------------------------------------
#
# Half of what arrives in a busy workspace is written by an app, and an app
# writes blocks. Those messages carry a `text` fallback too, but it is often
# the empty string or "New build failed" where the blocks hold the build. So
# the blocks are flattened back into the mrkdwn the rest of this file already
# reads, rather than into finished text: one flattener, one set of rules about
# what becomes a link.


def rich_element(element):
    kind = element.get("type")
    if kind == "text":
        return str(element.get("text") or "")
    if kind == "link":
        url = str(element.get("url") or "")
        label = str(element.get("text") or "")
        return "<%s|%s>" % (url, label) if label else "<%s>" % url
    if kind == "user":
        return "<@%s>" % element.get("user_id", "")
    if kind == "channel":
        return "<#%s>" % element.get("channel_id", "")
    if kind == "usergroup":
        return "<!subteam^%s>" % element.get("usergroup_id", "")
    if kind == "broadcast":
        return "<!%s>" % element.get("range", "here")
    if kind == "emoji":
        return ":%s:" % element.get("name", "")
    return ""


def rich_section(section):
    kind = section.get("type")
    inner = "".join(rich_element(e) for e in (section.get("elements") or []))
    if kind == "rich_text_quote":
        return "> " + inner
    if kind == "rich_text_preformatted":
        return inner
    if kind == "rich_text_list":
        return inner
    return inner


def block_text(block):
    kind = block.get("type")
    if kind == "rich_text":
        parts = []
        for section in block.get("elements") or []:
            if section.get("type") == "rich_text_list":
                for item in section.get("elements") or []:
                    parts.append("• " + rich_section(item))
            else:
                parts.append(rich_section(section))
        return "\n".join(part for part in parts if part)
    if kind in ("section", "header"):
        parts = []
        if isinstance(block.get("text"), dict):
            parts.append(str(block["text"].get("text") or ""))
        for field in block.get("fields") or []:
            if isinstance(field, dict) and field.get("text"):
                parts.append(str(field["text"]))
        return "\n".join(part for part in parts if part)
    if kind == "context":
        parts = [str(e.get("text") or "") for e in (block.get("elements") or [])
                 if isinstance(e, dict) and e.get("type", "").endswith("text")]
        return "  ".join(part for part in parts if part)
    if kind == "image":
        return str(block.get("title", {}).get("text") or block.get("alt_text") or "")
    return ""


def blocks_text(blocks):
    parts = [block_text(block) for block in (blocks or []) if isinstance(block, dict)]
    return "\n".join(part for part in parts if part).strip()


def attachment_text(attachments):
    """What an attachment adds, which for a good many apps is the whole message."""
    lines = []
    for attachment in (attachments or [])[:5]:
        if not isinstance(attachment, dict):
            continue
        for key in ("pretext", "title", "text", "fallback"):
            value = str(attachment.get(key) or "").strip()
            if not value:
                continue
            if key == "title" and attachment.get("title_link"):
                value = "<%s|%s>" % (attachment["title_link"], value)
            if key == "fallback" and (attachment.get("text") or attachment.get("title")):
                continue
            lines.append(value)
        for field in (attachment.get("fields") or [])[:8]:
            if isinstance(field, dict) and (field.get("title") or field.get("value")):
                lines.append("%s: %s" % (field.get("title", ""), field.get("value", "")))
    return "\n".join(lines).strip()


def message_source(message):
    """The mrkdwn to read this message from, wherever the sender put it."""
    text = str(message.get("text") or "").strip()
    blocks = blocks_text(message.get("blocks"))
    extra = attachment_text(message.get("attachments"))
    # Blocks win when they say more than the fallback line does, which is the
    # usual shape: text "New pull request", blocks the pull request.
    body = blocks if len(blocks) > len(text) else text
    if extra and extra not in body:
        body = (body + "\n" + extra).strip() if body else extra
    return body


# ---- files ---------------------------------------------------------------


def file_rows(message):
    """The pictures and the attachments on a message, told apart.

    A picture is drawn in the transcript; anything else is a chip with a name
    on it, because a transcript is not a file manager.
    """
    images = []
    others = []
    for item in (message.get("files") or [])[:10]:
        if not isinstance(item, dict):
            continue
        name = str(item.get("title") or item.get("name") or "file")
        if item.get("mode") == "tombstone" or item.get("file_access") == "check_file_info":
            others.append({"name": name, "kind": "unavailable", "size": 0, "link": "",
                           "preview": "This file is not available to this token"})
            continue
        mimetype = str(item.get("mimetype") or "")
        if mimetype.startswith("image/") and not mimetype.endswith("svg+xml"):
            # The thumbnail rather than the original: a transcript of
            # photographs off a modern phone is otherwise fifty megabytes of
            # download to draw at 320 pixels wide.
            url = (item.get("thumb_720") or item.get("thumb_480")
                   or item.get("thumb_360") or item.get("url_private") or "")
            width = int(item.get("thumb_720_w") or item.get("original_w") or 0 or 0)
            height = int(item.get("thumb_720_h") or item.get("original_h") or 0 or 0)
            if url:
                images.append({"url": url, "alt": name, "width": width, "height": height})
                continue
        others.append({
            "name": name,
            "kind": str(item.get("pretty_type") or item.get("filetype") or "file"),
            "size": int(item.get("size") or 0),
            # The permalink, not url_private: opening a file in a browser
            # should land on the page Slack made for it, which is a page the
            # browser is already signed in to. url_private without the token
            # is a sign-in redirect and nothing else.
            "link": str(item.get("permalink") or ""),
            "preview": str(item.get("preview") or "")[:600],
        })
    return images, others


def reaction_rows(message, me_id):
    """A message's reactions, counted, with yours marked.

    That is what makes a chip a toggle rather than a label: clicking one you
    are part of takes yours off.
    """
    rows = []
    for reaction in (message.get("reactions") or [])[:24]:
        name = str(reaction.get("name") or "")
        if not name:
            continue
        rows.append({
            "name": name,
            # A workspace's own emoji is a picture living in that workspace,
            # and there is no character for it. The name is what a reader can
            # be given instead, which is what Slack's own clients fall back to.
            "emoji": emoji_table.char_for(name) or (":%s:" % name.split("::")[0]),
            "count": int(reaction.get("count") or 0),
            "mine": str(me_id or "") in [str(u) for u in (reaction.get("users") or [])],
        })
    rows.sort(key=lambda row: (-row["count"], row["name"]))
    return rows


def iso_from_ts(ts):
    """Slack's "1712345678.000200" as the ISO string the window formats."""
    try:
        return datetime.fromtimestamp(float(ts), timezone.utc).replace(
            microsecond=0).isoformat().replace("+00:00", "Z")
    except (TypeError, ValueError):
        return ""


def sender_of(message, users):
    """Who said it, and under which id, for a person or an app alike."""
    user_id = str(message.get("user") or "")
    if user_id:
        return display_name(users, user_id, user_id), user_id
    bot = message.get("bot_profile") or {}
    name = (str(message.get("username") or "").strip() or str(bot.get("name") or "").strip())
    bot_id = str(message.get("bot_id") or bot.get("id") or "")
    return (name or "App"), bot_id


def message_row(message, users, channels, me_id, avatars=None):
    text, links = text_and_links(message_source(message), users, channels)
    images, files = file_rows(message)
    name, sender_id = sender_of(message, users)
    subtype = str(message.get("subtype") or "")
    person = (users or {}).get(sender_id) or {}
    return {
        "id": str(message.get("ts") or ""),
        "ts": str(message.get("ts") or ""),
        "from": name,
        "fromId": sender_id,
        "avatar": (avatars or {}).get(person.get("avatar") or "", ""),
        "when": iso_from_ts(message.get("ts")),
        "text": text,
        # Where the links are, rather than the links themselves: the transcript
        # builds its anchors out of escaped text, so nothing a sender wrote can
        # arrive already being markup.
        "links": links,
        "edited": bool(message.get("edited")),
        "system": subtype in SYSTEM_SUBTYPES,
        "mine": bool(me_id) and sender_id == str(me_id),
        "images": images,
        "files": files,
        "reactions": reaction_rows(message, me_id),
        # A thread hangs off its first message. `thread_ts == ts` is the
        # parent; anything else with a thread_ts is a reply, which only shows
        # up in a channel at all when somebody ticked "also send to channel".
        "threadTs": str(message.get("thread_ts") or ""),
        "replyCount": int(message.get("reply_count") or 0),
        "replyUsers": int(message.get("reply_users_count") or 0),
        "latestReply": iso_from_ts(message.get("latest_reply")) if message.get("latest_reply") else "",
        "parent": bool(message.get("thread_ts")) and str(message.get("thread_ts")) == str(message.get("ts")),
        "pinned": bool(message.get("pinned_to")),
    }


# --------------------------------------------------------------------------
# conversations
# --------------------------------------------------------------------------

MPDM_NAME = re.compile(r"^mpdm-(.*?)-\d+$")


def mpim_title(name, users, me_handle=""):
    """"mpdm-jan--priya--dana-1" as the people in it, other than you.

    Their handles, not their display names: the handles are in the name Slack
    already sent, and asking who is in a group DM is one more request per group
    for something the row already says.

    You are dropped, the way a one-to-one is named after the other person -
    every group DM otherwise carries your own name in the middle of it, which
    is a third of the width of the row spent saying who is reading it.
    """
    match = MPDM_NAME.match(str(name or ""))
    if not match:
        return str(name or "group")
    mine = str(me_handle or "").lower()
    handles = [part for part in match.group(1).split("--") if part and part.lower() != mine]
    by_handle = {}
    for row in (users or {}).values():
        if row.get("handle"):
            by_handle[row["handle"]] = row.get("name") or row["handle"]
    names = [by_handle.get(handle, handle) for handle in handles]
    if len(names) <= 3:
        return ", ".join(names)
    return "%s and %d others" % (", ".join(names[:3]), len(names) - 3)


def conversation_row(conversation, users, me_handle=""):
    """One sidebar row, before it has a preview or an unread mark on it."""
    kind = ("im" if conversation.get("is_im")
            else "mpim" if conversation.get("is_mpim")
            else "channel")
    name = str(conversation.get("name") or "")
    if kind == "im":
        with_user = str(conversation.get("user") or "")
        person = (users or {}).get(with_user) or {}
        title = person.get("name") or with_user
        subtitle_when_quiet = person.get("title") or ""
    elif kind == "mpim":
        with_user = ""
        title = mpim_title(name, users, me_handle)
        subtitle_when_quiet = ""
    else:
        with_user = ""
        title = "#" + name
        subtitle_when_quiet = str((conversation.get("topic") or {}).get("value") or "")

    return {
        "id": str(conversation.get("id") or ""),
        "kind": kind,
        "name": name,
        "title": title,
        "private": bool(conversation.get("is_private")) and kind == "channel",
        "withUserId": with_user,
        "topic": str((conversation.get("topic") or {}).get("value") or ""),
        "purpose": str((conversation.get("purpose") or {}).get("value") or ""),
        "quiet": subtitle_when_quiet,
        "member": conversation.get("is_member") is not False,
        # Slack's own two hints, both arriving free with the list. `updated` is
        # not the last message - a channel here reads 2024 and had a message
        # this morning - so it is a tiebreaker and never a claim. `priority` is
        # Slack's own relevance score, and only IMs carry one.
        "updated": int(conversation.get("updated") or 0),
        "priority": float(conversation.get("priority") or 0),
        "lastFrom": "",
        "lastText": "",
        "when": "",
        "ts": "",
        "unread": False,
        "unreadCount": 0,
        "presence": None,
        "avatar": "",
        # Whether this row was given a preview and an unread mark this poll.
        # A row that was not is still perfectly openable; it just costs a
        # request nobody has spent yet, and says so rather than claiming to
        # have nothing new in it.
        "current": False,
    }


def by_interest(rows, seen):
    """Most likely to have something in it, first.

    What is actually known first: the last message this plugin saw, remembered
    from the previous poll. Then Slack's own hints, which are hints - `updated`
    moves for reasons that are not messages, and `priority` only exists on IMs.
    Then the name, so the order is stable between polls rather than shuffling.
    """
    def key(row):
        return (-float(seen.get(row["id"]) or 0),
                -int(row.get("updated") or 0),
                -float(row.get("priority") or 0),
                row["title"].lower())

    return sorted(rows, key=key)


def sort_rows(rows, prefer_recent):
    """The order the sidebar draws them in, within each section.

    By what was actually read from the conversation, and only then by Slack's
    own `updated` - a row with no preview has to sort somewhere, and putting
    every one of them in a block at the bottom in alphabetical order is what
    made the channels look like an appendix.
    """
    def when(row):
        try:
            return float(row.get("ts") or 0)
        except (TypeError, ValueError):
            return 0.0

    if prefer_recent:
        return sorted(rows, key=lambda row: (-when(row), -int(row.get("updated") or 0),
                                             row["title"].lower()))
    return sorted(rows, key=lambda row: row["title"].lower())


def channel_names(alias, rows):
    """{id: name} for turning <#C024BE7LK> into #general, cached for the transcript."""
    names = read_json(cache_path(alias, "channels.json"), None) or {}
    known = dict(names.get("names") or {})
    for row in rows:
        if row.get("name"):
            known[row["id"]] = row["name"]
    write_json(cache_path(alias, "channels.json"),
               {"names": dict(list(known.items())[-800:]),
                "listedAt": float(names.get("listedAt") or 0),
                "all": names.get("all") or []})
    return known


# --------------------------------------------------------------------------
# what has happened lately
#
# The hard constraint this plugin is shaped around: Slack limits
# conversations.history to ONE REQUEST A MINUTE for apps that are not in its
# Marketplace, which every app anybody makes for themselves is. Measured on a
# real workspace: after a minute of quiet, six calls five seconds apart came
# back one success and five refusals. A sidebar that asks each conversation
# what was said in it last is therefore not something that can be built - not
# slowly, not carefully, not at all.
#
# What is not limited is search. One search for everything since a date, sorted
# newest first, returns the last hundred messages across every conversation the
# user is in - with the channel, the author, the text and the timestamp on each
# one. That is the same information forty history calls would have produced,
# for one request, and it covers every conversation rather than the forty that
# fitted in a budget.
#
# So: search says what has happened, conversations.info says how much of it has
# been read, and conversations.history is spent only on what somebody opens.
# --------------------------------------------------------------------------

FEED_DAYS = 14
FEED_PAGES = 3
FEED_COUNT = 100


def activity_feed(api, days=FEED_DAYS, pages=FEED_PAGES):
    """The newest message in every conversation that has had one lately.

    ({channel id: newest match}, {channel id: [every ts seen]}, problem).

    The second one is what makes an unread count possible: Slack's own count is
    not in anything this token may read, but every recent message is in this
    answer, and the ones newer than the read mark are exactly the ones waiting.
    It undercounts a conversation with more unread messages than the search
    window holds, which is the right way round to be wrong.

    Search is date granular, so this asks for a fortnight and keeps the newest
    match per conversation; anything quieter than that keeps whatever preview
    was remembered from an earlier poll.
    """
    since = (datetime.now(timezone.utc).date() - timedelta(days=max(1, days))).isoformat()
    feed = {}
    stamps = {}
    problem = ""
    for page in range(1, max(1, pages) + 1):
        ok, payload = api.call("search.messages", {
            "query": "after:%s" % since,
            "count": str(FEED_COUNT), "page": str(page),
            "sort": "timestamp", "sort_dir": "desc", "highlight": "false",
        })
        if not ok:
            problem = payload.get("error", "")
            break
        messages = payload.get("messages") or {}
        matches = messages.get("matches") or []
        for match in matches:
            channel = match.get("channel") or {}
            channel_id = str(channel.get("id") or "")
            ts = str(match.get("ts") or "")
            if not channel_id or not ts:
                continue
            stamps.setdefault(channel_id, []).append(ts)
            if channel_id in feed and not newer(ts, feed[channel_id].get("ts")):
                continue
            feed[channel_id] = match
        paging = messages.get("paging") or {}
        if not matches or page >= int(paging.get("pages") or 1):
            break
    return feed, stamps, problem


def load_previews(alias):
    return (read_json(cache_path(alias, "previews.json"), None) or {}).get("previews") or {}


def save_previews(alias, previews):
    # Newest first, so the trim keeps what a sidebar would draw.
    ordered = sorted(previews.items(), key=lambda row: -float(row[1].get("ts") or 0))
    write_json(cache_path(alias, "previews.json"), {"previews": dict(ordered[:400])})


def conversation_lists(api, alias, fresh=False):
    """Every channel and every DM you are in, from disk when that is good enough.

    Two paged calls, and the answer changes about weekly - somebody joins a
    channel or opens a new DM. Both of those go through this plugin, which
    refreshes on the spot, so between them the list is worth believing.
    """
    cached = read_json(cache_path(alias, "list.json"), None) or {}
    age = time.time() - float(cached.get("at") or 0)
    if not fresh and cached.get("rows") and age < LIST_TTL:
        return list(cached["rows"]), ""

    channels, channel_problem = api.paged(
        "users.conversations",
        {"types": "public_channel,private_channel", "exclude_archived": "true"},
        "channels", CHANNEL_LIST_CAP)
    dms, dm_problem = api.paged(
        "users.conversations",
        {"types": "im,mpim", "exclude_archived": "true"},
        "channels", DM_LIST_CAP)
    problem = channel_problem or dm_problem
    rows = channels + dms
    if rows:
        write_json(cache_path(alias, "list.json"), {"rows": rows, "at": time.time()})
    elif cached.get("rows"):
        # A refusal is not an empty workspace. Keep what was there.
        return list(cached["rows"]), problem
    return rows, problem


def fetch_account(alias, args):
    account = load_account(alias)
    # A token stored before this check existed, or one whose app was changed
    # underneath it. auth_required rather than an error of its own, because the
    # way out is the same one: the window puts the token box back.
    problem = token_problem(account.get("token"), account.get("scopes"))
    if problem:
        raise AccountError("auth_required", problem)

    api = Slack(account["token"])
    warnings = []

    listed, problem = conversation_lists(api, alias, fresh=getattr(args, "fresh", False))
    account = remember_scopes(alias, account, api)
    listing_problem = problem
    if listing_problem and not listed:
        if listing_problem in ("invalid_auth", "not_authed", "token_revoked", "account_inactive"):
            raise AccountError("auth_required", friendly(listing_problem))
        # missing_scope here means the token is not the one this needs, which
        # only the scopes can say - and they arrived with that very refusal.
        unusable = token_problem(account.get("token"), api.scopes or account.get("scopes"))
        if unusable:
            raise AccountError("auth_required", unusable)
        if listing_problem == "missing_scope":
            raise AccountError("auth_required", scope_error(
                ["channels:read", "groups:read", "im:read", "mpim:read"]))
        raise AccountError("list_failed", friendly(listing_problem))
    if listing_problem:
        warnings.append({"scope": "conversations", "message": friendly(listing_problem)})

    me_id = str(account.get("userId") or "")
    users, _ = load_users(alias)
    users = resolve_users(
        api, alias,
        [c.get("user") for c in listed if c.get("is_im")] + [me_id],
        users)

    rows = [conversation_row(conversation, users, account.get("userName", ""))
            for conversation in listed]
    rows = [row for row in rows if row["id"]]
    names = channel_names(alias, rows)
    marks, seen = load_marks(alias)

    # ---- what has happened, in one request -------------------------------
    feed, stamps, feed_problem = ({}, {}, "not_asked")
    if granted(account, "search"):
        feed, stamps, feed_problem = activity_feed(api)
    if feed_problem == "missing_scope" or feed_problem == "not_asked":
        warnings.append({"scope": "search", "message":
                         "Without search:read this cannot see what has been said since it last "
                         "looked: Slack limits reading a conversation's history to one request a "
                         "minute for an app that is not in its Marketplace, so the previews and "
                         "unread marks come from one search instead. Add the scope, reinstall the "
                         "app, and paste the new token."})
    elif feed_problem:
        warnings.append({"scope": "search", "message": friendly(feed_problem)})

    previews = load_previews(alias)
    by_id = {row["id"]: row for row in rows}

    # Everybody who spoke, resolved in one batch rather than one at a time.
    users = resolve_users(
        api, alias,
        mentioned_ids(feed.values()) + [str(m.get("user") or "") for m in feed.values()],
        users)

    for channel_id, match in feed.items():
        row = by_id.get(channel_id)
        if row is None:
            # A conversation that is not in the sidebar - an archived channel,
            # or one left since. Nothing to attach it to.
            continue
        ts = str(match.get("ts") or "")
        who, who_id = sender_of(match, users)
        text = plain_text(message_source(match), users, names)[:160]
        previews[channel_id] = {
            "ts": ts,
            "from": "you" if who_id and who_id == me_id else who,
            "text": text,
            "at": time.time(),
        }

    # Everything else keeps whatever was remembered, so a conversation that
    # said nothing this week still reads as itself rather than going blank.
    covered = 0
    for row in rows:
        preview = previews.get(row["id"])
        if not preview:
            if row["quiet"]:
                row["lastText"] = row["quiet"]
            continue
        covered += 1
        row["ts"] = str(preview.get("ts") or "")
        row["when"] = iso_from_ts(row["ts"]) if row["ts"] else ""
        row["lastFrom"] = str(preview.get("from") or "")
        row["lastText"] = str(preview.get("text") or "") or row["quiet"]
        row["current"] = row["id"] in feed
        if row["ts"]:
            seen[row["id"]] = row["ts"]

    # ---- and how much of it has been read --------------------------------
    #
    # conversations.info is not restricted the way history is - measured at ten
    # calls a second without a refusal - and it carries last_read. It is asked
    # only about conversations whose newest message is newer than the mark
    # already held, which in a quiet hour is none of them.
    ask = [row for row in rows
           if row["ts"] and newer(row["ts"], marks.get(row["id"], "0"))
           and row["lastFrom"] != "you"]
    ask = by_interest(ask, seen)[:max(1, min(args.conversations, CONVERSATION_CAP))]

    def read_state(row):
        ok, payload = api.call("conversations.info", {"channel": row["id"]})
        if not ok:
            return row["id"], None, payload.get("error", "")
        return row["id"], (payload.get("channel") or {}), ""

    problems = []
    if ask:
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            for channel_id, info, error in pool.map(read_state, ask):
                row = by_id.get(channel_id)
                if row is None:
                    continue
                if error or info is None:
                    # No answer means no claim: the row keeps whatever the last
                    # poll knew rather than lighting up on a guess.
                    if error:
                        problems.append(error)
                    continue
                last_read = str(info.get("last_read") or "")
                if not last_read:
                    last_read = marks.get(channel_id, "0")
                else:
                    marks[channel_id] = last_read
                row["unread"] = newer(row["ts"], last_read)
                if row["unread"]:
                    # Counted out of the same search that found them, and never
                    # fewer than one: a conversation that is unread has at
                    # least the message that made it so.
                    waiting = [ts for ts in stamps.get(channel_id, [])
                               if newer(ts, last_read)]
                    row["unreadCount"] = max(1, len(waiting))

    # Nothing you said yourself is unread, whatever the timestamps say: Slack
    # moves the read mark for the sender a moment after the message lands, and
    # a poll in between should not light your own words up as waiting for you.
    for row in rows:
        if row["unread"] and row["lastFrom"] == "you":
            row["unread"] = False
            row["unreadCount"] = 0

    save_marks(alias, marks, seen)
    save_previews(alias, previews)

    # Who is around is NOT asked here. It is one request per person and it was
    # five of the nine seconds a poll took - all of it in front of the JSON,
    # for a dot beside a name. The window asks for it separately once the
    # sidebar is already on screen; see cmd_presence.

    # ---- faces -----------------------------------------------------------
    if args.avatars:
        wanted_avatars = []
        for row in rows:
            person = users.get(row["withUserId"]) if row["withUserId"] else None
            if person and person.get("avatar"):
                wanted_avatars.append(person["avatar"])
        paths = cache_avatars(account["token"], wanted_avatars)
        for row in rows:
            person = users.get(row["withUserId"]) if row["withUserId"] else None
            if person:
                row["avatar"] = paths.get(person.get("avatar") or "", "")

    if problems:
        warnings.append({"scope": "previews", "message": friendly(problems[0])})
    if api.rate_limited:
        warnings.append({"scope": "rate", "message": friendly("ratelimited")})

    # Every channel is listed: there are usually few enough of them to be a
    # list, and a channel you are in but cannot see is a channel you have lost.
    channel_rows = [row for row in rows if row["kind"] == "channel"]
    channels = sort_rows(channel_rows, args.sort != "name")

    # Direct messages are not a list. This account has four hundred of them,
    # most being one conversation somebody started in 2023, so the sidebar
    # shows the ones with something in them and says how many it did not draw.
    # The quick switcher reaches every one of them by name.
    dm_rows = by_interest([row for row in rows if row["kind"] in ("im", "mpim")], seen)
    dms = [row for row in dm_rows if row["ts"] or row["unread"]]
    if len(dms) < DM_ROWS:
        # Ones that were never asked about, in interest order, to fill the
        # sidebar out to something worth having: a poll that only covered ten
        # DMs should not leave the section with ten rows in it.
        seen_ids = {row["id"] for row in dms}
        for row in dm_rows:
            if len(dms) >= DM_ROWS:
                break
            if row["id"] not in seen_ids:
                dms.append(row)
    hidden_dms = max(0, len(dm_rows) - len(dms))
    dms = sort_rows(dms[:DM_ROWS], args.sort != "name")

    result = dict(capability_flags(account))
    result.update({
        "ok": True,
        "alias": alias,
        "team": account.get("team", ""),
        "teamId": account.get("teamId", ""),
        "url": account.get("url", ""),
        "userId": me_id,
        "userName": account.get("userName", ""),
        "displayName": account.get("displayName", ""),
        "dms": dms,
        "channels": channels,
        "unreadCount": sum(1 for row in rows if row["unread"]),
        "unreadMessages": sum(row["unreadCount"] for row in rows if row["unread"]),
        # How many rows have anything to say. Not a budget any more - the
        # search covers every conversation at once - so a row without a preview
        # means nothing was said in it lately, which needs no apology.
        "covered": covered,
        "total": len(rows),
        "coveredChannels": sum(1 for row in channel_rows if row["lastText"]),
        "totalChannels": len(channel_rows),
        "hiddenDms": hidden_dms,
        # Whether the one request everything hangs on actually answered.
        "feed": feed_problem == "",
        "checked": len(ask),
        "missingScopes": missing_scopes(account),
        "warnings": warnings,
    })
    return result


PRESENCE_TTL = 60


def cmd_presence(args):
    """Who is around, for the people the sidebar is currently drawing.

    A command of its own, because it costs one request per person and a poll
    that waits for it is a sidebar that waits for it. The window calls this
    once the conversations are already on screen, so the dots arrive a moment
    later on a list somebody is already reading.
    """
    if args.demo:
        out({"ok": True, "presence": {
            str(user): {"state": "active" if index % 2 == 0 else "away", "activity": ""}
            for index, user in enumerate(args.user or [])}})

    account = load_account(args.account)
    if not granted(account, "presence"):
        fail("permission_required", scope_error(["users:read"]))

    wanted = [str(u) for u in dict.fromkeys(args.user or []) if str(u or "")][:PRESENCE_CAP]
    if not wanted:
        out({"ok": True, "presence": {}})

    # Kept for a minute. Presence changes on the scale of somebody walking to
    # a meeting, and a poll every two minutes should not be asking twenty
    # people twice about the same minute.
    cached = read_json(cache_path(args.account, "presence.json"), None) or {}
    known = cached.get("presence") or {}
    now = time.time()
    stale = [user for user in wanted
             if now - float((known.get(user) or {}).get("at") or 0) > PRESENCE_TTL]

    api = Slack(account["token"])

    def ask(user_id):
        ok, payload = api.call("users.getPresence", {"user": user_id})
        if not ok:
            return user_id, None
        return user_id, {
            "state": "active" if payload.get("presence") == "active" else "away",
            "activity": "", "at": now,
        }

    if stale:
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            for user_id, state in pool.map(ask, stale):
                if state:
                    known[user_id] = state
        write_json(cache_path(args.account, "presence.json"),
                   {"presence": dict(list(known.items())[-200:])})

    out({"ok": True, "presence": {user: known[user] for user in wanted if user in known}})


def cmd_fetch(args):
    aliases = args.account or []
    snapshot = {
        "ok": True,
        "fetchedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "accounts": [],
    }
    if args.demo:
        snapshot["accounts"] = [demo_account(alias) for alias in (aliases or ["demo"])]
        out(snapshot)

    # Something already on disk, and recent enough to be worth handing over
    # rather than earning again. Three callers want this and want it
    # differently: a shell that has just started wants whatever there is so the
    # sidebar is not blank; the second of the two services - the bar and the
    # window each have one - wants what the first just wrote rather than asking
    # Slack the same question twice; and the poll itself passes zero and does
    # the work.
    max_age = max(0, min(int(getattr(args, "max_age", 0) or 0), SNAPSHOT_MAX_AGE))
    if max_age and len(aliases) == 1:
        cached = read_json(cache_path(aliases[0], "snapshot.json"), None)
        if cached and time.time() - float(cached.get("at") or 0) < max_age:
            payload = cached.get("snapshot") or {}
            payload["cached"] = True
            payload["age"] = int(time.time() - float(cached.get("at") or 0))
            out(payload)

    for alias in aliases:
        try:
            snapshot["accounts"].append(fetch_account(alias, args))
        except AccountError as error:
            snapshot["accounts"].append(
                {"ok": False, "alias": alias,
                 "error": {"code": error.code, "message": error.message}})

    # Only a snapshot worth waking up to. One that says "not signed in" would
    # otherwise be handed to the next caller as if it were news.
    if len(aliases) == 1 and snapshot["accounts"] and snapshot["accounts"][0].get("ok"):
        write_json(cache_path(aliases[0], "snapshot.json"),
                   {"snapshot": snapshot, "at": time.time()})
    out(snapshot)


# --------------------------------------------------------------------------
# one conversation
# --------------------------------------------------------------------------

MENTION = re.compile(r"<@([UWB][A-Z0-9]{2,})")


def mentioned_ids(messages):
    """Every person named inside these messages, so they can be resolved in one go."""
    found = []
    for message in messages:
        for match in MENTION.finditer(message_source(message)):
            found.append(match.group(1))
        if message.get("user"):
            found.append(str(message["user"]))
    return found


def transcript(api, alias, account, messages, want_avatars):
    """Raw Slack messages as rows the window can draw."""
    users = resolve_users(api, alias, mentioned_ids(messages), load_users(alias)[0])
    names = (read_json(cache_path(alias, "channels.json"), None) or {}).get("names") or {}
    me_id = str(account.get("userId") or "")

    avatars = {}
    if want_avatars:
        wanted = []
        for message in messages:
            person = users.get(str(message.get("user") or ""))
            if person and person.get("avatar"):
                wanted.append(person["avatar"])
        avatars = cache_avatars(account["token"], wanted)

    return [message_row(message, users, names, me_id, avatars) for message in messages]


def cmd_messages(args):
    if args.demo:
        out(demo_messages(args.channel, args.thread))

    account = load_account(args.account)
    api = Slack(account["token"])

    if args.thread:
        ok, payload = api.call("conversations.replies", {
            "channel": args.channel, "ts": args.thread,
            "limit": str(max(1, min(args.top, MESSAGE_CAP))),
        })
        messages = payload.get("messages") or []
    else:
        params = {"channel": args.channel, "limit": str(max(1, min(args.top, MESSAGE_CAP)))}
        if args.around:
            # Anchored at one message rather than at the end: what jumping to a
            # search result means. Everything before it, and it at the bottom.
            params["latest"] = args.around
            params["inclusive"] = "true"
        ok, payload = api.call("conversations.history", params)
        # History arrives newest first; a transcript reads the other way.
        messages = list(reversed(payload.get("messages") or []))

    account = remember_scopes(args.account, account, api)
    if not ok:
        code = payload.get("error", "")
        if code in ("invalid_auth", "not_authed", "token_revoked"):
            fail("auth_required", friendly(code))
        if code == "missing_scope":
            fail("permission_required", scope_error(CAPABILITIES["read"]))
        if code == "ratelimited":
            # The one limit worth explaining rather than reporting, because it
            # is not about this workspace or this token being wrong: Slack
            # allows an app that is not in its Marketplace one history request
            # a minute, with a small burst. Everything else this plugin does
            # avoids that endpoint; opening a conversation cannot.
            fail("rate_limited",
                 "Slack allows one request a minute for reading a conversation, for an app that "
                 "is not in its Marketplace - and this one is yours. A few in a row is fine, then "
                 "it makes you wait. Give it a moment and press r.")
        fail("messages_failed", friendly(code))

    rows = transcript(api, args.account, account, messages, args.avatars)
    out({
        "ok": True,
        "channel": args.channel,
        "thread": args.thread or "",
        "anchored": bool(args.around),
        "hasMore": bool(payload.get("has_more")),
        "messages": rows,
    })


def cmd_send(args):
    text = str(args.text or "")
    if args.stdin:
        text = str(read_stdin_json().get("text") or "")
    text = text.strip()
    if not text:
        fail("empty", "Nothing to send")

    # The empty check runs first so demo behaves like the real thing, and then
    # the message goes nowhere. Anything below this line would post to Slack.
    if args.demo:
        out({"ok": True, "ts": "demo-sent"})

    account = load_account(args.account)
    if not granted(account, "post"):
        fail("permission_required", scope_error(["chat:write"]))
    api = Slack(account["token"])

    # Slack escapes exactly three characters, and a message that does not
    # escape them can turn a stray `<` into somebody else's link.
    body = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    params = {"channel": args.channel, "text": body}
    if args.thread:
        params["thread_ts"] = args.thread
        if args.broadcast:
            params["reply_broadcast"] = "true"
    ok, payload = api.call("chat.postMessage", params)
    remember_scopes(args.account, account, api)
    if not ok:
        code = payload.get("error", "")
        if code in ("missing_scope", "not_allowed_token_type"):
            fail("permission_required", scope_error(["chat:write"]))
        fail("send_failed", friendly(code))
    out({"ok": True, "ts": str(payload.get("ts") or "")})


def read_upload(path):
    """The bytes to send, or a refusal a person can act on.

    A directory, a socket or a device is not a file to send even though it has
    a path, and a helpful error beats a traceback in a JSON field.
    """
    if not path:
        fail("no_file", "No file to send")
    if not os.path.isfile(path):
        fail("no_file", "There is no file at %s" % path)
    try:
        size = os.path.getsize(path)
    except OSError as error:
        fail("unreadable", "Could not read %s: %s" % (path, error))
    if size == 0:
        fail("empty_file", "That file is empty")
    if size > UPLOAD_CAP:
        fail("too_large", "That file is %.1f MB; this sends up to %d MB" % (
            size / 1048576.0, UPLOAD_CAP // 1048576))
    try:
        with open(path, "rb") as handle:
            return handle.read(UPLOAD_CAP + 1)
    except OSError as error:
        fail("unreadable", "Could not read %s: %s" % (path, error))


def post_upload(url, filename, body, timeout=120):
    """PUT the bytes where Slack said to put them.

    The URL comes back from files.getUploadURLExternal and carries its own
    authorisation, so no token is attached here - and the host is checked
    first, because this is the one request in the plugin that *sends* the
    user's data somewhere rather than reading somebody else's.
    """
    parsed = urllib.parse.urlsplit(str(url or ""))
    if parsed.scheme != "https" or parsed.hostname not in UPLOAD_HOSTS:
        fail("bad_upload_host",
             "Slack asked for the upload to go to %s, which this plugin will not do"
             % (parsed.hostname or "nowhere"))

    # multipart/form-data with one part named "file", which is what Slack's own
    # documented example posts. The boundary is random so it cannot appear in
    # the body by accident.
    boundary = "----omarchy" + hashlib.sha256(os.urandom(16)).hexdigest()[:24]
    head = ("--%s\r\n"
            'Content-Disposition: form-data; name="file"; filename="%s"\r\n'
            "Content-Type: application/octet-stream\r\n\r\n"
            % (boundary, filename.replace('"', "").replace("\r", "").replace("\n", "")))
    payload = head.encode("utf-8") + body + ("\r\n--%s--\r\n" % boundary).encode("utf-8")

    request = urllib.request.Request(url, data=payload, method="POST", headers={
        "User-Agent": USER_AGENT,
        "Content-Type": "multipart/form-data; boundary=" + boundary,
    })
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            # This endpoint answers in plain text ("OK - 1234"), not JSON, so
            # the status is the whole answer.
            read_capped(response)
            return 200 <= response.status < 300, ""
    except urllib.error.HTTPError as error:
        return False, "the upload was refused (HTTP %d)" % error.code
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return False, "the upload could not be sent: %s" % error


def cmd_upload(args):
    """Send a file into a conversation, in Slack's three steps.

    getUploadURLExternal reserves an id and a URL, the bytes go to that URL,
    and completeUploadExternal is what actually puts the file in the channel -
    until that third call the file exists and nobody can see it.
    """
    path = str(args.file or "")
    comment = str(args.comment or "")
    if args.stdin:
        payload = read_stdin_json()
        path = str(payload.get("file") or path)
        comment = str(payload.get("comment") or comment)
    path = os.path.expanduser(path.strip())
    title = str(args.title or "").strip() or os.path.basename(path)

    # Read and check the file before the demo bail-out, so demo refuses exactly
    # what the real thing would refuse. Anything below that line reaches Slack.
    body = read_upload(path)
    if args.demo:
        out({"ok": True, "id": "demo-file", "title": title, "bytes": len(body)})

    account = load_account(args.account)
    if not granted(account, "upload"):
        fail("permission_required", scope_error(["files:write"]))
    if comment and not granted(account, "post"):
        fail("permission_required", scope_error(["chat:write"]))
    api = Slack(account["token"])

    ok, reserved = api.call("files.getUploadURLExternal", {
        "filename": os.path.basename(path),
        "length": str(len(body)),
    })
    remember_scopes(args.account, account, api)
    if not ok:
        code = reserved.get("error", "")
        if code in ("missing_scope", "not_allowed_token_type"):
            fail("permission_required", scope_error(["files:write"]))
        fail("upload_failed", friendly(code))

    file_id = str(reserved.get("file_id") or "")
    url = str(reserved.get("upload_url") or "")
    if not file_id or not url:
        fail("upload_failed", "Slack did not say where to put that file")

    sent, problem = post_upload(url, os.path.basename(path), body)
    if not sent:
        fail("upload_failed", "Slack reserved a place for that file but %s" % problem)

    files = [{"id": file_id, "title": title}]
    params = {"files": json.dumps(files), "channel_id": args.channel}
    if args.thread:
        params["thread_ts"] = args.thread
    if comment:
        # Escaped the way a message is: a filename or a comment must not be
        # able to turn a stray < into somebody else's link.
        params["initial_comment"] = comment.replace("&", "&amp;").replace(
            "<", "&lt;").replace(">", "&gt;")
    ok, completed = api.call("files.completeUploadExternal", params)
    if not ok:
        code = completed.get("error", "")
        if code in ("missing_scope", "not_allowed_token_type"):
            fail("permission_required", scope_error(["files:write"]))
        # The bytes are on Slack's side but in no conversation. Say so: a
        # "failed" that leaves a file half-shared is worth being precise about.
        fail("upload_incomplete",
             "That file reached Slack but could not be posted: %s" % friendly(code))

    shared = (completed.get("files") or [{}])[0]
    out({"ok": True,
         "id": file_id,
         "title": title,
         "bytes": len(body),
         "permalink": str(shared.get("permalink") or "")})


def cmd_react(args):
    name = str(args.emoji or "").strip().strip(":")
    if not name:
        fail("bad_reaction", "No emoji to react with")
    if args.demo:
        out({"ok": True, "name": name, "removed": bool(args.remove)})

    account = load_account(args.account)
    if not granted(account, "react"):
        fail("permission_required", scope_error(["reactions:write"]))
    api = Slack(account["token"])
    ok, payload = api.call(
        "reactions.remove" if args.remove else "reactions.add",
        {"channel": args.channel, "timestamp": args.ts, "name": name})
    remember_scopes(args.account, account, api)
    if not ok:
        code = payload.get("error", "")
        # Both of these mean the chip is already the way it was asked to be,
        # which is not a failure worth putting in front of anybody: the
        # transcript is re-read afterwards and will show the truth.
        if code in ("already_reacted", "no_reaction"):
            out({"ok": True, "name": name, "removed": bool(args.remove), "noop": True})
        if code == "missing_scope":
            fail("permission_required", scope_error(["reactions:write"]))
        fail("react_failed", friendly(code))
    out({"ok": True, "name": name, "removed": bool(args.remove)})


def cmd_reactions(_args):
    """The reactions the picker offers."""
    out({"ok": True, "reactions": emoji_table.picker_rows()})


def cmd_mark_read(args):
    if args.demo:
        out({"ok": True, "channel": args.channel})

    account = load_account(args.account)
    marks, seen = load_marks(args.account)
    # Never backwards. conversations.mark takes whatever ts it is given, older
    # ones included - that is how Slack's own "mark unread" works - so a stale
    # ts from a poll that missed the newest message would light a conversation
    # up again instead of quieting it. The read mark only ever moves forward.
    ts = str(args.ts or "")
    held = str(marks.get(args.channel) or "")
    if held and not newer(ts, held):
        out({"ok": True, "channel": args.channel, "ts": held, "already": True})

    if not granted(account, "markRead"):
        # Remembered locally anyway. Without the scope Slack itself will not
        # be told, but this window at least stops telling its own user about a
        # message they have read in it.
        marks[args.channel] = ts
        save_marks(args.account, marks, seen)
        fail("mark_read_permission_required", scope_error(["channels:write", "im:write"]))

    api = Slack(account["token"])
    ok, payload = api.call("conversations.mark", {"channel": args.channel, "ts": ts})
    remember_scopes(args.account, account, api)
    if not ok:
        fail("mark_read_failed", friendly(payload.get("error", "")))
    marks[args.channel] = ts
    save_marks(args.account, marks, seen)
    out({"ok": True, "channel": args.channel, "ts": ts})


def cmd_open_dm(args):
    """Open (or reopen) a direct message with somebody."""
    if args.demo:
        out({"ok": True, "id": "demo-im-0", "title": "Priya Raman", "kind": "im"})

    account = load_account(args.account)
    if not granted(account, "openDm"):
        fail("permission_required", scope_error(["im:write"]))
    api = Slack(account["token"])
    ok, payload = api.call("conversations.open", {"users": ",".join(args.user), "return_im": "true"})
    remember_scopes(args.account, account, api)
    if not ok:
        fail("open_failed", friendly(payload.get("error", "")))
    channel = payload.get("channel") or {}
    users = resolve_users(api, args.account, args.user)
    title = (", ".join(display_name(users, user_id) for user_id in args.user)
             if args.user else "Direct message")
    out({"ok": True, "id": str(channel.get("id") or ""), "title": title,
         "kind": "im" if len(args.user) == 1 else "mpim"})


def cmd_join(args):
    """Join a public channel, which is what opening one you are not in means."""
    if args.demo:
        out({"ok": True, "id": args.channel, "title": "#general"})

    account = load_account(args.account)
    if not granted(account, "join"):
        fail("permission_required", scope_error(["channels:write"]))
    api = Slack(account["token"])
    ok, payload = api.call("conversations.join", {"channel": args.channel})
    remember_scopes(args.account, account, api)
    if not ok:
        fail("join_failed", friendly(payload.get("error", "")))
    channel = payload.get("channel") or {}
    out({"ok": True, "id": str(channel.get("id") or args.channel),
         "title": "#" + str(channel.get("name") or "")})


# --------------------------------------------------------------------------
# finding things
# --------------------------------------------------------------------------


def refresh_directory(api, alias, account):
    """The workspace's people and channels, cached so typing is not a round trip.

    The quick switcher filters as you type. Asking Slack on every keystroke
    would be both slow and rate-limited into uselessness, so the lists are
    pulled once, kept for a few hours, and searched here.
    """
    users, listed_at = load_users(alias)
    problems = []
    if time.time() - listed_at > USER_TTL and granted(account, "people"):
        rows, problem = api.paged("users.list", {}, "members", DIRECTORY_CAP)
        if problem:
            problems.append(problem)
        else:
            for person in rows:
                if person.get("id") and not person.get("deleted"):
                    users[str(person["id"])] = user_row(person)
            save_users(alias, users, time.time())

    cached = read_json(cache_path(alias, "channels.json"), None) or {}
    channels = cached.get("all") or []
    if time.time() - float(cached.get("listedAt") or 0) > CHANNEL_TTL:
        rows, problem = api.paged(
            "conversations.list",
            {"types": "public_channel,private_channel", "exclude_archived": "true"},
            "channels", LIST_CAP)
        if problem:
            problems.append(problem)
        else:
            channels = [{
                "id": str(row.get("id") or ""),
                "name": str(row.get("name") or ""),
                "private": bool(row.get("is_private")),
                "member": bool(row.get("is_member")),
                "topic": str((row.get("topic") or {}).get("value") or ""),
            } for row in rows if row.get("id")]
            names = dict(cached.get("names") or {})
            for row in channels:
                names[row["id"]] = row["name"]
            write_json(cache_path(alias, "channels.json"),
                       {"names": names, "all": channels, "listedAt": time.time()})
    return users, channels, problems


def cmd_directory(args):
    """People and channels matching what has been typed so far."""
    if args.demo:
        out({"ok": True, "people": [
            {"id": "demo-p1", "name": "Priya Raman", "handle": "priya",
             "title": "Platform", "kind": "person"},
            {"id": "demo-p2", "name": "Dana Okafor", "handle": "dana",
             "title": "Design", "kind": "person"},
        ], "channels": [
            # The same ids the conversation list uses, because that is what
            # Slack does: one channel has one id in every answer, and the
            # switcher folds the two lists together on it.
            {"id": "demo-channel-3", "name": "general", "private": False,
             "member": True, "kind": "channel"},
            {"id": "demo-c9", "name": "incidents", "private": False,
             "member": False, "kind": "channel", "topic": "When something is on fire"},
        ]})

    account = load_account(args.account)
    api = Slack(account["token"])
    users, channels, problems = refresh_directory(api, args.account, account)
    remember_scopes(args.account, account, api)

    query = str(args.query or "").strip().lower().lstrip("#@")
    def matches(*fields):
        if not query:
            return True
        return any(query in str(field or "").lower() for field in fields)

    people = [{
        "id": row["id"], "name": row.get("name", ""), "handle": row.get("handle", ""),
        "title": row.get("title", ""), "kind": "person",
    } for row in users.values()
        if not row.get("deleted") and not row.get("bot")
        and matches(row.get("name"), row.get("handle"), row.get("real"))]
    people.sort(key=lambda row: (0 if row["name"].lower().startswith(query) else 1,
                                 row["name"].lower()))

    found_channels = [{
        "id": row["id"], "name": row["name"], "private": row.get("private", False),
        "member": row.get("member", False), "topic": row.get("topic", ""), "kind": "channel",
    } for row in channels if matches(row.get("name"), row.get("topic"))]
    found_channels.sort(key=lambda row: (0 if row["member"] else 1,
                                         0 if row["name"].lower().startswith(query) else 1,
                                         row["name"].lower()))

    out({"ok": True, "people": people[:25], "channels": found_channels[:25],
         "warning": friendly(problems[0]) if problems else ""})


def cmd_search(args):
    """Slack's own message search, which is the one thing polling cannot do."""
    if args.demo:
        out({"ok": True, "matches": [{
            "channel": "demo-channel-0", "channelName": "#platform", "from": "Tomás Lindqvist",
            "text": "Rolling back the 14:02 release.", "ts": "1712345678.000100",
            "when": iso_from_ts(time.time() - 3600), "permalink": "", "links": [],
        }]})

    query = str(args.query or "").strip()
    if not query:
        fail("empty_query", "Type something to search for")

    account = load_account(args.account)
    if not granted(account, "search"):
        fail("permission_required", scope_error(["search:read"]))
    api = Slack(account["token"])
    ok, payload = api.call("search.messages", {
        "query": query, "count": str(max(1, min(args.top, 40))),
        "sort": "timestamp", "sort_dir": "desc", "highlight": "false",
    })
    remember_scopes(args.account, account, api)
    if not ok:
        code = payload.get("error", "")
        if code in ("missing_scope", "not_allowed_token_type"):
            fail("permission_required", scope_error(["search:read"]))
        fail("search_failed", friendly(code))

    matches = ((payload.get("messages") or {}).get("matches") or [])
    users = resolve_users(api, args.account, mentioned_ids(matches), load_users(args.account)[0])
    names = (read_json(cache_path(args.account, "channels.json"), None) or {}).get("names") or {}

    rows = []
    for match in matches:
        channel = match.get("channel") or {}
        text, links = text_and_links(message_source(match), users, names)
        who, who_id = sender_of(match, users)
        rows.append({
            "channel": str(channel.get("id") or ""),
            "channelName": ("#" + str(channel.get("name") or "")) if channel.get("name")
                           else display_name(users, str(channel.get("user") or ""), "direct message"),
            "kind": "im" if channel.get("is_im") else "channel",
            "from": who,
            "fromId": who_id,
            "text": text,
            "links": links,
            "ts": str(match.get("ts") or ""),
            "when": iso_from_ts(match.get("ts")),
            "permalink": str(match.get("permalink") or ""),
        })
    out({"ok": True, "matches": rows, "total": int(
        (payload.get("messages") or {}).get("total") or len(rows))})


def cmd_image(args):
    """Download one picture and report where it landed."""
    account = load_account(args.account)
    try:
        path, cached = fetch_media(args.url, account.get("token", ""))
    except AccountError as error:
        fail(error.code, error.message)
    out({"ok": True, "path": path, "cached": cached})


# --------------------------------------------------------------------------
# signing in
#
# Slack has no device-code flow and will not redirect a browser to a desktop
# that has no https address to send it to, so there is no sign-in this plugin
# could host. What it can do is take the token Slack shows you on your own
# app's page - and take it over stdin rather than as an argument, because
# /proc/<pid>/cmdline is readable by anyone on this machine and
# /proc/<pid>/environ is not readable by anyone at all.
# --------------------------------------------------------------------------


def read_stdin_json():
    """One JSON object, on one line, from whoever started this."""
    try:
        line = sys.stdin.readline()
    except (OSError, ValueError):
        return {}
    try:
        parsed = json.loads(line or "{}")
    except ValueError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def cmd_login_set(args):
    token = str(read_stdin_json().get("token") or "").strip()
    if not token:
        fail("no_token", "No token arrived. Paste the User OAuth Token from your Slack app.")
    if not token.startswith("xox"):
        fail("bad_token", "That does not look like a Slack token. They begin with xoxp-.")

    problem = alias_problem(args.account)
    if problem:
        fail("bad_alias", problem)

    api = Slack(token)
    ok, payload = api.call("auth.test")
    if not ok:
        fail("login_failed", friendly(payload.get("error", "")))

    problem = token_problem(token, api.scopes)
    if problem:
        # Nothing is written. A token that cannot work is not a sign-in, and
        # storing it would leave the window claiming to be signed in to a
        # workspace it cannot read.
        fail("token_unusable", problem, scopes=api.scopes)

    account = {
        "alias": args.account,
        "token": token,
        "team": str(payload.get("team") or ""),
        "teamId": str(payload.get("team_id") or ""),
        "url": str(payload.get("url") or ""),
        "userId": str(payload.get("user_id") or ""),
        "userName": str(payload.get("user") or ""),
        "displayName": "",
        "bot": bool(payload.get("bot_id")),
        "scopes": api.scopes,
        "savedAt": time.time(),
    }
    users = resolve_users(api, args.account, [account["userId"]])
    account["displayName"] = display_name(users, account["userId"], account["userName"])
    write_json(state_path(args.account), account, private=True)

    out({
        "ok": True,
        "team": account["team"],
        "user": account["displayName"] or account["userName"],
        "userId": account["userId"],
        "bot": account["bot"],
        "scopes": account["scopes"],
        "missingScopes": missing_scopes(account),
    })


# --------------------------------------------------------------------------
# making the app
#
# The other way round the wall. Creating a Slack app is a button on
# api.slack.com, and when that button does nothing - a blocked script, a
# workspace that hides it, a browser that will not open the modal - there is no
# second button. There is an API, though, and the token it wants is the App
# Configuration Token from the bottom of that same page: the one everybody
# copies by mistake instead of the User OAuth Token.
#
# So the mistake becomes the way in. This creates the app from the same scope
# list the README documents, and hands back the page to press Install on.
# --------------------------------------------------------------------------

APP_NAME = "Omarchy Slack"
APP_DESCRIPTION = "Slack channels, DMs and threads in the Omarchy bar"


def app_manifest(name=APP_NAME):
    """The app this plugin wants, built from the scope list above.

    One list, not two: a manifest in the README that drifts from what the code
    checks for is a plugin that says a feature is missing while the app it told
    you to make has the scope.
    """
    return {
        "display_information": {"name": name, "description": APP_DESCRIPTION},
        "oauth_config": {"scopes": {"user": list(WANTED_SCOPES)}},
        "settings": {
            "org_deploy_enabled": False,
            "socket_mode_enabled": False,
            "is_hosted": False,
            # Rotation off on purpose: a rotating token expires in twelve hours
            # and this plugin has nowhere to keep a refresh token safely enough
            # to be worth it.
            "token_rotation_enabled": False,
        },
    }


def cmd_create_app(args):
    """Create the Slack app from a configuration token, and say where to install it."""
    token = str(read_stdin_json().get("token") or "").strip()
    if not token:
        fail("no_token", "No token arrived. Paste an App Configuration Token.")
    if not token.startswith("xoxe."):
        fail("wrong_token",
             "This wants the App Configuration Token - the Access Token at the bottom of the "
             "Your Apps page, starting xoxe. The xoxp- one is what you paste into the plugin "
             "afterwards, once the app exists.")

    api = Slack(token)
    manifest = json.dumps(app_manifest(args.name or APP_NAME))

    ok, payload = api.call("apps.manifest.validate", {"manifest": manifest})
    if not ok:
        # A rejected manifest names the field it did not like, which is the one
        # thing worth passing through verbatim.
        fail("manifest_rejected", friendly(payload.get("error", "")),
             detail=json.dumps(payload.get("errors") or [])[:600])
    if args.dry_run:
        out({"ok": True, "validated": True, "scopes": list(WANTED_SCOPES)})

    ok, payload = api.call("apps.manifest.create", {"manifest": manifest})
    if not ok:
        error = payload.get("error", "")
        if error in ("token_expired", "invalid_auth", "not_authed"):
            fail("token_expired",
                 "That configuration token has expired - they last twelve hours. Refresh it at "
                 "the bottom of the Your Apps page and paste the new Access Token.")
        fail("create_failed", friendly(error), detail=json.dumps(payload.get("errors") or [])[:600])

    app_id = str(payload.get("app_id") or "")
    out({
        "ok": True,
        "appId": app_id,
        # Where to press Install. The app exists at this point but is installed
        # nowhere, and only installing it produces the token the plugin wants.
        "installUrl": "https://api.slack.com/apps/%s/install-on-team" % app_id,
        "tokenUrl": "https://api.slack.com/apps/%s/oauth" % app_id,
        "scopes": list(WANTED_SCOPES),
    })


def cmd_login_status(args):
    account = read_json(state_path(args.account))
    if not account or not account.get("token"):
        out({"ok": True, "signedIn": False})
    result = dict(capability_flags(account))
    result.update({
        "ok": True,
        "signedIn": True,
        "team": account.get("team", ""),
        "user": account.get("displayName") or account.get("userName", ""),
        "bot": bool(account.get("bot")),
        "scopes": account.get("scopes", ""),
        "missingScopes": missing_scopes(account),
    })
    out(result)


def cmd_list(_args):
    accounts = []
    if os.path.isdir(STATE_DIR):
        for name in sorted(os.listdir(STATE_DIR)):
            if not name.endswith(".json"):
                continue
            data = read_json(os.path.join(STATE_DIR, name)) or {}
            accounts.append({
                "alias": name[:-5],
                "team": data.get("team", ""),
                "user": data.get("displayName") or data.get("userName", ""),
            })
    out({"ok": True, "accounts": accounts})


def cmd_remove(args):
    """Forget a workspace: the token, and everything cached about it."""
    removed = False
    path = state_path(args.account)
    if os.path.exists(path):
        os.remove(path)
        removed = True
    for name in ("users.json", "channels.json", "marks.json"):
        cached = cache_path(args.account, name)
        if os.path.exists(cached):
            os.remove(cached)
    out({"ok": True, "removed": removed})


PALETTE_PATH = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "omarchy", "current", "theme", "colors.toml",
)
PALETTE_NAMES = ("red", "orange", "yellow", "green", "cyan", "blue", "magenta",
                 "accent", "foreground", "muted")


def cmd_palette(_args):
    """The active theme's named colours.

    So a presence dot and a link are tinted in hues that belong to whatever
    theme is running rather than in hardcoded hex that fights it. The Teams
    and mail plugins read the same file for the same reason.
    """
    try:
        import tomllib

        with open(PALETTE_PATH, "rb") as handle:
            parsed = tomllib.load(handle)
    except (OSError, ValueError, ImportError) as error:
        out({"ok": False, "colors": {}, "error": {"code": "no_palette", "message": str(error)}})

    colors = {name: parsed[name] for name in PALETTE_NAMES
              if isinstance(parsed.get(name), str) and parsed[name].startswith("#")}
    out({"ok": True, "mode": parsed.get("mode", "dark"), "colors": colors})


# --------------------------------------------------------------------------
# demo data, so the layout can be built without anyone signing in
# --------------------------------------------------------------------------

DEMO_DMS = [
    ("demo-im-0", "Priya Raman", "Priya Raman", "Can you look at the deploy before standup?",
     3, True, 2, "active"),
    ("demo-im-1", "Dana Okafor", "you", "Sent - thanks!", 47, False, 0, "away"),
    ("demo-im-2", "Mikael Sørensen", "Mikael Sørensen",
     "The staging certificate expires on Friday.", 190, False, 0, "active"),
    ("demo-mpim-0", "priya, dana, tomas", "Dana Okafor", "Thursday works for me.",
     320, False, 0, ""),
]

DEMO_CHANNELS = [
    ("demo-channel-0", "platform", "Tomás Lindqvist", "Rolling back the 14:02 release.",
     11, True, 5, "Keeping the lights on"),
    ("demo-channel-1", "release-14-02", "Ana Beltrán",
     "Migration ran twice - writing it up now.", 26, True, 1, ""),
    ("demo-channel-2", "design", "Yuki Tanaka", "New mockups are in the thread.", 96, False, 0, ""),
    ("demo-channel-3", "general", "Ana Beltrán", "Retro moved to Thursday.", 300, False, 0,
     "Everything that concerns everyone"),
    ("demo-channel-4", "random", "Mikael Sørensen", "Coffee machine is fixed :tada:",
     1500, False, 0, ""),
]


def demo_account(alias):
    now = time.time()

    def row(kind, channel_id, title, who, text, ago, unread, count, extra):
        return {
            "id": channel_id, "kind": kind, "name": title.lstrip("#"),
            "title": title, "private": False,
            "withUserId": "demo-user" if kind == "im" else "",
            "topic": extra if kind == "channel" else "", "purpose": "", "quiet": "",
            "member": True, "lastFrom": who,
            "lastText": plain_text(text), "when": iso_from_ts(now - ago * 60),
            "ts": "%.6f" % (now - ago * 60), "unread": unread, "unreadCount": count,
            "presence": ({"state": extra, "activity": ""} if kind == "im" and extra else None),
            "avatar": "", "current": True,
        }

    dms = [row("im" if channel_id.startswith("demo-im") else "mpim",
               channel_id, title, who, text, ago, unread, count, extra)
           for channel_id, title, who, text, ago, unread, count, extra in DEMO_DMS]
    channels = [row("channel", channel_id, "#" + name, who, text, ago, unread, count, topic)
                for channel_id, name, who, text, ago, unread, count, topic in DEMO_CHANNELS]

    account = {name: True for name in CAPABILITIES}
    account.update({
        "ok": True, "alias": alias, "team": "Example Inc", "teamId": "T0DEMO",
        "url": "https://example.slack.com/", "userId": "demo-me",
        "userName": alias, "displayName": alias.capitalize(),
        "dms": dms, "channels": channels,
        "unreadCount": sum(1 for r in dms + channels if r["unread"]),
        "unreadMessages": sum(r["unreadCount"] for r in dms + channels),
        "covered": len(dms) + len(channels), "total": len(dms) + len(channels),
        "coveredChannels": len(channels), "totalChannels": len(channels),
        "hiddenDms": 0, "feed": True, "checked": len(dms) + len(channels),
        "missingScopes": [], "warnings": [],
    })
    return account


# The transcripts the demo hands back, keyed by the conversation that asked. A
# picture of a chat window wants a conversation with some shape to it - turns
# of different lengths, both sides of it, a thread, a link, a reaction - which
# two lines of "Looking now." does not have.
DEMO_TRANSCRIPTS = {
    "demo-channel-0": [
        ("Tomás Lindqvist", "t1", 34, "Rolling back the 14:02 release. Staging is red and I would "
                                      "rather not find out why during the demo.", 0, []),
        ("Ana Beltrán", "a1", 31, "Ack. Anything for me to do?", 0, []),
        ("Tomás Lindqvist", "t1", 26, "No - the rollback is clean.", 0, [("+1", 3, False)]),
        ("You", "demo-me", 21, "Found it: the migration ran twice because the job was queued from "
                               "both the tag and the branch push.", 0, [("tada", 2, True)]),
        ("Priya Raman", "p1", 12, "Ah, that would do it.", 0, []),
        ("Priya Raman", "p1", 8, "Can you put that in <https://example.com/releases/14-02|the "
                                 "release notes> so the next person does not spend an hour on it? "
                                 ":pray:", 4, []),
    ],
    "demo-im-0": [
        ("Priya Raman", "p1", 40, "Morning! Can you look at the deploy before standup?", 0, []),
        ("Priya Raman", "p1", 38, "The 14:02 build is red on staging and green locally, which is "
                                  "the annoying combination.", 0, []),
        ("You", "demo-me", 22, "Looking now.", 0, []),
        ("Priya Raman", "p1", 3, "Thank you :heart:", 0, []),
    ],
}

DEMO_FALLBACK = [
    ("Yuki Tanaka", "y1", 90, "New mockups are in the thread.", 2, []),
    ("You", "demo-me", 62, "Looks good to me - shipping the spacing change with it.", 0, []),
]

DEMO_THREAD = [
    ("Priya Raman", "p1", 8, "Can you put that in the release notes?", 0, []),
    ("You", "demo-me", 6, "Written up: the job now refuses to run twice for the same commit.",
     0, [("+1", 1, False)]),
    ("Ana Beltrán", "a1", 4, "Linked it from the runbook as well.", 0, []),
]


def demo_messages(channel, thread=""):
    now = time.time()
    turns = DEMO_THREAD if thread else DEMO_TRANSCRIPTS.get(str(channel or ""), DEMO_FALLBACK)
    messages = []
    for index, (who, who_id, ago, body, replies, reactions) in enumerate(turns):
        # Through the same reader the real thing goes through, so a demo line
        # with a link or an emoji in it comes out the way a real one does.
        text, links = text_and_links(body)
        stamp = "%.6f" % (now - ago * 60)
        messages.append({
            "id": stamp, "ts": stamp, "from": who, "fromId": who_id, "avatar": "",
            "when": iso_from_ts(now - ago * 60), "text": text, "links": links,
            "edited": index == 2 and not thread, "system": False, "mine": who_id == "demo-me",
            "images": [], "files": [],
            "reactions": [{"name": name, "emoji": emoji_table.char_for(name) or name,
                           "count": count, "mine": mine} for name, count, mine in reactions],
            "threadTs": stamp if replies else "", "replyCount": replies, "replyUsers": replies,
            "latestReply": "", "parent": bool(replies), "pinned": False,
        })
    return {"ok": True, "channel": channel, "thread": thread or "", "anchored": False,
            "hasMore": False, "messages": messages}


# --------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    def with_account(name, help_text):
        item = sub.add_parser(name, help=help_text)
        item.add_argument("--account", required=True, help="workspace alias, e.g. work")
        return item

    login = with_account("login-set", "store a user token, read as JSON on stdin")
    login.set_defaults(func=cmd_login_set)

    with_account("login-status", "whether this workspace is signed in").set_defaults(
        func=cmd_login_status)

    fetch = sub.add_parser("fetch", help="conversations, with previews and unread marks")
    fetch.add_argument("--account", action="append", required=True,
                       help="workspace alias; repeat for more")
    fetch.add_argument("--conversations", type=int, default=40,
                       help="how many conversations to check the read state of in one poll")
    fetch.add_argument("--sort", default="recent", choices=("recent", "name"))
    fetch.add_argument("--avatars", dest="avatars", action="store_true", default=True)
    fetch.add_argument("--no-avatars", dest="avatars", action="store_false",
                       help="skip the pictures - what the bar widget wants, since it only "
                            "ever draws a count")
    # Kept, and now only about the warning: presence itself is a command of its
    # own, so that a poll does not wait twenty requests for a dot.
    fetch.add_argument("--presence", dest="presence", action="store_true", default=True)
    fetch.add_argument("--no-presence", dest="presence", action="store_false")
    fetch.add_argument("--fresh", action="store_true",
                       help="re-read the conversation list rather than using the cached one")
    fetch.add_argument("--max-age", type=int, default=0, metavar="SECONDS",
                       help="hand back the last snapshot if it is younger than this, and ask "
                            "Slack nothing")
    fetch.add_argument("--demo", action="store_true", help="synthetic data, for building the layout")
    fetch.set_defaults(func=cmd_fetch)

    presence = with_account("presence", "who is around, for a list of people")
    presence.add_argument("--user", action="append", required=True, metavar="ID")
    presence.add_argument("--demo", action="store_true")
    presence.set_defaults(func=cmd_presence)

    messages = with_account("messages", "one conversation's recent messages")
    messages.add_argument("--channel", required=True, help="conversation id from a fetch")
    messages.add_argument("--thread", default="", help="a parent message's ts, for its replies")
    messages.add_argument("--around", default="",
                          help="anchor the transcript at this ts - what a search result opens on")
    messages.add_argument("--top", type=int, default=30)
    messages.add_argument("--avatars", dest="avatars", action="store_true", default=True)
    messages.add_argument("--no-avatars", dest="avatars", action="store_false")
    messages.add_argument("--demo", action="store_true")
    messages.set_defaults(func=cmd_messages)

    send = with_account("send", "post a message")
    send.add_argument("--channel", required=True)
    send.add_argument("--thread", default="", help="reply in this thread")
    send.add_argument("--broadcast", action="store_true",
                      help="a thread reply that also shows in the channel")
    send.add_argument("--text", default="", help="the message; --stdin is what the window uses")
    send.add_argument("--stdin", action="store_true", help='read {"text": "..."} from stdin')
    send.add_argument("--demo", action="store_true")
    send.set_defaults(func=cmd_send)

    upload = with_account("upload", "send a file into a conversation")
    upload.add_argument("--channel", required=True)
    upload.add_argument("--thread", default="", help="send it into this thread")
    upload.add_argument("--file", default="", help="path to send; --stdin is what the window uses")
    upload.add_argument("--comment", default="", help="a message to go with it")
    upload.add_argument("--title", default="", help="what it is called in Slack (default: the filename)")
    upload.add_argument("--stdin", action="store_true",
                        help='read {"file": "...", "comment": "..."} from stdin')
    upload.add_argument("--demo", action="store_true")
    upload.set_defaults(func=cmd_upload)

    react = with_account("react", "add or remove your reaction on a message")
    react.add_argument("--channel", required=True)
    react.add_argument("--ts", required=True, help="the message's ts")
    react.add_argument("--emoji", required=True, help="a Slack emoji name, e.g. tada")
    react.add_argument("--remove", action="store_true", help="take yours off instead")
    react.add_argument("--demo", action="store_true")
    react.set_defaults(func=cmd_react)

    sub.add_parser("reactions", help="the reactions the picker offers").set_defaults(
        func=cmd_reactions)

    mark = with_account("mark-read", "mark one conversation read up to a message")
    mark.add_argument("--channel", required=True)
    mark.add_argument("--ts", required=True)
    mark.add_argument("--demo", action="store_true")
    mark.set_defaults(func=cmd_mark_read)

    open_dm = with_account("open-dm", "open a direct message")
    open_dm.add_argument("--user", action="append", required=True,
                         metavar="ID", help="a person's id; repeat for a group DM")
    open_dm.add_argument("--demo", action="store_true")
    open_dm.set_defaults(func=cmd_open_dm)

    join = with_account("join", "join a public channel")
    join.add_argument("--channel", required=True)
    join.add_argument("--demo", action="store_true")
    join.set_defaults(func=cmd_join)

    directory = with_account("directory", "people and channels to jump to")
    directory.add_argument("--query", default="")
    directory.add_argument("--demo", action="store_true")
    directory.set_defaults(func=cmd_directory)

    search = with_account("search", "search messages")
    search.add_argument("--query", required=True)
    search.add_argument("--top", type=int, default=25)
    search.add_argument("--demo", action="store_true")
    search.set_defaults(func=cmd_search)

    image = with_account("image", "download one picture, and say where it is")
    image.add_argument("--url", required=True, help="a Slack-hosted image URL from a message")
    image.set_defaults(func=cmd_image)

    create = sub.add_parser(
        "create-app", help="create the Slack app from an App Configuration Token on stdin")
    create.add_argument("--name", default=APP_NAME, help="what to call it in Slack")
    create.add_argument("--dry-run", action="store_true",
                        help="ask Slack whether the manifest is acceptable, and stop there")
    create.set_defaults(func=cmd_create_app)

    sub.add_parser("palette", help="the active theme's named colours").set_defaults(
        func=cmd_palette)
    sub.add_parser("list", help="list configured workspaces").set_defaults(func=cmd_list)
    with_account("remove", "forget a workspace and everything cached about it").set_defaults(
        func=cmd_remove)

    args = parser.parse_args()
    try:
        args.func(args)
    except AccountError as error:
        fail(error.code, error.message)


if __name__ == "__main__":
    main()
