#!/usr/bin/env python3
"""Tests for slack.py: the parsing, and the rules about what may be fetched.

Run with `python3 dev/test-slack.py`. No network and no workspace: everything
here is either a pure function or the real code with the network answering to
order, the way the Teams and Office 365 plugins test their helpers.

What is deliberately covered: the shapes Slack actually sends (which are not
always the shapes the documentation suggests), and every place a decision is
made about permission or about which host gets the token. Those are the two
classes of bug that are invisible until they matter.
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))
import slack  # noqa: E402
import emoji  # noqa: E402


class Emitted(Exception):
    """slack.out() reached, carrying what it was about to print."""

    def __init__(self, payload):
        super().__init__("emitted")
        self.payload = payload


def capture(function, *args, **kwargs):
    """Run a cmd_* function and return the JSON it tried to print."""
    original = slack.out
    slack.out = lambda payload: (_ for _ in ()).throw(Emitted(payload))
    try:
        function(*args, **kwargs)
    except Emitted as emitted:
        return emitted.payload
    finally:
        slack.out = original
    raise AssertionError("nothing was emitted")


class Args:
    account = "work"
    demo = False


class FakeApi:
    """A Slack that answers from a script rather than from the network."""

    def __init__(self, answers):
        self.answers = answers
        self.calls = []
        self.scopes = ""
        self.rate_limited = False
        self.token = "xoxp-test"

    def call(self, method, params=None, timeout=20, retries=1):
        self.calls.append((method, dict(params or {})))
        answer = self.answers.get(method, (False, {"error": "not_scripted"}))
        return answer(params) if callable(answer) else answer

    def paged(self, method, params, key, cap):
        """One page, which is all any fixture here needs."""
        ok, payload = self.call(method, params)
        if not ok:
            return [], payload.get("error", "unknown")
        return (payload.get(key) or [])[:cap], ""


# --------------------------------------------------------------------------


class Names(unittest.TestCase):
    """What may be used as a workspace alias, since it becomes a filename."""

    def test_a_plain_name_is_fine(self):
        self.assertIsNone(slack.alias_problem("work"))

    def test_a_path_is_not(self):
        self.assertIsNotNone(slack.alias_problem("../../etc/passwd"))
        self.assertIsNotNone(slack.alias_problem(".."))
        self.assertIsNotNone(slack.alias_problem("with space"))
        self.assertIsNotNone(slack.alias_problem(""))

    def test_a_bad_alias_never_becomes_a_path(self):
        with self.assertRaises(slack.AccountError):
            slack.state_path("../escape")


class Text(unittest.TestCase):
    """Turning Slack's mrkdwn into the words in it."""

    users = {"U1": {"id": "U1", "name": "Priya Raman", "handle": "priya"}}
    channels = {"C1": "platform"}

    def flatten(self, raw):
        return slack.text_and_links(raw, self.users, self.channels)

    def test_a_mention_becomes_the_name_the_directory_knows(self):
        # Not the label Slack's own client wrote into the entity: that one is
        # whatever it was when the message was sent.
        text, links = self.flatten("<@U1|old-handle> can you look?")
        self.assertEqual(text, "@Priya Raman can you look?")
        self.assertEqual(links, [])

    def test_an_unknown_mention_keeps_something_readable(self):
        text, _ = self.flatten("ask <@U9>")
        self.assertEqual(text, "ask @U9")

    def test_a_channel_reference_becomes_a_hash_and_a_name(self):
        text, _ = self.flatten("see <#C1|platform>")
        self.assertEqual(text, "see #platform")

    def test_here_and_channel_are_not_links(self):
        text, links = self.flatten("<!here> deploy is out")
        self.assertEqual(text, "@here deploy is out")
        self.assertEqual(links, [])

    def test_a_date_entity_falls_back_to_the_words_slack_wrote_for_it(self):
        text, _ = self.flatten("posted <!date^1392734382^{date}|18 Feb 2014>")
        self.assertEqual(text, "posted 18 Feb 2014")

    def test_a_labelled_link_keeps_its_address_out_of_the_words(self):
        text, links = self.flatten("put it in <https://example.com/notes|the release notes>")
        self.assertEqual(text, "put it in the release notes")
        self.assertEqual(len(links), 1)
        self.assertEqual(links[0]["href"], "https://example.com/notes")
        self.assertEqual(text[links[0]["start"]:links[0]["end"]], "the release notes")

    def test_a_bare_link_is_its_own_words(self):
        text, links = self.flatten("<https://example.com/x>")
        self.assertEqual(text, "https://example.com/x")
        self.assertEqual(links[0]["href"], "https://example.com/x")

    def test_a_javascript_url_is_left_as_words(self):
        text, links = self.flatten("<javascript:alert(1)|click me>")
        self.assertEqual(links, [])
        self.assertEqual(text, "click me")

    def test_offsets_survive_an_emoji_before_the_link(self):
        # The emoji becomes one character where it was five, and the link's
        # offsets have to be offsets into the finished text or the anchor
        # lands on the wrong words.
        text, links = self.flatten(":tada: <https://example.com|ship it>")
        self.assertEqual(text, "\U0001F389 ship it")
        self.assertEqual(text[links[0]["start"]:links[0]["end"]], "ship it")

    def test_an_address_inside_a_link_is_not_read_as_a_shortcode(self):
        text, links = self.flatten("<https://example.com/a:b:c|there>")
        self.assertEqual(links[0]["href"], "https://example.com/a:b:c")
        self.assertEqual(text, "there")

    def test_slacks_three_escapes_are_decoded(self):
        text, _ = self.flatten("a &lt; b &amp;&amp; c &gt; d")
        self.assertEqual(text, "a < b && c > d")

    def test_a_control_character_cannot_forge_a_link_span(self):
        # The marks used to carry link positions through the substitutions are
        # C0 controls. A message arriving with one must not be able to make a
        # span of its own.
        text, links = self.flatten("\x00https://evil.example\x01words\x02")
        self.assertEqual(links, [])
        self.assertIn("words", text)

    def test_an_ampersand_in_a_query_string_survives(self):
        _, links = self.flatten("<https://example.com/?a=1&amp;b=2|there>")
        self.assertEqual(links[0]["href"], "https://example.com/?a=1&b=2")

    def test_plain_text_is_one_line(self):
        self.assertEqual(slack.plain_text("one\n\ntwo   three"), "one two three")


class Emoji(unittest.TestCase):
    def test_a_known_shortcode_becomes_its_character(self):
        self.assertEqual(emoji.expand("ship it :rocket:"), "ship it \U0001F680")

    def test_a_workspace_emoji_is_left_alone(self):
        # There is no character for a picture somebody uploaded, and the name
        # at least says what was meant.
        self.assertEqual(emoji.expand("nice :blob-wave:"), "nice :blob-wave:")

    def test_a_skin_tone_modifier_comes_off_its_hand(self):
        self.assertEqual(emoji.expand(":wave::skin-tone-4:"), "\U0001F44B")

    def test_the_picker_offers_characters_it_has(self):
        rows = emoji.picker_rows()
        self.assertTrue(all(row["emoji"] and row["name"] for row in rows))
        self.assertEqual(rows[0]["name"], "+1")


class Blocks(unittest.TestCase):
    """Messages written by apps, which is half of a busy workspace."""

    def test_rich_text_is_flattened_back_into_mrkdwn(self):
        message = {"text": "", "blocks": [{
            "type": "rich_text",
            "elements": [{"type": "rich_text_section", "elements": [
                {"type": "text", "text": "Build failed for "},
                {"type": "link", "url": "https://ci.example/1", "text": "run 1"},
                {"type": "text", "text": " "},
                {"type": "user", "user_id": "U1"},
            ]}],
        }]}
        text, links = slack.text_and_links(
            slack.message_source(message), {"U1": {"name": "Priya"}}, {})
        self.assertEqual(text, "Build failed for run 1 @Priya")
        self.assertEqual(links[0]["href"], "https://ci.example/1")

    def test_blocks_win_over_a_one_word_fallback(self):
        message = {"text": "New message", "blocks": [{
            "type": "section",
            "text": {"type": "mrkdwn", "text": "The deploy to production finished in 4m12s"},
        }]}
        self.assertIn("4m12s", slack.message_source(message))

    def test_an_attachment_is_added_when_it_says_something_new(self):
        message = {"text": "Heads up", "attachments": [
            {"title": "PR #41", "title_link": "https://example.com/41", "text": "Fix the race"}]}
        source = slack.message_source(message)
        self.assertIn("Heads up", source)
        self.assertIn("Fix the race", source)
        text, links = slack.text_and_links(source, {}, {})
        self.assertEqual(links[0]["href"], "https://example.com/41")

    def test_a_fallback_is_dropped_when_the_text_already_said_it(self):
        message = {"text": "", "attachments": [
            {"text": "the real thing", "fallback": "the real thing"}]}
        self.assertEqual(slack.message_source(message).count("the real thing"), 1)


class Files(unittest.TestCase):
    def test_a_picture_is_taken_at_thumbnail_size(self):
        images, others = slack.file_rows({"files": [{
            "mimetype": "image/png", "name": "shot.png",
            "url_private": "https://files.slack.com/full.png",
            "thumb_720": "https://files.slack.com/thumb.png",
            "thumb_720_w": 720, "thumb_720_h": 400,
        }]})
        self.assertEqual(others, [])
        self.assertEqual(images[0]["url"], "https://files.slack.com/thumb.png")
        self.assertEqual((images[0]["width"], images[0]["height"]), (720, 400))

    def test_anything_else_is_a_chip_pointing_at_its_page(self):
        images, others = slack.file_rows({"files": [{
            "mimetype": "application/pdf", "name": "notes.pdf", "pretty_type": "PDF",
            "size": 2048, "permalink": "https://example.slack.com/files/x",
            "url_private": "https://files.slack.com/notes.pdf",
        }]})
        self.assertEqual(images, [])
        # The permalink, not url_private: the browser is signed in to the one
        # and gets a redirect from the other.
        self.assertEqual(others[0]["link"], "https://example.slack.com/files/x")
        self.assertEqual(others[0]["kind"], "PDF")

    def test_a_file_this_token_may_not_read_says_so(self):
        _, others = slack.file_rows({"files": [
            {"mode": "tombstone", "name": "gone.png", "mimetype": "image/png"}]})
        self.assertEqual(others[0]["kind"], "unavailable")


