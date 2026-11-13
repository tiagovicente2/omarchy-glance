"""Tests for sync/caldir_export.py and the meeting-link gate in Model.js.

Run: python3 -m unittest tests/test_caldir_export.py

No network and no real caldir: every test that needs caldir writes a fake
`caldir` shell script into a temporary directory.
"""

from __future__ import annotations

import contextlib
import fcntl
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "sync"))

import caldir_export as ce  # noqa: E402

# Every row of the M1 table in the exporter review, plus close variants. Each
# must be refused by both the Python exporter and Model.safeUrl.
UNSAFE_URLS = [
    "https://meet.google.com.evil.example/",
    "https://meet.google.com@evil.example/",
    "https://evil.example\\@meet.google.com/abc",
    "https://evil.example\\.zoom.us/",
    "https://evil.example%2F.zoom.us/",
    "https://evil.example%40.zoom.us/",
    "https://evil.example%5C.zoom.us/",
    "https://evil.example%23.zoom.us/",
    "https://a@evil.example@meet.google.com/",
    "https://user:pw@meet.google.com:444/x",
    "https://meet.google.com:444/x",
    "https://meet.google.com:99999/x",
    "https://evil.example\x01@meet.google.com/",
    "https://meet.google.com\x01/abc",
    "https://meet.google.com/abc\\def",
    "https://meet.google.com/abc%5cdef",
    "https://meet.google.com/abc%00",
    "https://meet.google.com/abc%2541",
    "https://meet.google.com/abc%zz",
    "https://meet.google.com/a b",
    "https://evil.example/",
    "http://meet.google.com/abc",
    "javascript:alert(1)//meet.google.com",
    "https://notzoom.us/j/1",
    "https://zoom.us.evil.example/j/1",
    "https://meet.google.com\uff20evil.example/",
    "https://evil.example\uff0fmeet.google.com/",
    "https://meet\u3002google.com/abc",
    "https://1.2.3.4/",
    "https://meet.google.com:/x",
    "https://" + "a" * 250 + ".zoom.us/",
    "https://meet.google.com/" + "a" * 5000,
]

SAFE_URLS = {
    "https://meet.google.com/abc-defg-hij": "https://meet.google.com/abc-defg-hij",
    "https://meet.google.com:443/abc": "https://meet.google.com/abc",
    "https://MEET.Google.COM/abc": "https://meet.google.com/abc",
    "HTTPS://meet.google.com/abc": "https://meet.google.com/abc",
    "https://meet.google.com./abc": "https://meet.google.com/abc",
    "https://meet.google.com": "https://meet.google.com/",
    "https://us02web.zoom.us/j/123?pwd=abc": "https://us02web.zoom.us/j/123?pwd=abc",
    "https://zoomgov.com/j/1": "https://zoomgov.com/j/1",
    "https://teams.live.com/meet/9123": "https://teams.live.com/meet/9123",
    "https://teams.microsoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0?context=%7b%22Tid%22%7d":
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0?context=%7b%22Tid%22%7d",
}


class MeetingUrlGrammarTest(unittest.TestCase):
    def test_unsafe_urls_are_rejected(self):
        for url in UNSAFE_URLS:
            with self.subTest(url=url):
                self.assertEqual(ce.strict_meeting_url(url), "")
                if not any(ch.isspace() for ch in url):
                    # Free-text extraction ends a URL at whitespace by design.
                    self.assertEqual(ce.safe_meeting_url(url), "")

    def test_safe_urls_are_canonicalised(self):
        for url, expected in SAFE_URLS.items():
            with self.subTest(url=url):
                self.assertEqual(ce.strict_meeting_url(url), expected)

    def test_link_is_found_in_free_text(self):
        text = "Join: https://meet.google.com/abc-defg-hij. Or dial in."
        self.assertEqual(ce.safe_meeting_url(text), "https://meet.google.com/abc-defg-hij")

    def test_unsafe_link_does_not_hide_a_later_safe_one(self):
        text = "https://evil.example\\@meet.google.com/x then https://zoom.us/j/1"
        self.assertEqual(ce.safe_meeting_url(text), "https://zoom.us/j/1")

    def test_validate_document_rejects_unsafe_meeting_url(self):
        document = make_document([dict(sample_row(), meetingUrl="https://evil.example\\@meet.google.com/abc")])
        with self.assertRaises(ValueError):
            ce.validate_document(document)


