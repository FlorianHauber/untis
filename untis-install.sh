#!/bin/sh
# untis installer — a terminal client for WebUntis
# usage:  sh untis-install.sh            (installs to ~/.local/bin)
#         PREFIX=/some/dir sh untis-install.sh
set -e

DEST="${PREFIX:-$HOME/.local/bin}"

say()  { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- need python 3.8+ ------------------------------------------------------
PY=""
for p in python3 python; do
  if command -v "$p" >/dev/null 2>&1 &&
     "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
    PY="$p"; break
  fi
done
if [ -z "$PY" ]; then
  say "Python 3.8 or newer is required but wasn't found."
  case "$(uname -s)" in
    Darwin) say "  install it with:  xcode-select --install   (or: brew install python)";;
    Linux)  say "  install it with your package manager, e.g.:"
            say "    sudo apt install python3   |   sudo pacman -S python   |   sudo dnf install python3";;
  esac
  exit 1
fi

# --- write the program -----------------------------------------------------
mkdir -p "$DEST" || fail "can't create $DEST"
TMP="$DEST/.untis.tmp.$$"
cat > "$TMP" <<'__UNTIS_EOF__'
#!/usr/bin/env python3
"""
untis - a terminal client for WebUntis.

Talks to the WebUntis JSON-RPC API (the one the official apps and most
third-party clients use) plus a few of the web UI's REST endpoints for
homework, exams and absences.

  * no third-party packages    (Python 3.8+ standard library only)
  * session is cached, so repeated calls are fast
  * --json on every command for scripting

Quick start:
  untis setup                 find your school, log in, save config
  untis                       today's remaining lessons (or next school day)
  untis week                  week grid  (untis week +1 = next week)
  untis changes               cancellations / substitutions coming up
"""

import argparse
import base64
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta
from pathlib import Path

VERSION = "1.0"
CLIENT = "untis-cli"

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "untis"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "untis"
CONFIG_FILE = CONFIG_DIR / "config.json"
SESSION_FILE = CACHE_DIR / "session.json"

SCHOOL_SEARCH_URL = "https://mobile.webuntis.com/ms/schoolquery2"

# element types
T_CLASS, T_TEACHER, T_SUBJECT, T_ROOM, T_STUDENT = 1, 2, 3, 4, 5

ERR_NOT_AUTH = -8520
ERR_BAD_CREDS = -8504


# --------------------------------------------------------------------------
# output helpers
# --------------------------------------------------------------------------

class C:
    on = sys.stdout.isatty() and not os.environ.get("NO_COLOR")

    @classmethod
    def w(cls, code, s):
        return f"\033[{code}m{s}\033[0m" if cls.on else s


def bold(s): return C.w("1", s)
def dim(s): return C.w("2", s)
def red(s): return C.w("31", s)
def green(s): return C.w("32", s)
def yellow(s): return C.w("33", s)
def blue(s): return C.w("34", s)
def cyan(s): return C.w("36", s)
def strike(s): return C.w("9;31", s)


ANSI_RE = re.compile(r"\033\[[0-9;]*m")


def vlen(s):
    return len(ANSI_RE.sub("", s))


def pad(s, n):
    return s + " " * max(0, n - vlen(s))


def trunc(s, n):
    return s if len(s) <= n else s[: max(1, n - 1)] + "…"


def die(msg, code=1):
    print(red("error: ") + msg, file=sys.stderr)
    sys.exit(code)


def out_json(obj):
    print(json.dumps(obj, indent=2, ensure_ascii=False, default=str))


# --------------------------------------------------------------------------
# date helpers
# --------------------------------------------------------------------------

WEEKDAYS = {
    "mo": 0, "mon": 0, "monday": 0, "montag": 0,
    "tu": 1, "tue": 1, "tuesday": 1, "di": 1, "dienstag": 1,
    "we": 2, "wed": 2, "wednesday": 2, "mi": 2, "mittwoch": 2,
    "th": 3, "thu": 3, "thursday": 3, "do": 3, "donnerstag": 3,
    "fr": 4, "fri": 4, "friday": 4, "freitag": 4,
    "sa": 5, "sat": 5, "saturday": 5, "samstag": 5,
    "su": 6, "sun": 6, "sunday": 6, "so": 6, "sonntag": 6,
}
DAY_NAMES = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def d2i(d):
    return d.year * 10000 + d.month * 100 + d.day


def i2d(i):
    i = int(i)
    return date(i // 10000, (i // 100) % 100, i % 100)


def t2s(t):
    t = int(t)
    return f"{t // 100:02d}:{t % 100:02d}"


def now_t():
    n = datetime.now()
    return n.hour * 100 + n.minute


def tmin(t):
    t = int(t)
    return (t // 100) * 60 + t % 100


def parse_date(s, base=None):
    """today, tomorrow, yesterday, +N, -N, mo..su (next occurrence),
    YYYY-MM-DD, DD.MM., DD.MM.YYYY"""
    base = base or date.today()
    if s is None:
        return base
    s = s.strip().lower()
    if s in ("today", "heute", "t"):
        return base
    if s in ("tomorrow", "morgen", "tm"):
        return base + timedelta(days=1)
    if s in ("yesterday", "gestern"):
        return base - timedelta(days=1)
    if re.fullmatch(r"[+-]\d+", s):
        return base + timedelta(days=int(s))
    if s in WEEKDAYS:
        delta = (WEEKDAYS[s] - base.weekday()) % 7
        return base + timedelta(days=delta)
    m = re.fullmatch(r"(\d{4})-(\d{1,2})-(\d{1,2})", s)
    if m:
        return date(int(m[1]), int(m[2]), int(m[3]))
    m = re.fullmatch(r"(\d{1,2})\.(\d{1,2})\.(\d{2,4})?", s)
    if m:
        y = int(m[3]) if m[3] else base.year
        if y < 100:
            y += 2000
        return date(y, int(m[2]), int(m[1]))
    die(f"can't parse date '{s}' (try 2026-11-09, 9.11., +2, fr, tomorrow)")


def fmt_day(d):
    rel = {0: "today", 1: "tomorrow", -1: "yesterday"}.get((d - date.today()).days)
    s = f"{DAY_NAMES[d.weekday()]} {d.strftime('%d.%m.%Y')}"
    return f"{s}  {dim('(' + rel + ')')}" if rel else s


def monday(d):
    return d - timedelta(days=d.weekday())


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------

def load_config():
    if not CONFIG_FILE.exists():
        return {}
    try:
        return json.loads(CONFIG_FILE.read_text())
    except Exception as e:
        die(f"broken config {CONFIG_FILE}: {e}")


def save_config(cfg):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))
    os.chmod(CONFIG_FILE, 0o600)


