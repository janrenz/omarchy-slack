#!/usr/bin/env python3
"""Slack emoji shortcodes, as the characters they stand for.

Slack does not send emoji as characters. A message arrives with `:tada:` in
the text and a reaction arrives as the name `tada`, and it is up to the client
to know what that draws. Teams hands over the character in the tag's alt and
needs no table at all; Slack needs one, so here it is.

Only the names worth having. A workspace's custom emoji (`:blob-wave:`,
`:shipit:`) cannot be in any table - they are pictures uploaded to that
workspace - so anything unknown is left as the `:name:` it was, which is what
a reader would see in a terminal client and is at least honest about what was
sent.

Standard library only, no data files: a dict is smaller than the code that
would parse one.
"""

import re

# name -> the character. Aliases share a character on purpose: Slack sends
# whichever the sender's client wrote, and both have to draw.
EMOJI = {
    # the ones that carry a conversation
    "+1": "\U0001F44D", "thumbsup": "\U0001F44D", "yes": "\U0001F44D",
    "-1": "\U0001F44E", "thumbsdown": "\U0001F44E",
    "ok_hand": "\U0001F44C", "clap": "\U0001F44F", "raised_hands": "\U0001F64C",
    "pray": "\U0001F64F", "muscle": "\U0001F4AA", "wave": "\U0001F44B",
    "point_up": "☝️", "point_down": "\U0001F447", "point_left": "\U0001F448",
    "point_right": "\U0001F449", "handshake": "\U0001F91D", "writing_hand": "✍️",
    "eyes": "\U0001F440", "brain": "\U0001F9E0", "ear": "\U0001F442",

    # faces
    "smile": "\U0001F604", "smiley": "\U0001F603", "grin": "\U0001F601",
    "grinning": "\U0001F600", "laughing": "\U0001F606", "satisfied": "\U0001F606",
    "joy": "\U0001F602", "rofl": "\U0001F923", "sweat_smile": "\U0001F605",
    "slightly_smiling_face": "\U0001F642", "upside_down_face": "\U0001F643",
    "wink": "\U0001F609", "blush": "\U0001F60A", "innocent": "\U0001F607",
    "heart_eyes": "\U0001F60D", "kissing_heart": "\U0001F618", "yum": "\U0001F60B",
    "stuck_out_tongue": "\U0001F61B", "stuck_out_tongue_winking_eye": "\U0001F61C",
    "zany_face": "\U0001F92A", "sunglasses": "\U0001F60E", "nerd_face": "\U0001F913",
    "thinking_face": "\U0001F914", "face_with_monocle": "\U0001F9D0",
    "neutral_face": "\U0001F610", "expressionless": "\U0001F611",
    "no_mouth": "\U0001F636", "smirk": "\U0001F60F", "unamused": "\U0001F612",
    "roll_eyes": "\U0001F644", "face_with_raised_eyebrow": "\U0001F928",
    "grimacing": "\U0001F62C", "lying_face": "\U0001F925", "relieved": "\U0001F60C",
    "pensive": "\U0001F614", "sleepy": "\U0001F62A", "sleeping": "\U0001F634",
    "mask": "\U0001F637", "face_with_thermometer": "\U0001F912",
    "nauseated_face": "\U0001F922", "sneezing_face": "\U0001F927",
    "dizzy_face": "\U0001F635", "exploding_head": "\U0001F92F",
    "cowboy_hat_face": "\U0001F920", "partying_face": "\U0001F973",
    "confused": "\U0001F615", "worried": "\U0001F61F", "slightly_frowning_face": "\U0001F641",
    "frowning_face": "☹️", "persevere": "\U0001F623", "confounded": "\U0001F616",
    "tired_face": "\U0001F62B", "weary": "\U0001F629", "cry": "\U0001F622",
    "sob": "\U0001F62D", "triumph": "\U0001F624", "angry": "\U0001F620",
    "rage": "\U0001F621", "exploding": "\U0001F92F", "scream": "\U0001F631",
    "flushed": "\U0001F633", "zipper_mouth_face": "\U0001F910",
    "money_mouth_face": "\U0001F911", "hugging_face": "\U0001F917",
    "face_palm": "\U0001F926", "facepalm": "\U0001F926", "shrug": "\U0001F937",
    "man_shrugging": "\U0001F937", "woman_shrugging": "\U0001F937",
    "open_mouth": "\U0001F62E", "astonished": "\U0001F632", "hushed": "\U0001F62F",
    "smiling_face_with_tear": "\U0001F972", "melting_face": "\U0001FAE0",
    "salute": "\U0001FAE1", "saluting_face": "\U0001FAE1",

    # hearts and marks
    "heart": "❤️", "orange_heart": "\U0001F9E1", "yellow_heart": "\U0001F49B",
    "green_heart": "\U0001F49A", "blue_heart": "\U0001F499", "purple_heart": "\U0001F49C",
    "black_heart": "\U0001F5A4", "white_heart": "\U0001F90D", "broken_heart": "\U0001F494",
    "sparkling_heart": "\U0001F496", "heartpulse": "\U0001F497",
    # The card suits, which are not the hearts above them: `:hearts:` is the
    # suit and `:heart:` is the feeling, and a workspace reacts with both.
    "hearts": "♥️", "spades": "♠️", "clubs": "♣️", "diamonds": "♦️",
    "star": "⭐", "star2": "\U0001F31F", "sparkles": "✨", "boom": "\U0001F4A5",
    "fire": "\U0001F525", "zap": "⚡", "dizzy": "\U0001F4AB", "100": "\U0001F4AF",
    "white_check_mark": "✅", "heavy_check_mark": "✔️",
    "ballot_box_with_check": "☑️", "x": "❌", "negative_squared_cross_mark": "❎",
    "heavy_plus_sign": "➕", "heavy_minus_sign": "➖",
    "question": "❓", "grey_question": "❔", "exclamation": "❗",
    "warning": "⚠️", "no_entry": "⛔", "no_entry_sign": "\U0001F6AB",
    "bangbang": "‼️", "interrobang": "⁉️",
    "arrow_right": "➡️", "arrow_left": "⬅️",
    "arrow_up": "⬆️", "arrow_down": "⬇️",
    "recycle": "♻️", "wheel_of_dharma": "☸️",

    # the working day
    "tada": "\U0001F389", "confetti_ball": "\U0001F38A", "trophy": "\U0001F3C6",
    "medal": "\U0001F3C5", "rocket": "\U0001F680", "ship": "\U0001F6A2",
    "shipit": "\U0001F680", "hammer": "\U0001F528", "wrench": "\U0001F527",
    "hammer_and_wrench": "\U0001F6E0️", "gear": "⚙️", "nut_and_bolt": "\U0001F529",
    "bug": "\U0001F41B", "beetle": "\U0001FAB2", "ant": "\U0001F41C",
    "computer": "\U0001F4BB", "keyboard": "⌨️", "desktop_computer": "\U0001F5A5️",
    "iphone": "\U0001F4F1", "telephone": "☎️", "phone": "☎️",
    "email": "✉️", "envelope": "✉️", "inbox_tray": "\U0001F4E5",
    "outbox_tray": "\U0001F4E4", "package": "\U0001F4E6", "memo": "\U0001F4DD",
    "pencil": "✏️", "pencil2": "✏️", "page_facing_up": "\U0001F4C4",
    "clipboard": "\U0001F4CB", "calendar": "\U0001F4C5", "date": "\U0001F4C6",
    "chart_with_upwards_trend": "\U0001F4C8", "chart_with_downwards_trend": "\U0001F4C9",
    "bar_chart": "\U0001F4CA", "books": "\U0001F4DA", "book": "\U0001F4D6",
    "bookmark": "\U0001F516", "link": "\U0001F517", "paperclip": "\U0001F4CE",
    "lock": "\U0001F512", "unlock": "\U0001F513", "key": "\U0001F511",
    "mag": "\U0001F50D", "bulb": "\U0001F4A1", "hourglass": "⌛",
    "hourglass_flowing_sand": "⏳", "alarm_clock": "⏰", "watch": "⌚",
    "stopwatch": "⏱️", "clock": "\U0001F551", "calendar_spiral": "\U0001F5D3️",
    "construction": "\U0001F6A7", "traffic_light": "\U0001F6A6", "checkered_flag": "\U0001F3C1",
    "triangular_flag_on_post": "\U0001F6A9", "round_pushpin": "\U0001F4CD", "pushpin": "\U0001F4CC",
    "megaphone": "\U0001F4E3", "loudspeaker": "\U0001F4E2", "bell": "\U0001F514",
    "no_bell": "\U0001F515", "mailbox": "\U0001F4EB", "satellite": "\U0001F6F0️",
    "bank": "\U0001F3E6", "office": "\U0001F3E2", "house": "\U0001F3E0",
    "moneybag": "\U0001F4B0", "dollar": "\U0001F4B5", "credit_card": "\U0001F4B3",
    "scroll": "\U0001F4DC", "wastebasket": "\U0001F5D1️", "floppy_disk": "\U0001F4BE",
    "cd": "\U0001F4BF", "battery": "\U0001F50B", "electric_plug": "\U0001F50C",
    "microscope": "\U0001F52C", "telescope": "\U0001F52D", "test_tube": "\U0001F9EA",
    "dart": "\U0001F3AF", "game_die": "\U0001F3B2", "crystal_ball": "\U0001F52E",
    "compass": "\U0001F9ED", "world_map": "\U0001F5FA️", "airplane": "✈️",
    "car": "\U0001F697", "bike": "\U0001F6B2", "train": "\U0001F686",
    "bus": "\U0001F68C", "taxi": "\U0001F695", "fuelpump": "⛽",

    # food and weather, because standups have both
    "coffee": "☕", "tea": "\U0001F375", "beer": "\U0001F37A", "beers": "\U0001F37B",
    "wine_glass": "\U0001F377", "cocktail": "\U0001F378", "champagne": "\U0001F37E",
    "cake": "\U0001F370", "birthday": "\U0001F382", "cookie": "\U0001F36A",
    "doughnut": "\U0001F369", "pizza": "\U0001F355", "hamburger": "\U0001F354",
    "fries": "\U0001F35F", "taco": "\U0001F32E", "sushi": "\U0001F363",
    "bread": "\U0001F35E", "cheese": "\U0001F9C0", "apple": "\U0001F34E",
    "banana": "\U0001F34C", "strawberry": "\U0001F353", "watermelon": "\U0001F349",
    "avocado": "\U0001F951", "carrot": "\U0001F955", "corn": "\U0001F33D",
    "hot_pepper": "\U0001F336️", "salt": "\U0001F9C2", "popcorn": "\U0001F37F",
    "sunny": "☀️", "partly_sunny": "⛅", "cloud": "☁️",
    "rain_cloud": "\U0001F327️", "snowflake": "❄️", "snowman": "⛄",
    "umbrella": "☔", "rainbow": "\U0001F308", "ocean": "\U0001F30A",
    "droplet": "\U0001F4A7", "sweat_drops": "\U0001F4A6", "moon": "\U0001F314",
    "crescent_moon": "\U0001F319", "earth_africa": "\U0001F30D", "earth_americas": "\U0001F30E",
    "earth_asia": "\U0001F30F", "seedling": "\U0001F331", "herb": "\U0001F33F",
    "four_leaf_clover": "\U0001F340", "maple_leaf": "\U0001F341", "mushroom": "\U0001F344",
    "cactus": "\U0001F335", "palm_tree": "\U0001F334", "evergreen_tree": "\U0001F332",
    "sunflower": "\U0001F33B", "rose": "\U0001F339", "tulip": "\U0001F337",
    "bouquet": "\U0001F490",

    # the menagerie
    "dog": "\U0001F436", "cat": "\U0001F431", "mouse": "\U0001F42D", "hamster": "\U0001F439",
    "rabbit": "\U0001F430", "fox_face": "\U0001F98A", "bear": "\U0001F43B",
    "panda_face": "\U0001F43C", "koala": "\U0001F428", "tiger": "\U0001F42F",
    "lion_face": "\U0001F981", "cow": "\U0001F42E", "pig": "\U0001F437",
    "frog": "\U0001F438", "monkey_face": "\U0001F435", "see_no_evil": "\U0001F648",
    "hear_no_evil": "\U0001F649", "speak_no_evil": "\U0001F64A", "chicken": "\U0001F414",
    "penguin": "\U0001F427", "bird": "\U0001F426", "duck": "\U0001F986",
    "owl": "\U0001F989", "bee": "\U0001F41D", "butterfly": "\U0001F98B",
    "snail": "\U0001F40C", "turtle": "\U0001F422", "snake": "\U0001F40D",
    "octopus": "\U0001F419", "fish": "\U0001F41F", "whale": "\U0001F433",
    "dolphin": "\U0001F42C", "crab": "\U0001F980", "unicorn_face": "\U0001F984",
    "dragon": "\U0001F409", "sloth": "\U0001F9A5", "hedgehog": "\U0001F994",

    # people-ish
    "ghost": "\U0001F47B", "alien": "\U0001F47D", "robot_face": "\U0001F916",
    "skull": "\U0001F480", "poop": "\U0001F4A9", "clown_face": "\U0001F921",
    "santa": "\U0001F385", "eyes_closed": "\U0001F636", "zzz": "\U0001F4A4",
    "man": "\U0001F468", "woman": "\U0001F469", "baby": "\U0001F476",
    "sos": "\U0001F198", "sparkler": "\U0001F387", "balloon": "\U0001F388",
    "gift": "\U0001F381", "ribbon": "\U0001F380", "crown": "\U0001F451",
    "gem": "\U0001F48E", "guitar": "\U0001F3B8", "musical_note": "\U0001F3B5",
    "notes": "\U0001F3B6", "headphones": "\U0001F3A7", "microphone": "\U0001F3A4",
    "clapper": "\U0001F3AC", "art": "\U0001F3A8", "circus_tent": "\U0001F3AA",
    "soccer": "⚽", "basketball": "\U0001F3C0", "football": "\U0001F3C8",
    "tennis": "\U0001F3BE", "8ball": "\U0001F3B1", "chess_pawn": "♟️",
}

