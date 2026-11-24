#!/usr/bin/env python3
"""Consistency checks, run by CI on every pull request (Python standard library; PyYAML optional).

- The metrics of the app (HealthHook/Catalog.swift) and of Home Assistant (tools/generate_ha_package.py) match:
  same keys, same kinds (daily total / latest value / sleep), `<id>_avg` sensor for min/max metrics.
- The journal (homeassistant/health_hook/journal.py) knows the unit of every daily key the app sends.
- homeassistant/packages/health_hook.yaml is the generator's current output.
- Every UI string has a French translation, and every metric title is in the string catalog.
- The Home Assistant packages are valid YAML (if PyYAML is installed).

Run: python3 tools/check.py
"""
import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
errors = []


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def swift_metrics():
    """[(id, title, kind, min_max)] from Catalog.metrics; kind: total / latest / sleep."""
    text = (ROOT / "HealthHook" / "Catalog.swift").read_text(encoding="utf-8")
    body = text[text.index("static let metrics"):text.index("static let defaults")]
    out = []
    # One entry = from `total(` / `sample(` / `Metric(` to the next one
    starts = [m.start() for m in re.finditer(r"\b(?:total|sample|Metric)\(", body)]
    for a, b in zip(starts, starts[1:] + [len(body)]):
        entry = body[a:b]
        m = re.match(r'(total|sample)\("(\w+)", "([^"]+)"', entry)
        if m:
            kind = "total" if m.group(1) == "total" else "latest"
            out.append((m.group(2), m.group(3), kind, "minMax: true" in entry))
            continue
        m = re.match(r'Metric\(id: "(\w+)", title: "([^"]+)".*?kind: \.(\w+)', entry, re.S)
        if not m:
            errors.append(f"Catalog.swift: cannot parse {entry.strip()[:60]!r}")
            continue
        kind = {"cumulative": "total", "discrete": "latest", "sleep": "sleep"}[m.group(3)]
        out.append((m.group(1), m.group(2), kind, "minMax: true" in entry))
    return out


app = swift_metrics()
if len(app) < 40:
    errors.append(f"Catalog.swift: only {len(app)} metrics found, the parser is probably broken")

# 1. App ↔ Home Assistant sensors
gen = load("generate_ha_package", ROOT / "tools" / "generate_ha_package.py")
ha = {key: kind for key, _name, _unit, _dc, _icon, kind, _dec in gen.METRICS}
expected = {}
for mid, _title, kind, min_max in app:
    expected[mid] = {"total": gen.TOTAL, "latest": gen.LATEST, "sleep": gen.SLEEP}[kind]
    if min_max:
        expected[mid + "_avg"] = gen.DAY_AVG
for key in sorted(expected.keys() - ha.keys()):
    errors.append(f"generate_ha_package.py: no sensor for app key {key!r}")
for key in sorted(ha.keys() - expected.keys()):
    errors.append(f"generate_ha_package.py: sensor {key!r} matches no metric of the app")
for key in sorted(expected.keys() & ha.keys()):
    if expected[key] != ha[key]:
        errors.append(f"generate_ha_package.py: {key!r} is {ha[key]!r}, the app sends it as {expected[key]!r}")

# 2. Journal units = keys of `days`
journal = load("journal", ROOT / "homeassistant" / "health_hook" / "journal.py")
day_keys = set()
for mid, _title, kind, min_max in app:
    day_keys |= {mid + "_avg", mid + "_min", mid + "_max"} if min_max else {mid}
for key in sorted(day_keys - journal.UNITS.keys()):
    errors.append(f"journal.py: no unit in UNITS for {key!r}")
for key in sorted(journal.UNITS.keys() - day_keys):
    errors.append(f"journal.py: UNITS has {key!r}, which the app never sends in `days`")

# 3. Generated package up to date
package = ROOT / "homeassistant" / "packages" / "health_hook.yaml"
if package.read_text(encoding="utf-8") != gen.render():
    errors.append("health_hook.yaml is out of date: run python3 tools/generate_ha_package.py and commit it")

# 4. Translations
for catalog in ("Localizable.xcstrings", "InfoPlist.xcstrings"):
    strings = json.loads((ROOT / "HealthHook" / catalog).read_text(encoding="utf-8"))["strings"]
    for key, entry in strings.items():
        if entry.get("shouldTranslate") is False:
            continue
        fr = entry.get("localizations", {}).get("fr", {}).get("stringUnit", {})
        if fr.get("state") != "translated" or not fr.get("value"):
            errors.append(f"{catalog}: no French translation for {key!r}")
    if catalog == "Localizable.xcstrings":
        for mid, title, _kind, _mm in app:
            if title not in strings:
                errors.append(f"{catalog}: metric title {title!r} ({mid}) missing")

# 5. YAML syntax of the packages (Home Assistant tags accepted as-is)
try:
    import yaml
except ImportError:
    print("PyYAML not installed: YAML syntax not checked (pip install pyyaml)")
else:
    class Loader(yaml.SafeLoader):
        pass
    Loader.add_multi_constructor("!", lambda loader, suffix, node: None)
    for path in sorted((ROOT / "homeassistant" / "packages").glob("*.yaml")):
        try:
            yaml.load(path.read_text(encoding="utf-8"), Loader=Loader)
        except yaml.YAMLError as e:
            errors.append(f"{path.name}: invalid YAML: {e}")

if errors:
    print("\n".join(f"✗ {e}" for e in errors))
    sys.exit(1)
print(f"✓ {len(app)} metrics: app, Home Assistant sensors, journal and translations are consistent")