class Reactions(unittest.TestCase):
    def test_yours_is_marked_and_the_biggest_leads(self):
        rows = slack.reaction_rows({"reactions": [
            {"name": "eyes", "count": 1, "users": ["U9"]},
            {"name": "+1", "count": 3, "users": ["U1", "U2", "U9"]},
        ]}, "U1")
        self.assertEqual([row["name"] for row in rows], ["+1", "eyes"])
        self.assertTrue(rows[0]["mine"])
        self.assertFalse(rows[1]["mine"])
        self.assertEqual(rows[0]["emoji"], "\U0001F44D")

    def test_a_workspace_emoji_keeps_its_name(self):
        rows = slack.reaction_rows({"reactions": [
            {"name": "shipit-squirrel", "count": 1, "users": []}]}, "U1")
        self.assertEqual(rows[0]["emoji"], ":shipit-squirrel:")

    def test_who_reacted_is_named_for_the_line_a_chip_shows(self):
        users = {"U1": {"name": "Jan Renz"}, "U2": {"name": "Ana Beltr\u00e1n"}}
        rows = slack.reaction_rows({"reactions": [
            {"name": "+1", "count": 4, "users": ["U2", "U1", "U7"]}]}, "U1", users)
        # Yourself first and as "You". U7 is somebody this fetch has no name
        # for, and an id on a tooltip is noise - the count still says four.
        self.assertEqual(rows[0]["who"], ["You", "Ana Beltr\u00e1n"])
        self.assertEqual(rows[0]["count"], 4)

    def test_an_id_nobody_could_name_is_left_off_the_line(self):
        # resolve_users remembers an unnameable id as its own name.
        users = {"U7": {"name": "U7"}}
        rows = slack.reaction_rows({"reactions": [
            {"name": "+1", "count": 1, "users": ["U7"]}]}, "U1", users)
        self.assertEqual(rows[0]["who"], [])

    def test_whoever_reacted_is_looked_up_with_the_senders(self):
        # Last, so a busy transcript never spends its lookup budget on
        # tooltips and leaves a sender showing as a raw id.
        ids = slack.mentioned_ids([
            {"user": "U001", "text": "hi <@U002>",
             "reactions": [{"name": "+1", "count": 2, "users": ["U003", "U004"]}]}])
        self.assertEqual(ids, ["U002", "U001", "U003", "U004"])

    def test_without_the_people_a_chip_is_still_a_chip(self):
        rows = slack.reaction_rows({"reactions": [
            {"name": "+1", "count": 2, "users": ["U2", "U3"]}]}, "U1")
        self.assertEqual(rows[0]["who"], [])
        self.assertEqual(rows[0]["count"], 2)


class Timestamps(unittest.TestCase):
    def test_newer_compares_as_a_number_and_not_as_text(self):
        # "999999999.000100" sorts after "1712345678.000200" as a string, which
        # is the kind of comparison that works until it does not.
        self.assertTrue(slack.newer("1712345678.000200", "999999999.000100"))
        self.assertFalse(slack.newer("999999999.000100", "1712345678.000200"))

    def test_an_empty_mark_means_everything_is_newer(self):
        self.assertTrue(slack.newer("1712345678.000200", ""))

    def test_a_slack_stamp_becomes_an_iso_string(self):
        self.assertEqual(slack.iso_from_ts("1392734382.000100"), "2014-02-18T14:39:42Z")

    def test_nonsense_does_not_raise(self):
        self.assertEqual(slack.iso_from_ts("not a time"), "")


class Scopes(unittest.TestCase):
    """What a token may do, read from what Slack said rather than assumed."""

    account = {"scopes": "channels:history,channels:read,chat:write,users:read"}

    def test_a_capability_needs_one_of_its_scopes(self):
        self.assertTrue(slack.granted(self.account, "read"))
        self.assertTrue(slack.granted(self.account, "post"))
        self.assertFalse(slack.granted(self.account, "search"))
        self.assertFalse(slack.granted(self.account, "react"))

    def test_unknown_means_no(self):
        self.assertFalse(slack.granted({}, "post"))
        self.assertFalse(slack.granted(None, "read"))

    def test_a_prefix_is_not_a_scope(self):
        # "channels:read" must not satisfy "channels:write".
        self.assertFalse(slack.granted({"scopes": "channels:read"}, "join"))

    def test_what_is_missing_is_listed_in_the_readmes_order(self):
        missing = slack.missing_scopes(self.account)
        self.assertIn("search:read", missing)
        self.assertNotIn("chat:write", missing)
        self.assertEqual(missing, [s for s in slack.WANTED_SCOPES if s in missing])


class TokenKind(unittest.TestCase):
    """Which of the four things Slack calls a token this actually is.

    auth.test answers cheerfully for every one of them, so the sign-in cannot
    be "did the token work" - it has to be "is this the token that can do any
    of this", and only the scopes say.
    """

    def test_an_app_configuration_token_is_named_for_what_it_is(self):
        problem = slack.token_problem(
            "xoxe.xoxp-1-abc", "identify,app_configurations:read,app_configurations:write")
        self.assertIn("App Configuration Token", problem)
        self.assertIn("OAuth & Permissions", problem)

    def test_a_rotating_token_is_refused_because_it_cannot_be_refreshed(self):
        problem = slack.token_problem("xoxe.xoxp-1-abc", "channels:history,channels:read")
        self.assertIn("rotation", problem)

    def test_a_bot_token_is_the_wrong_half_of_the_page(self):
        self.assertIn("User OAuth Token", slack.token_problem("xoxb-1-abc", "chat:write"))

    def test_a_token_with_no_history_scopes_says_what_it_does_have(self):
        problem = slack.token_problem("xoxp-1-abc", "chat:write,users:read")
        self.assertIn("no history scopes", problem)
        self.assertIn("chat:write", problem)

    def test_the_right_token_is_no_problem_at_all(self):
        self.assertEqual(slack.token_problem(
            "xoxp-1-abc", "channels:history,channels:read,chat:write"), "")

    def test_scopes_nobody_has_reported_yet_are_not_second_guessed(self):
        # Before the first response there is nothing to judge, and refusing on
        # no evidence would refuse every good token too.
        self.assertEqual(slack.token_problem("xoxp-1-abc", ""), "")


class Hosts(unittest.TestCase):
    """Which host gets the token, which is the one that must never be wrong."""

    def setUp(self):
        self.requests = []

        class Response:
            headers = {"Content-Type": "image/png"}

            def read(self, _n):
                return b"\x89PNG fake"

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        def fake_urlopen(request, timeout=None):
            self.requests.append(request)
            return Response()

        self.original = slack.urllib.request.urlopen
        slack.urllib.request.urlopen = fake_urlopen
        self.cache = tempfile.mkdtemp()
        self.original_dir = slack.MEDIA_DIR
        slack.MEDIA_DIR = self.cache

    def tearDown(self):
        slack.urllib.request.urlopen = self.original
        slack.MEDIA_DIR = self.original_dir

    def test_an_image_from_anywhere_else_is_refused(self):
        with self.assertRaises(slack.AccountError):
            slack.fetch_media("https://evil.example/pixel.png", "xoxp-secret")
        self.assertEqual(self.requests, [])

    def test_http_is_refused_even_on_a_slack_host(self):
        with self.assertRaises(slack.AccountError):
            slack.fetch_media("http://files.slack.com/x.png", "xoxp-secret")
        self.assertEqual(self.requests, [])

    def test_the_token_goes_only_to_the_host_that_needs_it(self):
        slack.fetch_media("https://files.slack.com/x.png", "xoxp-secret")
        self.assertEqual(self.requests[-1].get_header("Authorization"), "Bearer xoxp-secret")

        slack.fetch_media("https://avatars.slack-edge.com/y.png", "xoxp-secret")
        # An avatar needs no token, so it is not given one - the CDN is not the
        # API, and a token sent somewhere it is not needed is a token that can
        # leak somewhere it was not meant to go.
        self.assertIsNone(self.requests[-1].get_header("Authorization"))

    def test_a_sign_in_page_is_not_an_image(self):
        class HtmlResponse:
            headers = {"Content-Type": "text/html"}

            def read(self, _n):
                return b"<html>sign in</html>"

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        slack.urllib.request.urlopen = lambda request, timeout=None: HtmlResponse()
        with self.assertRaises(slack.AccountError):
            slack.fetch_media("https://files.slack.com/expired.png", "xoxp-secret")


class Api(unittest.TestCase):
    """The one place a response is turned into an answer."""

    def test_calls_are_paced_rather_than_fired_all_at_once(self):
        # A burst is what Slack answers with 429s, and whatever loses that race
        # has no answer for the rest of the interval.
        api = slack.Slack("x")
        api.MIN_INTERVAL = 0.02
        api.METHOD_INTERVAL = {}
        started = time.monotonic()
        for _ in range(5):
            api._pace("conversations.info")
        self.assertGreater(time.monotonic() - started, 0.06)

    def test_one_method_does_not_wait_for_another(self):
        # Slack counts per method, so a shared queue makes each method wait for
        # the others' turns for nothing: seven conversations.info calls behind
        # one global gate took seven intervals rather than one.
        api = slack.Slack("x")
        api.MIN_INTERVAL = 0.05
        api.METHOD_INTERVAL = {}
        api._pace("search.messages")
        started = time.monotonic()
        api._pace("conversations.info")
        self.assertLess(time.monotonic() - started, 0.02, "a different bucket, so no wait")

    def test_the_restricted_endpoint_is_paced_more_carefully_than_the_rest(self):
        api = slack.Slack("x")
        self.assertGreater(api.METHOD_INTERVAL["conversations.history"],
                           api.METHOD_INTERVAL["conversations.info"])

    def test_a_rate_limit_is_waited_out_once(self):
        attempts = []

        class Limited(slack.urllib.error.HTTPError):
            def __init__(self):
                self.code = 429
                self.headers = {"Retry-After": "0"}

            def read(self, _n=None):
                return b""

        class Fine:
            status = 200
            headers = {}

            def read(self, _n):
                return b'{"ok": true}'

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        def urlopen(request, timeout=None):
            attempts.append(1)
            if len(attempts) == 1:
                raise Limited()
            return Fine()

        original = slack.urllib.request.urlopen
        slack.urllib.request.urlopen = urlopen
        try:
            api = slack.Slack("x")
            api.MIN_INTERVAL = 0
            ok, _ = api.call("conversations.history")
        finally:
            slack.urllib.request.urlopen = original
        self.assertTrue(ok)
        self.assertEqual(len(attempts), 2)
        self.assertFalse(api.rate_limited, "waited it out, so nothing to report")

    def test_what_the_token_may_do_is_read_off_the_response(self):
        class Response:
            status = 200
            headers = {"x-oauth-scopes": "chat:write,users:read"}

            def read(self, _n):
                return b'{"ok": true}'

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        original = slack.urllib.request.urlopen
        slack.urllib.request.urlopen = lambda request, timeout=None: Response()
        try:
            api = slack.Slack("xoxp-x")
            ok, _ = api.call("auth.test")
        finally:
            slack.urllib.request.urlopen = original
        self.assertTrue(ok)
        self.assertEqual(api.scopes, "chat:write,users:read")

    def test_slack_saying_no_is_not_an_exception(self):
        class Response:
            status = 200
            headers = {}

            def read(self, _n):
                return b'{"ok": false, "error": "channel_not_found"}'

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        original = slack.urllib.request.urlopen
        slack.urllib.request.urlopen = lambda request, timeout=None: Response()
        try:
            ok, payload = slack.Slack("x").call("conversations.history")
        finally:
            slack.urllib.request.urlopen = original
        self.assertFalse(ok)
        self.assertEqual(payload["error"], "channel_not_found")

    def test_a_code_becomes_a_sentence(self):
        self.assertIn("not valid", slack.friendly("invalid_auth"))
        self.assertIn("Slack said", slack.friendly("something_new_they_added"))


