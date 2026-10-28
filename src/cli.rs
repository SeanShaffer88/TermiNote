//! The command line: full parity with the GUI.
//!
//! Every command loads the store, dispatches to [`crate::ops`], and
//! saves when it changed anything. `list`, `search` and the GUI's
//! list all share one rule: only titles are printed, never body
//! text (except by `show`, which is the explicit way to read a note).
//!
//! Exit codes: 0 = success, 1 = the command could not be done
//! (for example, no such note), 2 = the command itself was not
//! understood. Errors go to stderr in plain words.

use crate::json::{self, Json};
use crate::note::{parse_tag_list, Note};
use crate::ops::{self, Filter, Sort};
use crate::store::{self, Store};
use crate::time;

pub const HELP: &str = "\
TermiNote - a dark terminal-themed notepad. Notes have a title and a
body, and are organised with tags (no folders).

Usage:
  TermiNote                      Open the window (Windows).
  TermiNote <command> [options]  Run a command instead.

Commands:
  add \"title\" [--body TEXT] [--tags a,b]   Add a note.
  list [--tag T] [--search Q] [--sort S]   List note titles only.
  show ID                                  Print one note in full.
  edit ID [--title T] [--body B] [--tags a,b]
                                           Change a note.
  delete ID                                Move a note to the trash.
  restore ID                               Bring a note back from the trash.
  delete-forever ID                        Permanently delete a trashed note.
  trash                                    List what is in the trash (titles).
  empty-trash                              Permanently delete everything in the trash.
  delete-all --yes                         Move every note to the trash.
  tag ID TAG                               Add a tag to a note.
  untag ID TAG                             Remove a tag from a note.
  rename-tag OLD NEW                       Rename a tag on every note.
  tags                                     List tags with counts.
  pin ID / unpin ID                        Pin or unpin a note (pinned show first).
  duplicate ID                             Copy a note.
  search Q                                 Search titles, bodies and tags (titles listed).
  export FILE                              Write all notes to FILE as JSON.
  import FILE                              Merge notes from a JSON export into this store.
  stats                                    Counts, word and character totals.
  help                                     This help.

Options:
  --sort S     modified (newest first), title, or created. Default: modified.
  --json       On list, show, search, tags and stats: print machine JSON.

Data lives in a local JSON file (see the README for where). Everything
is offline; nothing leaves this computer.
";

struct Loaded {
    store: Store,
    path: std::path::PathBuf,
}

fn load() -> Loaded {
    let path = store::data_file_path();
    let outcome = Store::load(&path, time::now_unix());
    if outcome.was_corrupt {
        eprintln!(
            "warning: the data file was damaged, so it was moved aside and a fresh, empty store was started. The damaged file was kept next to the data file with \".corrupt-\" in its name."
        );
    }
    Loaded {
        store: outcome.store,
        path,
    }
}

fn save(loaded: &Loaded) -> Result<(), String> {
    loaded.store.save(&loaded.path)
}

/// Extract a `--flag value` pair (removing both) or report it missing.
fn take_value(args: &mut Vec<String>, flag: &str) -> Option<String> {
    let pos = args.iter().position(|a| a == flag)?;
    if pos + 1 >= args.len() {
        return None;
    }
    let value = args.remove(pos + 1);
    args.remove(pos);
    Some(value)
}

fn take_flag(args: &mut Vec<String>, flag: &str) -> bool {
    if let Some(pos) = args.iter().position(|a| a == flag) {
        args.remove(pos);
        true
    } else {
        false
    }
}

fn parse_id(text: &str) -> Result<u64, String> {
    text.parse::<u64>()
        .map_err(|_| format!("\"{text}\" is not a note id (ids are numbers, shown by `list`)"))
}

fn print_note_line(note: &Note) {
    let pin = if note.pinned { " [pinned]" } else { "" };
    if note.tags.is_empty() {
        println!("{}  {}{}", note.id, note.title, pin);
    } else {
        println!(
            "{}  {}{}  [{}]",
            note.id,
            note.title,
            pin,
            note.tags.join(", ")
        );
    }
}

fn notes_json(notes: &[Note]) -> String {
    json::stringify(&Json::Arr(notes.iter().map(Note::to_json).collect()))
}

