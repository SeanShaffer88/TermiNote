use crate::{
    Note, NoteStore, SortMode,
    markdown::{
        MarkdownFormat, apply_format, insert_toc, note_to_html, render_markdown_plain,
        strip_list_markers, to_bullet_list, to_numbered_list,
    },
    parse_tags,
};
use std::{
    collections::HashMap,
    fs,
    io::{self, Write},
    path::Path,
};

const COMMANDS: &[&str] = &[
    "add", "list", "show", "edit", "search", "delete", "duplicate", "listify", "format",
    "render", "toc", "export-html", "pin", "unpin", "tag", "untag", "rename-tag", "tags",
    "trash", "restore", "delete-forever", "empty-trash", "delete-all", "export", "import",
    "add-file", "backup", "restore-backup", "stats", "help", "version",
];

#[derive(Default)]
struct Options {
    positional: Vec<String>,
    values: HashMap<String, String>,
    json: bool,
    yes: bool,
    untagged: bool,
}

pub fn is_cli_args(args: &[String]) -> bool {
    args.first().is_some_and(|command| {
        COMMANDS.contains(&command.as_str())
            || matches!(command.as_str(), "--help" | "-h" | "--version" | "-V")
    })
}

pub fn run_cli(args: &[String], data_dir: &Path) -> i32 {
    run_cli_with(args, data_dir, &mut io::stdout(), &mut io::stderr())
}