class Conversations(unittest.TestCase):
    def test_a_group_dm_is_named_after_the_people_in_it(self):
        users = {"U1": {"handle": "priya", "name": "Priya Raman"},
                 "U2": {"handle": "dana", "name": "Dana Okafor"}}
        self.assertEqual(slack.mpim_title("mpdm-priya--dana--tomas-1", users),
                         "Priya Raman, Dana Okafor, tomas")

    def test_a_group_dm_is_not_named_after_you(self):
        # Every group DM otherwise carries your own name in the middle of it,
        # which is a third of the row spent saying who is reading it.
        users = {"U1": {"handle": "priya", "name": "Priya Raman"}}
        self.assertEqual(
            slack.mpim_title("mpdm-priya--jan.renz--tomas-1", users, "jan.renz"),
            "Priya Raman, tomas")

    def test_a_direct_message_is_named_after_the_person(self):
        row = slack.conversation_row({"id": "D1", "is_im": True, "user": "U1"},
                                     {"U1": {"name": "Priya Raman"}})
        self.assertEqual(row["title"], "Priya Raman")
        self.assertEqual(row["kind"], "im")
        self.assertEqual(row["withUserId"], "U1")

    def test_a_channel_wears_its_hash(self):
        row = slack.conversation_row(
            {"id": "C1", "name": "platform", "topic": {"value": "Keeping the lights on"}}, {})
        self.assertEqual(row["title"], "#platform")
        self.assertEqual(row["topic"], "Keeping the lights on")

    def test_what_was_actually_read_beats_slacks_own_hint(self):
        # `updated` is not the last message: a channel can read 2024 and have
        # had a message this morning. What this plugin saw itself wins.
        rows = [
            {"id": "C1", "title": "#a", "updated": 9_999_999_999_999, "priority": 0},
            {"id": "C2", "title": "#b", "updated": 1, "priority": 0},
        ]
        order = slack.by_interest(rows, {"C2": "1712345678.0"})
        self.assertEqual([row["id"] for row in order], ["C2", "C1"])

    def test_slacks_hint_is_used_when_nothing_better_is_known(self):
        rows = [
            {"id": "C1", "title": "#a", "updated": 1, "priority": 0},
            {"id": "C2", "title": "#b", "updated": 9_999_999_999_999, "priority": 0},
        ]
        self.assertEqual([row["id"] for row in slack.by_interest(rows, {})], ["C2", "C1"])

    def test_the_order_is_stable_when_nothing_is_known_at_all(self):
        rows = [{"id": "C2", "title": "#b", "updated": 0, "priority": 0},
                {"id": "C1", "title": "#a", "updated": 0, "priority": 0}]
        self.assertEqual([row["id"] for row in slack.by_interest(rows, {})], ["C1", "C2"])

    def test_the_feed_keeps_the_newest_message_per_conversation(self):
        # One search answers for every conversation at once, and a busy one is
        # in it several times over.
        matches = [
            {"channel": {"id": "C1", "name": "platform"}, "ts": "1712345600.1", "text": "older"},
            {"channel": {"id": "C1", "name": "platform"}, "ts": "1712345900.1", "text": "newest"},
            {"channel": {"id": "D1", "is_im": True}, "ts": "1712345700.1", "text": "a dm"},
        ]
        api = FakeApi({"search.messages": (True, {"messages": {
            "matches": matches, "paging": {"pages": 1}}})})
        feed, stamps, problem = slack.activity_feed(api)
        self.assertEqual(problem, "")
        self.assertEqual(set(feed), {"C1", "D1"})
        self.assertEqual(feed["C1"]["text"], "newest")
        # Every stamp is kept, not just the newest: that is what an unread
        # count is counted out of.
        self.assertEqual(sorted(stamps["C1"]), ["1712345600.1", "1712345900.1"])

    def test_the_feed_asks_for_a_window_and_the_newest_first(self):
        api = FakeApi({"search.messages": (True, {"messages": {"matches": [], "paging": {"pages": 1}}})})
        slack.activity_feed(api, days=4)
        method, params = api.calls[0]
        self.assertEqual(method, "search.messages")
        self.assertTrue(params["query"].startswith("after:"))
        self.assertEqual(params["sort"], "timestamp")
        self.assertEqual(params["sort_dir"], "desc")

    def test_a_refused_search_is_reported_rather_than_guessed_around(self):
        api = FakeApi({"search.messages": (False, {"error": "missing_scope"})})
        feed, stamps, problem = slack.activity_feed(api)
        self.assertEqual((feed, stamps), ({}, {}))
        self.assertEqual(problem, "missing_scope")

    # ---- how deep the feed pages, which is the poll's whole cost ----------
    #
    # `search.messages` is Tier 2 - twenty a minute - and it is the one request
    # every poll spends whether or not anybody is at the machine. Three pages
    # per poll was three of that budget for two pages of answer the plugin
    # already had on disk.

    @staticmethod
    def _pages(count=3):
        """A search deep enough to page, one hundred messages to a page.

        Newest first, one second apart, so page 1 is the newest hundred and
        page 3 the oldest - which is the order the stopping rule reads.
        """
        def answer(params):
            page = int((params or {}).get("page") or 1)
            first = 100_000 - (page - 1) * 100
            return True, {"messages": {
                "matches": [{"channel": {"id": "C%d" % (n % 7)},
                             "ts": "%d.0" % (first - n)} for n in range(100)],
                "paging": {"pages": count}}}
        return {"search.messages": answer}

    def test_the_feed_pages_all_the_way_down_when_nothing_is_recorded_yet(self):
        """The first poll of a workspace: there is no gap to bridge, only
        coverage to build, and the deeper pages are where it comes from."""
        api = FakeApi(self._pages())
        slack.activity_feed(api, covered="")
        self.assertEqual(len(api.calls), 3)

    def test_the_feed_stops_at_the_page_that_reaches_the_last_poll(self):
        """The steady state, and the ordinary case: one page.

        Page 1 here reaches back to 99_901, and the last poll had already
        recorded a message at 99_950 - so page 1 spans the whole gap between
        the two polls, and pages 2 and 3 would re-read what `previews.json`
        already holds.
        """
        api = FakeApi(self._pages())
        feed, stamps, problem = slack.activity_feed(api, covered="99950.0")
        self.assertEqual(len(api.calls), 1)
        self.assertEqual(problem, "")
        self.assertTrue(feed, "and it still answered")

    def test_the_feed_keeps_paging_while_it_has_not_bridged_the_gap(self):
        """A laptop back from a day asleep: more than a page has arrived.

        The last poll's newest is below page 1 and below page 2, so stopping at
        either would leave a conversation whose only recent message is in the
        gap with no preview and no unread mark.
        """
        api = FakeApi(self._pages())
        slack.activity_feed(api, covered="99750.0")
        self.assertEqual(len(api.calls), 3)

    def test_the_cap_still_holds_however_far_behind_it_is(self):
        """FEED_PAGES is the deepest this looks, and that has not changed: a
        workspace that has said more than three pages' worth keeps whatever
        previews it had for the rest."""
        api = FakeApi(self._pages(count=40))
        slack.activity_feed(api, covered="1.0")
        self.assertEqual(len(api.calls), slack.FEED_PAGES)

    def test_the_high_water_mark_is_the_newest_thing_anywhere(self):
        # Compared as numbers, not as text: "999999999.1" sorts above
        # "1712345900.1" alphabetically and is eleven years older.
        self.assertEqual(slack.high_water(
            {"C1": "1712345600.1", "C2": "1712345900.1", "D1": "999999999.1"}),
            "1712345900.1")
        self.assertEqual(slack.high_water({}), "")
        self.assertEqual(slack.high_water(None), "")


