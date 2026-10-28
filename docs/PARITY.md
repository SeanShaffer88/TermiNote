# Parity — window vs command line

Every capability is an operation on the store in `lib/note_store.dart`.
The window (`lib/main.dart`, `lib/editor_screen.dart`,
`lib/settings_screen.dart`) and the command line (`lib/cli.dart`) both call
those same operations, so the two surfaces cannot drift apart in what they
do to the data. Scored from the code and the store tests.

| Capability | Window | Command line |
|---|---|---|
| Add a note | "Add note" button → editor | `add` |
| Edit title / body / tags | Editor page | `edit` |
| See one note in full | Editor page | `show` |
| List notes (titles only) | Card list | `list` (titles only) |
| Search titles, bodies, tags | Search button/field | `search`, `list --search` |
| Filter by tag / untagged | Tag chips | `list --tag`, `list --untagged` |
| Sort (modified / title / created / manual) | Sort button | `list --sort` |
| Reorder notes by hand | Drag a card by its handle | `order` field is shared; reorder itself is window-only (pointer task), the order is honoured by `list --sort manual` |
| Pin / unpin | Editor toolbar, card state | `pin`, `unpin` |
| Duplicate | Editor toolbar | `duplicate` |
| Delete one note | Card trash button / editor | `delete` |
| Delete all notes | "All Delete" button | `delete-all --yes` |
| See the trash | Settings → Trash | `trash` |
| Restore from trash | Settings → Trash | `restore` |
| Delete forever / empty trash | Settings → Trash | `delete-forever`, `empty-trash` |
| Add / remove a tag on a note | Editor tags field | `tag`, `untag` |
| Rename a tag everywhere | — (edit notes, or use the CLI) | `rename-tag` |
| List tags with counts | Tag chips (counts in Settings) | `tags` |
| Export all notes to JSON | Settings → Export | `export` |
| Import notes from JSON | Settings → Import | `import` |
| Store statistics | Settings → About (data location + counts) | `stats` |
| Change text size | Editor A− / A+ and Settings | — (display preference, window-only) |
| Help | Settings → About | `help` |

Known gaps, stated plainly: manual reorder is a pointer task, so the CLI
can read the order but not set it; renaming a tag across all notes is
currently a CLI command without a window button. Neither gap affects the
data: both surfaces read and write the same file through the same code.