@unittest.skipUnless(shutil.which("node"), "node is not installed")
class ModelSafeUrlTest(unittest.TestCase):
    """Model.safeUrl is the last gate before Qt.openUrlExternally."""

    def run_model(self, script: str, payload) -> object:
        program = (
            "const M = require(process.argv[1]);"
            "const input = JSON.parse(require('fs').readFileSync(0, 'utf8'));"
            f"process.stdout.write(JSON.stringify(({script})(M, input)));"
        )
        result = subprocess.run(
            ["node", "-e", program, str(ROOT / "Model.js")],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            timeout=30,
            check=True,
        )
        return json.loads(result.stdout)

    def test_unsafe_urls_are_rejected(self):
        results = self.run_model("(M, urls) => urls.map(M.safeUrl)", UNSAFE_URLS)
        for url, result in zip(UNSAFE_URLS, results):
            with self.subTest(url=url):
                self.assertEqual(result, "")

    def test_safe_urls_are_canonicalised(self):
        urls = list(SAFE_URLS)
        results = self.run_model("(M, urls) => urls.map(M.safeUrl)", urls)
        for url, result in zip(urls, results):
            with self.subTest(url=url):
                self.assertEqual(result, SAFE_URLS[url])

    def test_non_strings_are_rejected(self):
        results = self.run_model(
            "(M, _) => [M.safeUrl(undefined), M.safeUrl(null), M.safeUrl(42), M.safeUrl({}), M.meetingUrlFor(null)]",
            None,
        )
        self.assertEqual(results, ["", "", "", "", ""])

    def test_meeting_url_for_and_joinable(self):
        now = datetime(2026, 3, 2, 10, 0, tzinfo=timezone.utc)
        event = {
            "meetingUrl": "https://MEET.google.com/abc",
            "allDay": False,
            "start": "2026-03-02T10:05:00Z",
            "end": "2026-03-02T10:30:00Z",
            "dateKey": "2026-03-02",
        }
        unsafe = dict(event, meetingUrl="https://evil.example\\@meet.google.com/abc")
        script = (
            "(M, x) => [M.meetingUrlFor(x.event), M.isJoinableNow(x.event, x.now, x.today),"
            " M.meetingUrlFor(x.unsafe), M.isJoinableNow(x.unsafe, x.now, x.today)]"
        )
        payload = {"event": event, "unsafe": unsafe, "now": now.timestamp() * 1000, "today": "2026-03-02"}
        self.assertEqual(self.run_model(script, payload), ["https://meet.google.com/abc", True, "", False])


def sample_row(**overrides):
    row = {
        "id": "event-1",
        "calendarId": "work",
        "calendarName": "Work",
        "color": "#7986cb",
        "dateKey": "2026-03-02",
        "start": "2026-03-02T10:00:00+00:00",
        "end": "2026-03-02T11:00:00+00:00",
        "allDay": False,
        "title": "Standup",
        "location": "",
        "continuation": False,
    }
    row.update(overrides)
    return row


def make_document(events, **overrides):
    document = {"version": 1, "syncedAt": "2026-03-02T09:00:00Z", "source": "caldir", "events": events}
    document.update(overrides)
    return document


def raw_event(index=0, **overrides):
    raw = {
        "instance_id": f"event-{index}",
        "uid": f"uid-{index}",
        "title": f"Event {index}",
        "start": "2026-03-02T10:00:00+00:00",
        "end": "2026-03-02T11:00:00+00:00",
        "calendar": "work",
        "all_day": False,
        "description": "",
        "location": "",
    }
    raw.update(overrides)
    return raw


WINDOW = {"from_date": date(2026, 3, 1), "to_date": date(2026, 3, 31)}


