# Decisions

Decisions behind TermiNote 0.2.0, and why each one was made.

## Stack: Flutter for Windows, zero external packages

0.1.0 was Rust with native Windows controls. That build looked wrong on a
real desktop: native controls rendered with the platform chrome, clipped
buttons, and inconsistent spacing. The rewrite uses Flutter because it
renders its own interface, so the program can look like a mobile app
(the reference design) inside a desktop window, identically on every
machine. Dart is the language Flutter apps are written in.

The project depends on no pub packages at all — only the Flutter SDK and
its test SDK. That keeps the build reproducible, the download small, and
the program free of other people's update and abandonment risk. File
pickers are deliberately avoided for the same reason: export and import
take a path typed into a text field instead.

## Data format: unchanged from 0.1.0

The file is still plain JSON at the same location, with the same
`next_id`, `notes`, and `trash` fields. The only addition is a store-level
`order` array recording the manual card order. Older readers ignore
unknown fields, and this reader ignores unknown fields, so a 0.1.0
install and a 0.2.0 install can share one file without either of them
breaking the other's notes.

## List shows titles only

Every note has a title and a body, but the main list shows the title and
nothing else — no preview lines, no body snippets. This is the one rule
the widget tests enforce directly: a test pumps the list screen and
asserts the body text of every note is nowhere on screen. Search still
matches body text (finding a note by a word in its body is useful), it
just never prints that text into the list.

## Tags, never folders

Notes are organised with tags only. The tag filter is a scrolling row of
chips: "All notes", "Untagged", then one chip per tag. There is no
folder concept anywhere: no folder tree, no move-to-folder command, no
folder field in the data file.

## Look: phone app, desktop window

The reference is a mobile notepad app. The window keeps that layout — a
single centered column, a header row, a toolbar row, and rounded cards —
instead of a traditional desktop multi-pane layout. On a wide window the
column stays at a comfortable reading width with dark margins on either
side. Colours stay in the terminal theme: near-black background, white
text, red accent, monospace type everywhere.

## Command line lives in the same program

Every capability in the window is also available from the terminal,
through the same store code. On Windows the runner attaches to the parent
console before the Dart code runs when arguments are present, so
`TermiNote.exe list` prints into the terminal that ran it instead of
flashing a window. The window only opens when there are no arguments.

## Safety rules that did not change

- Saving is atomic (write a `.tmp` file, then rename it over the real
  file), so a crash mid-save cannot leave half a file.
- Deleting moves a note to the trash first; it is only gone for good
  when the trash is emptied or the note is deleted forever.
- A damaged data file is renamed with a `.corrupt-` timestamp and kept,
  never overwritten, and the program starts with an empty notebook.
- Uninstalling never deletes the user's notes.
- Everything works offline. There is no account, no sync, no network
  call, no analytics, and no data sale.
