//! TermiNote's platform-independent note model and file store.
//!
//! The Markdown format preserves the previous app's files: every note
//! stays a readable `<id>-<slug>.md` file with the same front matter,
//! and trashed notes stay under `notes/trash`.

use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    io,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
#[cfg(not(target_arch = "wasm32"))]
use fs2::FileExt;
#[cfg(not(target_arch = "wasm32"))]
use std::fs::{File, OpenOptions};

pub mod markdown;
pub mod cli;

const LEGACY_FILE: &str = "notes.json";

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct Note {
    pub id: u64,
    pub title: String,
    pub body: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub created: i64,
    #[serde(default)]
    pub modified: i64,
    #[serde(default)]
    pub order: i64,
    #[serde(skip)]
    file_name: Option<String>,
    #[serde(skip)]
    file_in_trash: bool,
}

impl Note {
    pub fn word_count(&self) -> usize {
        format!("{} {}", self.title, self.body)
            .split_whitespace()
            .count()
    }

    pub fn char_count(&self) -> usize {
        self.title.encode_utf16().count() + self.body.encode_utf16().count()
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub enum SortMode {
    #[default]
    #[serde(rename = "modifiedDesc")]
    ModifiedDesc,
    #[serde(rename = "titleAsc")]
    TitleAsc,
    #[serde(rename = "createdDesc")]
    CreatedDesc,
    #[serde(rename = "manual")]
    Manual,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct AppSettings {
    pub sort: SortMode,
    #[serde(rename = "textSize")]
    pub text_size: f64,
    pub minimize_to_tray: bool,
    pub close_action: String,
    pub auto_update: bool,
    pub window_placement: Option<WindowPlacement>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            sort: SortMode::ModifiedDesc,
            text_size: 16.0,
            minimize_to_tray: true,
            close_action: "ask".into(),
            auto_update: true,
            window_placement: None,
        }
    }
}

impl AppSettings {
    pub fn load(data_dir: &Path) -> Self {
        fs::read(data_dir.join("settings.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, data_dir: &Path) -> io::Result<()> {
        let text = serde_json::to_string_pretty(self)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        atomic_write(&data_dir.join("settings.json"), &text)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WindowPlacement {
    pub left: i32,
    pub top: i32,
    pub width: u32,
    pub height: u32,
    pub maximized: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ExportData {
    #[serde(default, rename = "next_id")]
    pub next_id: u64,
    #[serde(default)]
    pub notes: Vec<Note>,
    #[serde(default)]
    pub trash: Vec<Note>,
    #[serde(default)]
    pub order: Vec<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ImportResult {
    pub imported: usize,
    pub skipped: usize,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct StoreStats {
    pub notes: usize,
    pub trash: usize,
    pub tags: usize,
    pub pinned: usize,
    pub words: usize,
    pub characters: usize,
}

#[derive(Debug)]
pub struct NoteStore {
    data_dir: PathBuf,
    pub notes: Vec<Note>,
    pub trash: Vec<Note>,
    next_id: u64,
}

impl NoteStore {
    pub fn open(data_dir: impl Into<PathBuf>) -> io::Result<Self> {
        let data_dir = data_dir.into();
        fs::create_dir_all(&data_dir)?;
        if let Some(store) = Self::migrate_legacy(&data_dir)? {
            return Ok(store);
        }

        let notes_dir = notes_dir(&data_dir);
        let trash_dir = trash_dir(&data_dir);
        let mut notes = scan_folder(&notes_dir, false)?;
        let mut trash = scan_folder(&trash_dir, true)?;
        let live_ids: Vec<u64> = notes.iter().map(|note| note.id).collect();
        let trash_ids: Vec<u64> = trash.iter().map(|note| note.id).collect();
        repair_ids(&mut notes, &mut trash);
        for (index, note) in notes.iter_mut().enumerate() {
            if live_ids.get(index) != Some(&note.id) {
                write_note_to(&data_dir, note)?;
            }
        }
        for (index, note) in trash.iter_mut().enumerate() {
            if trash_ids.get(index) != Some(&note.id) {
                write_note_to(&data_dir, note)?;
            }
        }

        Ok(Self {
            data_dir,
            notes,
            trash,
        next_id: 1,
        }
        .with_next_id())
    }

    fn with_next_id(mut self) -> Self {
        let next_available = self
            .notes
            .iter()
            .chain(&self.trash)
            .map(|note| note.id)
            .max()
            .unwrap_or(0)
            .saturating_add(1)
            .max(1);
        self.next_id = self.next_id.max(next_available).max(1);
        self
    }

    fn migrate_legacy(data_dir: &Path) -> io::Result<Option<Self>> {
        let legacy = data_dir.join(LEGACY_FILE);
        if !legacy.is_file() || folder_has_markdown(&notes_dir(data_dir))? {
            return Ok(None);
        }

        let bytes = fs::read(&legacy)?;
        let mut export: ExportData = match serde_json::from_slice(&bytes) {
            Ok(value) => value,
            Err(_) => {
                let stamp = now_seconds();
                let mut quarantine = legacy.clone();
                quarantine.set_file_name(format!("notes.json.corrupt-{stamp}"));
                let _ = fs::rename(&legacy, quarantine);
                return Ok(Some(Self {
                    data_dir: data_dir.to_path_buf(),
                    notes: Vec::new(),
                    trash: Vec::new(),
                    next_id: 1,
                }));
            }
        };

        repair_ids(&mut export.notes, &mut export.trash);
        let mut store = Self {
            data_dir: data_dir.to_path_buf(),
            notes: export.notes,
            trash: export.trash,
            next_id: export.next_id.max(1),
        }
        .with_next_id();
        for note in store.notes.iter_mut() {
            note.file_in_trash = false;
            write_note_to(&store.data_dir, note)?;
        }
        for note in store.trash.iter_mut() {
            note.file_in_trash = true;
            write_note_to(&store.data_dir, note)?;
        }
        let mut backup = data_dir.join("notes.json.migrated.bak");
        let mut suffix = 2;
        while backup.exists() {
            backup = data_dir.join(format!("notes.json.migrated.bak{suffix}"));
            suffix += 1;
        }
        let _ = fs::rename(&legacy, backup);
        Ok(Some(store))
    }

    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }

    pub fn notes_dir(&self) -> PathBuf {
        notes_dir(&self.data_dir)
    }

    pub fn get(&self, id: u64) -> Option<&Note> {
        self.notes.iter().find(|note| note.id == id)
    }

    pub fn get_trashed(&self, id: u64) -> Option<&Note> {
        self.trash.iter().find(|note| note.id == id)
    }

    pub fn list(
        &self,
        search: &str,
        tag: Option<&str>,
        untagged: bool,
        sort: SortMode,
    ) -> Vec<Note> {
        let needle = search.trim().to_lowercase();
        let mut values: Vec<Note> = self
            .notes
            .iter()
            .filter(|note| {
                let matches_search = needle.is_empty()
                    || note.title.to_lowercase().contains(&needle)
                    || note.body.to_lowercase().contains(&needle)
                    || note.tags.iter().any(|value| value.contains(&needle));
                let matches_tag = match tag {
                    Some(tag) => note.tags.iter().any(|value| value == tag),
                    None if untagged => note.tags.is_empty(),
                    None => true,
                };
                matches_search && matches_tag
            })
            .cloned()
            .collect();

        values.sort_by(|a, b| {
            let pin = b.pinned.cmp(&a.pinned);
            if pin != std::cmp::Ordering::Equal {
                return pin;
            }
            match sort {
                SortMode::ModifiedDesc => b.modified.cmp(&a.modified).then(a.id.cmp(&b.id)),
                SortMode::TitleAsc => a.title.to_lowercase().cmp(&b.title.to_lowercase()),
                SortMode::CreatedDesc => b.created.cmp(&a.created).then(a.id.cmp(&b.id)),
                SortMode::Manual => a.order.cmp(&b.order).then(a.id.cmp(&b.id)),
            }
        });
        values
    }

    pub fn all_tags(&self) -> BTreeMap<String, usize> {
        let mut counts = BTreeMap::new();
        for note in &self.notes {
            for tag in &note.tags {
                *counts.entry(tag.clone()).or_insert(0) += 1;
            }
        }
        counts
    }

    pub fn add(&mut self, title: &str, body: &str, tags: &[String]) -> io::Result<Note> {
        let now = now_seconds();
        let note = Note {
            id: self.allocate_id(),
            title: if title.trim().is_empty() {
                "Untitled note".into()
            } else {
                title.into()
            },
            body: body.into(),
            tags: normalize_tags(tags.iter().map(String::as_str)),
            pinned: false,
            created: now,
            modified: now,
            order: self.notes.len() as i64,
            file_name: None,
            file_in_trash: false,
        };
        let mut note = note;
        self.write_note(&mut note)?;
        self.notes.push(note.clone());
        Ok(note)
    }

    pub fn update(
        &mut self,
        id: u64,
        title: &str,
        body: &str,
        tags: &[String],
    ) -> io::Result<Option<Note>> {
        let Some(index) = self.notes.iter().position(|note| note.id == id) else {
            return Ok(None);
        };
        let mut note = self.notes[index].clone();
        note.title = if title.trim().is_empty() {
            "Untitled note".into()
        } else {
            title.into()
        };
        note.body = body.into();
        note.tags = normalize_tags(tags.iter().map(String::as_str));
        note.modified = now_seconds();
        self.write_note(&mut note)?;
        self.notes[index] = note.clone();
        Ok(Some(note))
    }

    pub fn set_pinned(&mut self, id: u64, pinned: bool) -> io::Result<bool> {
        let Some(index) = self.notes.iter().position(|note| note.id == id) else {
            return Ok(false);
        };
        let mut note = self.notes[index].clone();
        note.pinned = pinned;
        note.modified = now_seconds();
        self.write_note(&mut note)?;
        self.notes[index] = note;
        Ok(true)
    }

    pub fn move_to_trash(&mut self, id: u64) -> io::Result<bool> {
        let Some(index) = self.notes.iter().position(|note| note.id == id) else {
            return Ok(false);
        };
        let mut note = self.notes[index].clone();
        let old_path = self.path_for(&note);
        note.modified = now_seconds();
        note.file_in_trash = true;
        note.file_name = None;
        self.write_note(&mut note)?;
        let new_path = self.path_for(&note);
        if old_path != new_path {
            if let Err(error) = remove_if_exists(&old_path) {
                let _ = remove_if_exists(&new_path);
                return Err(error);
            }
        }
        self.notes.remove(index);
        self.trash.push(note);
        self.sync_order();
        Ok(true)
    }

    pub fn restore(&mut self, id: u64) -> io::Result<bool> {
        let Some(index) = self.trash.iter().position(|note| note.id == id) else {
            return Ok(false);
        };
        let mut note = self.trash[index].clone();
        let old_path = self.path_for(&note);
        note.file_in_trash = false;
        note.file_name = None;
        note.modified = now_seconds();
        note.order = self.notes.len() as i64;
        self.write_note(&mut note)?;
        let new_path = self.path_for(&note);
        if old_path != new_path {
            if let Err(error) = remove_if_exists(&old_path) {
                let _ = remove_if_exists(&new_path);
                return Err(error);
            }
        }
        self.trash.remove(index);
        self.notes.push(note);
        self.sync_order();
        Ok(true)
    }

    pub fn delete_forever(&mut self, id: u64) -> io::Result<bool> {
        let Some(index) = self.trash.iter().position(|note| note.id == id) else {
            return Ok(false);
        };
        let note = &self.trash[index];
        remove_if_exists(&self.path_for(note))?;
        self.trash.remove(index);
        Ok(true)
    }

    pub fn empty_trash(&mut self) -> io::Result<usize> {
        let mut deleted = 0;
        while !self.trash.is_empty() {
            match remove_if_exists(&self.path_for(&self.trash[0])) {
                Ok(()) => {
                    self.trash.remove(0);
                    deleted += 1;
                }
                Err(error) => return Err(error),
            }
        }
        Ok(deleted)
    }

    pub fn delete_all(&mut self) -> io::Result<usize> {
        let ids: Vec<u64> = self.notes.iter().map(|note| note.id).collect();
        for id in &ids {
            self.move_to_trash(*id)?;
        }
        Ok(ids.len())
    }

    pub fn add_tag(&mut self, id: u64, raw_tag: &str) -> io::Result<bool> {
        let tag = normalize_tag(raw_tag);
        let Some(index) = self.notes.iter().position(|note| note.id == id) else {
            return Ok(false);
        };
        if tag.is_empty() {
            return Ok(false);
        }
        if self.notes[index].tags.contains(&tag) {
            return Ok(true);
        }
        let mut note = self.notes[index].clone();
        note.tags.push(tag);
        note.tags = normalize_tags(note.tags.iter().map(String::as_str));
        note.modified = now_seconds();
        self.write_note(&mut note)?;
        self.notes[index] = note;
        Ok(true)
    }

    pub fn remove_tag(&mut self, id: u64, raw_tag: &str) -> io::Result<bool> {
        let tag = normalize_tag(raw_tag);
        let Some(index) = self.notes.iter().position(|note| note.id == id) else {
            return Ok(false);
        };
        if !self.notes[index].tags.contains(&tag) {
            return Ok(false);
        }
        let mut note = self.notes[index].clone();
        note.tags.retain(|value| value != &tag);
        note.modified = now_seconds();
        self.write_note(&mut note)?;
        self.notes[index] = note;
        Ok(true)
    }

    pub fn duplicate(&mut self, id: u64) -> io::Result<Option<Note>> {
        let Some(source) = self.get(id).cloned() else {
            return Ok(None);
        };
        self.add(
            &format!("{} (copy)", source.title),
            &source.body,
            &source.tags,
        )
        .map(Some)
    }

    pub fn import_file_text(&mut self, text: &str, file_name: &str) -> io::Result<Note> {
        let decoded = decode_note_file(text, file_name, now_seconds());
        let now = now_seconds();
        let mut note = Note {
            id: self.allocate_id(),
            title: if decoded.title.trim().is_empty() {
                "Untitled note".into()
            } else {
                decoded.title
            },
            body: decoded.body,
            tags: decoded.tags,
            pinned: decoded.pinned,
            created: if decoded.created == 0 {
                now
            } else {
                decoded.created
            },
            modified: now,
            order: self.notes.len() as i64,
            file_name: None,
            file_in_trash: false,
        };
        self.write_note(&mut note)?;
        self.notes.push(note.clone());
        Ok(note)
    }

    pub fn stats(&self) -> StoreStats {
        StoreStats {
            notes: self.notes.len(),
            trash: self.trash.len(),
            tags: self.all_tags().len(),
            pinned: self.notes.iter().filter(|note| note.pinned).count(),
            words: self.notes.iter().map(Note::word_count).sum(),
            characters: self.notes.iter().map(Note::char_count).sum(),
        }
    }

    pub fn reorder(&mut self, ids: &[u64]) -> io::Result<()> {
        let live: HashSet<u64> = self.notes.iter().map(|note| note.id).collect();
        let mut order = Vec::with_capacity(self.notes.len());
        let mut seen = HashSet::new();
        for id in ids {
            if live.contains(id) && seen.insert(*id) {
                order.push(*id);
            }
        }
        for note in &self.notes {
            if seen.insert(note.id) {
                order.push(note.id);
            }
        }
        let mut updated = self.notes.clone();
        for (index, id) in order.iter().enumerate() {
            if let Some(note) = updated.iter_mut().find(|note| note.id == *id) {
                note.order = index as i64;
            }
        }
        for note in &mut updated {
            self.write_note(note)?;
        }
        self.notes = updated;
        Ok(())
    }

    pub fn rename_tag(&mut self, old: &str, new: &str) -> io::Result<usize> {
        let old = normalize_tag(old);
        let new = normalize_tag(new);
        if old.is_empty() || new.is_empty() || old == new {
            return Ok(0);
        }
        let mut changed = 0;
        for index in 0..self.notes.len() {
            if !self.notes[index].tags.contains(&old) {
                continue;
            }
            let mut note = self.notes[index].clone();
            for tag in &mut note.tags {
                if *tag == old {
                    *tag = new.clone();
                }
            }
            note.tags = normalize_tags(note.tags.iter().map(String::as_str));
            note.modified = now_seconds();
            self.write_note(&mut note)?;
            self.notes[index] = note;
            changed += 1;
        }
        Ok(changed)
    }

    pub fn delete_tag(&mut self, tag: &str) -> io::Result<usize> {
        let tag = normalize_tag(tag);
        let mut changed = 0;
        for index in 0..self.notes.len() {
            if !self.notes[index].tags.iter().any(|value| value == &tag) {
                continue;
            }
            let mut note = self.notes[index].clone();
            note.tags.retain(|value| value != &tag);
            note.modified = now_seconds();
            self.write_note(&mut note)?;
            self.notes[index] = note;
            changed += 1;
        }
        Ok(changed)
    }

    pub fn export_json(&self) -> Result<String, serde_json::Error> {
        fn exported(note: &Note) -> serde_json::Value {
            serde_json::json!({
                "id": note.id,
                "title": note.title,
                "body": note.body,
                "tags": note.tags,
                "pinned": note.pinned,
                "created": note.created,
                "modified": note.modified,
            })
        }
        serde_json::to_string_pretty(&serde_json::json!({
            "next_id": self.next_id,
            "notes": self.notes.iter().map(exported).collect::<Vec<_>>(),
            "trash": self.trash.iter().map(exported).collect::<Vec<_>>(),
            "order": self.notes.iter().map(|note| note.id).collect::<Vec<_>>(),
        }))
    }

    pub fn import_json(&mut self, content: &str) -> io::Result<ImportResult> {
        let incoming: ExportData = serde_json::from_str(content)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let mut known: HashSet<(String, String)> = self
            .notes
            .iter()
            .map(|note| (note.title.clone(), note.body.clone()))
            .collect();
        let mut result = ImportResult {
            imported: 0,
            skipped: 0,
        };
        for note in incoming.notes {
            if known.contains(&(note.title.clone(), note.body.clone())) {
                result.skipped += 1;
                continue;
            }
            let mut imported = Note {
                id: self.allocate_id(),
                title: if note.title.trim().is_empty() {
                    "Untitled note".into()
                } else {
                    note.title.clone()
                },
                body: note.body.clone(),
                tags: normalize_tags(note.tags.iter().map(String::as_str)),
                pinned: note.pinned,
                created: note.created,
                modified: note.modified,
                order: self.notes.len() as i64,
                file_name: None,
                file_in_trash: false,
            };
            self.write_note(&mut imported)?;
            self.notes.push(imported);
            known.insert((note.title.clone(), note.body.clone()));
            result.imported += 1;
        }
        Ok(result)
    }

    pub fn write_recovery_draft(
        &self,
        note: &Note,
        title: &str,
        body: &str,
        tags: &[String],
    ) -> io::Result<()> {
        let mut draft = note.clone();
        draft.title = title.into();
        draft.body = body.into();
        draft.tags = normalize_tags(tags.iter().map(String::as_str));
        draft.modified = now_seconds().max(note.modified.saturating_add(1));
        let path = self.data_dir.join("recovery").join(format!("recovery-{}.md", note.id));
        atomic_write(&path, &encode_note_file(&draft))
    }

    pub fn remove_recovery_draft(&self, id: u64) -> io::Result<()> {
        remove_if_exists(&self.data_dir.join("recovery").join(format!("recovery-{id}.md")))
    }

    pub fn recover_draft(&mut self, id: u64) -> io::Result<Option<Note>> {
        let Some(draft) = load_recovery_drafts(&self.data_dir)?
            .into_iter()
            .find(|draft| draft.id == id)
        else {
            return Ok(None);
        };
        let recovered = if self.get(id).is_some() {
            self.update(id, &draft.title, &draft.body, &draft.tags)?
        } else {
            Some(self.add(&draft.title, &draft.body, &draft.tags)?)
        };
        self.remove_recovery_draft(id)?;
        Ok(recovered)
    }

    fn allocate_id(&mut self) -> u64 {
        let id = self.next_id.max(1);
        self.next_id = id.saturating_add(1);
        id
    }

    fn sync_order(&mut self) {
        for (index, note) in self.notes.iter_mut().enumerate() {
            note.order = index as i64;
        }
    }

    fn path_for(&self, note: &Note) -> PathBuf {
        let folder = if note.file_in_trash {
            trash_dir(&self.data_dir)
        } else {
            notes_dir(&self.data_dir)
        };
        folder.join(note_file_name(note))
    }

    fn write_note(&self, note: &mut Note) -> io::Result<()> {
        write_note_to(&self.data_dir, note)
    }
}

pub fn resolve_data_dir(
    environment: &std::collections::HashMap<String, String>,
    executable: &Path,
) -> PathBuf {
    if let Some(override_path) = environment.get("TERMINOTE_DATA").filter(|v| !v.is_empty()) {
        let path = PathBuf::from(override_path);
        if path.extension().is_some_and(|ext| ext.eq_ignore_ascii_case("json")) {
            return path.parent().unwrap_or(Path::new(".")).to_path_buf();
        }
        return path;
    }

    let exe_dir = executable.parent().unwrap_or(Path::new("."));
    if exe_dir.join("portable.txt").is_file() {
        return exe_dir.to_path_buf();
    }
    if let Some(local_app_data) = environment.get("LOCALAPPDATA").filter(|v| !v.is_empty()) {
        return PathBuf::from(local_app_data).join("TermiNote");
    }
    std::env::temp_dir().join("terminote")
}

pub fn notes_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("notes")
}

pub fn trash_dir(data_dir: &Path) -> PathBuf {
    notes_dir(data_dir).join("trash")
}

pub fn recovery_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("recovery")
}

pub fn load_recovery_drafts(data_dir: &Path) -> io::Result<Vec<Note>> {
    let folder = recovery_dir(data_dir);
    let mut drafts = Vec::new();
    if !folder.is_dir() {
        return Ok(drafts);
    }
    for entry in fs::read_dir(folder)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(id) = name
            .strip_prefix("recovery-")
            .and_then(|name| name.strip_suffix(".md"))
            .and_then(|id| id.parse::<u64>().ok())
        else {
            continue;
        };
        let text = fs::read_to_string(entry.path())?;
        let mut note = decode_note_file(&text, &format!("{id}-recovery.md"), 0);
        note.id = id;
        note.file_name = None;
        note.file_in_trash = false;
        drafts.push(note);
    }
    drafts.sort_by_key(|note| note.modified);
    drafts.reverse();
    Ok(drafts)
}

#[cfg(not(target_arch = "wasm32"))]
pub fn acquire_data_lock(data_dir: &Path) -> io::Result<File> {
    fs::create_dir_all(data_dir)?;
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(data_dir.join(".terminote.lock"))?;
    file.try_lock_exclusive().map_err(|error| {
        if error.kind() == io::ErrorKind::WouldBlock {
            io::Error::new(
                io::ErrorKind::WouldBlock,
                "TermiNote is already using this notebook. Close it before running CLI commands.",
            )
        } else {
            error
        }
    })?;
    Ok(file)
}

pub fn backup_data(data_dir: &Path, destination: &Path) -> io::Result<usize> {
    if destination == data_dir || destination.starts_with(data_dir) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Backup folder cannot be inside the live notebook.",
        ));
    }
    if destination.exists() && fs::read_dir(destination)?.next().is_some() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "Backup folder is not empty.",
        ));
    }
    fs::create_dir_all(destination)?;
    let mut copied = 0;
    for folder in ["notes", "recovery"] {
        let source = data_dir.join(folder);
        if source.is_dir() {
            copied += copy_tree(&source, &destination.join(folder))?;
        }
    }
    for name in ["settings.json", LEGACY_FILE] {
        let source = data_dir.join(name);
        if source.is_file() {
            fs::copy(source, destination.join(name))?;
            copied += 1;
        }
    }
    Ok(copied)
}

