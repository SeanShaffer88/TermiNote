# TermiNote — Project Rules

Prompt in force: The Elite Software Master Prompt v1.1 · Annexes: A (desktop platform), C (owner annex). Annex B (orchestration) not in force for slices of this size; Annex D (AI features) does not apply — the product has no AI features.

Purpose in one line: A dark terminal-themed Windows notepad that looks like a mobile notepad app — titles-only list, tag organisation, local JSON data.

Frozen foundation:
- `lib/note_store.dart` is the whole data layer (model, store, operations, file IO). It never imports Flutter.
- Every capability is an operation on `NoteStore`; the GUI screens and `lib/cli.dart` are thin surfaces over it. No GUI-only data behaviour.
- Data format is the 0.1.0 JSON shape (`next_id`, `notes`, `trash`) plus the store-level `order` array. Format changes need a migration note in DECISIONS.md before they land.
- Zero pub dependencies: pubspec may only use the Flutter SDK and `flutter_test`.

Build: `flutter build windows --release`
Full gate: `dart format --output=none --set-exit-if-changed .` · `flutter analyze` · `flutter test` (all targets, unfiltered, output read)
Test corpus: `test/` — store tests incl. the 0.1.0 fixture, the titles-only widget test, golden renders into `preview/`.

Budgets: cold start to usable window under 2 s on a mid-range PC; idle CPU 0%; the list stays smooth at 1,000 notes; no network use at all.

Coverage floors: store operations 100% of public methods exercised by tests; the titles-only list rule has its own widget test and must never be weakened to pass.

Special rules for this project:
- The list shows note TITLES ONLY. Body text appears only inside the editor and in `show` CLI output. Any change that renders body text in a list, chip, tooltip, or search result is a defect, not a feature.
- Tags are the only organisation. No folders, ever.
- Theme: near-black `#0A0A0A` background, white text, red `#E81123` accent, Consolas monospace with Courier New / monospace fallback — in the window, the installer text, and these docs' descriptions of the program.
- Visual changes (colours, spacing, layout constants in the three screen files) follow the design recorded in preview/; do not restyle on initiative.
- Release assets are exactly two, x64 only: `TermiNote-Setup-x64.exe` and `TermiNote-Portable-x64.zip`. No winget, ever.
- The AppId GUID in the installer never changes.

Known limitations live at: QUALITY.md ("Known limitations") · Decision log: DECISIONS.md · QUALITY.md: QUALITY.md
