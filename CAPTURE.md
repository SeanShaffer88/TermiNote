# Windows 11 x64 field check

Run these checks with the built Tauri app before calling the rewrite field-verified:

- Launch the installer and portable ZIP; confirm both open the same black/red terminal-style layout.
- Resize, maximize, close, relaunch, and confirm window size, position, and maximized state are restored.
- Minimize to tray and restore with one left-click; exercise tray Open, New note, and Quit.
- Edit a note title, tags, Markdown body, and checklist item; confirm automatic saves survive closing and reopening.
- Interrupt the app while an edit is being saved; confirm the on-disk recovery draft is offered at next launch when the latest edit did not finish saving.
- Verify old `notes.json` data and old settings migrate without losing note, Trash, or window settings.
- Search and filter tags; create a tag and verify existing tags are suggested.
- Reorder notes in manual mode, pin/unpin, move a note to Trash, restore it, and permanently delete it.
- Create a backup, restore it, and confirm the current notebook has a safety copy.
- Run representative CLI commands (`list`, `show`, `add`, `edit`, `backup`, `stats`) and verify they use the same data folder.
- Verify update checking can be disabled and that an available update waits for autosaves before installing.
- Check narrow/wide window sizes and 150% display scaling for clipping and keyboard usability.

Until this pass is completed, the Tauri runtime and installer remain unverified outside CI.