class Sending(unittest.TestCase):
    """Writes, which are the ones that must refuse rather than half-work."""

    def setUp(self):
        self.state = tempfile.mkdtemp()
        self.original_state = slack.STATE_DIR
        self.original_cache = slack.CACHE_DIR
        slack.STATE_DIR = self.state
        slack.CACHE_DIR = os.path.join(self.state, "cache")
        slack.write_json(slack.state_path("work"), {
            "alias": "work", "token": "xoxp-test", "userId": "U1",
            "scopes": "chat:write,reactions:write,channels:history",
        }, private=True)

    def tearDown(self):
        slack.STATE_DIR = self.original_state
        slack.CACHE_DIR = self.original_cache

    def send_args(self, **kwargs):
        args = Args()
        args.channel = "C1"
        args.thread = ""
        args.broadcast = False
        args.text = "hello"
        args.stdin = False
        args.demo = False
        for key, value in kwargs.items():
            setattr(args, key, value)
        return args

    def test_the_three_characters_slack_escapes_are_escaped(self):
        sent = {}

        class Recorder(slack.Slack):
            def call(self, method, params=None, timeout=20):
                sent["method"] = method
                sent["params"] = params
                return True, {"ts": "1.1"}

        original = slack.Slack
        slack.Slack = Recorder
        try:
            payload = capture(slack.cmd_send, self.send_args(text="a < b & c > d"))
        finally:
            slack.Slack = original
        self.assertTrue(payload["ok"])
        self.assertEqual(sent["params"]["text"], "a &lt; b &amp; c &gt; d")

    def test_a_thread_reply_says_which_thread(self):
        sent = {}

        class Recorder(slack.Slack):
            def call(self, method, params=None, timeout=20):
                sent.update(params or {})
                return True, {"ts": "1.1"}

        original = slack.Slack
        slack.Slack = Recorder
        try:
            capture(slack.cmd_send, self.send_args(thread="99.1", broadcast=True))
        finally:
            slack.Slack = original
        self.assertEqual(sent["thread_ts"], "99.1")
        self.assertEqual(sent["reply_broadcast"], "true")

    def test_nothing_is_sent_when_there_is_nothing_to_send(self):
        payload = capture(slack.cmd_send, self.send_args(text="   "))
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"]["code"], "empty")

    def test_a_token_without_chat_write_refuses_before_the_request(self):
        slack.write_json(slack.state_path("work"), {
            "alias": "work", "token": "xoxp-test", "scopes": "channels:history"}, private=True)

        class Explode(slack.Slack):
            def call(self, method, params=None, timeout=20):
                raise AssertionError("should not have asked Slack")

        original = slack.Slack
        slack.Slack = Explode
        try:
            payload = capture(slack.cmd_send, self.send_args())
        finally:
            slack.Slack = original
        self.assertEqual(payload["error"]["code"], "permission_required")
        self.assertIn("chat:write", payload["error"]["message"])

    def test_reacting_twice_is_not_an_error_worth_showing(self):
        class Recorder(slack.Slack):
            def call(self, method, params=None, timeout=20):
                return False, {"error": "already_reacted"}

        args = Args()
        args.channel, args.ts, args.emoji, args.remove = "C1", "1.1", "tada", False
        original = slack.Slack
        slack.Slack = Recorder
        try:
            payload = capture(slack.cmd_react, args)
        finally:
            slack.Slack = original
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["noop"])

    def test_marking_read_without_the_scope_still_remembers_it_here(self):
        slack.write_json(slack.state_path("work"), {
            "alias": "work", "token": "xoxp-test", "scopes": "channels:history"}, private=True)
        args = Args()
        args.channel, args.ts, args.demo = "C1", "1712345678.1", False
        payload = capture(slack.cmd_mark_read, args)
        self.assertFalse(payload["ok"])
        marks, _ = slack.load_marks("work")
        # Slack was not told, but this window will stop claiming the message is
        # waiting for somebody who has just read it.
        self.assertEqual(marks["C1"], "1712345678.1")

    def test_a_token_that_is_not_a_token_is_refused_before_the_network(self):
        original_stdin = sys.stdin
        sys.stdin = type("S", (), {"readline": staticmethod(lambda: '{"token": "hunter2"}\n')})()
        try:
            args = Args()
            payload = capture(slack.cmd_login_set, args)
        finally:
            sys.stdin = original_stdin
        self.assertEqual(payload["error"]["code"], "bad_token")


class Uploads(unittest.TestCase):
    """Sending a file, which is the one request that puts our data somewhere."""

    def setUp(self):
        self.state = tempfile.mkdtemp()
        self.original_state = slack.STATE_DIR
        slack.STATE_DIR = self.state
        slack.write_json(slack.state_path("work"), {
            "alias": "work", "token": "xoxp-test", "userId": "U1",
            "scopes": "files:write,chat:write",
        }, private=True)
        self.file = os.path.join(self.state, "note.txt")
        with open(self.file, "w") as handle:
            handle.write("hello")

    def tearDown(self):
        slack.STATE_DIR = self.original_state

    def upload_args(self, **kwargs):
        args = Args()
        args.channel = "C1"
        args.thread = ""
        args.file = self.file
        args.comment = ""
        args.title = ""
        args.stdin = False
        args.demo = False
        for key, value in kwargs.items():
            setattr(args, key, value)
        return args

    def recorder(self, answers):
        sent = {"calls": []}

        class Recorder(slack.Slack):
            def call(self, method, params=None, timeout=20):
                sent["calls"].append((method, params or {}))
                return answers.get(method, (True, {}))

        return sent, Recorder

    def run_upload(self, args, answers, posted=(True, "")):
        sent, Recorder = self.recorder(answers)
        original_api, original_post = slack.Slack, slack.post_upload

        def fake_post(url, filename, body, timeout=120):
            sent["posted"] = {"url": url, "filename": filename, "bytes": len(body)}
            return posted

        slack.Slack, slack.post_upload = Recorder, fake_post
        try:
            return capture(slack.cmd_upload, args), sent
        finally:
            slack.Slack, slack.post_upload = original_api, original_post

    ANSWERS = {
        "files.getUploadURLExternal": (True, {
            "file_id": "F1", "upload_url": "https://files.slack.com/upload/v1/abc"}),
        "files.completeUploadExternal": (True, {"files": [{"permalink": "https://x/y"}]}),
    }

    def test_the_three_steps_happen_in_order_and_the_file_lands_in_the_channel(self):
        payload, sent = self.run_upload(self.upload_args(), self.ANSWERS)
        self.assertTrue(payload["ok"])
        self.assertEqual([call[0] for call in sent["calls"]],
                         ["files.getUploadURLExternal", "files.completeUploadExternal"])
        reserve = sent["calls"][0][1]
        self.assertEqual(reserve["filename"], "note.txt")
        self.assertEqual(reserve["length"], "5")
        self.assertEqual(sent["posted"]["bytes"], 5)
        complete = sent["calls"][1][1]
        self.assertEqual(complete["channel_id"], "C1")
        self.assertEqual(json.loads(complete["files"]), [{"id": "F1", "title": "note.txt"}])

    def test_a_thread_upload_says_which_thread(self):
        _, sent = self.run_upload(self.upload_args(thread="99.1"), self.ANSWERS)
        self.assertEqual(sent["calls"][1][1]["thread_ts"], "99.1")

    def test_a_comment_is_escaped_the_way_a_message_is(self):
        _, sent = self.run_upload(self.upload_args(comment="a < b & c"), self.ANSWERS)
        self.assertEqual(sent["calls"][1][1]["initial_comment"], "a &lt; b &amp; c")

    def test_a_file_that_reached_slack_but_no_conversation_says_exactly_that(self):
        answers = dict(self.ANSWERS)
        answers["files.completeUploadExternal"] = (False, {"error": "channel_not_found"})
        payload, _ = self.run_upload(self.upload_args(), answers)
        self.assertEqual(payload["error"]["code"], "upload_incomplete")

    def test_a_missing_scope_refuses_before_anything_is_sent(self):
        slack.write_json(slack.state_path("work"), {
            "alias": "work", "token": "xoxp-test", "scopes": "chat:write"}, private=True)
        payload, sent = self.run_upload(self.upload_args(), self.ANSWERS)
        self.assertEqual(payload["error"]["code"], "permission_required")
        self.assertEqual(sent["calls"], [])
        self.assertNotIn("posted", sent)

    def test_a_directory_is_not_a_file_to_send(self):
        payload = capture(slack.cmd_upload, self.upload_args(file=self.state, demo=True))
        self.assertEqual(payload["error"]["code"], "no_file")

    def test_an_empty_file_is_refused(self):
        empty = os.path.join(self.state, "empty.bin")
        open(empty, "wb").close()
        payload = capture(slack.cmd_upload, self.upload_args(file=empty, demo=True))
        self.assertEqual(payload["error"]["code"], "empty_file")

    def test_something_larger_than_the_cap_is_refused_by_size_not_by_reading_it(self):
        big = os.path.join(self.state, "big.bin")
        with open(big, "wb") as handle:
            handle.truncate(slack.UPLOAD_CAP + 1)
        payload = capture(slack.cmd_upload, self.upload_args(file=big, demo=True))
        self.assertEqual(payload["error"]["code"], "too_large")

    def test_a_demo_upload_sends_nothing(self):
        sent, Recorder = self.recorder(self.ANSWERS)
        original = slack.Slack
        slack.Slack = Recorder
        try:
            payload = capture(slack.cmd_upload, self.upload_args(demo=True))
        finally:
            slack.Slack = original
        self.assertTrue(payload["ok"])
        self.assertEqual(sent["calls"], [])

    def test_the_bytes_go_nowhere_but_slack(self):
        # The URL is named by an API response rather than by a message, but it
        # is still somebody else naming where our file goes.
        for url in ("https://evil.example/upload",
                    "http://files.slack.com/upload/v1/abc",
                    "https://files.slack.com.evil.example/x"):
            with self.assertRaises(Emitted) as caught:
                original = slack.out
                slack.out = lambda payload: (_ for _ in ()).throw(Emitted(payload))
                try:
                    slack.post_upload(url, "note.txt", b"hello")
                finally:
                    slack.out = original
            self.assertEqual(caught.exception.payload["error"]["code"], "bad_upload_host")

    def test_the_multipart_body_carries_the_file_under_a_random_boundary(self):
        seen = {}

        class Response:
            status = 200
            headers = {"Content-Type": "text/plain"}

            def read(self, *_a):
                return b"OK - 5"

            def __enter__(self):
                return self

            def __exit__(self, *_a):
                return False

        def fake_urlopen(request, timeout=None):
            seen["type"] = request.headers.get("Content-type") or request.get_header("Content-type")
            seen["body"] = request.data
            return Response()

        original = slack.urllib.request.urlopen
        slack.urllib.request.urlopen = fake_urlopen
        try:
            ok, problem = slack.post_upload(
                "https://files.slack.com/upload/v1/abc", 'odd"name\r\n.txt', b"hello")
        finally:
            slack.urllib.request.urlopen = original
        self.assertTrue(ok, problem)
        boundary = seen["type"].split("boundary=")[1]
        self.assertIn(boundary.encode(), seen["body"])
        self.assertIn(b'name="file"', seen["body"])
        # Quotes and newlines out of a filename would end the header early.
        self.assertIn(b'filename="oddname.txt"', seen["body"])
        self.assertTrue(seen["body"].endswith(("--%s--\r\n" % boundary).encode()))


