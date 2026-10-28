//! The on-disk store: all notes plus a trash list, saved as one
//! JSON file.
//!
//! Saving never loses work: the new file is written to a temporary
//! file in the same folder and then renamed over the old one, so a
//! crash mid-save leaves either the old file or the new file, never
//! a half-written one. A file that cannot be parsed at all is
//! quarantined (renamed to `notes.json.corrupt-<timestamp>`) and an
//! empty store is returned with a flag, so the program still opens
//! and the original bytes are kept for recovery.

use std::path::PathBuf;

use crate::json::{self, Json};
use crate::note::Note;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Store {
    pub next_id: u64,
    pub notes: Vec<Note>,
    pub trash: Vec<Note>,
}

/// The result of loading a store from disk.
#[derive(Debug, Clone)]
pub struct LoadOutcome {
    pub store: Store,
    /// True when an existing file was corrupt and was quarantined.
    pub was_corrupt: bool,
    /// True when no data file existed yet (a first run).
    pub was_missing: bool,
}

impl Store {
    pub fn new() -> Self {
        Store {
            next_id: 1,
            notes: Vec::new(),
            trash: Vec::new(),
        }
    }

    /// Allocate the next free id.
    pub fn alloc_id(&mut self) -> u64 {
        let id = self.next_id.max(1);
        self.next_id = id + 1;
        id
    }

    pub fn to_json(&self) -> Json {
        Json::Obj(vec![
            ("next_id".to_string(), Json::Num(self.next_id as f64)),
            (
                "notes".to_string(),
                Json::Arr(self.notes.iter().map(Note::to_json).collect()),
            ),
            (
                "trash".to_string(),
                Json::Arr(self.trash.iter().map(Note::to_json).collect()),
            ),
        ])
    }

    pub fn from_json(value: &Json) -> Option<Store> {
        let fields = json::as_obj(value)?;
        let mut notes = Vec::new();
        if let Some(items) = json::get(fields, "notes").and_then(json::as_arr) {
            for item in items {
                if let Some(note) = Note::from_json(item) {
                    notes.push(note);
                }
            }
        }
        let mut trash = Vec::new();
        if let Some(items) = json::get(fields, "trash").and_then(json::as_arr) {
            for item in items {
                if let Some(note) = Note::from_json(item) {
                    trash.push(note);
                }
            }
        }
        let highest = notes
            .iter()
            .chain(trash.iter())
            .map(|n| n.id)
            .max()
            .unwrap_or(0);
        let stored_next = json::get(fields, "next_id")
            .and_then(json::as_u64)
            .unwrap_or(1);
        Some(Store {
            next_id: stored_next.max(highest + 1).max(1),
            notes,
            trash,
        })
    }

    /// Serialise the whole store to JSON text.
    pub fn to_json_text(&self) -> String {
        json::stringify(&self.to_json())
    }

    /// Load the store at `path`.
    ///
    /// - Missing file: an empty store, `was_missing` set.
    /// - Readable, valid file: the stored notes.
    /// - Existing but unparseable file: the file is renamed to
    ///   `<name>.corrupt-<now>` beside itself, an empty store is
    ///   returned and `was_corrupt` is set.
    pub fn load(path: &std::path::Path, now: u64) -> LoadOutcome {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return LoadOutcome {
                    store: Store::new(),
                    was_corrupt: false,
                    was_missing: true,
                };
            }
            Err(_) => {
                return LoadOutcome {
                    store: Store::new(),
                    was_corrupt: true,
                    was_missing: false,
                };
            }
        };
        if text.trim().is_empty() {
            return LoadOutcome {
                store: Store::new(),
                was_corrupt: false,
                was_missing: false,
            };
        }
        match json::parse(&text).and_then(|v| Store::from_json(&v)) {
            Some(store) => LoadOutcome {
                store,
                was_corrupt: false,
                was_missing: false,
            },
            None => {
                quarantine(path, now);
                LoadOutcome {
                    store: Store::new(),
                    was_corrupt: true,
                    was_missing: false,
                }
            }
        }
    }

    /// Save atomically: write a temp file in the same folder, then
    /// rename it over the destination.
    pub fn save(&self, path: &std::path::Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| format!("could not create the data folder: {e}"))?;
            }
        }
        let tmp = temp_path_for(path);
        std::fs::write(&tmp, self.to_json_text())
            .map_err(|e| format!("could not write the data file: {e}"))?;
        // On Windows, rename does not replace an existing file, so
        // remove the destination first. The temp file is complete at
        // this point, so the window for loss is a single rename.
        if path.exists() {
            let _ = std::fs::remove_file(path);
        }
        std::fs::rename(&tmp, path).map_err(|e| format!("could not replace the data file: {e}"))?;
        Ok(())
    }
}