pub fn run_cli_with(
    args: &[String],
    data_dir: &Path,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> i32 {
    let Some(command) = args.first().map(String::as_str) else {
        let _ = writeln!(out, "{}", help_text());
        return 0;
    };
    let Some(options) = parse_options(&args[1..], err) else {
        return 2;
    };
    if matches!(command, "help" | "--help" | "-h") {
        let _ = writeln!(out, "{}", help_text());
        return 0;
    }
    if matches!(command, "version" | "--version" | "-V") {
        let _ = writeln!(out, "TermiNote {}", env!("CARGO_PKG_VERSION"));
        return 0;
    }
    let mut store = match NoteStore::open(data_dir) {
        Ok(store) => store,
        Err(error) => {
            let _ = writeln!(err, "Could not open the notebook: {error}");
            return 1;
        }
    };
    let positional = &options.positional;
    match command {
        "add" => {
            let title = options.values.get("title").cloned().unwrap_or_else(|| positional.join(" "));
            if title.is_empty() {
                return usage(err, "Usage: terminote add \"title\" [--body TEXT] [--tags a,b]");
            }
            let body = options.values.get("body").map(String::as_str).unwrap_or("");
            let tags = parse_tags(options.values.get("tags").map(String::as_str).unwrap_or(""));
            match store.add(&title, body, &tags) {
                Ok(note) => report_save(store, out, format!("Added note {} \"{}\".", note.id, note.title)),
                Err(error) => fail(err, format!("Could not add note: {error}")),
            }
        }
        "list" | "search" => {
            let query = if command == "search" {
                positional.join(" ")
            } else {
                options.values.get("search").cloned().unwrap_or_default()
            };
            if command == "search" && query.is_empty() {
                return usage(err, "Usage: terminote search WORDS");
            }
            let notes = store.list(
                &query,
                options.values.get("tag").map(String::as_str),
                options.untagged,
                parse_sort(options.values.get("sort")),
            );
            if options.json {
                print_json(out, notes.iter().map(note_json).collect::<Vec<_>>())
            } else {
                for note in notes {
                    let _ = writeln!(out, "{}", note_line(&note));
                }
                0
            }
        }
        "show" => {
            let Some(id) = id_arg(positional, "Usage: terminote show ID", err) else {
                return 2;
            };
            let Some(note) = store.get(id).or_else(|| store.get_trashed(id)) else {
                return not_found(err, id);
            };
            if options.json {
                print_json(out, note_json(note))
            } else {
                let _ = writeln!(out, "{}\nCreated:  {}\nModified: {}\n\n{}",
                    note.title, note.created, note.modified, note.body);
                0
            }
        }
        "edit" => {
            let Some(id) = id_arg(positional, "Usage: terminote edit ID [--title T] [--body B] [--tags a,b]", err) else {
                return 2;
            };
            let Some(note) = store.get(id).cloned() else {
                return not_found(err, id);
            };
            let title = options.values.get("title").map(String::as_str).unwrap_or(&note.title);
            let body = options.values.get("body").map(String::as_str).unwrap_or(&note.body);
            let tags = options.values.get("tags").map(|value| parse_tags(value)).unwrap_or(note.tags);
            match store.update(id, title, body, &tags) {
                Ok(Some(_)) => report_save(store, out, format!("Updated note {id}.")),
                Ok(None) => not_found(err, id),
                Err(error) => fail(err, format!("Could not save note: {error}")),
            }
        }
        "delete" => {
            let Some(id) = id_arg(positional, "Usage: terminote delete ID", err) else {
                return 2;
            };
            match store.move_to_trash(id) {
                Ok(true) => report_save(store, out, format!("Moved note {id} to the trash.")),
                Ok(false) => not_found(err, id),
                Err(error) => fail(err, format!("Could not move note: {error}")),
            }
        }
        "restore" => {
            let Some(id) = id_arg(positional, "Usage: terminote restore ID", err) else {
                return 2;
            };
            match store.restore(id) {
                Ok(true) => report_save(store, out, format!("Restored note {id}.")),
                Ok(false) => fail(err, format!("No note with id {id} in the trash.")),
                Err(error) => fail(err, format!("Could not restore note: {error}")),
            }
        }
        "delete-forever" => {
            let Some(id) = id_arg(positional, "Usage: terminote delete-forever ID", err) else {
                return 2;
            };
            match store.delete_forever(id) {
                Ok(true) => report_save(store, out, format!("Deleted note {id} for good.")),
                Ok(false) => fail(err, format!("No note with id {id} in the trash.")),
                Err(error) => fail(err, format!("Could not delete note: {error}")),
            }
        }
        "empty-trash" => match store.empty_trash() {
            Ok(count) => report_save(store, out, format!("Deleted {count} note(s) for good.")),
            Err(error) => fail(err, format!("Could not empty the trash: {error}")),
        },
        "delete-all" => {
            if !options.yes {
                let _ = writeln!(err, "This moves every note to the trash. Run again with --yes.");
                return 2;
            }
            match store.delete_all() {
                Ok(count) => report_save(store, out, format!("Moved {count} note(s) to the trash.")),
                Err(error) => fail(err, format!("Could not delete all notes: {error}")),
            }
        }
        "trash" => {
            if options.json {
                print_json(out, store.trash.iter().map(note_json).collect::<Vec<_>>())
            } else {
                for note in &store.trash {
                    let _ = writeln!(out, "{}", note_line(note));
                }
                0
            }
        }
        "pin" | "unpin" => {
            let Some(id) = id_arg(positional, "Usage: terminote pin|unpin ID", err) else {
                return 2;
            };
            match store.set_pinned(id, command == "pin") {
                Ok(true) => report_save(store, out, format!("{} note {id}.", if command == "pin" { "Pinned" } else { "Unpinned" })),
                Ok(false) => not_found(err, id),
                Err(error) => fail(err, format!("Could not update note: {error}")),
            }
        }
        "tag" | "untag" => {
            let Some(id) = id_arg(positional, "Usage: terminote tag|untag ID TAG", err) else {
                return 2;
            };
            let Some(tag) = positional.get(1) else {
                return usage(err, "Usage: terminote tag|untag ID TAG");
            };
            let result = if command == "tag" {
                store.add_tag(id, tag)
            } else {
                store.remove_tag(id, tag)
            };
            match result {
                Ok(true) => report_save(store, out, format!("Updated tags on note {id}.")),
                Ok(false) => fail(err, format!("Note {id} or tag was not found.")),
                Err(error) => fail(err, format!("Could not update tag: {error}")),
            }
        }
        "rename-tag" => {
            if positional.len() < 2 {
                return usage(err, "Usage: terminote rename-tag OLD NEW");
            }
            match store.rename_tag(&positional[0], &positional[1]) {
                Ok(count) => report_save(store, out, format!("Renamed on {count} note(s).")),
                Err(error) => fail(err, format!("Could not rename tag: {error}")),
            }
        }
        "tags" => {
            let tags = store.all_tags();
            if options.json {
                print_json(out, tags)
            } else {
                for (tag, count) in tags {
                    let _ = writeln!(out, "{tag} ({count})");
                }
                0
            }
        }
        "duplicate" => {
            let Some(id) = id_arg(positional, "Usage: terminote duplicate ID", err) else {
                return 2;
            };
            match store.duplicate(id) {
                Ok(Some(note)) => report_save(store, out, format!("Duplicated as note {} \"{}\".", note.id, note.title)),
                Ok(None) => not_found(err, id),
                Err(error) => fail(err, format!("Could not duplicate note: {error}")),
            }
        }
        "listify" => {
            let Some(id) = id_arg(positional, "Usage: terminote listify ID numbered|bullets|plain", err) else {
                return 2;
            };
            let Some(note) = store.get(id).cloned() else {
                return not_found(err, id);
            };
            let Some(kind) = positional.get(1).map(String::as_str) else {
                return usage(err, "Usage: terminote listify ID numbered|bullets|plain");
            };
            let body = match kind {
                "numbered" => to_numbered_list(&note.body),
                "bullets" => to_bullet_list(&note.body),
                "plain" => strip_list_markers(&note.body),
                _ => return usage(err, "Unknown list style. Use numbered, bullets, or plain."),
            };
            match store.update(id, &note.title, &body, &note.tags) {
                Ok(_) => report_save(store, out, format!("Updated note {id}.")),
                Err(error) => fail(err, format!("Could not save note: {error}")),
            }
        }
        "format" => {
            let Some(id) = id_arg(positional, "Usage: terminote format ID FORMAT", err) else {
                return 2;
            };
            let Some(note) = store.get(id).cloned() else {
                return not_found(err, id);
            };
            let Some(kind) = positional.get(1).and_then(|value| parse_format(value)) else {
                return usage(err, "Format: bold, italic, strike, code, heading, link, quote, checklist");
            };
            let formatted = apply_format(&note.body, 0, note.body.len(), kind);
            match store.update(id, &note.title, &formatted.text, &note.tags) {
                Ok(_) => report_save(store, out, format!("Formatted note {id}.")),
                Err(error) => fail(err, format!("Could not save note: {error}")),
            }
        }
        "render" => {
            let Some(id) = id_arg(positional, "Usage: terminote render ID", err) else {
                return 2;
            };
            let Some(note) = store.get(id).or_else(|| store.get_trashed(id)) else {
                return not_found(err, id);
            };
            let _ = writeln!(out, "{}\n\n{}", note.title, render_markdown_plain(&note.body));
            0
        }
        "toc" => {
            let Some(id) = id_arg(positional, "Usage: terminote toc ID", err) else {
                return 2;
            };
            let Some(note) = store.get(id).cloned() else {
                return not_found(err, id);
            };
            let body = insert_toc(&note.body);
            if body == note.body {
                let _ = writeln!(err, "Note {id} has no headings.");
                return 1;
            }
            match store.update(id, &note.title, &body, &note.tags) {
                Ok(_) => report_save(store, out, format!("Updated table of contents in note {id}.")),
                Err(error) => fail(err, format!("Could not save note: {error}")),
            }
        }
        "export-html" => {
            let Some(id) = id_arg(positional, "Usage: terminote export-html ID FILE", err) else {
                return 2;
            };
            let Some(note) = store.get(id).or_else(|| store.get_trashed(id)) else {
                return not_found(err, id);
            };
            let Some(path) = positional.get(1) else {
                return usage(err, "Usage: terminote export-html ID FILE");
            };
            match fs::write(path, note_to_html(&note.title, &note.body)) {
                Ok(()) => {
                    let _ = writeln!(out, "Wrote note {id} as HTML to {path}.");
                    0
                }
                Err(error) => fail(err, format!("Could not write HTML: {error}")),
            }
        }
        "export" => {
            let Some(path) = positional.first() else {
                return usage(err, "Usage: terminote export FILE");
            };
            match store.export_json().and_then(|json| fs::write(path, json).map_err(|error| serde_json::Error::io(error))) {
                Ok(()) => {
                    let _ = writeln!(out, "Exported {} note(s) to {path}.", store.notes.len());
                    0
                }
                Err(error) => fail(err, format!("Could not export notes: {error}")),
            }
        }
        "import" => {
            let Some(path) = positional.first() else {
                return usage(err, "Usage: terminote import FILE");
            };
            let text = match fs::read_to_string(path) {
                Ok(text) => text,
                Err(error) => return fail(err, format!("Could not read {path}: {error}")),
            };
            match store.import_json(&text) {
                Ok(result) => report_save(store, out, format!("Imported {} note(s); skipped {}.", result.imported, result.skipped)),
                Err(error) => fail(err, format!("Could not import notes: {error}")),
            }
        }
        "add-file" => {
            let Some(path) = positional.first() else {
                return usage(err, "Usage: terminote add-file FILE");
            };
            let Some(name) = Path::new(path).file_name().and_then(|name| name.to_str()) else {
                return fail(err, "Invalid file path.".into());
            };
            let lower = name.to_lowercase();
            if !lower.ends_with(".md") && !lower.ends_with(".txt") {
                return fail(err, "Only .md and .txt files can be added.".into());
            }
            let text = match fs::read_to_string(path) {
                Ok(text) if text.len() <= 5 * 1024 * 1024 => text,
                Ok(_) => return fail(err, "File is larger than 5 MB.".into()),
                Err(error) => return fail(err, format!("Could not read file: {error}")),
            };
            if text.trim().is_empty() {
                return fail(err, "File is empty.".into());
            }
            match store.import_file_text(&text, name) {
                Ok(note) => report_save(store, out, format!("Added note {} from {name}.", note.id)),
                Err(error) => fail(err, format!("Could not add file: {error}")),
            }
        }
        "backup" => {
            let Some(path) = positional.first() else {
                return usage(err, "Usage: terminote backup FOLDER");
            };
            match crate::backup_data(data_dir, Path::new(path)) {
                Ok(count) => {
                    let _ = writeln!(out, "Backed up {count} item(s) to {path}.");
                    0
                }
                Err(error) => fail(err, format!("Could not create backup: {error}")),
            }
        }
        "restore-backup" => {
            let Some(path) = positional.first() else {
                return usage(err, "Usage: terminote restore-backup FOLDER --yes");
            };
            if !options.yes {
                let _ = writeln!(err, "This replaces live notes. The current notebook is backed up first; pass --yes to continue.");
                return 2;
            }
            match crate::restore_backup(data_dir, Path::new(path)) {
                Ok(()) => {
                    let _ = writeln!(out, "Restored from {path}. A pre-restore backup was kept in the data folder.");
                    0
                }
                Err(error) => fail(err, format!("Could not restore backup: {error}")),
            }
        }
        "stats" => {
            let stats = store.stats();
            let json = serde_json::json!({
                "notes": stats.notes, "trash": stats.trash, "tags": stats.tags,
                "pinned": stats.pinned, "words": stats.words, "characters": stats.characters
            });
            if options.json {
                print_json(out, json)
            } else {
                let _ = writeln!(out, "Notes: {}\nIn trash: {}\nTags: {}\nPinned: {}\nTotal words: {}\nTotal characters: {}",
                    stats.notes, stats.trash, stats.tags, stats.pinned, stats.words, stats.characters);
                0
            }
        }
        _ => {
            let _ = writeln!(err, "Unknown command \"{command}\". Run: terminote help");
            2
        }
    }
}

fn parse_options(args: &[String], err: &mut dyn Write) -> Option<Options> {
    let mut options = Options::default();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        match arg.as_str() {
            "--json" => options.json = true,
            "--yes" => options.yes = true,
            "--untagged" => options.untagged = true,
            _ if arg.starts_with("--") => {
                let value = &arg[2..];
                if let Some((name, value)) = value.split_once('=') {
                    options.values.insert(name.to_string(), value.to_string());
                } else if let Some(next) = args.get(index + 1) {
                    index += 1;
                    options.values.insert(value.to_string(), next.clone());
                } else {
                    let _ = writeln!(err, "Option {arg} needs a value.");
                    return None;
                }
            }
            _ => options.positional.push(arg.clone()),
        }
        index += 1;
    }
    Some(options)
}

