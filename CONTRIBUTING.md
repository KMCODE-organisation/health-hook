# Contributing to Health Hook

Thanks for your interest! Bug reports, ideas and pull requests are welcome.

## Before you start

- **Bugs and questions**: open an [issue](../../issues/new/choose). Include your iOS and Home Assistant versions and,
  for sync problems, the status line shown in the app.
- **Bigger changes** (new feature, payload format change): open an issue first so we can agree on the approach.
- **Never** paste your webhook URL, Home Assistant URL or real health data in an issue or a pull request.

## Project layout

| Path | What |
|---|---|
| `HealthHook/` | iOS app (SwiftUI, iOS 17+, no dependencies) |
| `HealthHook/Catalog.swift` | the list of Health metrics (JSON keys, units, kinds) |
| `HealthHook/Localizable.xcstrings` | UI strings, English (source) + French |
| `project.yml` | XcodeGen project description (the `.xcodeproj` is generated, not committed) |
| `HealthHook.xcconfig` | shared build settings; includes your git-ignored `Local.xcconfig` |
| `homeassistant/packages/health_hook.yaml` | Home Assistant package, **generated** by `tools/generate_ha_package.py` |
| `homeassistant/packages/health_hook_summary.yaml` | optional AI summary package (hand-written) |
| `homeassistant/health_hook/journal.py` | daily journal script run by Home Assistant (Python standard library only) |
| `tools/` | Mac helpers (auto-reinstall), package generator, icon source |

## Building

```bash
brew install xcodegen
xcodegen && open HealthHook.xcodeproj
```

Put your `BUNDLE_ID_PREFIX` and `DEVELOPMENT_TEAM` in `Local.xcconfig` (copy `Local.xcconfig.example`). It is ignored
by git: never commit personal values, and never set these two settings in `project.yml` (they would override
`Local.xcconfig`).

## Adding a Health metric

A metric lives in three places that must stay in sync:

1. **`HealthHook/Catalog.swift`**: add it to `Catalog.metrics` with `total(…)` for cumulative data (daily sum) or
   `sample(…)` for discrete data (latest value + daily average). The `id` is the JSON key: `snake_case`, English.
   Using a cumulative option on a discrete type (or the reverse) crashes HealthKit, so check the type's
   [aggregation style](https://developer.apple.com/documentation/healthkit/hkquantityaggregationstyle).
2. **`HealthHook/Localizable.xcstrings`**: add the title with its French translation (Xcode's String Catalog editor
   does it for you).
3. **`tools/generate_ha_package.py`**: add the sensor (same key, unit, icon, kind), run
   `python3 tools/generate_ha_package.py`, and commit the regenerated `health_hook.yaml`.
   Also add the unit to `UNITS` in `homeassistant/health_hook/journal.py`.

Never rename or remove an existing key: it would break users' sensors and history.

## Pull requests

- One topic per pull request, with a short description of what and why.
- Code, comments and commit messages in English; keep the French translation complete for UI strings.
- Check that the app builds and that a sync still reaches Home Assistant.
- For Home Assistant changes: `ha core check` (or *Developer tools → YAML → Check configuration*) must pass.
- No new dependencies in the app or in `journal.py`.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
