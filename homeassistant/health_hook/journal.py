#!/usr/bin/env python3
"""Health Hook journal: one JSON line per day (daily totals / averages sent by the app in `days`).

Run by Home Assistant (shell_command, Core container, Python standard library only):
  journal.py add <payload JSON, base64>        merges payload["days"] into the journal, by date
  journal.py summary <today YYYY-MM-DD> [since YYYY-MM-DD | -]
      prints a compact summary for the AI summary: 7/30/90-day averages (complete days), today (partial for
      totals; sleep = last night), yesterday, the days since the previous summary (7 at most) and a fingerprint
      of the journal (unchanged = no new data).

The journal lives next to this script: /config/health_hook/journal.jsonl (included in Home Assistant backups).
"""
import base64
import hashlib
import json
import os
import sys
from datetime import date, timedelta

JOURNAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "journal.jsonl")

UNITS = {
    "steps": "steps", "walking_running_distance": "km", "cycling_distance": "km", "swimming_distance": "m",
    "flights_climbed": "floors", "active_energy": "kcal", "resting_energy": "kcal", "exercise_time": "min",
    "stand_time": "min", "swimming_strokes": "strokes", "time_in_daylight": "min",
    "heart_rate_avg": "bpm", "heart_rate_min": "bpm", "heart_rate_max": "bpm", "resting_heart_rate": "bpm",
    "walking_heart_rate": "bpm", "heart_rate_recovery": "bpm", "hrv": "ms", "spo2": "%", "respiratory_rate": "/min",
    "vo2max": "mL/kg/min", "blood_pressure_systolic": "mmHg", "blood_pressure_diastolic": "mmHg",
    "blood_glucose": "mg/dL", "sleep": "h", "wrist_temperature": "°C",
    "weight": "kg", "bmi": "kg/m²", "body_fat": "%", "lean_body_mass": "kg", "height": "cm",
    "waist_circumference": "cm", "body_temperature": "°C",
    "walking_speed": "km/h", "step_length": "cm", "walking_asymmetry": "%", "double_support": "%",
    "walking_steadiness": "%", "six_minute_walk": "m", "environmental_audio": "dB", "headphone_audio": "dB",
    "dietary_energy": "kcal", "protein": "g", "carbohydrates": "g", "fat": "g", "sugar": "g", "fiber": "g",
    "sodium": "mg", "caffeine": "mg", "water": "L",
}


def load():
    journal = {}
    try:
        with open(JOURNAL, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    d = json.loads(line)
                    journal[d["date"]] = d
    except FileNotFoundError:
        pass
    return journal


def save(journal):
    tmp = JOURNAL + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for key in sorted(journal):
            f.write(json.dumps(journal[key], ensure_ascii=False, separators=(",", ":")) + "\n")
    os.replace(tmp, JOURNAL)


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def add(b64):
    payload = json.loads(base64.b64decode(b64))
    journal = load()
    merged = 0
    for day in payload.get("days") or []:
        d = day.get("date")
        values = {k: v for k, v in day.items() if k != "date" and is_number(v)}
        if not d or not values:
            continue
        line = journal.get(d, {"date": d})
        line.update(values)          # the most recent sync wins (today gets completed during the day)
        journal[d] = line
        merged += 1
    if merged:
        save(journal)
    print(json.dumps({"merged_days": merged, "journal_days": len(journal)}))


def rnd(v):
    return round(v) if abs(v) >= 100 else round(v, 1)


def summary(today_txt, since_txt):
    journal = load()
    today = date.fromisoformat(today_txt)
    yesterday = today - timedelta(days=1)

    def values(key, n):
        # n complete days before today
        out = []
        for i in range(1, n + 1):
            v = journal.get((today - timedelta(days=i)).isoformat(), {}).get(key)
            if is_number(v):
                out.append(v)
        return out

    order = list(UNITS)
    keys = sorted({k for d in journal.values() for k in d if k != "date"},
                  key=lambda k: order.index(k) if k in order else len(order))
    metrics = {}
    for key in keys:
        v90 = values(key, 90)
        now = journal.get(today.isoformat(), {}).get(key)
        if not v90 and not is_number(now):
            continue
        m = {"unit": UNITS.get(key, "")}
        if is_number(now):
            m["today"] = rnd(now)
        y = journal.get(yesterday.isoformat(), {}).get(key)
        if is_number(y):
            m["yesterday"] = rnd(y)
        for n in (7, 30, 90):
            v = values(key, n)
            if v:
                m[f"avg{n}"] = rnd(sum(v) / len(v))
        v30 = values(key, 30)
        if v30:
            m["min30"], m["max30"] = rnd(min(v30)), rnd(max(v30))
        m["days_measured_90"] = len(v90)
        metrics[key] = m

    # Days since the previous summary (its day included: it was partial), 7 at most
    start = today - timedelta(days=6)
    if since_txt and since_txt != "-":
        try:
            start = max(start, date.fromisoformat(since_txt[:10]))
        except ValueError:
            pass
    recent = [journal[d] for d in sorted(journal) if start.isoformat() <= d <= today.isoformat()]

    dates = sorted(journal)
    fingerprint = hashlib.sha1("".join(json.dumps(journal[d], sort_keys=True) for d in dates).encode()).hexdigest()[:16]
    print(json.dumps({
        "fingerprint": fingerprint,
        "today": today.isoformat(),
        "journal": {"first_day": dates[0] if dates else None, "days": len(dates)},
        "metrics": metrics,
        "days_since_previous_summary": recent,
    }, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action == "add" and len(sys.argv) == 3:
        add(sys.argv[2])
    elif action == "summary" and len(sys.argv) >= 3:
        summary(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "-")
    else:
        sys.exit("usage: journal.py add <base64> | summary <YYYY-MM-DD> [since]")
