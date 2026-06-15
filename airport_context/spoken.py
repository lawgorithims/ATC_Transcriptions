"""
Spoken-form generation for ATC context (spec section 12).

These are pure functions with no I/O so they can be unit-tested directly and
reused at both ingestion time (precomputing ``spoken_ident``) and runtime.

Design choices that follow the spec:
* Runway and frequency digits are spoken individually ("three zero left", not
  "thirty left"), because ATC speaks runway/frequency digits one at a time.
* The aviation digit set uses "niner" for 9; "tree"/"fife" variants are surfaced
  only as spelling hints (see phrases.py), not in the main spoken forms.
* Callsign flight numbers also get a *grouped* natural form ("twelve thirty
  four") in addition to digit-by-digit, since ATC readbacks use both.
"""

from __future__ import annotations

import re
from typing import Optional

# Aviation pronunciation of single digits (spec section 12).
AVIATION_DIGITS = {
    "0": "zero",
    "1": "one",
    "2": "two",
    "3": "three",
    "4": "four",
    "5": "five",
    "6": "six",
    "7": "seven",
    "8": "eight",
    "9": "niner",
}

# ICAO phonetic alphabet.
PHONETIC = {
    "A": "alpha",
    "B": "bravo",
    "C": "charlie",
    "D": "delta",
    "E": "echo",
    "F": "foxtrot",
    "G": "golf",
    "H": "hotel",
    "I": "india",
    "J": "juliet",
    "K": "kilo",
    "L": "lima",
    "M": "mike",
    "N": "november",
    "O": "oscar",
    "P": "papa",
    "Q": "quebec",
    "R": "romeo",
    "S": "sierra",
    "T": "tango",
    "U": "uniform",
    "V": "victor",
    "W": "whiskey",
    "X": "xray",
    "Y": "yankee",
    "Z": "zulu",
}

_RUNWAY_SUFFIX = {"L": "left", "R": "right", "C": "center"}

# Natural cardinal words 0-99, used only for *grouped* callsign flight numbers.
_ONES = [
    "zero", "one", "two", "three", "four",
    "five", "six", "seven", "eight", "nine",
]
_TEENS = [
    "ten", "eleven", "twelve", "thirteen", "fourteen",
    "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
]
_TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]


def speak_digits(s: str) -> str:
    """Speak each digit individually: '307' -> 'three zero seven'."""
    return " ".join(AVIATION_DIGITS[ch] for ch in str(s) if ch.isdigit())


def speak_alnum(s: str) -> str:
    """Speak digits aviation-style and letters phonetically: '5AB' -> 'five alpha bravo'."""
    out = []
    for ch in str(s).upper():
        if ch.isdigit():
            out.append(AVIATION_DIGITS[ch])
        elif ch.isalpha():
            out.append(PHONETIC.get(ch, ch.lower()))
    return " ".join(out)


def cardinal_two_digit(n: int) -> str:
    """Natural cardinal for 0-99: 34 -> 'thirty four', 12 -> 'twelve'."""
    if n < 0 or n > 99:
        raise ValueError("cardinal_two_digit expects 0-99")
    if n < 10:
        return _ONES[n]
    if n < 20:
        return _TEENS[n - 10]
    tens, ones = divmod(n, 10)
    return _TENS[tens] + ((" " + _ONES[ones]) if ones else "")


_RUNWAY_IDENT_RE = re.compile(r"^\s*(\d{1,2})\s*([LRC](?:\s*/?\s*[LRC])*)?\s*$")


def runway_spoken(ident: str) -> str:
    """'30L' -> 'runway three zero left'; '04' -> 'runway zero four'; '4' -> 'runway four'.

    Multi-side idents are spoken in full: '28L/R' -> 'runway two eight left right',
    '16 R/C/L' -> 'runway one six right center left'. Non-standard idents (e.g.
    helipad 'H1') are passed through unchanged.
    """
    ident = (ident or "").strip().upper()
    if not ident:
        return ""
    m = _RUNWAY_IDENT_RE.match(ident)
    if not m:
        return ident  # not a normal runway number
    digits, sides = m.group(1), m.group(2) or ""
    spoken = "runway " + " ".join(AVIATION_DIGITS[d] for d in digits)
    side_words = [_RUNWAY_SUFFIX[c] for c in sides if c in _RUNWAY_SUFFIX]
    if side_words:
        spoken += " " + " ".join(side_words)
    return spoken


def frequency_spoken(mhz) -> str:
    """'118.7' -> 'one one eight point seven'; '120.95' -> 'one two zero point niner five'."""
    out = []
    for ch in str(mhz).strip():
        if ch.isdigit():
            out.append(AVIATION_DIGITS[ch])
        elif ch == ".":
            out.append("point")
    return " ".join(out)


def grouped_number(num: str) -> Optional[str]:
    """Natural grouped reading of a callsign flight number, or None if ambiguous.

    Produces forms ATC actually uses ('twelve thirty four', 'fifty six seventy',
    'two twenty one', 'one hundred') and declines awkward cases (leading zeros,
    mixed groups like 1205) so the renderer falls back to digit-by-digit.
    """
    s = str(num)
    if not s.isdigit():
        return None
    length = len(s)
    if length == 1:
        return cardinal_two_digit(int(s))
    if length == 2:
        if s[0] == "0":
            return None
        return cardinal_two_digit(int(s))
    if length == 3:
        a = int(s[0])
        tail = s[1:]
        if tail == "00":
            return f"{cardinal_two_digit(a)} hundred"
        if 10 <= int(tail) <= 99:
            return f"{cardinal_two_digit(a)} {cardinal_two_digit(int(tail))}"
        return None
    if length == 4:
        if s[0] == "0":
            return None
        head, tail = s[:2], s[2:]
        if tail == "00":
            if s[1] == "0":  # X000 reads as "X thousand" (e.g. 2000 -> two thousand)
                return f"{_ONES[int(s[0])]} thousand"
            return f"{cardinal_two_digit(int(head))} hundred"
        if 10 <= int(tail) <= 99:
            return f"{cardinal_two_digit(int(head))} {cardinal_two_digit(int(tail))}"
        return None
    return None


def titlecase_telephony(name: str) -> str:
    """Keep curated telephony names as-is (they may be mixed-case like 'SkyWest')."""
    return name