class Manifest(unittest.TestCase):
    """The app this plugin asks Slack to make."""

    def test_the_manifest_asks_for_exactly_what_the_code_checks_for(self):
        # Two lists would drift, and the drift is silent: the window would say
        # a feature needs a scope the app it told you to create already has.
        manifest = slack.app_manifest()
        self.assertEqual(manifest["oauth_config"]["scopes"]["user"], slack.WANTED_SCOPES)

    def test_every_capability_is_covered_by_a_scope_it_asks_for(self):
        asked = set(slack.WANTED_SCOPES)
        for capability, scopes in slack.CAPABILITIES.items():
            self.assertTrue(asked & set(scopes), "%s is unreachable" % capability)

    def test_rotation_is_off_because_it_could_not_be_honoured(self):
        self.assertFalse(slack.app_manifest()["settings"]["token_rotation_enabled"])

    def test_only_a_configuration_token_may_create_an_app(self):
        original_stdin = sys.stdin
        sys.stdin = type("S", (), {"readline": staticmethod(lambda: '{"token": "xoxp-1-user"}\n')})()
        try:
            args = Args()
            args.name, args.dry_run = "", True
            payload = capture(slack.cmd_create_app, args)
        finally:
            sys.stdin = original_stdin
        self.assertEqual(payload["error"]["code"], "wrong_token")


class Caches(unittest.TestCase):
    """What is not asked again, and when it is asked anyway."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.original_state, self.original_cache = slack.STATE_DIR, slack.CACHE_DIR
        slack.STATE_DIR = self.dir
        slack.CACHE_DIR = os.path.join(self.dir, "cache")
        slack.write_json(slack.state_path("work"), {
            "alias": "work", "token": "xoxp-test", "userId": "U1",
            "scopes": ",".join(slack.WANTED_SCOPES)}, private=True)

    def tearDown(self):
        slack.STATE_DIR, slack.CACHE_DIR = self.original_state, self.original_cache

    @staticmethod
    def _lists():
        """Channels on one call, direct messages on the other, as Slack does."""
        def by_type(params):
            if "public_channel" in (params or {}).get("types", ""):
                return True, {"channels": [{"id": "C1", "name": "a"}]}
            return True, {"channels": [{"id": "D1", "is_im": True}]}
        return {"users.conversations": by_type}

    def test_the_conversation_list_is_read_once_and_then_believed(self):
        api = FakeApi(self._lists())
        first, _ = slack.conversation_lists(api, "work")
        second, _ = slack.conversation_lists(api, "work")
        self.assertEqual([row["id"] for row in first], ["C1", "D1"])
        self.assertEqual(first, second)
        self.assertEqual(len(api.calls), 2, "two paged calls the first time, none the second")

    def test_asking_for_it_fresh_asks_slack_again(self):
        api = FakeApi(self._lists())
        slack.conversation_lists(api, "work")
        slack.conversation_lists(api, "work", fresh=True)
        self.assertEqual(len(api.calls), 4)

    def test_a_refusal_does_not_empty_a_list_that_was_working(self):
        good = FakeApi(self._lists())
        slack.conversation_lists(good, "work")
        broken = FakeApi({"users.conversations": (False, {"error": "ratelimited"})})
        # Expire it, so the refusal is what the fresh read runs into.
        rows, problem = slack.conversation_lists(broken, "work", fresh=True)
        self.assertEqual([row["id"] for row in rows], ["C1", "D1"])
        self.assertEqual(problem, "ratelimited")

    def test_a_recent_snapshot_is_handed_back_without_asking_slack(self):
        slack.write_json(slack.cache_path("work", "snapshot.json"),
                         {"snapshot": {"ok": True, "accounts": [{"alias": "work", "ok": True}]},
                          "at": time.time()})

        class Explode(slack.Slack):
            def call(self, *a, **k):
                raise AssertionError("a cached snapshot must cost nothing")

        args = Args()
        args.account, args.demo, args.max_age = ["work"], False, 120
        args.conversations, args.sort = 40, "recent"
        args.avatars = args.presence = args.fresh = False
        original = slack.Slack
        slack.Slack = Explode
        try:
            payload = capture(slack.cmd_fetch, args)
        finally:
            slack.Slack = original
        self.assertTrue(payload["cached"])
        self.assertEqual(payload["accounts"][0]["alias"], "work")

    def test_a_snapshot_older_than_asked_for_is_not_used(self):
        slack.write_json(slack.cache_path("work", "snapshot.json"),
                         {"snapshot": {"ok": True, "accounts": []}, "at": time.time() - 600})
        asked = []

        class Counting(slack.Slack):
            def call(self, method, params=None, timeout=20, retries=1):
                asked.append(method)
                return False, {"error": "invalid_auth"}

        args = Args()
        args.account, args.demo, args.max_age = ["work"], False, 120
        args.conversations, args.sort = 40, "recent"
        args.avatars = args.presence = args.fresh = False
        original = slack.Slack
        slack.Slack = Counting
        try:
            payload = capture(slack.cmd_fetch, args)
        finally:
            slack.Slack = original
        self.assertNotIn("cached", payload)
        self.assertTrue(asked, "it went and asked")

    def test_presence_is_kept_and_not_asked_again_on_the_next_poll(self):
        asked = []

        class Counting(slack.Slack):
            def call(self, method, params=None, timeout=20, retries=1):
                asked.append((params or {}).get("user"))
                return True, {"presence": "active"}

        args = Args()
        args.user, args.demo = ["U1", "U2", "U1"], False
        original = slack.Slack
        slack.Slack = Counting
        try:
            first = capture(slack.cmd_presence, args)
            second = capture(slack.cmd_presence, args)
        finally:
            slack.Slack = original
        self.assertEqual(first["presence"]["U1"]["state"], "active")
        self.assertEqual(second["presence"]["U2"]["state"], "active")
        # Two people, asked about once between them: the repeat in the list is
        # not a second request, and neither is the poll that follows. Presence
        # is kept for PRESENCE_TTL, which is several polls' worth - it is one
        # request per person and it moves on the scale of somebody walking to
        # a meeting.
        self.assertEqual(sorted(asked), ["U1", "U2"])
        self.assertGreaterEqual(slack.PRESENCE_TTL, 120)

    def test_a_poll_that_waited_on_another_one_takes_its_answer(self):
        """The two-monitor case: one bar polls, the other inherits.

        `cached_snapshot` is what decides it. `since` is the moment this poll
        began waiting, and anything written after that is the other poll's
        answer - handed over whatever max_age said, because a poll passes zero
        and zero means "nothing stale", not "ask again regardless".
        """
        began = time.time()
        slack.write_json(slack.cache_path("work", "snapshot.json"),
                         {"snapshot": {"ok": True, "accounts": [{"alias": "work"}]},
                          "at": began + 1})
        handed = slack.cached_snapshot("work", max_age=0, since=began)
        self.assertTrue(handed["cached"])
        self.assertEqual(handed["accounts"][0]["alias"], "work")

    def test_a_snapshot_from_before_the_wait_is_not_that_answer(self):
        began = time.time()
        slack.write_json(slack.cache_path("work", "snapshot.json"),
                         {"snapshot": {"ok": True, "accounts": []}, "at": began - 30})
        self.assertIsNone(slack.cached_snapshot("work", max_age=0, since=began))

    def test_a_poll_waits_for_a_poll_another_process_is_already_running(self):
        """The lock itself, which only means anything between processes.

        flock is owned by the process, so a second FetchSlot in this one would
        be handed the lock it already holds. The holder therefore has to be a
        real other process.
        """
        path = slack.cache_path("work", "fetch.lock")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        holder = subprocess.Popen(
            [sys.executable, "-c",
             "import fcntl,sys,time\n"
             "h=open(sys.argv[1],'a+')\n"
             "fcntl.flock(h, fcntl.LOCK_EX)\n"
             "sys.stdout.write('held\\n'); sys.stdout.flush()\n"
             "time.sleep(1.0)\n", path],
            stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(holder.stdout.readline().strip(), "held")
            with slack.FetchSlot("work") as slot:
                self.assertTrue(slot.waited, "it noticed somebody else was mid-poll")
        finally:
            holder.wait(timeout=5)

    def test_a_free_slot_is_taken_at_once(self):
        with slack.FetchSlot("work") as slot:
            self.assertFalse(slot.waited)


class Transcripts(unittest.TestCase):
    """The one request Slack rations hardest, and how often it is spent.

    `conversations.history` is capped at about one a minute for an app outside
    Slack's Marketplace, so reading four channels in a row used to be one
    transcript and three refusals. What is kept on disk, and what makes it
    safe to believe, is the subject here.
    """

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.original_state, self.original_cache = slack.STATE_DIR, slack.CACHE_DIR
        slack.STATE_DIR = self.dir
        slack.CACHE_DIR = os.path.join(self.dir, "cache")
        slack.write_json(slack.state_path("work"), {
            "alias": "work", "token": "xoxp-test", "userId": "U1",
            "scopes": ",".join(slack.WANTED_SCOPES)}, private=True)
        self.asked = []

    def tearDown(self):
        slack.STATE_DIR, slack.CACHE_DIR = self.original_state, self.original_cache

    def _args(self, **overrides):
        args = Args()
        args.account, args.demo = "work", False
        args.channel, args.thread, args.around = "C1", "", ""
        args.top, args.avatars, args.fresh = 40, False, False
        for key, value in overrides.items():
            setattr(args, key, value)
        return args

    def _run(self, args, history=None):
        """cmd_messages with the network answering to order."""
        asked = self.asked
        answers = {
            "conversations.history": (True, {"messages": history if history is not None
                                             else [{"type": "message", "user": "U2",
                                                    "ts": "100.0", "text": "hello"}]}),
            "conversations.replies": (True, {"messages": [
                {"type": "message", "user": "U2", "ts": "100.0", "text": "in a thread"}]}),
            # What canvas_of asks, which rides along with opening a
            # conversation and is therefore kept or saved with it.
            "conversations.info": (True, {"channel": {"id": "C1"}}),
        }

        class Scripted(slack.Slack):
            def call(self, method, params=None, timeout=20, retries=1):
                asked.append(method)
                return answers.get(method, (True, {}))

        original = slack.Slack
        slack.Slack = Scripted
        try:
            return capture(slack.cmd_messages, args)
        finally:
            slack.Slack = original

    def _seen(self, ts):
        """What the poll's one search remembers about this conversation."""
        slack.save_marks("work", {}, {"C1": ts})

    def test_the_second_open_of_a_conversation_costs_nothing(self):
        first = self._run(self._args())
        self.assertEqual(first["messages"][0]["text"], "hello")
        self.assertIn("conversations.history", self.asked)
        spent = len(self.asked)

        second = self._run(self._args())
        self.assertTrue(second["cached"])
        self.assertEqual(second["messages"][0]["text"], "hello")
        self.assertEqual(len(self.asked), spent, "nothing was asked the second time")

    def test_a_kept_transcript_carries_the_canvas_id_so_that_is_not_asked_twice(self):
        self._run(self._args())
        self.asked = []
        again = self._run(self._args())
        self.assertTrue(again["cached"])
        self.assertNotIn("conversations.info", self.asked,
                         "the canvas id came back with the transcript")

    def test_a_conversation_the_poll_has_learned_nothing_new_about_is_believed(self):
        self._seen("100.0")
        self._run(self._args())
        self.asked = []
        payload = self._run(self._args())
        self.assertTrue(payload["cached"])
        self.assertEqual(self.asked, [])

    def test_a_conversation_the_poll_has_since_seen_something_in_is_read_again(self):
        self._seen("100.0")
        self._run(self._args())
        self._seen("200.0")
        self.asked = []
        payload = self._run(self._args())
        self.assertNotIn("cached", payload)
        self.assertIn("conversations.history", self.asked)

    def test_a_reply_in_a_thread_does_not_make_a_channel_look_stale_for_ever(self):
        """The bug this criterion replaced, and why it is not a ts comparison.

        `seen` comes from a search, which returns thread replies;
        `conversations.history` returns only top-level messages. So a channel
        whose last word was a reply in a thread has a `seen` permanently ahead
        of anything its own transcript can end on. Comparing the two made that
        channel look stale on every single open - measured on a real workspace,
        where it never hit the cache once.
        """
        # The search saw a thread reply, later than any message in the channel.
        self._seen("150.0")
        first = self._run(self._args())
        self.assertEqual(first["messages"][-1]["ts"], "100.0", "history stops earlier")
        self.asked = []
        payload = self._run(self._args())
        self.assertTrue(payload["cached"], "the poll has learned nothing since")

    def test_asking_for_it_fresh_ignores_what_is_on_disk(self):
        self._seen("100.0")
        self._run(self._args())
        self.asked = []
        payload = self._run(self._args(fresh=True))
        self.assertNotIn("cached", payload)
        self.assertIn("conversations.history", self.asked)

    def test_asking_for_more_than_was_kept_is_a_different_question(self):
        self._seen("100.0")
        self._run(self._args(top=40))
        self.asked = []
        payload = self._run(self._args(top=60))
        self.assertNotIn("cached", payload)

    def test_asking_for_the_faces_when_it_was_kept_without_them_is_too(self):
        self._seen("100.0")
        self._run(self._args(avatars=False))
        self.asked = []
        payload = self._run(self._args(avatars=True))
        self.assertNotIn("cached", payload)

    def test_a_jump_to_a_search_result_is_not_kept(self):
        self._run(self._args(around="100.0"))
        self.assertFalse(os.path.exists(slack.transcript_cache_path("work", "C1", "")))

    def test_a_thread_is_kept_under_its_own_name(self):
        self._run(self._args(thread="90.0"))
        self.assertTrue(os.path.exists(slack.transcript_cache_path("work", "C1", "90.0")))
        # And the channel's own transcript is a different record, not this one.
        self.assertFalse(os.path.exists(slack.transcript_cache_path("work", "C1", "")))
        self.asked = []
        payload = self._run(self._args(thread="90.0"))
        self.assertTrue(payload["cached"])
        self.assertEqual(self.asked, [])

    def test_a_conversation_with_no_witness_at_all_is_worth_only_its_age(self):
        """Quieter than the search's fortnight, or not covered by it yet."""
        self._run(self._args())
        record = slack.read_json(slack.transcript_cache_path("work", "C1", ""))
        self.assertEqual(record["seen"], "", "nothing remembered when it was written")
        self.asked = []
        self.assertTrue(self._run(self._args())["cached"], "its age is still good")

        path = slack.transcript_cache_path("work", "C1", "")
        record["at"] = time.time() - (slack.TRANSCRIPT_TTL + 5)
        slack.write_json(path, record)
        self.assertNotIn("cached", self._run(self._args()))

    def test_a_thread_is_worth_only_its_age_since_seen_does_not_say_which_one(self):
        self._run(self._args(thread="90.0"))
        path = slack.transcript_cache_path("work", "C1", "90.0")
        record = slack.read_json(path)
        record["at"] = time.time() - (slack.THREAD_TTL + 5)
        slack.write_json(path, record)
        # Even with the poll having learned nothing new about the conversation:
        # `seen` moving says something was said, not which thread said it.
        self._seen("100.0")
        self.asked = []
        payload = self._run(self._args(thread="90.0"))
        self.assertNotIn("cached", payload)
        self.assertIn("conversations.replies", self.asked)

    def test_a_thread_read_here_stops_the_chip_saying_new_even_from_disk(self):
        """A cached transcript is not a cached set of thread marks.

        Reading a thread is remembered locally, because Slack has no method for
        it - so the marks are applied again on the way out of the cache, or the
        channel would go on saying "new" about a thread that was just read.
        """
        self._run(self._args(), history=[
            {"type": "message", "user": "U2", "ts": "100.0", "text": "parent",
             "thread_ts": "100.0", "reply_count": 2, "subscribed": True,
             "last_read": "100.0", "latest_reply": "150.0"}])
        record = slack.read_json(slack.transcript_cache_path("work", "C1", ""))
        self.assertTrue(record["payload"]["messages"][0]["threadUnread"],
                        "unread when it was written")

        slack.save_thread_marks("work", {"C1:100.0": "150.0"})
        payload = self._run(self._args())
        self.assertTrue(payload["cached"])
        self.assertFalse(payload["messages"][0]["threadUnread"])

    def test_sending_forgets_the_transcript_so_the_reload_reaches_slack(self):
        self._seen("100.0")
        self._run(self._args())
        self.assertTrue(os.path.exists(slack.transcript_cache_path("work", "C1", "")))

        args = Args()
        args.account, args.demo = "work", False
        args.channel, args.thread, args.broadcast = "C1", "", False
        args.text, args.stdin = "hi", False

        class Posting(slack.Slack):
            def call(self, method, params=None, timeout=20, retries=1):
                return True, {"ok": True, "ts": "300.0"}

        original = slack.Slack
        slack.Slack = Posting
        try:
            capture(slack.cmd_send, args)
        finally:
            slack.Slack = original

        self.assertFalse(os.path.exists(slack.transcript_cache_path("work", "C1", "")))
        self.asked = []
        payload = self._run(self._args())
        self.assertNotIn("cached", payload)

    def test_a_reply_forgets_the_thread_and_the_channel_it_is_in(self):
        """Both, because a reply moves the parent's count in the channel too."""
        self._run(self._args())
        self._run(self._args(thread="90.0"))
        slack.drop_transcript("work", "C1")
        self.assertFalse(os.path.exists(slack.transcript_cache_path("work", "C1", "")))
        self.assertFalse(os.path.exists(slack.transcript_cache_path("work", "C1", "90.0")))

    def test_a_conversation_id_cannot_name_a_path_of_its_own(self):
        """A conversation id comes from the server; a filename built out of one
        must land in this directory and nowhere else."""
        home = os.path.join(slack.CACHE_DIR, "work", "transcripts")
        for hostile in ("../../etc/passwd", "/etc/passwd", "..", ".", "C1/../../x"):
            path = slack.transcript_cache_path("work", hostile, "")
            self.assertEqual(os.path.dirname(os.path.realpath(path)),
                             os.path.realpath(home), hostile)