fn cmd_list(
    loaded: &Loaded,
    mut args: Vec<String>,
    json_out: bool,
) -> Result<String, (i32, String)> {
    let tag = take_value(&mut args, "--tag");
    let search = take_value(&mut args, "--search").unwrap_or_default();
    let sort = match take_value(&mut args, "--sort") {
        Some(name) => Some(Sort::parse(&name).ok_or_else(|| {
            (
                2,
                format!("unknown sort \"{name}\" (use modified, title or created)"),
            )
        })?),
        None => None,
    };
    if !args.is_empty() {
        return Err((2, format!("unexpected extra text: {}", args.join(" "))));
    }
    let (tag_filter, untagged) = match tag.as_deref() {
        None => (None, false),
        Some("untagged") => (None, true),
        Some(t) => (Some(t.to_string()), false),
    };
    let notes = ops::list(
        &loaded.store,
        &Filter {
            search,
            tag: tag_filter,
            untagged_only: untagged,
            sort,
        },
    );
    if json_out {
        println!("{}", notes_json(&notes));
    } else if notes.is_empty() {
        println!("No notes found.");
    } else {
        for note in &notes {
            print_note_line(note);
        }
    }
    Ok(String::new())
}

/// Run one CLI invocation. `args` excludes the program name.
/// Returns the process exit code.
pub fn run(args: &[String]) -> i32 {
    let mut args: Vec<String> = args.to_vec();
    let json_out = take_flag(&mut args, "--json");
    if args.is_empty() {
        eprintln!("no command given.\n\n{HELP}");
        return 2;
    }
    let command = args.remove(0);
    match dispatch(&command, args, json_out) {
        Ok(message) => {
            if !message.is_empty() {
                println!("{message}");
            }
            0
        }
        Err((code, message)) => {
            eprintln!("terminote: {message}");
            code
        }
    }
}

