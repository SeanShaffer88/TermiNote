# TermiNote project rules

- Supported desktop target: Windows 11 x64 only.
- App logic, UI components, storage, Markdown, CLI, and lifecycle code are Rust. The UI is Dioxus compiled to WebAssembly and hosted by Tauri; CSS is used for presentation. Do not reintroduce Flutter or Dart.
- Preserve the established near-black scanline theme, white monospace text, and red accent unless the user requests a redesign.
- Keep note data local. Notes use Markdown files; preserve legacy `notes.json` migration and the previous settings shape.
- GUI and CLI must use the shared `terminote-core` crate and the same data lock.
- Keep saves atomic and serialized. Never discard a failed edit without retaining a recovery draft.
- Keep user data when uninstalling. Permanent deletion must remain explicit.
- Release assets are exactly `TermiNote-Setup-x64.exe` and `TermiNote-Portable-x64.zip`; no ARM64 artifacts.
- Do not start a performance rewrite until profiling establishes a bottleneck.
- Run core tests and the UI check for changes; rely on Windows x64 CI for native packaging.