class BoundsTest(unittest.TestCase):
    def test_long_fields_are_truncated(self):
        rows = ce.normalize_events(
            [raw_event(title="T" * 5000, location="L" * 5000)],
            {"work": {"name": "N" * 1000, "color": "#33b679"}},
            **WINDOW,
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(len(rows[0]["title"]), ce.MAX_TITLE_CHARS)
        self.assertEqual(len(rows[0]["location"]), ce.MAX_LOCATION_CHARS)
        self.assertEqual(len(rows[0]["calendarName"]), ce.MAX_CALENDAR_NAME_CHARS)
        self.assertEqual(ce.MAX_TITLE_CHARS, 512)
        self.assertEqual(ce.MAX_LOCATION_CHARS, 512)
        self.assertEqual(ce.MAX_CALENDAR_NAME_CHARS, 128)

    def test_oversized_identifier_drops_the_event(self):
        rows = ce.normalize_events([raw_event(instance_id="x" * 5000)], {}, **WINDOW)
        self.assertEqual(rows, [])

    def test_row_count_is_capped_keeping_the_earliest(self):
        raws = [
            raw_event(i, start=f"2026-03-{1 + i % 28:02d}T10:00:00+00:00", end=f"2026-03-{1 + i % 28:02d}T11:00:00+00:00")
            for i in range(ce.MAX_EVENTS + 200)
        ]
        rows = ce.normalize_events(raws, {}, **WINDOW)
        self.assertEqual(len(rows), ce.MAX_EVENTS)
        self.assertEqual(ce.MAX_EVENTS, 5000)
        self.assertEqual(rows[0]["dateKey"], "2026-03-01")

    def test_validate_document_enforces_caps(self):
        cases = {
            "title": sample_row(title="T" * 513),
            "location": sample_row(location="L" * 513),
            "calendarName": sample_row(calendarName="N" * 129),
            "id": sample_row(id="x" * 5000),
            "title type": sample_row(title=["not", "a", "string"]),
        }
        for name, row in cases.items():
            with self.subTest(field=name):
                with self.assertRaises(ValueError):
                    ce.validate_document(make_document([row]))
        with self.assertRaises(ValueError):
            ce.validate_document(make_document([sample_row()] * (ce.MAX_EVENTS + 1)))
        ce.validate_document(make_document([sample_row()] * ce.MAX_EVENTS))

    def test_validate_document_checks_pulled_at(self):
        ce.validate_document(make_document([], pulledAt=None))
        ce.validate_document(make_document([], pulledAt="2026-03-02T09:00:00Z"))
        for bad in ("yesterday", 12, "2026-03-02T09:00:00"):
            with self.subTest(pulledAt=bad):
                with self.assertRaises(ValueError):
                    ce.validate_document(make_document([], pulledAt=bad))

    def test_refuses_to_write_an_oversized_document(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "calendar-events.json"
            document = make_document([sample_row(title="T" * 500)] * 50)
            with mock.patch.object(ce, "MAX_DOCUMENT_BYTES", 1000):
                with self.assertRaises(ValueError):
                    ce.atomic_write(target, document)
            self.assertFalse(target.exists())
            self.assertEqual(os.listdir(tmp), [])
        self.assertEqual(ce.MAX_DOCUMENT_BYTES, 8 * 1024 * 1024)


class IcsParsingTest(unittest.TestCase):
    def write_calendar(self, root: Path, name: str, files: dict[str, str]) -> None:
        calendar = root / name
        calendar.mkdir(parents=True)
        for filename, content in files.items():
            (calendar / filename).write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")

    def test_valarm_uid_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_calendar(root, "cal", {"a.ics": """
                BEGIN:VCALENDAR
                BEGIN:VEVENT
                UID:event-1
                URL:https://meet.google.com/abc-defg-hij
                BEGIN:VALARM
                UID:alarm-9
                URL:https://zoom.us/j/999
                ACTION:DISPLAY
                END:VALARM
                SUMMARY:Planning
                END:VEVENT
                END:VCALENDAR
            """})
            found = ce.ics_meeting_urls(root)
        self.assertEqual(found, {("cal", "event-1"): "https://meet.google.com/abc-defg-hij"})

    def test_valarm_before_uid_does_not_end_the_event(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_calendar(root, "cal", {"a.ics": """
                BEGIN:VCALENDAR
                BEGIN:VEVENT
                BEGIN:VALARM
                UID:alarm-1
                END:VALARM
                UID:event-2
                X-GOOGLE-CONFERENCE:https://meet.google.com/xyz
                END:VEVENT
                END:VCALENDAR
            """})
            found = ce.ics_meeting_urls(root)
        self.assertEqual(found, {("cal", "event-2"): "https://meet.google.com/xyz"})

    def test_unsafe_ics_link_is_dropped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_calendar(root, "cal", {"a.ics": """
                BEGIN:VCALENDAR
                BEGIN:VEVENT
                UID:event-3
                URL:https://evil.example\\@meet.google.com/abc
                END:VEVENT
                END:VCALENDAR
            """})
            self.assertEqual(ce.ics_meeting_urls(root), {})

    def test_invalid_utf8_calendar_config_is_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bad" / ".caldir").mkdir(parents=True)
            (root / "bad" / ".caldir" / "config.toml").write_bytes(b'name = "\xff\xfe"\n')
            (root / "good" / ".caldir").mkdir(parents=True)
            (root / "good" / ".caldir" / "config.toml").write_text('name = "Good"\ncolor = "#33B679"\n')
            self.assertEqual(ce.read_toml(root / "bad" / ".caldir" / "config.toml"), {})
            metadata = ce.calendar_metadata(root)
        self.assertEqual(metadata["bad"]["name"], "bad")
        self.assertEqual(metadata["good"], {"name": "Good", "color": "#33b679", "readOnly": False})


FAKE_CALDIR = """#!/bin/sh
# Fake caldir for tests. Behaviour comes from FAKE_* environment variables.
echo "$*" >> "$FAKE_LOG"
if [ "$1" = "pull" ]; then
  case "${FAKE_PULL:-ok}" in
    ok) exit 0 ;;
    fail) echo "Pulling work..." >&2; echo "Error: token expired for work" >&2; exit 1 ;;
    hang)
      [ -n "${FAKE_IGNORE_TERM:-}" ] && trap '' TERM
      sleep 1000 &
      echo $! > "$FAKE_CHILD_PID"
      wait
      ;;
  esac
fi
if [ "$1" = "--json" ] && [ "$2" = "events" ]; then
  case "${FAKE_EVENTS:-ok}" in
    ok) cat "$FAKE_EVENTS_FILE"; exit 0 ;;
    none)
      printf 'Error: No calendars found.\\n\\nConnect your first calendar with:\\n  caldir connect <provider>\\n' >&2
      exit 1
      ;;
    garbage) echo "not json"; exit 0 ;;
  esac
fi
echo "unexpected arguments: $*" >&2
exit 64
"""


class FakeCaldirCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.binary = self.tmp / "bin" / "caldir"
        self.binary.parent.mkdir()
        self.binary.write_text(FAKE_CALDIR)
        self.binary.chmod(0o755)
        self.log = self.tmp / "calls.log"
        self.log.touch()
        self.output = self.tmp / "state" / "calendar-events.json"
        config = self.tmp / "config" / "caldir"
        config.mkdir(parents=True)
        caldir_root = self.tmp / "caldir"
        (caldir_root / "work" / ".caldir").mkdir(parents=True)
        (caldir_root / "work" / ".caldir" / "config.toml").write_text('name = "Work"\ncolor = "#33b679"\n')
        (config / "config.toml").write_text(f'calendar_dir = "{caldir_root}"\n')
        today = date.today()
        self.events_file = self.tmp / "events.json"
        self.events_file.write_text(json.dumps([
            raw_event(1, start=f"{today}T10:00:00+00:00", end=f"{today}T11:00:00+00:00",
                      description="Join https://meet.google.com/abc-defg-hij"),
        ]))
        self.env = {
            "XDG_CONFIG_HOME": str(self.tmp / "config"),
            "FAKE_LOG": str(self.log),
            "FAKE_EVENTS_FILE": str(self.events_file),
            "FAKE_CHILD_PID": str(self.tmp / "child.pid"),
        }
        patcher = mock.patch.dict(os.environ, self.env)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_main(self, *args: str, binary: str | None = None) -> tuple[int, str]:
        stderr = io.StringIO()
        argv = ["--caldir-bin", binary or str(self.binary), "--output", str(self.output), *args]
        with contextlib.redirect_stderr(stderr):
            try:
                code = ce.main(argv)
            except SystemExit as exit_:
                code = exit_.code
        return code, stderr.getvalue()

    def pulls(self) -> int:
        return sum(1 for line in self.log.read_text().splitlines() if line == "pull")

    def document(self) -> dict:
        return json.loads(self.output.read_text())


class ExitCodeTest(FakeCaldirCase):
    def test_export_without_pull(self):
        code, stderr = self.run_main()
        self.assertEqual((code, stderr), (0, ""))
        document = self.document()
        self.assertIsNone(document["pulledAt"])
        self.assertEqual(self.pulls(), 0)
        self.assertEqual(document["events"][0]["meetingUrl"], "https://meet.google.com/abc-defg-hij")
        self.assertEqual(document["events"][0]["calendarName"], "Work")

    def test_pull_failure_exports_and_exits_10(self):
        os.environ["FAKE_PULL"] = "fail"
        code, stderr = self.run_main("--pull")
        self.assertEqual(code, 10)
        self.assertEqual(stderr.strip(), "caldir pull failed: token expired for work")
        self.assertTrue(self.output.exists())
        self.assertIsNone(self.document()["pulledAt"])

    def test_pull_failure_keeps_the_previous_pulled_at(self):
        self.assertEqual(self.run_main("--pull")[0], 0)
        first = self.document()["pulledAt"]
        os.environ["FAKE_PULL"] = "fail"
        code, _ = self.run_main("--force-pull")
        self.assertEqual(code, 10)
        self.assertEqual(self.document()["pulledAt"], first)

    def test_missing_binary_exits_3(self):
        code, stderr = self.run_main(binary=str(self.tmp / "nowhere" / "caldir"))
        self.assertEqual(code, 3)
        self.assertTrue(stderr.startswith("caldir export failed: caldir not found"))
        self.assertNotIn("Errno", stderr)
        self.assertFalse(self.output.exists())

    def test_missing_binary_with_pull_exits_3(self):
        code, _ = self.run_main("--pull", binary=str(self.tmp / "nowhere" / "caldir"))
        self.assertEqual(code, 3)

    def test_caldir_error_is_reported_cleanly(self):
        os.environ["FAKE_EVENTS"] = "none"
        code, stderr = self.run_main()
        self.assertEqual(code, 1)
        self.assertEqual(stderr.strip(), "caldir export failed: No calendars found.")
        self.assertNotIn("[", stderr)

    def test_invalid_json_is_reported_cleanly(self):
        os.environ["FAKE_EVENTS"] = "garbage"
        code, stderr = self.run_main()
        self.assertEqual(code, 1)
        self.assertEqual(stderr.strip(), "caldir export failed: caldir returned invalid JSON")

    def test_busy_lock_exits_75_and_does_nothing(self):
        self.output.parent.mkdir(parents=True)
        lock = self.output.with_name(self.output.name + ".lock").open("a+")
        self.addCleanup(lock.close)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        code, stderr = self.run_main("--pull")
        self.assertEqual((code, stderr), (75, ""))
        self.assertFalse(self.output.exists())
        self.assertEqual(self.log.read_text(), "")

    def test_usage_error_exits_1_not_2(self):
        code, stderr = self.run_main("--no-such-flag")
        self.assertEqual(code, 1)
        self.assertTrue(stderr.startswith("caldir export failed:"))
        code, _ = self.run_main("--pull-interval", "-5")
        self.assertEqual(code, 1)

    def test_bad_date_exits_1(self):
        code, stderr = self.run_main("--from", "2026-03-10", "--to", "2026-03-01")
        self.assertEqual(code, 1)
        self.assertEqual(stderr.strip(), "caldir export failed: --to must not be before --from")


class PullRateLimitTest(FakeCaldirCase):
    def test_pull_is_rate_limited(self):
        self.assertEqual(self.run_main("--pull")[0], 0)
        pulled_at = self.document()["pulledAt"]
        self.assertIsNotNone(pulled_at)
        self.assertEqual(self.pulls(), 1)
        self.assertEqual(self.run_main("--pull")[0], 0)
        self.assertEqual(self.pulls(), 1)
        self.assertEqual(self.document()["pulledAt"], pulled_at)

    def test_force_pull_ignores_the_interval(self):
        self.run_main("--pull")
        self.assertEqual(self.run_main("--force-pull")[0], 0)
        self.assertEqual(self.pulls(), 2)

    def test_pull_interval_is_honoured(self):
        self.run_main("--pull")
        self.run_main("--pull", "--pull-interval", "0")
        self.assertEqual(self.pulls(), 2)

    def test_old_pull_is_repeated(self):
        self.run_main("--pull")
        document = self.document()
        old = datetime.now(timezone.utc) - timedelta(seconds=301)
        document["pulledAt"] = ce.iso_utc(old)
        self.output.write_text(json.dumps(document))
        self.run_main("--pull")
        self.assertEqual(self.pulls(), 2)
        self.assertNotEqual(self.document()["pulledAt"], document["pulledAt"])

    def test_future_pulled_at_is_not_trusted(self):
        self.run_main("--pull")
        document = self.document()
        document["pulledAt"] = ce.iso_utc(datetime.now(timezone.utc) + timedelta(days=1))
        self.output.write_text(json.dumps(document))
        self.run_main("--pull")
        self.assertEqual(self.pulls(), 2)

    def test_pull_is_due(self):
        now = datetime(2026, 3, 2, 12, 0, tzinfo=timezone.utc)
        self.assertTrue(ce.pull_is_due(None, now, 300))
        self.assertFalse(ce.pull_is_due(now - timedelta(seconds=299), now, 300))
        self.assertTrue(ce.pull_is_due(now - timedelta(seconds=300), now, 300))
        self.assertTrue(ce.pull_is_due(now + timedelta(seconds=1), now, 300))


def process_gone(pid: int) -> bool:
    try:
        state = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0]
    except (FileNotFoundError, ProcessLookupError, IndexError):
        return True
    return state in ("Z", "X")


class TimeoutTest(FakeCaldirCase):
    def wait_for_child_pid(self) -> int:
        path = Path(self.env["FAKE_CHILD_PID"])
        return int(path.read_text().strip())

    def assert_grandchild_killed(self):
        pid = self.wait_for_child_pid()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not process_gone(pid):
            time.sleep(0.05)
        if not process_gone(pid):
            os.kill(pid, 9)
            self.fail(f"grandchild {pid} survived the timeout")

    def test_timeout_kills_the_process_group(self):
        os.environ["FAKE_PULL"] = "hang"
        with mock.patch.object(ce, "PULL_TIMEOUT_SECONDS", 1):
            started = time.monotonic()
            code, stderr = self.run_main("--pull")
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual(code, 10)
        self.assertEqual(stderr.strip(), "caldir pull failed: timed out after 1 seconds")
        self.assert_grandchild_killed()

    def test_timeout_escalates_to_sigkill(self):
        os.environ["FAKE_PULL"] = "hang"
        os.environ["FAKE_IGNORE_TERM"] = "1"
        with mock.patch.object(ce, "PULL_TIMEOUT_SECONDS", 1), mock.patch.object(ce, "KILL_GRACE_SECONDS", 0.5):
            code, _ = self.run_main("--pull")
        self.assertEqual(code, 10)
        self.assert_grandchild_killed()


class WrapperTest(FakeCaldirCase):
    def test_wrapper_runs_the_exporter(self):
        result = subprocess.run(
            [str(ROOT / "sync" / "caldir-export"), "--caldir-bin", str(self.binary), "--output", str(self.output)],
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertTrue(self.output.exists())

    def test_wrapper_without_script_exits_1(self):
        lonely = self.tmp / "lonely"
        lonely.mkdir()
        shutil.copy(ROOT / "sync" / "caldir-export", lonely / "caldir-export")
        result = subprocess.run([str(lonely / "caldir-export")], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stderr.startswith("caldir export failed:"))


class ErrorLineTest(unittest.TestCase):
    def test_prefers_the_error_line(self):
        stderr = "Error: config error: bad TOML at line 1\n  |\n1 | x = [\n\nCaused by:\n    bad TOML\n"
        self.assertEqual(ce.caldir_error_line(stderr, "", 1), "config error: bad TOML at line 1")

    def test_falls_back_to_last_line_and_caps_length(self):
        self.assertEqual(ce.caldir_error_line("one\ntwo\n", "", 1), "two")
        self.assertEqual(len(ce.caldir_error_line("x" * 1000, "", 1)), 200)
        self.assertEqual(ce.caldir_error_line("", "", 5), "exit status 5")


if __name__ == "__main__":
    unittest.main()