pub fn restore_backup(data_dir: &Path, backup: &Path) -> io::Result<()> {
    let source_notes = backup.join("notes");
    if !source_notes.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Backup does not contain a notes folder.",
        ));
    }
    fs::create_dir_all(data_dir)?;
    let unique = format!(
        "{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    );
    let stage = data_dir.join(format!(".restore-stage-{unique}"));
    let previous_notes = data_dir.join(format!(".restore-old-{unique}"));
    let safety = data_dir.join("backups").join(format!("pre-restore-{unique}"));
    fs::create_dir_all(&stage)?;
    copy_tree(&source_notes, &stage.join("notes"))?;
    let source_settings = backup.join("settings.json");
    if source_settings.is_file() {
        fs::copy(&source_settings, stage.join("settings.json"))?;
    }
    if data_dir.join("notes").is_dir() || data_dir.join("settings.json").is_file() {
        fs::create_dir_all(&safety)?;
        if data_dir.join("notes").is_dir() {
            copy_tree(&data_dir.join("notes"), &safety.join("notes"))?;
        }
        if data_dir.join("settings.json").is_file() {
            fs::copy(data_dir.join("settings.json"), safety.join("settings.json"))?;
        }
    }

    let live_notes = data_dir.join("notes");
    let had_notes = live_notes.exists();
    if had_notes {
        fs::rename(&live_notes, &previous_notes)?;
    }
    if let Err(error) = fs::rename(stage.join("notes"), &live_notes) {
        if had_notes {
            let _ = fs::rename(&previous_notes, &live_notes);
        }
        let _ = fs::remove_dir_all(&stage);
        return Err(error);
    }

    if source_settings.is_file() {
        let result = fs::read_to_string(stage.join("settings.json"))
            .and_then(|text| atomic_write(&data_dir.join("settings.json"), &text));
        if let Err(error) = result {
            let _ = fs::remove_dir_all(&live_notes);
            if had_notes {
                let _ = fs::rename(&previous_notes, &live_notes);
            }
            if safety.join("settings.json").is_file() {
                let _ = fs::copy(safety.join("settings.json"), data_dir.join("settings.json"));
            }
            let _ = fs::remove_dir_all(&stage);
            return Err(error);
        }
    }
    if had_notes {
        fs::remove_dir_all(previous_notes)?;
    }
    let _ = fs::remove_dir_all(stage);
    Ok(())
}

