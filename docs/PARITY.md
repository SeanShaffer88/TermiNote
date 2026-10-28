# Parity — GUI vs CLI

Every capability is an operation in `src/ops.rs`. This matrix shows how each one is reached from the window and from the command line.

| Operation (ops.rs) | GUI | CLI |
|---|---|---|
| `add` | "Add note" button / Ctrl+N; also drag-and-drop of `.txt`/`.md` | `add "title" [--body] [--tags]` |
| `update` | Editor fields with autosave (~600 ms) and Ctrl+S | `edit ID [--title] [--body] [--tags]` |
| `get` | Click a title: the note opens in the editor | `show ID` |
| `list` (search / tag filter / sort / pinned first) | Search box, tags sidebar, notes list (titles only) | `list [--tag] [--search] [--sort]`, `search Q` |
| `delete` (to trash) | Delete button; Delete key on the list (asks first) | `delete ID` |
| `restore` | "Undo delete" button / Ctrl+Shift+Z (most recent trashed note) | `restore ID` (any trashed note) |
| `delete_forever` | Not in the GUI in v0.1.0 | `delete-forever ID` |
| `empty_trash` | Not in the GUI in v0.1.0 | `empty-trash` |
| `delete_all` (to trash) | "Delete all" button (asks first) | `delete-all --yes` |
| `tag_add` | Tags field in the editor | `tag ID TAG` |
| `tag_remove` | Tags field in the editor | `untag ID TAG` |
| `rename_tag` | Not in the GUI in v0.1.0 (edit tags per note instead) | `rename-tag OLD NEW` |
| `all_tags` (with counts) | Tags sidebar | `tags` |
| `set_pinned` / `toggle_pin` | Pin/Unpin button in the editor | `pin ID` / `unpin ID` |
| `duplicate` | Duplicate button in the editor | `duplicate ID` |
| `export_json` | Not in the GUI in v0.1.0 | `export FILE` |
| `import_json` (merge, new ids) | Drag-and-drop a `.json` export onto the window | `import FILE` |
| `export_note_text` | Copy from the editor | `show ID` prints the same title + body shape |
| `stats` | Sidebar status line (shown / total / trash counts) | `stats` (full counts, words and characters) |
| Trash listing | Sidebar status line shows the trash count | `trash` |
| Help | F1 / Help button (built-in, offline) | `help` |
| About | About button | `version` prints the version |

Known asymmetries (all deliberate in v0.1.0, and listed here so they are visible rather than silent): permanent deletion, tag renaming and JSON export are CLI-only; the GUI's restore covers the most recently deleted note while the CLI can restore any trashed note by id. The operations themselves are identical — both shells dispatch to the same `ops` functions.