fn parse_sort(value: Option<&String>) -> SortMode {
    match value.map(String::as_str) {
        Some("titleAsc") => SortMode::TitleAsc,
        Some("createdDesc") => SortMode::CreatedDesc,
        Some("manual") => SortMode::Manual,
        _ => SortMode::ModifiedDesc,
    }
}

fn parse_format(value: &str) -> Option<MarkdownFormat> {
    match value.to_lowercase().as_str() {
        "bold" => Some(MarkdownFormat::Bold),
        "italic" => Some(MarkdownFormat::Italic),
        "strike" | "strikethrough" => Some(MarkdownFormat::Strike),
        "code" => Some(MarkdownFormat::Code),
        "heading" => Some(MarkdownFormat::Heading),
        "link" => Some(MarkdownFormat::Link),
        "quote" => Some(MarkdownFormat::Quote),
        "checklist" => Some(MarkdownFormat::Checklist),
        _ => None,
    }
}

fn id_arg(positional: &[String], usage: &str, err: &mut dyn Write) -> Option<u64> {
    let Some(raw) = positional.first() else {
        let _ = writeln!(err, "{usage}");
        return None;
    };
    match raw.parse() {
        Ok(id) => Some(id),
        Err(_) => {
            let _ = writeln!(err, "\"{raw}\" is not a note id.");
            None
        }
    }
}