class Demo(unittest.TestCase):
    """The fixtures, which every screenshot and every layout change is built on."""

    def test_a_demo_fetch_answers_without_a_token(self):
        args = Args()
        args.account = ["demo"]
        args.demo = True
        args.conversations = 25
        args.sort = "recent"
        args.avatars = True
        args.presence = True
        payload = capture(slack.cmd_fetch, args)
        account = payload["accounts"][0]
        self.assertTrue(account["ok"])
        self.assertTrue(account["dms"] and account["channels"])
        self.assertTrue(account["unreadCount"] > 0)

    def test_a_demo_write_writes_nothing(self):
        args = Args()
        args.demo = True
        args.channel, args.ts, args.emoji, args.remove = "C1", "1.1", "tada", False

        class Explode(slack.Slack):
            def call(self, *a, **k):
                raise AssertionError("demo mode reached the network")

        original = slack.Slack
        slack.Slack = Explode
        try:
            self.assertTrue(capture(slack.cmd_react, args)["ok"])
        finally:
            slack.Slack = original

    def test_the_demo_transcript_goes_through_the_real_reader(self):
        payload = slack.demo_messages("demo-channel-0")
        with_link = [m for m in payload["messages"] if m["links"]]
        self.assertTrue(with_link)
        self.assertEqual(with_link[0]["links"][0]["href"], "https://example.com/releases/14-02")
        # And the emoji in it is a character by the time it leaves here.
        self.assertTrue(any("\U0001F64F" in m["text"] for m in payload["messages"]))


class CanvasText(unittest.TestCase):
    """A canvas's HTML as prose, with the links still pointing somewhere.

    The offsets are the whole point: the window escapes this text itself and
    then puts anchors back at these positions, so a converter that moved the
    text without moving the links would put an anchor around the wrong words.
    """

    def convert(self, markup, names=None):
        return slack.canvas_text(markup, names)

    def spans(self, body, links):
        return [body[link["start"]:link["end"]] for link in links]

    def test_a_link_still_wraps_its_own_words(self):
        body, links, _ = self.convert(
            '<p>See <a href="https://example.com/x">the runbook</a> first.</p>')
        self.assertEqual(body, "See the runbook first.")
        self.assertEqual(self.spans(body, links), ["the runbook"])

    def test_a_scheme_nobody_should_follow_keeps_its_words_and_loses_its_address(self):
        body, links, _ = self.convert('<p><a href="javascript:alert(1)">Click</a></p>')
        self.assertEqual(body, "Click")
        self.assertEqual(links, [])

    def test_a_list_is_one_line_per_item_and_no_blank_lines_between(self):
        """A canvas puts a `<br/>` before every `</li>`, which used to arrive
        as a blank line inside every list."""
        body, _, _ = self.convert(
            "<ul><li>one<br/></li><li>two<br/></li></ul><p>after</p>")
        self.assertEqual(body, "• one\n• two\n\nafter")

    def test_a_table_row_is_a_line_and_its_cells_are_separated(self):
        body, _, _ = self.convert(
            "<table><tr><td>Staging</td><td>on merge</td></tr>"
            "<tr><td>Live</td><td>at ten</td></tr></table>")
        self.assertEqual(body, "Staging\ton merge\nLive\tat ten")

    def test_nothing_a_canvas_contains_arrives_as_markup(self):
        body, links, _ = self.convert("<p>&lt;b&gt;not bold&lt;/b&gt;</p>")
        self.assertEqual(body, "<b>not bold</b>")
        self.assertEqual(links, [])

    def test_a_script_is_not_read_as_words(self):
        body, _, _ = self.convert("<p>before</p><script>alert(1)</script><p>after</p>")
        self.assertEqual(body, "before\n\nafter")

    def test_a_mention_becomes_a_name_without_moving_the_links(self):
        body, links, _ = self.convert(
            '<p>@U0123ABC see <a href="https://example.com/x">this</a></p>',
            {"U0123ABC": {"name": "Ada Lovelace"}})
        self.assertEqual(body, "@Ada Lovelace see this")
        self.assertEqual(self.spans(body, links), ["this"])

    def test_an_unknown_mention_is_left_as_it_arrived(self):
        body, _, _ = self.convert("<p>@U0123ABC</p>", {})
        self.assertEqual(body, "@U0123ABC")

    def test_a_long_canvas_is_cut_and_says_so(self):
        body, _, truncated = self.convert("<p>%s</p>" % ("x" * (slack.CANVAS_TEXT_CAP + 50)))
        self.assertTrue(truncated)
        self.assertTrue(len(body) <= slack.CANVAS_TEXT_CAP)

    def test_a_link_past_the_cut_is_dropped_rather_than_left_dangling(self):
        markup = ("<p>%s</p><p><a href=\"https://example.com/x\">tail</a></p>"
                  % ("x" * (slack.CANVAS_TEXT_CAP + 50)))
        body, links, truncated = self.convert(markup)
        self.assertTrue(truncated)
        for link in links:
            self.assertTrue(link["end"] <= len(body))