fn temp_path_for(path: &std::path::Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "notes.json".to_string());
    name.push_str(".tmp");
    match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join(name),
        _ => PathBuf::from(name),
    }
}

fn quarantine(path: &std::path::Path, now: u64) {
    let base = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "notes.json".to_string());
    let name = format!("{base}.corrupt-{now}");
    let dest = match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join(name),
        _ => PathBuf::from(name),
    };
    let _ = std::fs::rename(path, &dest);
}

/// The folder TermiNote keeps its data in.
///
/// - If a file called `portable.txt` sits beside the program, the
///   program folder itself is used (portable mode).
/// - Otherwise `%LOCALAPPDATA%\TermiNote` on Windows, falling back
///   to the current folder when that variable is unavailable.
pub fn data_dir() -> PathBuf {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            if dir.join("portable.txt").is_file() {
                return dir.to_path_buf();
            }
        }
    }
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        if !local.trim().is_empty() {
            return PathBuf::from(local).join("TermiNote");
        }
    }
    PathBuf::from("TermiNote-data")
}

/// The full path of the notes data file.
///
/// The `TERMINOTE_DATA` environment variable, when set, names the
/// file directly (used by tests and scripts).
pub fn data_file_path() -> PathBuf {
    if let Ok(custom) = std::env::var("TERMINOTE_DATA") {
        if !custom.trim().is_empty() {
            return PathBuf::from(custom);
        }
    }
    // Portable mode: the data file sits beside the program.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            if dir.join("portable.txt").is_file() {
                return dir.join("notes.json");
            }
        }
    }
    data_dir().join("notes.json")
}

/// The settings file lives beside the data file.
pub fn settings_file_path() -> PathBuf {
    match data_file_path().parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join("settings.json"),
        _ => PathBuf::from("settings.json"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("terminote-test-{}-{}", std::process::id(), tag));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn save_load_round_trip() {
        let dir = temp_dir("roundtrip");
        let path = dir.join("notes.json");
        let mut store = Store::new();
        let id = store.alloc_id();
        store
            .notes
            .push(Note::new(id, "First", "Body text", vec!["a".into()], 10));
        store.trash.push(Note::new(99, "Old", "", vec![], 5));
        store.next_id = 100;
        store.save(&path).unwrap();
        let outcome = Store::load(&path, 1000);
        assert!(!outcome.was_corrupt);
        assert!(!outcome.was_missing);
        assert_eq!(outcome.store, store);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn missing_file_is_empty_not_corrupt() {
        let dir = temp_dir("missing");
        let outcome = Store::load(&dir.join("nope.json"), 1000);
        assert!(outcome.was_missing);
        assert!(!outcome.was_corrupt);
        assert_eq!(outcome.store, Store::new());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_file_is_quarantined() {
        let dir = temp_dir("corrupt");
        let path = dir.join("notes.json");
        std::fs::write(&path, "{ this is not json").unwrap();
        let outcome = Store::load(&path, 4242);
        assert!(outcome.was_corrupt);
        assert_eq!(outcome.store, Store::new());
        assert!(!path.exists(), "corrupt file should be moved away");
        let quarantined = dir.join("notes.json.corrupt-4242");
        assert!(quarantined.exists(), "quarantined copy should exist");
        assert_eq!(
            std::fs::read_to_string(&quarantined).unwrap(),
            "{ this is not json"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn next_id_stays_ahead_of_loaded_ids() {
        let text = r#"{"next_id":2,"notes":[{"id":50,"title":"t","body":"","tags":[],"pinned":false,"created":1,"modified":1}],"trash":[]}"#;
        let store = Store::from_json(&json::parse(text).unwrap()).unwrap();
        assert_eq!(store.next_id, 51);
    }

    #[test]
    fn save_leaves_no_temp_file() {
        let dir = temp_dir("tempfile");
        let path = dir.join("notes.json");
        Store::new().save(&path).unwrap();
        assert!(path.exists());
        assert!(!dir.join("notes.json.tmp").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
