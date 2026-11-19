# Shared behavior

The desktop interface and terminal commands call the same `terminote-core` Rust operations and use the same local note files.

| Capability | Desktop app | CLI |
|---|---|---|
| Create and edit notes | Inline editor, autosaved | `add`, `edit`, `show` |
| Checklist notes | Inline add, edit, check, and delete | `format`, `listify`, `edit` |
| Search and tags | Search field, tag filters, tag suggestions | `search`, `list --search`, `tag`, `untag`, `tags` |
| Pin and reorder | Pin control; drag or move controls in manual order | `pin`, `unpin` |
| Markdown | Edit, split, preview, toolbar, find/replace | `format`, `render`, `toc`, `export-html` |
| Trash and recovery | Trash view, restore, recovery prompt | `trash`, `restore`, `delete-forever`, `empty-trash` |
| Import/export and backup | JSON import/export; backup and restore | `import`, `export`, `backup`, `restore-backup` |
| Window lifecycle | Tray, single-click restore, remembered placement, close choice | Not applicable |
| Statistics | Settings | `stats` |

The command line also supports `duplicate`, `rename-tag`, `add-file`, and destructive actions with explicit confirmation. Run `TermiNote.exe help` for full syntax.

## Compatibility

New notes are Markdown files with metadata. On first launch, existing `notes.json` data is migrated and retained as a backup. The Rust core reads and writes the previous settings JSON shape, including sort, text size, tray, close action, update preference, and window placement.

## Verification boundary

Core tests and the Dioxus UI check run in the workspace. The Tauri host, installer, and Windows event behavior require the Windows x64 CI job and a Windows 11 runtime check; see [QUALITY.md](../QUALITY.md).
