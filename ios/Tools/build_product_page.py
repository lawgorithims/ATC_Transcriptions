#!/usr/bin/env python3
"""Turn APP_STORE_LISTING.md into a paste-ready App Store Connect product page.

Two jobs:

1. Unwrap the description. The markdown source is hard-wrapped at 100 columns for review;
   App Store Connect preserves newlines verbatim, so pasting it as-is puts ragged line
   breaks in the middle of sentences on the live product page. Paragraphs and bullets
   become single lines here; blank lines and ALL-CAPS section headers are kept.

2. Measure every field against Apple's real limit, so nothing is estimated.
"""

import re
import sys
from pathlib import Path

LISTING = Path(sys.argv[1])
OUT = Path(sys.argv[2])

text = LISTING.read_text(encoding="utf-8")


def fenced_block_after(heading: str) -> str:
    """The first ``` block following a heading."""
    start = text.index(heading)
    fence = text.index("```", start) + 3
    end = text.index("```", fence)
    return text[fence:end].strip("\n")


def unwrap(block: str) -> str:
    out: list[str] = []
    buf: list[str] = []

    def flush() -> None:
        if buf:
            out.append(" ".join(s.strip() for s in buf))
            buf.clear()

    for line in block.split("\n"):
        stripped = line.strip()
        if not stripped:                      # blank line: a real paragraph break
            flush()
            out.append("")
        elif stripped.startswith("•"):        # a bullet starts a new block
            flush()
            buf.append(stripped)
        elif line.startswith("  ") and buf:   # indented: continuation of the bullet above
            buf.append(stripped)
        elif stripped.isupper():              # an all-caps line is a section header
            flush()
            out.append(stripped)
        else:
            buf.append(stripped)
    flush()
    return "\n".join(out).strip("\n")


description = unwrap(fenced_block_after("## 2. Description"))
review_notes = unwrap(fenced_block_after("## 5. App Review notes"))

# Keywords and promotional text are single-line fields already; read them from their blocks.
keywords = fenced_block_after("**Keywords**").strip()
promo = unwrap(fenced_block_after("**Promotional text**"))

FIELDS = [
    ("App Name",            "Obelisk EFB",                                  30),
    ("Subtitle",            "Offline electronic flight bag",                30),
    ("Promotional Text",    promo,                                          170),
    ("Keywords",            keywords,                                       100),
    ("Description",         description,                                    4000),
    ("Support URL",         "https://obeliskaerospace.com",                 None),
    ("Marketing URL",       "https://obeliskaerospace.com",                 None),
    ("Privacy Policy URL",  "https://obeliskaerospace.com/legal/privacy",   None),
    ("Copyright",           "2026 Obelisk Aerospace LLC",                   None),
]

lines = [
    "OBELISK — APP STORE CONNECT PRODUCT PAGE",
    "",
    "Every field below is paste-ready: the text is already unwrapped, so what you paste is",
    "what the product page shows. Counts are measured, not estimated.",
    "",
    "Generated from APP_STORE_LISTING.md by Tools/build_product_page.py — edit the markdown",
    "and regenerate rather than editing this file, or the two will drift.",
    "",
    "=" * 86,
    "",
]

over = []
for name, value, limit in FIELDS:
    n = len(value)
    if limit is None:
        head = f"{name}"
    else:
        head = f"{name}  [{n} / {limit}]"
        if n > limit:
            over.append((name, n, limit))
    lines += [head, "-" * len(head), value, "", ""]

lines += [
    "=" * 86,
    "",
    "APP REVIEW INFORMATION -> NOTES",
    "-" * 31,
    review_notes,
    "",
    "",
    "=" * 86,
    "",
    "SIGN-IN INFORMATION",
    "-" * 19,
    "Leave 'Sign-in required' UNCHECKED, and provide no demo account.",
    "No feature in the app is behind a login: EntitlementStore.resolve() grants every",
    "capability unconditionally and never reads the account. See APP_STORE_LISTING.md §5.",
    "",
    "=" * 86,
    "",
    "CATEGORY, RATING, PRICE",
    "-" * 23,
    "Primary category    Navigation",
    "Secondary category  Weather",
    "Age rating          4+  (answer 'None' to every questionnaire item)",
    "Price               Free, no in-app purchases in this build",
    "",
    "=" * 86,
    "",
    "APP PRIVACY  (must match ATCTranscribe/PrivacyInfo.xcprivacy — Apple compares them)",
    "-" * 82,
    "Collect data from this app?  YES",
    "",
    "  Contact Info -> Email Address    linked: YES   tracking: no   App Functionality",
    "  Contact Info -> Name             linked: YES   tracking: no   App Functionality",
    "  Identifiers  -> User ID          linked: YES   tracking: no   App Functionality",
    "  Location     -> Precise Location linked: NO    tracking: no   App Functionality",
    "",
    "Tracking across apps and websites:  NO.  Tracking domains list:  empty.",
    "Nothing else is collected — no usage data, diagnostics, contacts, photos, purchase",
    "or search history, and no identifier beyond the account's own user id.",
    "",
    "=" * 86,
    "",
    "SCREENSHOTS",
    "-" * 11,
    "iPhone 6.9\"  ->  screenshots/iphone-6.9/   five, 1320 x 2868",
    "iPad 13\"     ->  screenshots/ipad-13/      five, 2064 x 2752",
    "Upload in filename order; 01 leads the page.",
    "",
    "App icon: app-icon-1024.png (1024x1024, RGB, no alpha). App Store Connect normally",
    "takes the icon from the build itself — this copy is here in case it asks.",
    "",
]

OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")

print(f"wrote {OUT}")
for name, value, limit in FIELDS:
    flag = "" if limit is None or len(value) <= limit else "   <-- OVER LIMIT"
    shown = f"{len(value)} / {limit}" if limit else f"{len(value)} chars"
    print(f"  {name:<20} {shown}{flag}")
if over:
    sys.exit(f"over Apple's limit: {over}")