fn copy_tree(source: &Path, destination: &Path) -> io::Result<usize> {
    fs::create_dir_all(destination)?;
    let mut count = 0;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        let target = destination.join(entry.file_name());
        if kind.is_dir() {
            count += copy_tree(&entry.path(), &target)?;
        } else if kind.is_file() {
            fs::copy(entry.path(), target)?;
            count += 1;
        } else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Backup contains an unsupported filesystem entry.",
            ));
        }
    }
    Ok(count)
}

pub fn normalize_tag(value: &str) -> String {
    value.trim().to_lowercase().chars().take(40).collect::<String>().trim().to_string()
}

pub fn normalize_tags<'a>(values: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    let mut seen = HashSet::new();
    values
        .into_iter()
        .map(normalize_tag)
        .filter(|tag| !tag.is_empty() && seen.insert(tag.clone()))
        .collect()
}

pub fn parse_tags(value: &str) -> Vec<String> {
    normalize_tags(value.split(','))
}

pub fn tag_suggestions(value: &str, existing: impl IntoIterator<Item = String>) -> Vec<String> {
    let (before, query) = value.rsplit_once(',').unwrap_or(("", value));
    let query = normalize_tag(query);
    if query.is_empty() {
        return Vec::new();
    }
    let used: HashSet<String> = parse_tags(before).into_iter().collect();
    let mut seen = HashSet::new();
    let mut suggestions: Vec<String> = existing
        .into_iter()
        .map(|tag| normalize_tag(&tag))
        .filter(|tag| {
            !tag.is_empty()
                && seen.insert(tag.clone())
                && tag.starts_with(&query)
                && !used.contains(tag)
        })
        .collect();
    suggestions.sort();
    suggestions
}