class CanvasDiscovery(unittest.TestCase):
    """Which canvas a channel keeps, out of the two shapes Slack answers with."""

    def ids(self, properties):
        return slack.canvas_ids({"channel": {"properties": properties}})

    def test_a_canvas_tab_is_found(self):
        self.assertEqual(self.ids({"tabs": [
            {"type": "files", "id": "files"},
            {"type": "canvas", "id": "Ct1", "data": {"file_id": "F1"}}]}), ["F1"])

    def test_the_older_channel_canvas_is_found(self):
        self.assertEqual(self.ids({"canvas": {"file_id": "F2", "is_empty": False}}), ["F2"])

    def test_an_empty_channel_canvas_is_not_offered(self):
        """Offering to open it would be offering a blank page."""
        self.assertEqual(self.ids({"canvas": {"file_id": "F3", "is_empty": True}}), [])

    def test_a_channel_with_neither_offers_nothing(self):
        self.assertEqual(self.ids({"tabs": [{"type": "files", "id": "files"}]}), [])

    def test_the_tab_wins_over_the_migrated_one(self):
        """A channel can carry both - the old one migrated and a new one beside
        it - and the tab is the one Slack's own client shows."""
        self.assertEqual(self.ids({
            "canvas": {"file_id": "old", "is_empty": False},
            "tabs": [{"type": "canvas", "id": "Ct1", "data": {"file_id": "new"}}],
        }), ["new", "old"])


class CanvasTitle(unittest.TestCase):
    """Slack takes a canvas's title from its first heading, so it arrives twice."""

    def test_the_repeated_title_goes_and_the_links_move_with_it(self):
        body, links = slack.drop_repeated_title(
            "On call\n\nsee here", [{"href": "https://example.com/x", "start": 13, "end": 17}],
            "On call")
        self.assertEqual(body, "see here")
        self.assertEqual(body[links[0]["start"]:links[0]["end"]], "here")

    def test_a_first_line_that_merely_starts_with_the_title_is_kept(self):
        body, _ = slack.drop_repeated_title("On call this week", [], "On call")
        self.assertEqual(body, "On call this week")

    def test_a_canvas_whose_body_does_not_repeat_it_is_untouched(self):
        body, _ = slack.drop_repeated_title("• een\n• twee", [], "een")
        self.assertEqual(body, "• een\n• twee")


class CanvasMarkdown(unittest.TestCase):
    """The same markup read a second way, as the source the editor edits.

    This is the text a save sends back, so what it loses, the canvas loses.
    Every test here is either a structure that has to survive the round trip
    or a thing that must never be written at all.
    """

    def convert(self, markup):
        return slack.canvas_markdown(markup)

    def test_the_structure_prose_throws_away_is_kept(self):
        body, _, lossy = self.convert(
            "<h2>Rota</h2><ul><li>Ada<br/></li><li>Grace<br/></li></ul>"
            "<p>See <a href=\"https://example.com/x\">the runbook</a>.</p>")
        self.assertEqual(body, "## Rota\n\n- Ada\n- Grace\n\n"
                               "See [the runbook](https://example.com/x).")
        self.assertEqual(lossy, [])

    def test_a_numbered_list_keeps_its_numbers_and_a_nested_one_its_indent(self):
        body, _, _ = self.convert(
            "<ol><li>first</li><li>second<ul><li>under it</li></ul></li></ol>")
        self.assertEqual(body, "1. first\n2. second\n  - under it")

    def test_a_table_gets_the_header_rule_markdown_needs(self):
        body, _, _ = self.convert(
            "<table><tr><th>Where</th><th>When</th></tr>"
            "<tr><td>Live</td><td>at ten</td></tr></table>")
        self.assertEqual(body, "| Where | When |\n| --- | --- |\n| Live | at ten |")

    def test_a_checklist_stays_a_checklist(self):
        body, _, _ = self.convert(
            "<ul><li><input type=\"checkbox\" checked/>done</li>"
            "<li><input type=\"checkbox\"/>todo</li></ul>")
        self.assertEqual(body, "- [x] done\n- [ ] todo")

    def test_text_that_looks_like_markup_comes_back_as_text(self):
        """Invariant 3, in the other direction: a canvas that says `**hi**`
        must not come back as bold, and must not be able to write a tag."""
        body, _, _ = self.convert("<p>**hi** and &lt;b&gt;bold&lt;/b&gt; and [a](b)</p>")
        self.assertEqual(body, r"\*\*hi\*\* and \<b>bold\</b> and \[a\](b)")

    def test_a_line_that_would_become_a_list_is_escaped_and_one_that_would_not_is_left(self):
        body, _, _ = self.convert("<p>- not a list</p><p>5 &gt; 3</p>")
        self.assertEqual(body, "\\- not a list\n\n5 > 3")

    def test_a_picture_is_never_written_and_is_said_out_loud(self):
        """A remote image in Markdown is a fetch waiting to happen (invariant
        2), and a canvas holding one is a canvas this window will not
        replace - dropping somebody's screenshot is not an edit."""
        body, _, lossy = self.convert(
            "<p>before</p><p><img src=\"https://evil.example/x.png\"/></p><p>after</p>")
        self.assertEqual(body, "before\n\nafter")
        self.assertNotIn("evil.example", body)
        self.assertEqual(lossy, ["a picture"])

    def test_a_mention_keeps_the_id_slack_needs_back(self):
        body, _, _ = self.convert("<p>Ask @U0123ABC</p>")
        self.assertEqual(body, "Ask ![](@U0123ABC)")

    def test_a_scheme_nobody_should_follow_loses_its_address_here_too(self):
        body, _, _ = self.convert("<p><a href=\"javascript:alert(1)\">Click</a></p>")
        self.assertEqual(body, "Click")

    def test_a_code_block_is_fenced_and_not_escaped(self):
        body, _, _ = self.convert("<pre>if a &lt; b:\n    go()</pre>")
        self.assertEqual(body, "```\nif a < b:\n    go()\n```")

    def test_a_canvas_too_long_to_read_says_so_because_it_may_not_be_saved(self):
        body, truncated, _ = self.convert("<p>%s</p>" % ("x" * (slack.CANVAS_TEXT_CAP + 50)))
        self.assertTrue(truncated)
        self.assertTrue(len(body) <= slack.CANVAS_TEXT_CAP)

    def test_the_title_heading_is_not_sent_back_because_slack_puts_it_there(self):
        body = slack.drop_markdown_title("# On call\n\n- Ada", "On call")
        self.assertEqual(body, "- Ada")

    def test_a_heading_that_is_not_the_title_stays(self):
        body = slack.drop_markdown_title("# Rota\n\n- Ada", "On call")
        self.assertEqual(body, "# Rota\n\n- Ada")

    def test_a_digest_ignores_trailing_space_and_nothing_else(self):
        self.assertEqual(slack.canvas_digest("a  \nb\n"), slack.canvas_digest("a\nb"))
        self.assertNotEqual(slack.canvas_digest("a\nb"), slack.canvas_digest("a\nB"))


