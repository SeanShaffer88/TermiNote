# Parity — window vs command line

Every capability is an operation on the store in `lib/note_store.dart`.
The window (`lib/main.dart`, `lib/editor_screen.dart`,
`lib/settings_screen.dart`) and the command line (`lib/cli.dart`) both call
those same operations, so the two surfaces cannot drift apart in what they
do to the data. Scored from the code and the store tests.

Storage is shared too: since 0.3.0 both surfaces read and write the same
per-note Markdown files in the same notes folder (one `.md` file per note,
trash in its `trash` subfolder) through the same store code, and both run
the same one-time conversion when an old `notes.json` is found.

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
| Turn the note body into a list | Editor toolbar "1." / "•" buttons (selected lines or whole body; same button again converts back) | `listify ID numbered\|bullets\|plain` |
| Find text inside a note | Editor find bar (Ctrl+F): match count, previous/next, the match selected in the body | — (window-only) |
| Type the date and time into a note | F5 in the editor stamps it at the cursor, in the list's timestamp format | — (window-only) |
| Show a note's file in Explorer | Editor FILE button (saves first) | — (window-only) |
| Drive the list by keyboard | Arrow keys move the card highlight (mouse hover moves it too), Enter opens, Delete trashes with undo | — (window-only) |
| Recover work after a sudden close | Offered at startup ("Recover unsaved work?") when a recovery draft's text is newer than the saved note | — (window-only; the CLI saves before it returns, so it never leaves drafts) |
| Ask before closing with unsaved work | Editor close dialog ("Save before closing?") and program quit dialog ("Save before quitting?"). The window itself asks before any close (close button, Alt+F4, tray Quit all flow through the same prompt); the framework lifecycle listener answers by the same decision as a fallback | — (every CLI command saves before it returns, so there is never anything unsaved to lose) |
| Minimize to the system tray | Settings toggle (on by default) + tray icon with Open / New note / Quit (Quit posts a normal close, so it flows through the window-close prompt above) | — (window-only; the CLI has no window) |
| Choose what the X button does | Settings radios (Ask every time / Quit / Minimize to the system tray, default Ask). Asking shows a dialog with the two choices, a "Don't ask again" checkbox that remembers the pick as the setting, and Cancel. The tray menu's Quit always quits, whatever the X choice says; a remembered tray choice with the tray switched off quits instead | — (window-only; the CLI has no window) |
| One running window | A second window launch brings the already-running window to the front and exits — it never opens a second window over the same notes | — (unaffected: CLI calls run normally, including while the window is open) |
| Delete one note | Card trash button / editor | `delete` |
| Delete all notes | "All Delete" button | `delete-all --yes` |
| See the trash | Settings → Trash | `trash` |
| Restore from trash | Settings → Trash | `restore` |
| Delete forever / empty trash | Settings → Trash (asks first in a dialog) | `delete-forever`, `empty-trash` |
| Add / remove a tag on a note | Editor tags field | `tag`, `untag` |
| Rename a tag everywhere | Settings → Tags → Rename (renaming onto an existing tag merges them) | `rename-tag` |
| Add notes from .md / .txt files | Drag the files onto the window (a TermiNote-format file keeps its title, tags, and pin) | `add-file` |
| List tags with counts | Tag chips (counts in Settings) | `tags` |
| Export all notes to JSON | Settings → Export | `export` |
| Import notes from JSON | Settings → Import | `import` |
| Back up / restore the notes folder | Settings → Back up notes / Restore backup | — (window only) |

| Store statistics | Settings → About (data location + counts) | `stats` |
| Program version | Settings → About | `version` |
| Change text size | Editor A− / A+ and Settings | — (display preference, window-only) |
| Help | Settings → About | `help` |

Import merges with fresh ids and skips notes already present (a live note
with the same title and body), reporting both counts; a copy that only
exists in the trash does not count as already present.

Known gaps, stated plainly: manual reorder is a pointer task, so the CLI
can read the order but not set it; renaming a tag across all notes is
currently a CLI command without a window button; minimize to the system
tray is window-only by nature. None of these gaps affect the data: both
surfaces read and write the same note files through the same code.