fn note_json(note: &Note) -> serde_json::Value {
    serde_json::json!({
        "id": note.id, "title": note.title, "body": note.body,
        "tags": note.tags, "pinned": note.pinned,
        "created": note.created, "modified": note.modified
    })
}

fn note_line(note: &Note) -> String {
    let pin = if note.pinned { "* " } else { "" };
    let tags = if note.tags.is_empty() {
        String::new()
    } else {
        format!("  [{}]", note.tags.join(", "))
    };
    format!("{}  {pin}{}{tags}", note.id, note.title)
}

fn print_json(out: &mut dyn Write, value: impl serde::Serialize) -> i32 {
    match serde_json::to_string_pretty(&value) {
        Ok(json) => {
            let _ = writeln!(out, "{json}");
            0
        }
        Err(error) => {
            let _ = writeln!(out, "Could not encode JSON: {error}");
            1
        }
    }
}

fn report_save(_store: NoteStore, out: &mut dyn Write, message: String) -> i32 {
    // Note operations write through the store immediately. This explicit
    // return point keeps command output after successful persistence.
    let _ = writeln!(out, "{message}");
    0
}

fn fail(err: &mut dyn Write, message: String) -> i32 {
    let _ = writeln!(err, "{message}");
    1
}

fn usage(err: &mut dyn Write, message: &str) -> i32 {
    let _ = writeln!(err, "{message}");
    2
}

