"""Unit tests for scoreboard.write_report (marker-region splice — the guard
that keeps a re-run from destroying RESULTS.md's hand-written analysis).

Run from python-legacy/:  python tests/test_scoreboard_report.py
"""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dataset.scoreboard import write_report, _MARK_BEGIN, _MARK_END

_results = []


def check(name, fn):
    try:
        fn()
        _results.append((name, True, ""))
    except AssertionError as e:
        _results.append((name, False, str(e)))


def _tmp(name="report.md"):
    return Path(tempfile.mkdtemp()) / name


def test_fresh_target_gets_wrapped_report():
    out = _tmp()
    write_report(out, "# Title\n\n| a | b |\n")
    text = out.read_text(encoding="utf-8")
    assert text.startswith(_MARK_BEGIN + "\n"), "report must open with the begin marker"
    assert text.rstrip("\n").endswith(_MARK_END), "report must close with the end marker"
    assert "# Title" in text and "| a | b |" in text


def test_marker_region_replaced_hand_content_preserved():
    out = _tmp()
    out.write_text(
        "prelude that must survive\n\n"
        f"{_MARK_BEGIN}\nOLD TABLE\n{_MARK_END}\n\n"
        "## Hand-written analysis\nmust survive too\n",
        encoding="utf-8",
    )
    write_report(out, "NEW TABLE\n")
    text = out.read_text(encoding="utf-8")
    assert "OLD TABLE" not in text, "stale generated region must be replaced"
    assert "NEW TABLE" in text
    assert "prelude that must survive" in text, "content before the region was lost"
    assert "## Hand-written analysis\nmust survive too" in text, "content after the region was lost"


def test_rerun_is_idempotent():
    out = _tmp()
    out.write_text(
        f"{_MARK_BEGIN}\nOLD\n{_MARK_END}\n\n## Analysis\nkept\n", encoding="utf-8"
    )
    write_report(out, "TABLE\n")
    first = out.read_text(encoding="utf-8")
    write_report(out, "TABLE\n")
    assert out.read_text(encoding="utf-8") == first, "second identical run must be a no-op"


def test_existing_file_without_markers_is_refused():
    out = _tmp()
    out.write_text("# Hand-written doc\nirreplaceable\n", encoding="utf-8")
    try:
        write_report(out, "TABLE\n")
        assert False, "expected SystemExit for a marker-less existing file"
    except SystemExit as e:
        assert "refusing" in str(e)
    assert out.read_text(encoding="utf-8") == "# Hand-written doc\nirreplaceable\n", \
        "refused write must leave the file untouched"


def test_end_marker_before_begin_is_refused():
    out = _tmp()
    out.write_text(f"{_MARK_END}\ngarbled\n{_MARK_BEGIN}\n", encoding="utf-8")
    try:
        write_report(out, "TABLE\n")
        assert False, "expected SystemExit for a garbled marker order"
    except SystemExit:
        pass


if __name__ == "__main__":
    for name, fn in sorted((k, v) for k, v in list(globals().items())
                           if k.startswith("test_") and callable(v)):
        check(name, fn)
    failed = [r for r in _results if not r[1]]
    for name, ok, msg in _results:
        print(f"{'PASS' if ok else 'FAIL'}  {name}{('  ' + msg) if msg else ''}")
    print(f"{len(_results) - len(failed)}/{len(_results)} passed")
    raise SystemExit(1 if failed else 0)