class CanvasWrite(unittest.TestCase):
    """Saving a canvas, which replaces all of somebody else's document."""

    MARKUP = ("<h1>On call</h1><p>Ada is on call.</p>")

    def setUp(self):
        self.state = tempfile.mkdtemp()
        self.original_state = slack.STATE_DIR
        slack.STATE_DIR = self.state
        self.sign_in("files:read,canvases:write")
        self.markup = self.MARKUP
        self.original_fetch = slack.fetch_canvas
        slack.fetch_canvas = lambda url, token, timeout=30: self.markup

    def tearDown(self):
        slack.STATE_DIR = self.original_state
        slack.fetch_canvas = self.original_fetch

    def sign_in(self, scopes):
        slack.write_json(slack.state_path("work"), {
            "alias": "work", "token": "xoxp-test", "userId": "U1", "scopes": scopes,
        }, private=True)

    def current(self):
        body, _, _ = slack.canvas_markdown(self.markup)
        return slack.drop_markdown_title(body, "On call")

    def args(self, **kwargs):
        args = Args()
        args.channel = "C1"
        args.file = "F1"
        args.operation = "replace"
        args.markdown = "Grace is on call."
        args.base = slack.canvas_digest(self.current())
        args.stdin = False
        args.demo = False
        for key, value in kwargs.items():
            setattr(args, key, value)
        return args

    def run_edit(self, args, answers=None):
        answers = dict({"files.info": (True, {"file": {
            "title": "On call", "url_private": "https://files.slack.com/x"}}),
            "canvases.edit": (True, {})}, **(answers or {}))
        sent = []

        class Recorder(slack.Slack):
            def call(self, method, params=None, timeout=20):
                sent.append((method, params or {}))
                return answers.get(method, (True, {}))

        original = slack.Slack
        slack.Slack = Recorder
        try:
            return capture(slack.cmd_canvas_edit, args), sent
        finally:
            slack.Slack = original

    def test_a_save_replaces_the_whole_document_in_one_change(self):
        payload, sent = self.run_edit(self.args())
        self.assertTrue(payload["ok"])
        edit = dict(sent)["canvases.edit"]
        self.assertEqual(edit["canvas_id"], "F1")
        # One change per call: Slack refuses an array with two in it.
        changes = json.loads(edit["changes"])
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0]["operation"], "replace")
        self.assertNotIn("section_id", changes[0])
        self.assertEqual(changes[0]["document_content"],
                         {"type": "markdown", "markdown": "Grace is on call."})

    def test_a_canvas_somebody_else_has_edited_is_not_overwritten(self):
        payload, sent = self.run_edit(self.args(base="a digest of something else"))
        self.assertEqual(payload["error"]["code"], "canvas_changed")
        self.assertNotIn("canvases.edit", dict(sent))

    def test_a_save_that_changes_nothing_asks_slack_for_nothing(self):
        payload, sent = self.run_edit(self.args(markdown=self.current()))
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["unchanged"])
        self.assertNotIn("canvases.edit", dict(sent))

    def test_a_canvas_holding_a_picture_is_refused_rather_than_emptied(self):
        self.markup = self.MARKUP + "<p><img src=\"https://files.slack.com/p.png\"/></p>"
        payload, sent = self.run_edit(self.args(base=slack.canvas_digest(self.current())))
        self.assertEqual(payload["error"]["code"], "not_editable")
        self.assertIn("a picture", payload["error"]["message"])
        self.assertNotIn("canvases.edit", dict(sent))

    def test_adding_to_the_end_needs_no_digest_and_reads_nothing_first(self):
        """The safe operation: it cannot overwrite what it never read."""
        payload, sent = self.run_edit(self.args(operation="insert_at_end", base=""))
        self.assertTrue(payload["ok"])
        self.assertEqual([call[0] for call in sent], ["canvases.edit"])
        self.assertEqual(json.loads(dict(sent)["canvases.edit"]["changes"])[0]["operation"],
                         "insert_at_end")

    def test_a_replace_without_a_digest_is_refused_before_anything_is_sent(self):
        payload, sent = self.run_edit(self.args(base=""))
        self.assertEqual(payload["error"]["code"], "no_base")
        self.assertEqual(sent, [])

    def test_a_token_that_may_not_write_says_so_rather_than_trying(self):
        self.sign_in("files:read")
        payload, sent = self.run_edit(self.args())
        self.assertEqual(payload["error"]["code"], "permission_required")
        self.assertIn("canvases:write", payload["error"]["message"])
        self.assertEqual(sent, [])

    def test_the_demo_writes_nothing(self):
        payload, sent = self.run_edit(self.args(demo=True))
        self.assertTrue(payload["ok"])
        self.assertEqual(sent, [])


class Favourites(unittest.TestCase):
    """Starred conversations - what Slack's own sidebar calls a favourite."""

    def rows(self, *specs):
        out = []
        for title, ts, starred in specs:
            out.append({"id": title, "title": title, "ts": ts, "updated": 0,
                        "starred": starred, "unread": False})
        return out

    def test_a_favourite_leads_whatever_spoke_last(self):
        ordered = slack.sort_rows(
            self.rows(("#loud", "200", False), ("#starred", "100", True)), True)
        self.assertEqual([row["title"] for row in ordered], ["#starred", "#loud"])

    def test_a_favourite_leads_in_alphabetical_order_too(self):
        ordered = slack.sort_rows(
            self.rows(("#aaa", "0", False), ("#zzz", "0", True)), False)
        self.assertEqual([row["title"] for row in ordered], ["#zzz", "#aaa"])

    def test_favourites_are_still_ordered_among_themselves(self):
        ordered = slack.sort_rows(
            self.rows(("#old", "100", True), ("#new", "200", True)), True)
        self.assertEqual([row["title"] for row in ordered], ["#new", "#old"])

    def test_a_token_without_the_scope_is_not_asked(self):
        """An app installed before this feature existed has no stars:read, and
        the sidebar keeps the order it always had rather than erroring."""
        class Explode(slack.Slack):
            def call(self, *a, **k):
                raise AssertionError("asked Slack without the scope")

        found, problem = slack.starred_ids(Explode("x"), "demo", {"scopes": "channels:read"})
        self.assertEqual((found, problem), (set(), ""))

    def test_only_the_items_that_are_conversations_count(self):
        """Starring a message is not starring the conversation it is in, and a
        starred message carries the channel it lives in."""
        captured = {}

        class Fake(slack.Slack):
            def paged(self, method, params, key, cap):
                captured["method"] = method
                return [{"type": "message", "channel": "C_message"},
                        {"type": "channel", "channel": "C_real"},
                        {"type": "im", "channel": "D_real"},
                        {"type": "file", "file": {"id": "F1"}}], ""

        with tempfile.TemporaryDirectory() as cache:
            slack.CACHE_DIR = cache
            found, problem = slack.starred_ids(
                Fake("x"), "demo", {"scopes": "stars:read"}, fresh=True)
        self.assertEqual(captured["method"], "stars.list")
        self.assertEqual(found, {"C_real", "D_real"})
        self.assertEqual(problem, "")


class OutgoingEscape(unittest.TestCase):
    """A message on its way out, escaped - with mentions let back through.

    Slack escapes exactly three characters and a message that does not escape
    them can turn a stray `<` into somebody else's link. But a mention *is*
    `<@U024BE7LH>` on the wire, so the composer's completed mentions arrived as
    the literal text `&lt;@U024BE7LH&gt;` - visible punctuation instead of a
    name. Exactly two shapes are restored, which is what keeps the escape worth
    having.
    """

    def test_a_stray_angle_bracket_is_still_escaped(self):
        self.assertEqual(slack.escape_outgoing("a < b and c > d"),
                         "a &lt; b and c &gt; d")

    def test_an_ampersand_is_still_escaped(self):
        self.assertEqual(slack.escape_outgoing("plain & simple"), "plain &amp; simple")

    def test_a_user_mention_survives(self):
        self.assertEqual(slack.escape_outgoing("hi <@U024BE7LH> please look"),
                         "hi <@U024BE7LH> please look")

    def test_the_other_id_prefixes_survive_too(self):
        # W is an enterprise user and B is a bot; both are ids a mention can name.
        for token in ("<@W012ABC>", "<@B012ABC>"):
            self.assertEqual(slack.escape_outgoing(token), token)

    def test_the_three_broadcasts_survive(self):
        for token in ("<!here>", "<!channel>", "<!everyone>"):
            self.assertEqual(slack.escape_outgoing("shout " + token), "shout " + token)

    def test_any_other_bang_form_stays_escaped(self):
        # Slack has more of them - subteam, date - and none are offered by the
        # composer, so none are handed to Slack to interpret.
        self.assertEqual(slack.escape_outgoing("<!subteam^S123>"),
                         "&lt;!subteam^S123&gt;")
        self.assertEqual(slack.escape_outgoing("<!date^1234^{date}>"),
                         "&lt;!date^1234^{date}&gt;")

    def test_a_label_part_stays_escaped_because_it_is_slacks_to_write(self):
        self.assertEqual(slack.escape_outgoing("<@U024BE7LH|jan>"),
                         "&lt;@U024BE7LH|jan&gt;")

    def test_something_that_only_looks_like_an_id_stays_escaped(self):
        self.assertEqual(slack.escape_outgoing("<@lowercase>"), "&lt;@lowercase&gt;")
        self.assertEqual(slack.escape_outgoing("<@U1>"), "&lt;@U1&gt;")

    def test_a_link_somebody_typed_is_still_not_a_link(self):
        self.assertEqual(slack.escape_outgoing("<https://evil/|click>"),
                         "&lt;https://evil/|click&gt;")

    def test_several_mentions_in_one_message_all_survive(self):
        self.assertEqual(
            slack.escape_outgoing("<@U024BE7LH> and <@U024BE7LX>, see <!here>"),
            "<@U024BE7LH> and <@U024BE7LX>, see <!here>")


class SigningOut(unittest.TestCase):
    """Sign out has to leave nothing behind that says otherwise.

    The bug: the token was deleted and the finished snapshot was not, so the
    next fetch handed the snapshot back, the window went on drawing a
    signed-in workspace, and the box you paste a token into never appeared.
    """

    def workspace(self, cache, state):
        slack.CACHE_DIR = cache
        slack.STATE_DIR = state
        os.makedirs(os.path.join(cache, "work", "transcripts"), exist_ok=True)
        os.makedirs(state, exist_ok=True)
        slack.write_json(slack.cache_path("work", "snapshot.json"),
                         {"at": time.time(),
                          "snapshot": {"ok": True, "accounts": [{"ok": True, "team": "Somewhere"}]}})
        for name in ("previews.json", "list.json", "threads.json", "marks.json"):
            slack.write_json(slack.cache_path("work", name), {"kept": True})
        slack.write_json(slack.cache_path("work", "transcripts/C1.json"), {"kept": True})
        slack.write_json(slack.state_path("work"), {"token": "xoxp-test"})

    def test_a_snapshot_is_not_handed_over_once_the_token_is_gone(self):
        with tempfile.TemporaryDirectory() as cache, tempfile.TemporaryDirectory() as state:
            self.workspace(cache, state)
            # With the token there, the cache is exactly what it is for.
            self.assertIsNotNone(slack.cached_snapshot("work", max_age=900))
            os.remove(slack.state_path("work"))
            # Without it, there is nothing this could be a copy of.
            self.assertIsNone(slack.cached_snapshot("work", max_age=900))

    def test_signing_out_forgets_every_cache_and_not_three_files(self):
        with tempfile.TemporaryDirectory() as cache, tempfile.TemporaryDirectory() as state:
            self.workspace(cache, state)
            args = Args()
            args.account = "work"
            self.assertTrue(capture(slack.cmd_remove, args)["removed"])
            self.assertFalse(os.path.exists(slack.state_path("work")))
            self.assertFalse(os.path.exists(os.path.join(cache, "work")))

    def test_signing_out_of_a_workspace_that_was_never_in_says_so_quietly(self):
        with tempfile.TemporaryDirectory() as cache, tempfile.TemporaryDirectory() as state:
            slack.CACHE_DIR = cache
            slack.STATE_DIR = state
            args = Args()
            args.account = "work"
            answer = capture(slack.cmd_remove, args)
            self.assertTrue(answer["ok"])
            self.assertFalse(answer["removed"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