fn not_found(err: &mut dyn Write, id: u64) -> i32 {
    let _ = writeln!(err, "No note with id {id}.");
    1
}

fn help_text() -> &'static str {
    "TermiNote - a dark terminal-themed notepad.\n\
     Usage: terminote <command> [options]\n\
     Notes: add, list, show, edit, search, delete, duplicate, listify, format, render, toc, export-html\n\
     Tags: tag, untag, rename-tag, tags\n\
     Trash: trash, restore, delete-forever, empty-trash, delete-all --yes\n\
     Files: export FILE, import FILE, add-file FILE, backup FOLDER, restore-backup FOLDER --yes\n\
     Other: stats, version, help\n\
     Sort names: modifiedDesc, titleAsc, createdDesc, manual."
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_add_and_list_use_the_same_markdown_store() {
        let temp = tempfile::tempdir().unwrap();
        let mut output = Vec::new();
        let mut errors = Vec::new();
        let add = vec!["add".into(), "hello".into(), "--body".into(), "world".into()];
        assert_eq!(run_cli_with(&add, temp.path(), &mut output, &mut errors), 0);
        assert!(String::from_utf8(std::mem::take(&mut output))
            .unwrap()
            .contains("Added note 1"));

        output.clear();
        let list = vec!["list".into()];
        assert_eq!(run_cli_with(&list, temp.path(), &mut output, &mut errors), 0);
        assert!(String::from_utf8(output).unwrap().contains("hello"));
        assert!(errors.is_empty());
    }

    #[test]
    fn cli_rejects_destructive_delete_all_without_yes() {
        let temp = tempfile::tempdir().unwrap();
        let mut output = Vec::new();
        let mut errors = Vec::new();
        let args = vec!["delete-all".into()];
        assert_eq!(run_cli_with(&args, temp.path(), &mut output, &mut errors), 2);
        assert!(String::from_utf8(errors).unwrap().contains("--yes"));
    }
}