fn dispatch(command: &str, args: Vec<String>, json_out: bool) -> Result<String, (i32, String)> {
    let fail = |m: String| (1, m);
    match command {
        "help" | "--help" | "-h" => {
            print!("{HELP}");
            Ok(String::new())
        }
        "version" | "--version" | "-V" => Ok(format!("TermiNote {}", env!("CARGO_PKG_VERSION"))),
        "add" => {
            let mut args = args;
            let body = take_value(&mut args, "--body").unwrap_or_default();
            let tags = take_value(&mut args, "--tags")
                .map(|t| parse_tag_list(&t))
                .unwrap_or_default();
            if args.len() != 1 {
                return Err((2, "add needs exactly one title in quotes".to_string()));
            }
            let mut loaded = load();
            let note = ops::add(&mut loaded.store, &args[0], &body, tags, time::now_unix());
            save(&loaded).map_err(fail)?;
            Ok(format!("Added note {} \"{}\".", note.id, note.title))
        }
        "list" => {
            let loaded = load();
            cmd_list(&loaded, args, json_out)
        }
        "search" => {
            if args.is_empty() {
                return Err((2, "search needs the words to look for".to_string()));
            }
            let loaded = load();
            let notes = ops::list(
                &loaded.store,
                &Filter {
                    search: args.join(" "),
                    ..Default::default()
                },
            );
            if json_out {
                println!("{}", notes_json(&notes));
                Ok(String::new())
            } else if notes.is_empty() {
                Ok("No notes found.".to_string())
            } else {
                for note in &notes {
                    print_note_line(note);
                }
                Ok(String::new())
            }
        }
        "show" => {
            if args.len() != 1 {
                return Err((2, "show needs one note id".to_string()));
            }
            let loaded = load();
            let id = parse_id(&args[0]).map_err(|m| (2, m))?;
            let note = ops::get(&loaded.store, id).map_err(fail)?.clone();
            if json_out {
                println!("{}", json::stringify(&note.to_json()));
                Ok(String::new())
            } else {
                let mut out = format!("{}\n", note.title);
                if !note.tags.is_empty() {
                    use std::fmt::Write as _;
                    let _ = writeln!(out, "Tags: {}", note.tags.join(", "));
                }
                if note.pinned {
                    out.push_str("Pinned: yes\n");
                }
                out.push('\n');
                out.push_str(&note.body);
                Ok(out)
            }
        }
        "edit" => {
            let mut args = args;
            let title = take_value(&mut args, "--title");
            let body = take_value(&mut args, "--body");
            let tags = take_value(&mut args, "--tags").map(|t| parse_tag_list(&t));
            if args.len() != 1 {
                return Err((2, "edit needs one note id".to_string()));
            }
            if title.is_none() && body.is_none() && tags.is_none() {
                return Err((
                    2,
                    "edit needs at least one of --title, --body or --tags".to_string(),
                ));
            }
            let id = parse_id(&args[0]).map_err(|m| (2, m))?;
            let mut loaded = load();
            let note = ops::update(
                &mut loaded.store,
                id,
                title.as_deref(),
                body.as_deref(),
                tags,
                time::now_unix(),
            )
            .map_err(fail)?;
            save(&loaded).map_err(fail)?;
            Ok(format!("Saved note {} \"{}\".", note.id, note.title))
        }
        "delete" => {
            if args.len() != 1 {
                return Err((2, "delete needs one note id".to_string()));
            }
            let id = parse_id(&args[0]).map_err(|m| (2, m))?;
            let mut loaded = load();
            let note = ops::delete(&mut loaded.store, id, time::now_unix()).map_err(fail)?;
            save(&loaded).map_err(fail)?;
            Ok(format!(
                "Moved note {} \"{}\" to the trash. Bring it back with: restore {}",
                note.id, note.title, note.id
            ))
        }
        "restore" => {
            if args.len() != 1 {
                return Err((2, "restore needs one note id".to_string()));
            }
            let id = parse_id(&args[0]).map_err(|m| (2, m))?;
            let mut loaded = load();
            let note = ops::restore(&mut loaded.store, id, time::now_unix()).map_err(fail)?;
            save(&loaded).map_err(fail)?;
            Ok(format!("Restored note {} \"{}\".", note.id, note.title))
        }
        "delete-forever" => {
            if args.len() != 1 {
                return Err((2, "delete-forever needs one note id".to_string()));
            }
            let id = parse_id(&args[0]).map_err(|m| (2, m))?;
            let mut loaded = load();
            let note = ops::delete_forever(&mut loaded.store, id).map_err(fail)?;
            save(&loaded).map_err(fail)?;
            Ok(format!(
                "Permanently deleted note {} \"{}\".",
                note.id, note.title
            ))
        }
        "trash" => {
            let loaded = load();
            let notes = ops::list_trash(&loaded.store);
            if notes.is_empty() {
                Ok("The trash is empty.".to_string())
            } else {
                for note in &notes {
                    print_note_line(note);
                }
                Ok(String::new())
            }
        }
        "empty-trash" => {
            let mut loaded = load();
            let count = ops::empty_trash(&mut loaded.store);
            save(&loaded).map_err(fail)?;
            Ok(format!(
                "Permanently deleted {count} note(s) from the trash."
            ))
        }
        "delete-all" => {
            let mut args = args;
            if !take_flag(&mut args, "--yes") {
                return Err((
                    2,
                    "delete-all moves every note to the trash; run it again with --yes if you mean it"
                        .to_string(),
                ));
            }
            let mut loaded = load();
            let count = ops::delete_all(&mut loaded.store, time::now_unix());
            save(&loaded).map_err(fail)?;
            Ok(format!(
                "Moved {count} note(s) to the trash. Bring them back one at a time with restore ID (see `trash`)."
            ))
        }
        "tag" | "untag" => {
            if args.len() != 2 {
                return Err((2, format!("{command} needs a note id and a tag")));
            }
            let id = parse_id(&args[0]).map_err(|m| (2, m))?;
            let mut loaded = load();
            let now = time::now_unix();
            let note = if command == "tag" {
                ops::tag_add(&mut loaded.store, id, &args[1], now)
            } else {
                ops::tag_remove(&mut loaded.store, id, &args[1], now)
            }
            .map_err(fail)?;
            save(&loaded).map_err(fail)?;
            Ok(format!(
                "Note {} tags: {}",
                note.id,
                if note.tags.is_empty() {
                    "(none)".to_string()
                } else {
                    note.tags.join(", ")
                }
            ))
        }
        "rename-tag" => {
            if args.len() != 2 {
                return Err((
                    2,
                    "rename-tag needs the old tag and the new tag".to_string(),
                ));
            }
            let mut loaded = load();
            let changed = ops::rename_tag(&mut loaded.store, &args[0], &args[1], time::now_unix())
                .map_err(fail)?;
            save(&loaded).map_err(fail)?;
            Ok(format!("Renamed the tag on {changed} note(s)."))
        }
        "tags" => {
            let loaded = load();
            let tags = ops::all_tags(&loaded.store);
            if json_out {
                let arr = Json::Arr(
                    tags.iter()
                        .map(|(name, count)| {
                            Json::Obj(vec![
                                ("tag".to_string(), Json::Str(name.clone())),
                                ("count".to_string(), Json::Num(*count as f64)),
                            ])
                        })
                        .collect(),
                );
                println!("{}", json::stringify(&arr));
                Ok(String::new())
            } else if tags.is_empty() {
                Ok("No tags yet.".to_string())
            } else {
                for (name, count) in &tags {
                    println!("{name} ({count})");
                }
                Ok(String::new())
            }
        }
        "pin" | "unpin" => {
            if args.len() != 1 {
                return Err((2, format!("{command} needs one note id")));
            }
            let id = parse_id(&args[0]).map_err(|m| (2, m))?;
            let mut loaded = load();
            let note = ops::set_pinned(&mut loaded.store, id, command == "pin", time::now_unix())
                .map_err(fail)?;
            save(&loaded).map_err(fail)?;
            Ok(format!(
                "Note {} \"{}\" {}.",
                note.id,
                note.title,
                if note.pinned { "pinned" } else { "unpinned" }
            ))
        }
        "duplicate" => {
            if args.len() != 1 {
                return Err((2, "duplicate needs one note id".to_string()));
            }
            let id = parse_id(&args[0]).map_err(|m| (2, m))?;
            let mut loaded = load();
            let note = ops::duplicate(&mut loaded.store, id, time::now_unix()).map_err(fail)?;
            save(&loaded).map_err(fail)?;
            Ok(format!("Copied as note {} \"{}\".", note.id, note.title))
        }
        "export" => {
            if args.len() != 1 {
                return Err((2, "export needs one file name".to_string()));
            }
            let loaded = load();
            std::fs::write(&args[0], ops::export_json(&loaded.store))
                .map_err(|e| fail(format!("could not write {}: {e}", args[0])))?;
            Ok(format!(
                "Exported {} note(s) to {}.",
                loaded.store.notes.len(),
                args[0]
            ))
        }
        "import" => {
            if args.len() != 1 {
                return Err((2, "import needs one file name".to_string()));
            }
            let text = std::fs::read_to_string(&args[0])
                .map_err(|e| fail(format!("could not read {}: {e}", args[0])))?;
            let mut loaded = load();
            let count =
                ops::import_json(&mut loaded.store, &text, time::now_unix()).map_err(fail)?;
            save(&loaded).map_err(fail)?;
            Ok(format!(
                "Imported {count} note(s) from {} (they were given new ids; nothing was overwritten).",
                args[0]
            ))
        }
        "stats" => {
            let loaded = load();
            let s = ops::stats(&loaded.store);
            if json_out {
                let obj = Json::Obj(vec![
                    ("notes".to_string(), Json::Num(s.notes as f64)),
                    ("trash".to_string(), Json::Num(s.trash as f64)),
                    ("tags".to_string(), Json::Num(s.tags as f64)),
                    ("pinned".to_string(), Json::Num(s.pinned as f64)),
                    ("total_words".to_string(), Json::Num(s.total_words as f64)),
                    ("total_chars".to_string(), Json::Num(s.total_chars as f64)),
                ]);
                println!("{}", json::stringify(&obj));
                Ok(String::new())
            } else {
                Ok(format!(
                    "Notes: {}\nIn trash: {}\nTags: {}\nPinned: {}\nTotal words: {}\nTotal characters: {}",
                    s.notes, s.trash, s.tags, s.pinned, s.total_words, s.total_chars
                ))
            }
        }
        other => Err((
            2,
            format!(
                "unknown command \"{other}\".\n\nRun `TermiNote help` for the list of commands."
            ),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn take_value_and_flag() {
        let mut args = vec![
            "T".to_string(),
            "--body".to_string(),
            "hello".to_string(),
            "--yes".to_string(),
        ];
        assert_eq!(take_value(&mut args, "--body"), Some("hello".to_string()));
        assert!(take_flag(&mut args, "--yes"));
        assert!(!take_flag(&mut args, "--yes"));
        assert_eq!(args, vec!["T".to_string()]);
        let mut args = vec!["--body".to_string()];
        assert_eq!(take_value(&mut args, "--body"), None);
    }

    #[test]
    fn unknown_command_is_exit_2_shape() {
        let err = dispatch("frobnicate", vec![], false).unwrap_err();
        assert_eq!(err.0, 2);
    }

    #[test]
    fn parse_id_rejects_words() {
        assert_eq!(parse_id("12"), Ok(12));
        assert!(parse_id("abc").is_err());
    }
}