def get_password(cfg):
    if os.environ.get("UNTIS_PASSWORD"):
        return os.environ["UNTIS_PASSWORD"]
    if cfg.get("password_cmd"):
        r = subprocess.run(cfg["password_cmd"], shell=True, capture_output=True, text=True)
        if r.returncode != 0:
            die(f"password_cmd failed: {r.stderr.strip()}")
        return r.stdout.splitlines()[0] if r.stdout else ""
    if cfg.get("password"):
        return base64.b64decode(cfg["password"]).decode()
    if not sys.stdin.isatty():
        die("no password available (set UNTIS_PASSWORD, password_cmd, or run `untis setup`)")
    return getpass.getpass(f"WebUntis password for {cfg.get('username')}: ")


# --------------------------------------------------------------------------
# API client
# --------------------------------------------------------------------------

class UntisError(Exception):
    def __init__(self, msg, code=None):
        super().__init__(msg)
        self.code = code


class Untis:
    def __init__(self, cfg):
        for k in ("server", "school", "username"):
            if not cfg.get(k):
                die("not configured — run `untis setup` first")
        self.cfg = cfg
        server = cfg["server"].strip()
        server = re.sub(r"^https?://", "", server).split("/")[0]
        self.base = f"https://{server}/WebUntis"
        self.school = cfg["school"]
        self.cookies = {}
        self.session = None
        self.token = None
        self._load_session()

    # ----- session handling -----

    def _load_session(self):
        try:
            s = json.loads(SESSION_FILE.read_text())
            if (s.get("server") == self.base and s.get("school") == self.school
                    and s.get("username") == self.cfg["username"]
                    and time.time() - s.get("ts", 0) < 8 * 60):
                self.session = s
                self.cookies["JSESSIONID"] = s["sessionId"]
        except Exception:
            pass

    def _save_session(self):
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        self.session["ts"] = time.time()
        SESSION_FILE.write_text(json.dumps(self.session))
        os.chmod(SESSION_FILE, 0o600)

    def login(self):
        self.cookies = {}
        res = self._rpc_raw("authenticate", {
            "user": self.cfg["username"],
            "password": get_password(self.cfg),
            "client": CLIENT,
        })
        self.session = {
            "server": self.base,
            "school": self.school,
            "username": self.cfg["username"],
            "sessionId": res["sessionId"],
            "personId": res.get("personId"),
            "personType": res.get("personType"),
            "klasseId": res.get("klasseId"),
        }
        self.cookies["JSESSIONID"] = res["sessionId"]
        self._save_session()
        return self.session

    def logout(self):
        if self.session:
            try:
                self._rpc_raw("logout", {})
            except Exception:
                pass
        try:
            SESSION_FILE.unlink()
        except FileNotFoundError:
            pass

    def ensure(self):
        if not self.session:
            self.login()
        return self.session

    # ----- transport -----

    def _cookie_header(self):
        c = dict(self.cookies)
        c["schoolname"] = '"_' + base64.b64encode(self.school.encode()).decode() + '"'
        return "; ".join(f"{k}={v}" for k, v in c.items())

    def _absorb_cookies(self, resp):
        for h in resp.headers.get_all("Set-Cookie") or []:
            kv = h.split(";", 1)[0]
            if "=" in kv:
                k, v = kv.split("=", 1)
                if k.strip() != "schoolname":
                    self.cookies[k.strip()] = v.strip()

    def _request(self, url, data=None, headers=None):
        h = {
            "User-Agent": f"{CLIENT}/{VERSION}",
            "Accept": "application/json",
            "Cookie": self._cookie_header(),
        }
        if data is not None:
            h["Content-Type"] = "application/json"
        h.update(headers or {})
        req = urllib.request.Request(url, data=data, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                self._absorb_cookies(r)
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()
        except urllib.error.URLError as e:
            die(f"can't reach {url.split('?')[0]}: {e.reason}")

    def _rpc_raw(self, method, params):
        url = f"{self.base}/jsonrpc.do?school={urllib.parse.quote(self.school)}"
        body = json.dumps({"id": CLIENT, "method": method, "params": params,
                           "jsonrpc": "2.0"}).encode()
        status, raw = self._request(url, body)
        try:
            data = json.loads(raw)
        except Exception:
            raise UntisError(f"{method}: unexpected response (HTTP {status})")
        if "error" in data:
            err = data["error"]
            raise UntisError(f"{method}: {err.get('message')} ({err.get('code')})",
                             err.get("code"))
        return data.get("result")

    def rpc(self, method, params=None):
        self.ensure()
        try:
            res = self._rpc_raw(method, params or {})
        except UntisError as e:
            if e.code != ERR_NOT_AUTH:
                raise
            self.login()
            res = self._rpc_raw(method, params or {})
        self._save_session()
        return res

    def rest(self, path, params=None):
        """GET a /WebUntis/api/... endpoint. Tries cookie auth, then bearer token."""
        self.ensure()
        url = f"{self.base}/api/{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        for attempt in range(3):
            headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
            status, raw = self._request(url, headers=headers)
            try:
                data = json.loads(raw)
            except Exception:
                data = None
            if status == 200 and data is not None:
                self._save_session()
                return data
            if attempt == 0:
                # maybe the session expired, or the endpoint wants a JWT
                if status in (401, 403) or data is None:
                    if not self.token:
                        self.token = self._get_token()
                    if not self.token:
                        self.login()
                        self.token = self._get_token()
                    continue
            elif attempt == 1 and status in (401, 403):
                self.login()
                self.token = self._get_token()
                continue
            raise UntisError(f"GET {path}: HTTP {status}")
        raise UntisError(f"GET {path}: not authorised")

    def _get_token(self):
        status, raw = self._request(f"{self.base}/api/token/new")
        tok = raw.decode(errors="replace").strip().strip('"')
        if status == 200 and tok.count(".") == 2:
            return tok
        return None

    # ----- convenience -----

    def timetable(self, start, end, element=None):
        s = self.ensure()
        if element is None:
            if not s.get("personId") or not s.get("personType"):
                raise UntisError("account has no own timetable; use --class/--teacher/--room")
            element = {"id": s["personId"], "type": s["personType"]}
        fields = ["id", "name", "longname", "externalkey"]
        return self.rpc("getTimetable", {"options": {
            "element": element,
            "startDate": d2i(start),
            "endDate": d2i(end),
            "showInfo": True,
            "showSubstText": True,
            "showLsText": True,
            "showStudentgroup": True,
            "klasseFields": fields,
            "roomFields": fields,
            "subjectFields": fields,
            "teacherFields": fields,
        }}) or []

    def timegrid(self):
        try:
            return self.rpc("getTimegridUnits") or []
        except UntisError:
            return []

    def holidays(self):
        try:
            return self.rpc("getHolidays") or []
        except UntisError:
            return []


def client():
    return Untis(load_config())


# --------------------------------------------------------------------------
# lesson normalisation
# --------------------------------------------------------------------------

def _names(elems, key="name"):
    return [e.get(key) or e.get("name") or f"#{e.get('id')}" for e in elems or []]


def normalize(raw):
    su, te, ro, kl = (raw.get(k) or [] for k in ("su", "te", "ro", "kl"))
    te_now = [e for e in te if e.get("id")]
    te_orig = [e.get("orgname") or f"#{e['orgid']}" for e in te if e.get("orgid")]
    ro_now = [e for e in ro if e.get("id")]
    ro_orig = [e.get("orgname") or f"#{e['orgid']}" for e in ro if e.get("orgid")]
    code = raw.get("code")
    if code == "cancelled":
        status = "cancelled"
    elif code == "irregular" or te_orig or ro_orig:
        status = "changed"
    else:
        status = "normal"
    notes = [raw.get(k) for k in ("lstext", "substText", "info") if raw.get(k)]
    activity = raw.get("activityType")
    return {
        "id": raw.get("id"),
        "date": i2d(raw["date"]).isoformat(),
        "_date": raw["date"],
        "start": t2s(raw["startTime"]),
        "end": t2s(raw["endTime"]),
        "_start": int(raw["startTime"]),
        "_end": int(raw["endTime"]),
        "subjects": _names(su),
        "subjects_long": _names(su, "longname"),
        "teachers": _names(te_now),
        "teachers_original": te_orig,
        "rooms": _names(ro_now),
        "rooms_original": ro_orig,
        "classes": _names(kl),
        "status": status,
        "type": "exam" if raw.get("lstype") == "ex" else (activity or "lesson"),
        "notes": notes,
        "studentgroup": raw.get("sg"),
    }


def _sig(l):
    return (l["_date"], tuple(l["subjects"]), tuple(l["teachers"]), tuple(l["rooms"]),
            l["status"], tuple(l["notes"]), tuple(l["teachers_original"]))


def merge_doubles(lessons, max_gap=10):
    out = []
    for l in lessons:
        prev = out[-1] if out else None
        if (prev and _sig(prev) == _sig(l)
                and 0 <= tmin(l["_start"]) - tmin(prev["_end"]) <= max_gap):
            prev["_end"], prev["end"] = l["_end"], l["end"]
            prev["merged"] = prev.get("merged", 1) + 1
        else:
            out.append(dict(l))
    return out


def sort_lessons(ls):
    order = {"normal": 0, "changed": 1, "cancelled": 2}
    return sorted(ls, key=lambda l: (l["_date"], l["_start"], order[l["status"]],
                                     l["subjects"]))


def period_map(grid):
    """startTime -> period name, endTime -> period name"""
    starts, ends = {}, {}
    for day in grid:
        for u in day.get("timeUnits", []):
            starts.setdefault(int(u["startTime"]), u.get("name", ""))
            ends.setdefault(int(u["endTime"]), u.get("name", ""))
    return starts, ends


def public(l):
    return {k: v for k, v in l.items() if not k.startswith("_")}


def holiday_on(hols, d):
    di = d2i(d)
    for h in hols:
        if int(h["startDate"]) <= di <= int(h["endDate"]):
            return h.get("longName") or h.get("name")
    return None


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------

def lesson_line(l, pmap=None, now=None):
    starts, ends = pmap or ({}, {})
    p1, p2 = starts.get(l["_start"], ""), ends.get(l["_end"], "")
    per = p1 if (not p2 or p1 == p2) else f"{p1}-{p2}"

    su = ", ".join(l["subjects"]) or (l["notes"][0] if l["notes"] else "—")
    te = ", ".join(l["teachers"])
    ro = ", ".join(l["rooms"])
    extra = []

    if l["status"] == "cancelled":
        su_s = strike(su)
        te_s, ro_s = dim(te), dim(ro)
        extra.append(red("cancelled"))
    else:
        su_s = bold(su) if l["status"] == "normal" else C.w("1;33", su)
        te_s = te
        ro_s = ro
        if l["teachers_original"]:
            te_s = yellow(te or "—")
            extra.append(yellow(f"sub for {', '.join(l['teachers_original'])}"))
        if l["rooms_original"]:
            ro_s = yellow(ro or "—")
            extra.append(yellow(f"room was {', '.join(l['rooms_original'])}"))
        if l["status"] == "changed" and not extra:
            extra.append(yellow("changed"))
    if l["type"] == "exam":
        extra.insert(0, C.w("1;35", "EXAM"))
    notes = [n for n in l["notes"] if n != su]
    if notes:
        extra.append(cyan(" · ".join(notes)))

    is_now = now is not None and l["_start"] <= now < l["_end"] and l["status"] != "cancelled"
    mark = green("▶") if is_now else " "
    time_s = f"{l['start']}–{l['end']}"
    time_s = green(time_s) if is_now else (dim(time_s) if now is not None and l["_end"] <= now else time_s)
    return (f"{mark} {dim(pad(per, 4))}{time_s}  {pad(su_s, 12)} "
            f"{pad(te_s, 12)} {pad(ro_s, 8)} {'  '.join(extra)}").rstrip()


def print_day(d, lessons, pmap, hols, header=True):
    if header:
        print(bold(fmt_day(d)))
    h = holiday_on(hols, d)
    if h:
        print("  " + cyan(f"🌴 {h}"))
    if not lessons:
        if not h:
            print("  " + dim("no lessons"))
        return
    now = now_t() if d == date.today() else None
    for l in lessons:
        print(lesson_line(l, pmap, now))


def print_grid(days, by_day, grid, hols):
    units = []
    for g in grid:
        for u in g.get("timeUnits", []):
            key = (int(u["startTime"]), int(u["endTime"]))
            if key not in [(a, b) for _, a, b in units]:
                units.append((u.get("name", ""), *key))
    units.sort(key=lambda u: u[1])
    # add slots for lessons outside the grid
    for d in days:
        for l in by_day.get(d, []):
            if not any(a < l["_end"] and l["_start"] < b for _, a, b in units):
                units.append(("", l["_start"], l["_end"]))
    units.sort(key=lambda u: u[1])
    if not units:
        print(dim("no lessons"))
        return

    term = shutil.get_terminal_size((100, 24)).columns
    cw = max(6, min(14, (term - 15) // len(days) - 1))
    head = " " * 15 + " ".join(pad(bold(f"{DAY_NAMES[d.weekday()]} {d.strftime('%d.%m')}")
                                   if d != date.today() else C.w("1;32", (f"{DAY_NAMES[d.weekday()]} {d.strftime('%d.%m')}")), cw)
                               for d in days)
    print(head)
    hol_cells = {d: holiday_on(hols, d) for d in days}
    for name, a, b in units:
        cells = []
        for d in days:
            if hol_cells[d]:
                cells.append(pad(dim(trunc(hol_cells[d], cw)), cw))
                continue
            hits = [l for l in by_day.get(d, []) if l["_start"] < b and a < l["_end"]]
            if not hits:
                cells.append(" " * cw)
                continue
            live = [l for l in hits if l["status"] != "cancelled"] or hits
            txt = "/".join(dict.fromkeys(
                (", ".join(l["subjects"]) or "?") for l in live))
            txt = trunc(txt, cw - 1)
            if all(l["status"] == "cancelled" for l in live):
                cell = strike(txt)
            elif any(l["type"] == "exam" for l in live):
                cell = C.w("1;35", txt + "!")
            elif any(l["status"] == "changed" for l in live) or len(live) < len(hits):
                cell = yellow(txt + "*")
            else:
                cell = txt
            cells.append(pad(cell, cw))
        label = dim(pad(name, 3)) + f"{t2s(a)}–{t2s(b)}" if name else dim("   ") + f"{t2s(a)}–{t2s(b)}"
        print(pad(label, 15) + " ".join(cells))
    print(dim(f"\n{strike('X')} cancelled   " + yellow("X*") + " changed   "
              + C.w("1;35", "X!") + " exam"))


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def resolve_element(u, args):
    for opt, method, typ in (("klasse", "getKlassen", T_CLASS),
                             ("teacher", "getTeachers", T_TEACHER),
                             ("room", "getRooms", T_ROOM)):
        want = getattr(args, opt, None)
        if not want:
            continue
        items = u.rpc(method) or []
        w = want.lower()
        hit = ([i for i in items if i.get("name", "").lower() == w]
               or [i for i in items if w in (i.get("name", "") + " " + i.get("longName", "")).lower()])
        if not hit:
            die(f"no {opt} matching '{want}'")
        if len(hit) > 1 and hit[0].get("name", "").lower() != w:
            die(f"'{want}' is ambiguous: " + ", ".join(i["name"] for i in hit[:10]))
        return {"id": hit[0]["id"], "type": typ}
    return None


def fetch(u, args, start, end):
    raw = u.timetable(start, end, resolve_element(u, args))
    ls = sort_lessons([normalize(r) for r in raw])
    if not getattr(args, "no_merge", False):
        ls = merge_doubles(ls)
    if getattr(args, "hide_cancelled", False):
        ls = [l for l in ls if l["status"] != "cancelled"]
    return ls


def group_by_day(ls):
    by = {}
    for l in ls:
        by.setdefault(i2d(l["_date"]), []).append(l)
    return by


def cmd_day(args, d=None):
    u = client()
    d = d or parse_date(args.date)
    ls = fetch(u, args, d, d)
    if args.json:
        return out_json([public(l) for l in ls])
    print_day(d, ls, period_map(u.timegrid()), u.holidays())


def cmd_today(args):
    args.date = "today"
    cmd_day(args)


def cmd_tomorrow(args):
    args.date = "tomorrow"
    cmd_day(args)


def cmd_default(args):
    """today if lessons remain, else the next day with lessons"""
    u = client()
    today = date.today()
    ls = fetch(u, args, today, today + timedelta(days=14))
    by = group_by_day(ls)
    n = now_t()
    remaining = [l for l in by.get(today, []) if l["_end"] > n and l["status"] != "cancelled"]
    if remaining:
        d = today
    else:
        future = sorted(k for k, v in by.items() if k > today
                        and any(l["status"] != "cancelled" for l in v))
        d = future[0] if future else today
    if args.json:
        return out_json([public(l) for l in by.get(d, [])])
    print_day(d, by.get(d, []), period_map(u.timegrid()), u.holidays())


def cmd_week(args):
    u = client()
    ref = args.date
    if ref and re.fullmatch(r"[+-]\d+", ref):
        start = monday(date.today()) + timedelta(weeks=int(ref))
    else:
        d = parse_date(ref)
        # on weekends, "this week" means the upcoming one
        if ref is None and d.weekday() >= 5:
            d += timedelta(days=7 - d.weekday())
        start = monday(d)
    end = start + timedelta(days=6)
    ls = fetch(u, args, start, end)
    if args.json:
        return out_json([public(l) for l in ls])
    by = group_by_day(ls)
    ndays = 6 if any(d.weekday() == 5 for d in by) else 5
    if any(d.weekday() == 6 for d in by):
        ndays = 7
    days = [start + timedelta(days=i) for i in range(ndays)]
    hols = u.holidays()
    grid = u.timegrid()
    wk = start.isocalendar()[1]
    print(bold(f"Week {wk}") + dim(f"  {start.strftime('%d.%m.')} – {days[-1].strftime('%d.%m.%Y')}"))
    print()
    if args.list:
        pmap = period_map(grid)
        for d in days:
            print_day(d, by.get(d, []), pmap, hols)
            print()
    else:
        print_grid(days, by, grid, hols)


def cmd_next(args):
    u = client()
    today = date.today()
    ls = [l for l in fetch(u, args, today, today + timedelta(days=14))
          if l["status"] != "cancelled"]
    n = now_t()
    cur = [l for l in ls if l["_date"] == d2i(today) and l["_start"] <= n < l["_end"]]
    nxt = [l for l in ls if (l["_date"], l["_start"]) > (d2i(today), n)]
    if args.json:
        return out_json({"current": [public(l) for l in cur],
                         "next": [public(l) for l in nxt[:1]]})
    pmap = period_map(u.timegrid())
    if cur:
        l = cur[0]
        left = tmin(l["_end"]) - tmin(n)
        print(green("now   ") + lesson_line(l, pmap).strip() + dim(f"   ({left} min left)"))
    if nxt:
        l = nxt[0]
        d = i2d(l["_date"])
        when = "" if d == today else f"{fmt_day(d)}  "
        if d == today:
            mins = tmin(l["_start"]) - tmin(n)
            when = dim(f"in {mins // 60}h {mins % 60:02d}m  " if mins >= 60 else f"in {mins} min  ")
        print(cyan("next  ") + when + lesson_line(l, pmap).strip())
    if not cur and not nxt:
        print(dim("nothing in the next two weeks 🎉"))


def cmd_changes(args):
    u = client()
    start = date.today()
    end = start + timedelta(days=args.days)
    ls = [l for l in fetch(u, args, start, end) if l["status"] != "normal" or l["type"] == "exam"]
    if args.json:
        return out_json([public(l) for l in ls])
    if not ls:
        return print(dim(f"no changes in the next {args.days} days"))
    pmap = period_map(u.timegrid())
    for d, day_ls in sorted(group_by_day(ls).items()):
        print(bold(fmt_day(d)))
        for l in day_ls:
            print(lesson_line(l, pmap))
        print()


def _rng(args, default_back, default_fwd):
    back = args.past if args.past is not None else default_back
    fwd = args.days if args.days is not None else default_fwd
    return date.today() - timedelta(days=back), date.today() + timedelta(days=fwd)


def cmd_homework(args):
    u = client()
    start, end = _rng(args, 7, 14)
    data = u.rest("homeworks/lessons", {"startDate": d2i(start), "endDate": d2i(end)}).get("data", {})
    lessons = {l["id"]: l for l in data.get("lessons", [])}
    teachers = {t["id"]: t.get("name") for t in data.get("teachers", [])}
    hws = []
    for h in data.get("homeworks", []):
        les = lessons.get(h.get("lessonId"), {})
        hws.append({
            "id": h.get("id"),
            "subject": les.get("subject", ""),
            "assigned": i2d(h["date"]).isoformat() if h.get("date") else None,
            "due": i2d(h["dueDate"]).isoformat() if h.get("dueDate") else None,
            "text": (h.get("text") or "").strip(),
            "remark": (h.get("remark") or "").strip(),
            "teacher": teachers.get(h.get("teacherId")),
            "completed": bool(h.get("completed")),
        })
    hws.sort(key=lambda h: (h["due"] or "", h["subject"]))
    if not args.all:
        hws = [h for h in hws if not h["completed"]]
    if args.json:
        return out_json(hws)
    if not hws:
        return print(dim("no homework 🎉"))
    today = date.today()
    for h in hws:
        due = date.fromisoformat(h["due"]) if h["due"] else None
        days = (due - today).days if due else None
        if due is None:
            due_s = dim("no due date")
        elif days < 0:
            due_s = red(f"overdue {due.strftime('%d.%m.')}")
        elif days == 0:
            due_s = C.w("1;31", "due today")
        elif days == 1:
            due_s = yellow("due tomorrow")
        else:
            due_s = f"due {DAY_NAMES[due.weekday()]} {due.strftime('%d.%m.')}" + dim(f" ({days}d)")
        check = green("✓") if h["completed"] else "•"
        print(f"{check} {bold(pad(h['subject'] or '?', 8))} {due_s}")
        for line in h["text"].splitlines() or ["(no text)"]:
            print("    " + line)
        if h["remark"]:
            print("    " + dim(h["remark"]))
    return None


def cmd_exams(args):
    u = client()
    start, end = _rng(args, 0, 60)
    s = u.ensure()
    params = {"startDate": d2i(start), "endDate": d2i(end), "klasseId": -1, "withGrades": "true"}
    if s.get("personType") == T_STUDENT:
        params["studentId"] = s["personId"]
    data = u.rest("exams", params).get("data", {})
    exams = []
    for e in data.get("exams", []):
        exams.append({
            "date": i2d(e["examDate"]).isoformat() if e.get("examDate") else None,
            "start": t2s(e["startTime"]) if e.get("startTime") else None,
            "end": t2s(e["endTime"]) if e.get("endTime") else None,
            "subject": e.get("subject") or "",
            "type": e.get("examType") or "",
            "name": e.get("name") or "",
            "text": (e.get("text") or "").strip(),
            "rooms": e.get("rooms") or [],
            "teachers": e.get("teachers") or [],
            "grade": e.get("grade") or None,
        })
    exams.sort(key=lambda e: (e["date"] or "", e["start"] or ""))
    if args.json:
        return out_json(exams)
    if not exams:
        return print(dim("no exams coming up"))
    today = date.today()
    for e in exams:
        d = date.fromisoformat(e["date"]) if e["date"] else None
        days = (d - today).days if d else None
        when = (f"{DAY_NAMES[d.weekday()]} {d.strftime('%d.%m.')}" if d else "?")
        tag = red(f"in {days}d") if days is not None and days <= 3 else dim(f"in {days}d")
        tm = f" {e['start']}–{e['end']}" if e["start"] else ""
        title = " · ".join(x for x in (e["type"], e["name"]) if x)
        print(f"{bold(pad(when, 10))}{tm}  {C.w('1;35', pad(e['subject'], 8))} {title}  {tag}")
        meta = ", ".join(e["rooms"] + e["teachers"])
        if meta:
            print("    " + dim(meta))
        if e["text"]:
            print("    " + e["text"])
    return None


def cmd_absences(args):
    u = client()
    s = u.ensure()
    start, end = _rng(args, 365, 0)
    data = u.rest("classreg/absences/students", {
        "startDate": d2i(start), "endDate": d2i(end),
        "studentId": s.get("personId"), "excuseStatusId": -1,
    }).get("data", {})
    abs_ = []
    for a in data.get("absences", []):
        exc = a.get("excuse") or {}
        abs_.append({
            "start": f"{i2d(a['startDate']).isoformat()} {t2s(a['startTime'])}",
            "end": f"{i2d(a['endDate']).isoformat()} {t2s(a['endTime'])}",
            "reason": a.get("reason") or "",
            "text": a.get("text") or "",
            "excused": bool(a.get("isExcused")),
            "excuse_status": exc.get("excuseStatus") or a.get("excuseStatus") or "",
        })
    abs_.sort(key=lambda a: a["start"], reverse=True)
    if args.json:
        return out_json(abs_)
    if not abs_:
        return print(dim("no absences recorded"))
    unexc = sum(1 for a in abs_ if not a["excused"])
    for a in abs_:
        st = green("excused  ") if a["excused"] else red("unexcused")
        sd, st_t = a["start"].split()
        ed, en_t = a["end"].split()
        span = f"{i2d(sd.replace('-', '')).strftime('%d.%m.%y')} {st_t}–" + \
               (en_t if sd == ed else f"{i2d(ed.replace('-', '')).strftime('%d.%m.%y')} {en_t}")
        print(f"{st}  {pad(span, 26)} {a['reason']}" + (dim(f"  {a['text']}") if a["text"] else ""))
    print(dim(f"\n{len(abs_)} absences, {unexc} unexcused"))
    return None


def cmd_holidays(args):
    u = client()
    hols = sorted(u.holidays(), key=lambda h: h["startDate"])
    if not args.all:
        hols = [h for h in hols if int(h["endDate"]) >= d2i(date.today())]
    if args.json:
        return out_json(hols)
    today = date.today()
    for h in hols:
        s, e = i2d(h["startDate"]), i2d(h["endDate"])
        span = s.strftime("%d.%m.%Y") if s == e else f"{s.strftime('%d.%m.')} – {e.strftime('%d.%m.%Y')}"
        if s <= today <= e:
            tag = green("now")
        else:
            tag = dim(f"in {(s - today).days}d") if s > today else ""
        print(f"{pad(span, 24)} {bold(h.get('longName') or h.get('name'))}  {tag}")


def cmd_list(method, cols):
    def run(args):
        u = client()
        items = u.rpc(method) or []
        if args.filter:
            f = args.filter.lower()
            items = [i for i in items if f in json.dumps(i, ensure_ascii=False).lower()]
        if args.json:
            return out_json(items)
        items.sort(key=lambda i: str(i.get(cols[0], "")).lower())
        for i in items:
            vals = [str(i.get(c, "") or "") for c in cols]
            print(bold(pad(vals[0], 12)) + "  " + "  ".join(vals[1:]))
        return None
    return run


def cmd_whoami(args):
    u = client()
    s = u.login()
    info = {"server": u.base, "school": u.school, "username": u.cfg["username"],
            "personId": s.get("personId"), "personType": s.get("personType"),
            "klasseId": s.get("klasseId")}
    try:
        sy = u.rpc("getCurrentSchoolyear")
        info["schoolyear"] = sy.get("name") if sy else None
    except UntisError:
        pass
    if args.json:
        return out_json(info)
    types = {1: "class", 2: "teacher", 3: "subject", 4: "room", 5: "student", 12: "parent"}
    print(f"{bold(info['username'])} @ {info['school']}  ({u.base})")
    print(dim(f"person {info['personId']} ({types.get(info['personType'], info['personType'])})"
              + (f", schoolyear {info['schoolyear']}" if info.get("schoolyear") else "")))
    return None


def cmd_logout(args):
    cfg = load_config()
    if cfg:
        Untis(cfg).logout()
    print("session cleared")


def search_schools(q):
    body = json.dumps({"id": CLIENT, "method": "searchSchool", "jsonrpc": "2.0",
                       "params": [{"search": q}]}).encode()
    req = urllib.request.Request(SCHOOL_SEARCH_URL, data=body, headers={
        "Content-Type": "application/json", "User-Agent": f"{CLIENT}/{VERSION}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.loads(r.read())
    except Exception as e:
        die(f"school search failed: {e}")
    if "error" in data:
        msg = data["error"].get("message", "")
        if "too many" in msg.lower():
            die("too many results — be more specific")
        die(f"school search: {msg}")
    return data.get("result", {}).get("schools", [])


def cmd_search(args):
    schools = search_schools(" ".join(args.query))
    if args.json:
        return out_json(schools)
    for s in schools:
        print(f"{bold(s.get('displayName'))}  {dim(s.get('address', ''))}")
        print(f"    server {s.get('server')}   school {s.get('loginName')}")
    if not schools:
        print(dim("no schools found"))
    return None


def cmd_setup(args):
    cfg = load_config()
    print(bold("WebUntis setup") + dim(f"  (saves to {CONFIG_FILE})\n"))
    server = school = None
    q = input("School name or city to search (empty = enter server manually): ").strip()
    if q:
        schools = search_schools(q)
        if not schools:
            print(dim("nothing found, enter it manually"))
        for i, s in enumerate(schools[:20], 1):
            print(f"  {i:2}. {s.get('displayName')}  {dim(s.get('address', ''))}")
        if schools:
            pick = input("Number: ").strip()
            if pick.isdigit() and 1 <= int(pick) <= min(20, len(schools)):
                s = schools[int(pick) - 1]
                server, school = s["server"], s["loginName"]
    if not server:
        print(dim("Find these in the WebUntis login URL, e.g. "
                  "https://SERVER.webuntis.com/WebUntis/?school=SCHOOL"))
        server = input(f"Server [{cfg.get('server', '')}]: ").strip() or cfg.get("server")
        school = input(f"School [{cfg.get('school', '')}]: ").strip() or cfg.get("school")
    user = input(f"Username [{cfg.get('username', '')}]: ").strip() or cfg.get("username")
    if not (server and school and user):
        die("server, school and username are required")
    pw = getpass.getpass("Password: ")
    new = {"server": server, "school": school, "username": user}
    u = Untis({**new, "password": base64.b64encode(pw.encode()).decode()})
    u.session = None
    try:
        s = u.login()
    except UntisError as e:
        die("login failed: " + ("wrong username or password" if e.code == ERR_BAD_CREDS else str(e)))
    print(green("✓ logged in") + dim(f"  (person {s.get('personId')}, type {s.get('personType')})"))
    print("\nHow should the password be stored?")
    print("  1. in the config file (obfuscated, chmod 600)  [default]")
    print("  2. a shell command, e.g. `pass show school/untis`")
    print("  3. don't store — ask every time (or use $UNTIS_PASSWORD)")
    choice = input("Choice [1]: ").strip() or "1"
    if choice == "1":
        new["password"] = base64.b64encode(pw.encode()).decode()
    elif choice == "2":
        new["password_cmd"] = input("Command: ").strip()
    save_config(new)
    print(green(f"✓ saved {CONFIG_FILE}") + "\n\nTry: " + bold("untis") + ", "
          + bold("untis week") + ", " + bold("untis changes") + ", " + bold("untis homework"))


# --------------------------------------------------------------------------
# argument parsing
# --------------------------------------------------------------------------

def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="machine-readable output")
    common.add_argument("--no-color", action="store_true", help="disable colours")

    tt = argparse.ArgumentParser(add_help=False)
    g = tt.add_argument_group("timetable target (default: your own)")
    g.add_argument("-c", "--class", dest="klasse", metavar="NAME", help="class timetable")
    g.add_argument("-t", "--teacher", metavar="NAME", help="teacher timetable")
    g.add_argument("-r", "--room", metavar="NAME", help="room timetable")
    tt.add_argument("--no-merge", action="store_true", help="don't merge double periods")
    tt.add_argument("--hide-cancelled", action="store_true", help="hide cancelled lessons")

    rng = argparse.ArgumentParser(add_help=False)
    rng.add_argument("-d", "--days", type=int, help="days ahead")
    rng.add_argument("-p", "--past", type=int, help="days back")

    p = argparse.ArgumentParser(
        prog="untis", parents=[common, tt],
        description="Terminal client for WebUntis.",
        epilog="Dates: today, tomorrow, +2, -1, mo..fr, 2026-11-09, 9.11., 9.11.2026\n"
               "Run without a command to see today's remaining lessons (or the next school day).",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--version", action="version", version=f"untis {VERSION}")
    sub = p.add_subparsers(dest="cmd", metavar="COMMAND")

    def add(name, fn, help, parents=(common,), aliases=()):
        sp = sub.add_parser(name, parents=list(parents), help=help, aliases=list(aliases),
                            description=help)
        sp.set_defaults(fn=fn)
        return sp

    add("setup", cmd_setup, "configure school & login", aliases=["login"])
    add("today", cmd_today, "today's timetable", (common, tt))
    add("tomorrow", cmd_tomorrow, "tomorrow's timetable", (common, tt), aliases=["tm"])
    sp = add("day", cmd_day, "timetable for a given day", (common, tt), aliases=["d"])
    sp.add_argument("date", nargs="?", help="date (default today)")
    sp = add("week", cmd_week, "week overview (grid)", (common, tt), aliases=["w"])
    sp.add_argument("date", nargs="?", help="any day in the week, or +N / -N weeks")
    sp.add_argument("-l", "--list", action="store_true", help="list instead of grid")
    add("next", cmd_next, "current & next lesson", (common, tt), aliases=["n"])
    sp = add("changes", cmd_changes, "cancellations, substitutions, room changes",
             (common, tt), aliases=["ch"])
    sp.add_argument("-d", "--days", type=int, default=7, help="days ahead (default 7)")
    sp = add("homework", cmd_homework, "homework (7 days back, 14 ahead)", (common, rng),
             aliases=["hw"])
    sp.add_argument("-a", "--all", action="store_true", help="include completed")
    add("exams", cmd_exams, "upcoming exams (60 days)", (common, rng), aliases=["ex"])
    add("absences", cmd_absences, "your absences (last 365 days)", (common, rng), aliases=["abs"])
    sp = add("holidays", cmd_holidays, "school holidays", aliases=["hol"])
    sp.add_argument("-a", "--all", action="store_true", help="include past holidays")
    for name, method, cols, al in (
            ("subjects", "getSubjects", ["name", "longName"], "su"),
            ("teachers", "getTeachers", ["name", "foreName", "longName"], "te"),
            ("rooms", "getRooms", ["name", "longName", "building"], "ro"),
            ("classes", "getKlassen", ["name", "longName"], "cl")):
        sp = add(name, cmd_list(method, cols), f"list {name}", aliases=[al])
        sp.add_argument("filter", nargs="?", help="substring filter")
    sp = add("search", cmd_search, "search for a school")
    sp.add_argument("query", nargs="+")
    add("whoami", cmd_whoami, "show account info / test login")
    add("logout", cmd_logout, "end and forget the cached session")
    return p


def main():
    p = build_parser()
    args = p.parse_args()
    if args.no_color:
        C.on = False
    fn = getattr(args, "fn", None) or cmd_default
    try:
        fn(args)
    except UntisError as e:
        msg = str(e)
        if e.code == ERR_BAD_CREDS:
            msg = "wrong username or password — run `untis setup`"
        elif "-8509" in msg or "no right" in msg.lower():
            msg += " (your account isn't allowed to do that)"
        die(msg)
    except KeyboardInterrupt:
        print()
        sys.exit(130)
    except BrokenPipeError:
        pass


if __name__ == "__main__":
    main()
__UNTIS_EOF__

# use whichever python we found if plain `python3` isn't it
if [ "$PY" != "python3" ]; then
  sed "1s|.*|#!/usr/bin/env $PY|" "$TMP" > "$TMP.2" && mv "$TMP.2" "$TMP"
fi
chmod 755 "$TMP"
mv "$TMP" "$DEST/untis"
"$DEST/untis" --version >/dev/null 2>&1 || fail "installed, but it doesn't run — check your Python install"

say "✓ installed $DEST/untis"

# --- PATH check ------------------------------------------------------------
case ":$PATH:" in
  *":$DEST:"*) ;;
  *)
    SHELL_NAME="$(basename "${SHELL:-sh}")"
    case "$SHELL_NAME" in
      zsh)  RC="$HOME/.zshrc";;
      bash) if [ "$(uname -s)" = Darwin ]; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi;;
      fish) RC="";;
      *)    RC="$HOME/.profile";;
    esac
    if [ "$SHELL_NAME" = fish ]; then
      fish -c "fish_add_path '$DEST'" 2>/dev/null && say "✓ added $DEST to your fish PATH"
    elif [ -n "$RC" ] && ! grep -qs "$DEST" "$RC"; then
      printf '\n# added by untis installer\nexport PATH="%s:$PATH"\n' "$DEST" >> "$RC"
      say "✓ added $DEST to PATH in $RC"
    fi
    say "  open a new terminal (or run: export PATH=\"$DEST:\$PATH\")"
    ;;
esac

say ""
say "Next:  untis setup     (find your school and log in)"
say "Then:  untis           untis week      untis changes     untis --help"
