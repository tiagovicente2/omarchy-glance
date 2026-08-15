#!/usr/bin/env python3
"""Export renCal/Caldir events to Omarchy Glance's JSON contract."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlsplit

CONTRACT_VERSION = 1
DEFAULT_OUTPUT = Path("~/.local/state/omarchy/calendar-events.json").expanduser()
DEFAULT_PAST_DAYS = 7
DEFAULT_FUTURE_DAYS = 60
DEFAULT_COLOR_PALETTE = (
    "#7986cb", "#33b679", "#8e24aa", "#e67c73", "#f6bf26",
    "#f4511e", "#039be5", "#616161", "#3f51b5", "#0b8043",
)
URL_RE = re.compile(r"https://[^\s<>\"']+", re.IGNORECASE)
HEX_COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
MEETING_HOSTS = (
    "meet.google.com",
    "teams.microsoft.com",
    "zoom.us",
    "zoomgov.com",
)
ICS_MEETING_PROPERTIES = {
    "URL",
    "CONFERENCE",
    "X-GOOGLE-CONFERENCE",
    "X-MICROSOFT-ONLINE-MEETING-CONFLINK",
    "X-MICROSOFT-SKYPETEAMSMEETINGURL",
}


def default_config_path() -> Path:
    config_home = os.environ.get("XDG_CONFIG_HOME")
    base = Path(config_home).expanduser() if config_home else Path("~/.config").expanduser()
    return base / "caldir" / "config.toml"


def default_caldir_binary() -> str:
    local = Path("~/.local/bin/caldir").expanduser()
    return shutil.which("caldir") or (str(local) if local.is_file() else "caldir")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    today = date.today()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--caldir-bin", default=default_caldir_binary())
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--from", dest="from_date", default=(today - timedelta(days=DEFAULT_PAST_DAYS)).isoformat())
    parser.add_argument("--to", dest="to_date", default=(today + timedelta(days=DEFAULT_FUTURE_DAYS)).isoformat())
    return parser.parse_args(argv)


def read_toml(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            value = tomllib.load(handle)
            return value if isinstance(value, dict) else {}
    except (OSError, tomllib.TOMLDecodeError):
        return {}


def configured_caldir(config_path: Path) -> Path:
    configured = read_toml(config_path).get("calendar_dir", "~/caldir")
    return Path(os.path.expandvars(os.path.expanduser(str(configured)))).resolve()


def fallback_color(slug: str) -> str:
    digest = hashlib.sha256(slug.encode("utf-8", "replace")).digest()
    return DEFAULT_COLOR_PALETTE[digest[0] % len(DEFAULT_COLOR_PALETTE)]


def calendar_metadata(caldir_root: Path) -> dict[str, dict[str, Any]]:
    metadata: dict[str, dict[str, Any]] = {}
    try:
        children = sorted(path for path in caldir_root.iterdir() if path.is_dir())
    except OSError:
        return metadata

    for calendar in children:
        slug = calendar.name
        config = read_toml(calendar / ".caldir" / "config.toml")
        color = str(config.get("color") or "")
        if not HEX_COLOR_RE.fullmatch(color):
            color = fallback_color(slug)
        metadata[slug] = {
            "name": str(config.get("name") or slug),
            "color": color.lower(),
            "readOnly": bool(config.get("read_only", False)),
        }
    return metadata


def safe_meeting_url(*values: Any) -> str:
    for value in values:
        for match in URL_RE.findall(str(value or "")):
            candidate = match.rstrip(".,;:!?)]}")
            try:
                parts = urlsplit(candidate)
            except ValueError:
                continue
            host = (parts.hostname or "").lower().rstrip(".")
            if parts.scheme.lower() != "https" or not host:
                continue
            if any(host == allowed or host.endswith("." + allowed) for allowed in MEETING_HOSTS):
                return candidate
    return ""


def unescape_ics_text(value: str) -> str:
    return re.sub(r"\\([\\,;])", r"\1", value).replace("\\n", "\n").replace("\\N", "\n")


def unfolded_ics_lines(path: Path) -> Iterable[str]:
    """Yield RFC5545 content lines without interpreting recurrence or dates."""
    with path.open("r", encoding="utf-8", errors="replace", newline=None) as handle:
        pending = ""
        for raw_line in handle:
            line = raw_line.rstrip("\r\n")
            if line.startswith((" ", "\t")):
                pending += line[1:]
                continue
            if pending:
                yield pending
            pending = line
        if pending:
            yield pending


def ics_meeting_urls(caldir_root: Path) -> dict[tuple[str, str], str]:
    """Map calendar/UID to safe conference URLs from top-level ICS files only."""
    found: dict[tuple[str, str], str] = {}
    try:
        calendars = sorted(path for path in caldir_root.iterdir() if path.is_dir())
    except OSError:
        return found

    for calendar in calendars:
        try:
            files = sorted(calendar.glob("*.ics"))
        except OSError:
            continue
        for path in files:
            in_event = False
            uid = ""
            meeting_url = ""
            try:
                lines = unfolded_ics_lines(path)
                for line in lines:
                    upper = line.upper()
                    if upper == "BEGIN:VEVENT":
                        in_event = True
                        uid = ""
                        meeting_url = ""
                        continue
                    if upper == "END:VEVENT":
                        if uid and meeting_url:
                            found.setdefault((calendar.name, uid), meeting_url)
                        in_event = False
                        continue
                    if not in_event or ":" not in line:
                        continue
                    raw_name, value = line.split(":", 1)
                    name = raw_name.split(";", 1)[0].rsplit(".", 1)[-1].upper()
                    if name == "UID":
                        uid = unescape_ics_text(value.strip())
                    elif name in ICS_MEETING_PROPERTIES and not meeting_url:
                        meeting_url = safe_meeting_url(value)
            except OSError:
                continue
    return found


def parse_datetime_local(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text or len(text) == 10:
        return None
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        return parsed.astimezone() if parsed.tzinfo is not None else parsed
    except ValueError:
        return None


def parse_date_value(value: Any) -> date | None:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        if len(text) == 10:
            return date.fromisoformat(text)
        parsed = parse_datetime_local(text)
        return parsed.date() if parsed else None
    except ValueError:
        return None


def covered_dates(
    start_value: Any,
    end_value: Any,
    all_day: bool,
    from_date: date | None = None,
    to_date: date | None = None,
) -> list[date]:
    start_date = parse_date_value(start_value)
    if start_date is None:
        return []
    end_date = parse_date_value(end_value) or start_date

    if all_day:
        # RFC5545 all-day DTEND is exclusive.
        last = end_date - timedelta(days=1) if end_date > start_date else start_date
    else:
        last = end_date
        end_dt = parse_datetime_local(end_value)
        start_dt = parse_datetime_local(start_value)
        if end_dt and start_dt and end_dt > start_dt and end_dt.timetz().replace(tzinfo=None) == time.min:
            last -= timedelta(days=1)

    if last < start_date:
        last = start_date
    first_visible = max(start_date, from_date) if from_date else start_date
    last_visible = min(last, to_date) if to_date else last
    if last_visible < first_visible:
        return []
    return [first_visible + timedelta(days=offset) for offset in range((last_visible - first_visible).days + 1)]


def normalized_event(
    raw: Any,
    metadata: dict[str, dict[str, Any]],
    meeting_urls: dict[tuple[str, str], str] | None = None,
    from_date: date | None = None,
    to_date: date | None = None,
) -> list[dict[str, Any]]:
    if not isinstance(raw, dict):
        return []
    instance_id = str(raw.get("instance_id") or "").strip()
    title = str(raw.get("title") or "").strip()
    start = str(raw.get("start") or "").strip()
    end = str(raw.get("end") or start).strip()
    slug = str(raw.get("calendar") or "").strip()
    if not instance_id or not title or not start or not slug:
        return []

    all_day = bool(raw.get("all_day", False))
    dates = covered_dates(start, end, all_day, from_date, to_date)
    if not dates:
        return []

    cal = metadata.get(slug, {"name": slug, "color": fallback_color(slug), "readOnly": False})
    response = str(raw.get("rsvp") or "").replace("_", "-")
    uid = str(raw.get("uid") or "").strip()
    meeting_url = safe_meeting_url(raw.get("description"), raw.get("location"))
    if not meeting_url and uid:
        meeting_url = (meeting_urls or {}).get((slug, uid), "")
    base: dict[str, Any] = {
        "id": instance_id,
        "calendarId": slug,
        "calendarName": str(cal.get("name") or slug),
        "color": str(cal.get("color") or fallback_color(slug)),
        "start": start,
        "end": end,
        "allDay": all_day,
        "title": title,
        "location": str(raw.get("location") or ""),
    }
    if meeting_url:
        base["meetingUrl"] = meeting_url
    if response:
        base["responseStatus"] = response

    first_date = parse_date_value(start)
    return [
        {
            **base,
            "dateKey": day.isoformat(),
            "continuation": bool(not all_day and first_date and day > first_date),
        }
        for day in dates
    ]


def chronological_sort_value(value: Any) -> float:
    parsed = parse_datetime_local(value)
    if parsed is None:
        return float("inf")
    try:
        return parsed.timestamp()
    except (OSError, OverflowError, ValueError):
        return float("inf")


def normalize_events(
    raw_events: Any,
    metadata: dict[str, dict[str, Any]],
    meeting_urls: dict[tuple[str, str], str] | None = None,
    from_date: date | None = None,
    to_date: date | None = None,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if isinstance(raw_events, list):
        for raw in raw_events:
            try:
                rows.extend(normalized_event(raw, metadata, meeting_urls, from_date, to_date))
            except (TypeError, ValueError, OverflowError):
                # One malformed ICS record must not suppress the rest.
                continue
    rows.sort(key=lambda row: (
        row["dateKey"],
        0 if row["allDay"] else 1,
        chronological_sort_value(row["start"]),
        row["title"].casefold(),
        row["id"],
    ))
    return rows


def run_caldir(binary: str, from_date: str, to_date: str) -> list[dict[str, Any]]:
    result = subprocess.run(
        [binary, "--json", "events", "--from", from_date, "--to", to_date],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    )
    parsed = json.loads(result.stdout)
    if not isinstance(parsed, list):
        raise ValueError("caldir JSON output is not an array")
    return parsed


def validate_document(document: Any) -> None:
    if not isinstance(document, dict) or document.get("version") != CONTRACT_VERSION:
        raise ValueError("invalid contract version")
    if not isinstance(document.get("syncedAt"), str) or not document["syncedAt"]:
        raise ValueError("missing syncedAt")
    if not isinstance(document.get("source"), str) or not document["source"]:
        raise ValueError("missing source")
    events = document.get("events")
    if not isinstance(events, list):
        raise ValueError("events must be an array")
    required = ("id", "calendarId", "calendarName", "color", "dateKey", "start", "end", "allDay", "title", "location")
    for index, event in enumerate(events):
        if not isinstance(event, dict):
            raise ValueError(f"events[{index}] is not an object")
        for field in required:
            if field not in event:
                raise ValueError(f"events[{index}].{field} is missing")
        if not HEX_COLOR_RE.fullmatch(str(event["color"])):
            raise ValueError(f"events[{index}].color is invalid")
        if parse_date_value(event["dateKey"]) is None or len(str(event["dateKey"])) != 10:
            raise ValueError(f"events[{index}].dateKey is invalid")
        if not isinstance(event.get("continuation"), bool):
            raise ValueError(f"events[{index}].continuation is invalid")
        meeting_url = event.get("meetingUrl")
        if meeting_url and safe_meeting_url(meeting_url) != meeting_url:
            raise ValueError(f"events[{index}].meetingUrl is unsafe")


def build_document(
    raw_events: Any,
    metadata: dict[str, dict[str, Any]],
    now: datetime | None = None,
    meeting_urls: dict[tuple[str, str], str] | None = None,
    from_date: date | None = None,
    to_date: date | None = None,
) -> dict[str, Any]:
    timestamp = now or datetime.now(timezone.utc)
    document = {
        "version": CONTRACT_VERSION,
        "syncedAt": timestamp.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "source": "caldir",
        "events": normalize_events(raw_events, metadata, meeting_urls, from_date, to_date),
    }
    validate_document(document)
    return document


def atomic_write(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def acquire_export_lock(output: Path):
    output.parent.mkdir(parents=True, exist_ok=True)
    lock_path = output.with_name(output.name + ".lock")
    handle = lock_path.open("a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    return handle


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    output = args.output.expanduser()
    lock_handle = None
    try:
        lock_handle = acquire_export_lock(output)
        if lock_handle is None:
            return 0
        config_path = default_config_path().resolve()
        root = configured_caldir(config_path)
        metadata = calendar_metadata(root)
        meeting_urls = ics_meeting_urls(root)
        from_date = date.fromisoformat(args.from_date)
        to_date = date.fromisoformat(args.to_date)
        if to_date < from_date:
            raise ValueError("--to must not be before --from")
        raw = run_caldir(args.caldir_bin, args.from_date, args.to_date)
        document = build_document(raw, metadata, meeting_urls=meeting_urls, from_date=from_date, to_date=to_date)
        atomic_write(output, document)
    except (OSError, ValueError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"caldir export failed: {error}", file=sys.stderr)
        return 1
    finally:
        if lock_handle is not None:
            lock_handle.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