# What the reaction picker offers. Slack takes any name in the workspace, so
# this is a shortlist rather than a limit: nine, because nine can be numbered
# and reached without leaving the home row. The tenth thing anyone wants is
# never the same tenth thing, and the message box is right there.
PICKER = [
    "+1", "heart", "joy", "tada", "eyes", "white_check_mark", "rocket", "pray", "sob",
]

# `:wave::skin-tone-3:` - the modifier is a shortcode of its own, written
# straight after the hand it modifies. Nothing here draws skin tones, so they come off
# rather than being left as five stray characters in the middle of a sentence.
SKIN_TONE = re.compile(r":skin-tone-\d:")
SHORTCODE = re.compile(r":([a-z0-9_+\-']{1,64}):")


def char_for(name):
    """The character `:name:` stands for, or "" if this table has never heard of it.

    A reaction carries its skin tone welded on with a double colon -
    `ok_hand::skin-tone-2` - rather than as the separate shortcode a message
    body uses. Looked up whole, every toned hand in a workspace missed the
    table and drew as the text `:ok_hand:`, which is the one case where the
    name-instead-of-a-picture fallback is wrong: the emoji is right there, only
    spelled with a modifier this table does not keep. So the modifier comes off
    before the lookup, the same way `expand` takes it out of a sentence.
    """
    base = str(name or "").strip().lower().strip(":").split("::")[0]
    return EMOJI.get(base, "")


def expand(text):
    """A message with the shortcodes it knows replaced by characters.

    Unknown names are left exactly as they arrived. A workspace's own emoji
    are pictures that live in that workspace and cannot be in any table, and
    `:blob-wave:` at least says what was meant; a blank does not.
    """
    without_tones = SKIN_TONE.sub("", str(text or ""))
    return SHORTCODE.sub(
        lambda match: EMOJI.get(match.group(1).lower(), match.group(0)), without_tones)


def picker_rows():
    """The reactions the picker offers, as {name, emoji}."""
    return [{"name": name, "emoji": EMOJI.get(name, ":%s:" % name)} for name in PICKER]