pub fn note_slug(title: &str) -> String {
    let mut out = String::new();
    let mut separator = false;
    for ch in title.to_lowercase().chars() {
        if ch.is_ascii_alphanumeric() {
            if separator && !out.is_empty() {
                out.push('-');
            }
            out.push(ch);
            separator = false;
        } else {
            separator = true;
        }
        if out.len() >= 40 {
            break;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    if out.is_empty() { "note".into() } else { out }
}

pub fn note_file_name(note: &Note) -> String {
    format!("{}-{}.md", note.id, note_slug(&note.title))
}

pub fn encode_note_file(note: &Note) -> String {
    let title = quote_title(&note.title.replace(['\r', '\n'], " "));
    let tags = note.tags.iter().map(|tag| tag.replace(['[', ']', ','], "")).collect::<Vec<_>>().join(", ");
    format!(
        "---\nid: {}\ntitle: {}\ntags: [{}]\npinned: {}\ncreated: {}\nmodified: {}\norder: {}\n---\n\n{}",
        note.id, title, tags, note.pinned, note.created, note.modified, note.order, note.body
    )
}

pub fn decode_note_file(text: &str, file_name: &str, file_modified_seconds: i64) -> Note {
    let fallback = || Note {
        id: id_from_file_name(file_name),
        title: text.lines().find(|line| !line.trim().is_empty()).unwrap_or("Untitled note").trim().into(),
        body: text.into(),
        tags: Vec::new(),
        pinned: false,
        created: file_modified_seconds,
        modified: file_modified_seconds,
        order: 0,
        file_name: Some(file_name.into()),
        file_in_trash: false,
    };
    let lines: Vec<&str> = text.split('\n').collect();
    if lines.first().map(|line| line.trim()) != Some("---") {
        return fallback();
    }
    let Some(close) = lines.iter().enumerate().skip(1).find_map(|(index, line)| {
        if line.trim() == "---" { Some(index) } else { None }
    }) else {
        return fallback();
    };
    let mut id = None;
    let mut title = None;
    let mut tags = None;
    let mut pinned = None;
    let mut created = None;
    let mut modified = None;
    let mut order = None;
    let mut recognized = false;
    for line in &lines[1..close] {
        let Some((key, raw)) = line.trim_end().split_once(':') else { continue };
        let value = raw.trim();
        match key.trim() {
            "id" => id = value.parse().ok(),
            "title" => {
                title = Some(unquote_title(value));
                recognized = true;
            }
            "tags" => {
                let inner = value.strip_prefix('[').and_then(|v| v.strip_suffix(']')).unwrap_or(value);
                tags = Some(parse_tags(inner));
                recognized = true;
            }
            "pinned" => {
                pinned = Some(value == "true");
                recognized = true;
            }
            "created" => created = value.parse().ok(),
            "modified" => modified = value.parse().ok(),
            "order" => order = value.parse().ok(),
            _ => {}
        }
    }
    if !recognized {
        return fallback();
    }
    let mut body_start = close + 1;
    if lines.get(body_start).is_some_and(|line| line.trim().is_empty()) {
        body_start += 1;
    }
    Note {
        id: id.unwrap_or_else(|| id_from_file_name(file_name)),
        title: title.unwrap_or_else(|| title_from_file_name(file_name)),
        body: lines[body_start..].join("\n"),
        tags: tags.unwrap_or_default(),
        pinned: pinned.unwrap_or(false),
        created: created.unwrap_or(file_modified_seconds),
        modified: modified.unwrap_or(file_modified_seconds),
        order: order.unwrap_or(0),
        file_name: Some(file_name.into()),
        file_in_trash: false,
    }
}

fn quote_title(value: &str) -> String {
    let wrapped = value.len() >= 2 && value.starts_with('"') && value.ends_with('"');
    if !value.starts_with(' ') && !value.ends_with(' ') && !wrapped {
        return value.into();
    }
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn unquote_title(value: &str) -> String {
    if value.len() < 2 || !value.starts_with('"') || !value.ends_with('"') {
        return value.into();
    }
    let mut out = String::new();
    let mut chars = value[1..value.len() - 1].chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\\' && chars.peek().is_some_and(|next| *next == '\\' || *next == '"') {
            out.push(chars.next().unwrap_or(ch));
        } else {
            out.push(ch);
        }
    }
    out
}

fn id_from_file_name(file_name: &str) -> u64 {
    file_name.split_once('-').and_then(|(id, _)| id.parse().ok()).unwrap_or(0)
}

fn title_from_file_name(file_name: &str) -> String {
    let stem = Path::new(file_name).file_stem().unwrap_or_default().to_string_lossy();
    let title = stem.split_once('-').map(|(_, title)| title).unwrap_or(&stem);
    let title = title.replace('-', " ");
    if title.is_empty() { "Untitled note".into() } else { title }
}

fn scan_folder(dir: &Path, in_trash: bool) -> io::Result<Vec<Note>> {
    let mut paths = Vec::new();
    match fs::read_dir(dir) {
        Ok(entries) => {
            for entry in entries {
                let entry = entry?;
                let path = entry.path();
                let name = entry.file_name().to_string_lossy().to_string();
                if !entry.file_type()?.is_file()
                    || name.starts_with('.') || name.starts_with('~')
                    || !name.to_ascii_lowercase().ends_with(".md")
                {
                    continue;
                }
                paths.push(path);
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    }
    paths.sort();
    let mut notes = Vec::with_capacity(paths.len());
    for path in paths {
        let metadata = fs::metadata(&path)?;
        let modified = metadata.modified().ok().and_then(|time| time.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs() as i64).unwrap_or(0);
        let bytes = fs::read(&path)?;
        let text = String::from_utf8_lossy(&bytes);
        let name = path.file_name().unwrap_or_default().to_string_lossy();
        let mut note = decode_note_file(&text, &name, modified);
        note.file_in_trash = in_trash;
        notes.push(note);
    }
    Ok(notes)
}

fn folder_has_markdown(dir: &Path) -> io::Result<bool> {
    match fs::read_dir(dir) {
        Ok(entries) => {
            for entry in entries {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().to_lowercase();
                if entry.file_type()?.is_file() && !name.starts_with('.') && !name.starts_with('~') && name.ends_with(".md") {
                    return Ok(true);
                }
            }
            Ok(false)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

fn repair_ids(notes: &mut [Note], trash: &mut [Note]) {
    let high = notes.iter().chain(trash.iter()).map(|note| note.id).max().unwrap_or(0);
    let mut next = high.saturating_add(1);
    let mut seen = HashSet::new();
    for note in notes.iter_mut().chain(trash.iter_mut()) {
        if note.id == 0 || !seen.insert(note.id) {
            note.id = next;
            next = next.saturating_add(1);
            seen.insert(note.id);
        }
    }
}

fn write_note_to(data_dir: &Path, note: &mut Note) -> io::Result<()> {
    let folder = if note.file_in_trash {
        trash_dir(data_dir)
    } else {
        notes_dir(data_dir)
    };
    let path = folder.join(note_file_name(note));
    let old_path = note.file_name.as_ref().map(|name| folder.join(name));
    atomic_write(&path, &encode_note_file(note))?;
    if let Some(old) = old_path {
        if old != path {
            if let Err(error) = remove_if_exists(&old) {
                let _ = remove_if_exists(&path);
                return Err(error);
            }
        }
    }
    note.file_name = path.file_name().map(|name| name.to_string_lossy().into_owned());
    Ok(())
}

fn atomic_write(path: &Path, text: &str) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no parent"))?;
    fs::create_dir_all(parent)?;
    let mut tmp = path.as_os_str().to_os_string();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    fs::write(&tmp, text)?;
    if cfg!(windows) && path.exists() {
        let name = path.file_name().unwrap_or_default().to_string_lossy();
        let mut suffix = 1_u64;
        let backup = loop {
            let candidate = parent.join(format!("{name}.replace-backup-{suffix}"));
            if !candidate.exists() {
                break candidate;
            }
            suffix = suffix.saturating_add(1);
        };
        fs::rename(path, &backup)?;
        if let Err(error) = fs::rename(&tmp, path) {
            let _ = fs::rename(&backup, path);
            let _ = remove_if_exists(&tmp);
            return Err(error);
        }
        let _ = remove_if_exists(&backup);
        Ok(())
    } else {
        match fs::rename(&tmp, path) {
            Ok(()) => Ok(()),
            Err(error) => {
                let _ = remove_if_exists(&tmp);
                Err(error)
            }
        }
    }
}

fn remove_if_exists(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(title: &str, body: &str) -> Note {
        Note {
            id: 3,
            title: title.into(),
            body: body.into(),
            tags: vec!["prompt".into(), "idea".into()],
            pinned: true,
            created: 1_761_674_007,
            modified: 1_761_674_321,
            order: 2,
            file_name: None,
            file_in_trash: false,
        }
    }

    #[test]
    fn markdown_file_round_trip_preserves_body_and_metadata() {
        let original = note("  Keep spaces ", "Heading\n\n- [ ] task\n");
        let encoded = encode_note_file(&original);
        let decoded = decode_note_file(&encoded, "3-keep-spaces.md", 0);
        assert_eq!(decoded.title, original.title);
        assert_eq!(decoded.body, original.body);
        assert_eq!(decoded.tags, original.tags);
        assert_eq!(decoded.id, original.id);
        assert!(decoded.pinned);
        assert_eq!(decoded.created, original.created);
        assert_eq!(decoded.modified, original.modified);
        assert_eq!(decoded.order, original.order);
    }

    #[test]
    fn no_front_matter_keeps_the_whole_file_as_body() {
        let decoded = decode_note_file("Hand-written note\nsecond line", "9-my-note.md", 42);
        assert_eq!(decoded.id, 9);
        assert_eq!(decoded.title, "Hand-written note");
        assert_eq!(decoded.body, "Hand-written note\nsecond line");
        assert_eq!(decoded.created, 42);
    }

    #[test]
    fn tag_normalization_deduplicates_and_suggests_existing_tags() {
        assert_eq!(parse_tags(" Idea, prompt, IDEA "), ["idea", "prompt"]);
        assert_eq!(
            tag_suggestions("idea, pr", ["prompt".into(), "private".into(), "idea".into()]),
            ["private", "prompt"]
        );
    }

    #[test]
    fn note_operations_preserve_files_when_moved_to_trash_and_restored() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = NoteStore::open(temp.path()).unwrap();
        let added = store.add("First note", "Body", &["prompt".into()]).unwrap();
        assert!(notes_dir(temp.path()).join(note_file_name(&added)).exists());
        assert!(store.move_to_trash(added.id).unwrap());
        assert!(trash_dir(temp.path()).join(note_file_name(store.get_trashed(added.id).unwrap())).exists());
        assert!(store.restore(added.id).unwrap());
        assert_eq!(store.notes.len(), 1);
        assert!(notes_dir(temp.path()).join(note_file_name(&store.notes[0])).exists());
        assert_eq!(store.trash.len(), 0);
    }

    #[test]
    fn failed_permanent_delete_does_not_remove_the_in_memory_note() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = NoteStore::open(temp.path()).unwrap();
        let added = store.add("Keep", "", &[]).unwrap();
        store.move_to_trash(added.id).unwrap();
        let path = trash_dir(temp.path()).join(note_file_name(store.get_trashed(added.id).unwrap()));
        fs::remove_file(&path).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(store.delete_forever(added.id).is_err());
        assert_eq!(store.trash.len(), 1);
    }

    #[test]
    fn failed_trash_move_keeps_the_note_live_and_its_file_intact() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = NoteStore::open(temp.path()).unwrap();
        let added = store.add("Keep me", "Body", &[]).unwrap();
        let original = notes_dir(temp.path()).join(note_file_name(&added));
        fs::write(trash_dir(temp.path()), "blocks trash folder").unwrap();
        assert!(store.move_to_trash(added.id).is_err());
        assert_eq!(store.notes.len(), 1);
        assert_eq!(store.trash.len(), 0);
        assert_eq!(fs::read_to_string(original).unwrap(), encode_note_file(&added));
    }

    #[test]
    fn json_import_adds_fresh_ids_and_keeps_metadata() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = NoteStore::open(temp.path()).unwrap();
        let json = r#"{"next_id":40,"notes":[{"id":9,"title":"Imported","body":"Text","tags":["IDEA"],"pinned":true,"created":10,"modified":11}]}"#;
        let result = store.import_json(json).unwrap();
        assert_eq!(result.imported, 1);
        let imported = &store.notes[0];
        assert_eq!(imported.id, 1);
        assert!(imported.pinned);
        assert_eq!(imported.created, 10);
        assert_eq!(imported.modified, 11);
        assert_eq!(imported.tags, ["idea"]);
    }

    #[test]
    fn settings_read_and_write_the_legacy_json_shape() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(
            temp.path().join("settings.json"),
            r#"{"sort":"titleAsc","textSize":18,"minimize_to_tray":false,"close_action":"quit","auto_update":false,"window_placement":{"left":12,"top":34,"width":900,"height":700,"maximized":true}}"#,
        )
        .unwrap();
        let settings = AppSettings::load(temp.path());
        assert_eq!(settings.sort, SortMode::TitleAsc);
        assert_eq!(settings.text_size, 18.0);
        assert!(!settings.minimize_to_tray);
        assert_eq!(settings.close_action, "quit");
        assert!(!settings.auto_update);
        assert!(settings.window_placement.as_ref().unwrap().maximized);

        settings.save(temp.path()).unwrap();
        let saved: serde_json::Value =
            serde_json::from_slice(&fs::read(temp.path().join("settings.json")).unwrap()).unwrap();
        assert_eq!(saved["sort"], "titleAsc");
        assert_eq!(saved["textSize"], 18.0);
    }

    #[test]
    fn backup_restore_keeps_a_safety_copy_of_the_current_notebook() {
        let temp = tempfile::tempdir().unwrap();
        let data = temp.path().join("live");
        let backup = temp.path().join("backup");
        let mut store = NoteStore::open(&data).unwrap();
        store.add("Before backup", "Original", &[]).unwrap();
        let settings = AppSettings {
            text_size: 19.0,
            ..AppSettings::default()
        };
        settings.save(&data).unwrap();

        assert!(backup_data(&data, &backup).unwrap() >= 2);
        store.add("Temporary", "Discarded by restore", &[]).unwrap();
        restore_backup(&data, &backup).unwrap();

        let restored = NoteStore::open(&data).unwrap();
        assert_eq!(restored.notes.len(), 1);
        assert_eq!(restored.notes[0].title, "Before backup");
        assert_eq!(AppSettings::load(&data).text_size, 19.0);
        assert!(
            fs::read_dir(data.join("backups"))
                .unwrap()
                .any(|entry| entry.unwrap().file_name().to_string_lossy().starts_with("pre-restore-"))
        );
    }

    #[test]
    fn gui_and_cli_data_lock_rejects_a_second_writer_until_release() {
        let temp = tempfile::tempdir().unwrap();
        let first = acquire_data_lock(temp.path()).unwrap();
        let second = acquire_data_lock(temp.path()).unwrap_err();
        assert_eq!(second.kind(), io::ErrorKind::WouldBlock);
        drop(first);
        assert!(acquire_data_lock(temp.path()).is_ok());
    }

    #[test]
    fn newer_recovery_draft_can_restore_the_note_without_losing_its_id() {
        let temp = tempfile::tempdir().unwrap();
        let mut store = NoteStore::open(temp.path()).unwrap();
        let original = store.add("Draft", "saved", &[]).unwrap();
        store
            .write_recovery_draft(&original, "Draft edited", "unsaved text", &["idea".into()])
            .unwrap();
        let drafts = load_recovery_drafts(temp.path()).unwrap();
        assert_eq!(drafts.len(), 1);
        assert!(drafts[0].modified > original.modified);
        let recovered = store.recover_draft(original.id).unwrap().unwrap();
        assert_eq!(recovered.id, original.id);
        assert_eq!(recovered.title, "Draft edited");
        assert_eq!(recovered.body, "unsaved text");
        assert!(load_recovery_drafts(temp.path()).unwrap().is_empty());
    }
}
