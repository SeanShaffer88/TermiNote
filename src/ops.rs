//! Every capability of TermiNote as an operation on the store.
//!
//! This module is the registry: the GUI and the command line both
//! dispatch here, so anything one can do the other can do too (see
//! `docs/PARITY.md`). Time is passed in as `now` (unix seconds) so
//! every operation is deterministic and testable.

use crate::json::{self, Json};
use crate::note::{normalize_tag, normalize_tags, Note};
use crate::store::Store;

/// How a note list is ordered. Pinned notes always come first,
/// whichever order is chosen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sort {
    ModifiedDesc,
    TitleAsc,
    CreatedDesc,
}

impl Sort {
    pub fn parse(text: &str) -> Option<Sort> {
        match text.trim().to_lowercase().as_str() {
            "modified" | "modifieddesc" | "modified-desc" => Some(Sort::ModifiedDesc),
            "title" | "titleasc" | "title-asc" => Some(Sort::TitleAsc),
            "created" | "createddesc" | "created-desc" => Some(Sort::CreatedDesc),
            _ => None,
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Sort::ModifiedDesc => "modified",
            Sort::TitleAsc => "title",
            Sort::CreatedDesc => "created",
        }
    }
}

/// Filters for listing notes. An empty search and no tag filter
/// match everything.
#[derive(Debug, Clone, Default)]
pub struct Filter {
    /// Free text matched (case-insensitively) against title, body
    /// and tags.
    pub search: String,
    /// When set, only notes carrying this tag are listed. The
    /// special values handled by callers ("all" / "untagged") are
    /// resolved before building the filter; see [`TagFilter`].
    pub tag: Option<String>,
    /// When true, only notes with no tags at all are listed.
    pub untagged_only: bool,
    pub sort: Option<Sort>,
}

impl Filter {
    pub fn sort(&self) -> Sort {
        self.sort.unwrap_or(Sort::ModifiedDesc)
    }
}

/// Aggregate numbers about the store.
#[derive(Debug, Clone, PartialEq)]
pub struct Stats {
    pub notes: usize,
    pub trash: usize,
    pub tags: usize,
    pub pinned: usize,
    pub total_words: usize,
    pub total_chars: usize,
}

fn not_found(id: u64) -> String {
    format!("no note with id {id}")
}

fn note_index(store: &Store, id: u64) -> Result<usize, String> {
    store
        .notes
        .iter()
        .position(|n| n.id == id)
        .ok_or_else(|| not_found(id))
}

/// Add a note and return it (with its new id).
pub fn add(store: &mut Store, title: &str, body: &str, tags: Vec<String>, now: u64) -> Note {
    let id = store.alloc_id();
    let note = Note::new(id, title, body, tags, now);
    store.notes.push(note.clone());
    note
}

/// Replace a note's title, body and tags. Only the fields that are
/// `Some` change. `modified` always moves to `now` when anything
/// changed.
pub fn update(
    store: &mut Store,
    id: u64,
    title: Option<&str>,
    body: Option<&str>,
    tags: Option<Vec<String>>,
    now: u64,
) -> Result<Note, String> {
    let idx = note_index(store, id)?;
    let note = &mut store.notes[idx];
    let mut changed = false;
    if let Some(t) = title {
        if note.title != t {
            note.title = t.to_string();
            changed = true;
        }
    }
    if let Some(b) = body {
        if note.body != b {
            note.body = b.to_string();
            changed = true;
        }
    }
    if let Some(tags) = tags {
        let tags = normalize_tags(tags);
        if note.tags != tags {
            note.tags = tags;
            changed = true;
        }
    }
    if changed {
        note.modified = now;
    }
    Ok(note.clone())
}

/// Fetch one live note by id.
pub fn get(store: &Store, id: u64) -> Result<&Note, String> {
    store
        .notes
        .iter()
        .find(|n| n.id == id)
        .ok_or_else(|| not_found(id))
}

/// Fetch one trashed note by id.
pub fn get_trashed(store: &Store, id: u64) -> Result<&Note, String> {
    store
        .trash
        .iter()
        .find(|n| n.id == id)
        .ok_or_else(|| format!("no note with id {id} in the trash"))
}

fn matches(note: &Note, filter: &Filter) -> bool {
    if filter.untagged_only && !note.tags.is_empty() {
        return false;
    }
    if let Some(tag) = &filter.tag {
        let tag = normalize_tag(tag);
        if !note.tags.iter().any(|t| t == &tag) {
            return false;
        }
    }
    let query = filter.search.trim().to_lowercase();
    if !query.is_empty() {
        let in_title = note.title.to_lowercase().contains(&query);
        let in_body = note.body.to_lowercase().contains(&query);
        let in_tags = note.tags.iter().any(|t| t.to_lowercase().contains(&query));
        if !in_title && !in_body && !in_tags {
            return false;
        }
    }
    true
}

/// List live notes matching the filter, pinned first, then in the
/// chosen order. Returns clones so callers can hold the list while
/// mutating the store.
pub fn list(store: &Store, filter: &Filter) -> Vec<Note> {
    let mut out: Vec<Note> = store
        .notes
        .iter()
        .filter(|n| matches(n, filter))
        .cloned()
        .collect();
    let sort = filter.sort();
    out.sort_by(|a, b| {
        // Pinned always first.
        match b.pinned.cmp(&a.pinned) {
            std::cmp::Ordering::Equal => {}
            other => return other,
        }
        match sort {
            Sort::ModifiedDesc => b.modified.cmp(&a.modified).then_with(|| b.id.cmp(&a.id)),
            Sort::CreatedDesc => b.created.cmp(&a.created).then_with(|| b.id.cmp(&a.id)),
            Sort::TitleAsc => a
                .title
                .to_lowercase()
                .cmp(&b.title.to_lowercase())
                .then_with(|| a.id.cmp(&b.id)),
        }
    });
    out
}

/// List trashed notes, most recently modified first.
pub fn list_trash(store: &Store) -> Vec<Note> {
    let mut out = store.trash.clone();
    out.sort_by(|a, b| b.modified.cmp(&a.modified).then_with(|| b.id.cmp(&a.id)));
    out
}

/// Delete a note: it moves to the trash (never gone in one click).
pub fn delete(store: &mut Store, id: u64, now: u64) -> Result<Note, String> {
    let idx = note_index(store, id)?;
    let mut note = store.notes.remove(idx);
    note.modified = now;
    store.trash.push(note.clone());
    Ok(note)
}

/// Restore a note from the trash.
pub fn restore(store: &mut Store, id: u64, now: u64) -> Result<Note, String> {
    let idx = store
        .trash
        .iter()
        .position(|n| n.id == id)
        .ok_or_else(|| format!("no note with id {id} in the trash"))?;
    let mut note = store.trash.remove(idx);
    note.modified = now;
    store.notes.push(note.clone());
    Ok(note)
}

/// Permanently remove a note from the trash.
pub fn delete_forever(store: &mut Store, id: u64) -> Result<Note, String> {
    let idx = store
        .trash
        .iter()
        .position(|n| n.id == id)
        .ok_or_else(|| format!("no note with id {id} in the trash"))?;
    Ok(store.trash.remove(idx))
}

/// Permanently remove everything in the trash. Returns how many
/// notes were removed.
pub fn empty_trash(store: &mut Store) -> usize {
    let count = store.trash.len();
    store.trash.clear();
    count
}

/// Move every live note to the trash. Returns how many moved.
pub fn delete_all(store: &mut Store, now: u64) -> usize {
    let count = store.notes.len();
    for mut note in store.notes.drain(..) {
        note.modified = now;
        store.trash.push(note);
    }
    count
}

/// Add a tag to a note (normalised; adding an existing tag changes
/// nothing except that the call still succeeds).
pub fn tag_add(store: &mut Store, id: u64, tag: &str, now: u64) -> Result<Note, String> {
    let tag = normalize_tag(tag);
    if tag.is_empty() {
        return Err("a tag cannot be empty".to_string());
    }
    let idx = note_index(store, id)?;
    let note = &mut store.notes[idx];
    if !note.tags.contains(&tag) {
        note.tags.push(tag);
        note.modified = now;
    }
    Ok(note.clone())
}

/// Remove a tag from a note.
pub fn tag_remove(store: &mut Store, id: u64, tag: &str, now: u64) -> Result<Note, String> {
    let tag = normalize_tag(tag);
    let idx = note_index(store, id)?;
    let note = &mut store.notes[idx];
    let before = note.tags.len();
    note.tags.retain(|t| t != &tag);
    if note.tags.len() != before {
        note.modified = now;
    }
    Ok(note.clone())
}

/// Rename a tag on every live note that carries it. If the new name
/// already exists on a note, the two merge (no duplicates). Returns
/// how many notes changed.
pub fn rename_tag(store: &mut Store, old: &str, new: &str, now: u64) -> Result<usize, String> {
    let old = normalize_tag(old);
    let new = normalize_tag(new);
    if old.is_empty() {
        return Err("the old tag cannot be empty".to_string());
    }
    if new.is_empty() {
        return Err("the new tag cannot be empty".to_string());
    }
    let mut changed = 0;
    for note in store.notes.iter_mut() {
        if note.tags.iter().any(|t| t == &old) {
            for tag in note.tags.iter_mut() {
                if *tag == old {
                    *tag = new.clone();
                }
            }
            note.tags = normalize_tags(note.tags.clone());
            note.modified = now;
            changed += 1;
        }
    }
    Ok(changed)
}

/// Every tag in use on live notes, with the number of notes carrying
/// it, in alphabetical order.
pub fn all_tags(store: &Store) -> Vec<(String, usize)> {
    let mut counts: Vec<(String, usize)> = Vec::new();
    for note in &store.notes {
        for tag in &note.tags {
            if let Some(entry) = counts.iter_mut().find(|(t, _)| t == tag) {
                entry.1 += 1;
            } else {
                counts.push((tag.clone(), 1));
            }
        }
    }
    counts.sort_by(|a, b| a.0.cmp(&b.0));
    counts
}

/// Set or clear a note's pin.
pub fn set_pinned(store: &mut Store, id: u64, pinned: bool, now: u64) -> Result<Note, String> {
    let idx = note_index(store, id)?;
    let note = &mut store.notes[idx];
    if note.pinned != pinned {
        note.pinned = pinned;
        note.modified = now;
    }
    Ok(note.clone())
}

/// Toggle a note's pin.
pub fn toggle_pin(store: &mut Store, id: u64, now: u64) -> Result<Note, String> {
    let current = get(store, id)?.pinned;
    set_pinned(store, id, !current, now)
}

/// Copy a note: same title, body and tags, new id, created and
/// modified set to `now`. The copy is not pinned.
pub fn duplicate(store: &mut Store, id: u64, now: u64) -> Result<Note, String> {
    let source = get(store, id)?.clone();
    let new_id = store.alloc_id();
    let copy = Note {
        id: new_id,
        title: source.title,
        body: source.body,
        tags: source.tags,
        pinned: false,
        created: now,
        modified: now,
    };
    store.notes.push(copy.clone());
    Ok(copy)
}

/// Export the whole store (notes and trash) as JSON text — the same
/// shape the data file uses.
pub fn export_json(store: &Store) -> String {
    store.to_json_text()
}

/// Import notes from JSON text in the export shape. Imported notes
/// are merged in with fresh ids, so nothing already here is ever
/// overwritten. Returns how many live notes were imported. Trash in
/// the imported file is imported as trash too.
pub fn import_json(store: &mut Store, text: &str, now: u64) -> Result<usize, String> {
    let value =
        json::parse(text).ok_or_else(|| "that file is not valid TermiNote JSON".to_string())?;
    let imported = Store::from_json(&value)
        .ok_or_else(|| "that file does not look like a TermiNote export".to_string())?;
    let mut count = 0;
    for note in imported.notes {
        let new_id = store.alloc_id();
        store.notes.push(Note {
            id: new_id,
            title: note.title,
            body: note.body,
            tags: note.tags,
            pinned: note.pinned,
            created: note.created,
            modified: if note.modified == 0 {
                now
            } else {
                note.modified
            },
        });
        count += 1;
    }
    for note in imported.trash {
        let new_id = store.alloc_id();
        store.trash.push(Note {
            id: new_id,
            title: note.title,
            body: note.body,
            tags: note.tags,
            pinned: note.pinned,
            created: note.created,
            modified: note.modified,
        });
    }
    Ok(count)
}

/// Export one note as plain text: title, a blank line, then body.
pub fn export_note_text(store: &Store, id: u64) -> Result<String, String> {
    let note = get(store, id)?;
    if note.body.is_empty() {
        Ok(note.title.clone())
    } else {
        Ok(format!("{}\n\n{}", note.title, note.body))
    }
}

/// Aggregate counts for the whole store.
pub fn stats(store: &Store) -> Stats {
    Stats {
        notes: store.notes.len(),
        trash: store.trash.len(),
        tags: all_tags(store).len(),
        pinned: store.notes.iter().filter(|n| n.pinned).count(),
        total_words: store.notes.iter().map(Note::word_count).sum(),
        total_chars: store.notes.iter().map(Note::char_count).sum(),
    }
}

/// JSON representation of one note, for `--json` output.
pub fn note_json(note: &Note) -> Json {
    note.to_json()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seeded() -> Store {
        let mut store = Store::new();
        add(
            &mut store,
            "Beta note",
            "body about cats",
            vec!["Pets".into()],
            100,
        );
        add(
            &mut store,
            "alpha note",
            "dogs and more",
            vec!["pets".into(), "home".into()],
            200,
        );
        add(&mut store, "Gamma", "nothing here", vec![], 300);
        store
    }

    #[test]
    fn add_assigns_ids_and_timestamps() {
        let mut store = Store::new();
        let a = add(&mut store, "One", "", vec![], 10);
        let b = add(&mut store, "Two", "", vec![], 20);
        assert_eq!((a.id, b.id), (1, 2));
        assert_eq!(a.created, 10);
        assert_eq!(b.modified, 20);
    }

    #[test]
    fn list_is_titles_in_modified_order() {
        let store = seeded();
        let notes = list(&store, &Filter::default());
        let titles: Vec<&str> = notes.iter().map(|n| n.title.as_str()).collect();
        assert_eq!(titles, vec!["Gamma", "alpha note", "Beta note"]);
    }

    #[test]
    fn pinned_always_first() {
        let mut store = seeded();
        // Pin the oldest note; it must jump ahead of newer ones.
        let _ = set_pinned(&mut store, 1, true, 50);
        let notes = list(&store, &Filter::default());
        assert_eq!(notes[0].id, 1);
        // Also under title sort: pinned first, rest alphabetical.
        let notes = list(
            &store,
            &Filter {
                sort: Some(Sort::TitleAsc),
                ..Default::default()
            },
        );
        assert_eq!(notes[0].id, 1);
        assert_eq!(notes[1].title, "alpha note");
    }

    #[test]
    fn search_matches_title_body_and_tags() {
        let store = seeded();
        let by_body = list(
            &store,
            &Filter {
                search: "CATS".into(),
                ..Default::default()
            },
        );
        assert_eq!(by_body.len(), 1);
        assert_eq!(by_body[0].title, "Beta note");
        let by_tag = list(
            &store,
            &Filter {
                search: "home".into(),
                ..Default::default()
            },
        );
        assert_eq!(by_tag.len(), 1);
        assert_eq!(by_tag[0].id, 2);
        let by_title = list(
            &store,
            &Filter {
                search: "gamma".into(),
                ..Default::default()
            },
        );
        assert_eq!(by_title.len(), 1);
        let none = list(
            &store,
            &Filter {
                search: "zebra".into(),
                ..Default::default()
            },
        );
        assert!(none.is_empty());
    }

    #[test]
    fn tag_filter_and_untagged_filter() {
        let store = seeded();
        let pets = list(
            &store,
            &Filter {
                tag: Some("PETS".into()),
                ..Default::default()
            },
        );
        assert_eq!(pets.len(), 2);
        let untagged = list(
            &store,
            &Filter {
                untagged_only: true,
                ..Default::default()
            },
        );
        assert_eq!(untagged.len(), 1);
        assert_eq!(untagged[0].title, "Gamma");
    }

    #[test]
    fn title_sort_is_case_insensitive() {
        let store = seeded();
        let notes = list(
            &store,
            &Filter {
                sort: Some(Sort::TitleAsc),
                ..Default::default()
            },
        );
        let titles: Vec<&str> = notes.iter().map(|n| n.title.as_str()).collect();
        assert_eq!(titles, vec!["alpha note", "Beta note", "Gamma"]);
    }

    #[test]
    fn update_changes_only_given_fields() {
        let mut store = seeded();
        let note = update(&mut store, 1, Some("Renamed"), None, None, 999).unwrap();
        assert_eq!(note.title, "Renamed");
        assert_eq!(note.body, "body about cats");
        assert_eq!(note.modified, 999);
        assert!(update(&mut store, 77, Some("x"), None, None, 1).is_err());
    }

    #[test]
    fn delete_restore_and_delete_forever() {
        let mut store = seeded();
        let gone = delete(&mut store, 2, 400).unwrap();
        assert_eq!(gone.id, 2);
        assert_eq!(store.notes.len(), 2);
        assert_eq!(store.trash.len(), 1);
        assert!(get(&store, 2).is_err());
        let back = restore(&mut store, 2, 500).unwrap();
        assert_eq!(back.id, 2);
        assert_eq!(store.notes.len(), 3);
        assert!(store.trash.is_empty());
        delete(&mut store, 2, 600).unwrap();
        delete_forever(&mut store, 2).unwrap();
        assert!(store.trash.is_empty());
        assert_eq!(empty_trash(&mut store), 0);
    }

    #[test]
    fn delete_all_moves_everything_to_trash() {
        let mut store = seeded();
        assert_eq!(delete_all(&mut store, 700), 3);
        assert!(store.notes.is_empty());
        assert_eq!(store.trash.len(), 3);
        assert_eq!(empty_trash(&mut store), 3);
    }

    #[test]
    fn tag_add_remove_and_rename() {
        let mut store = seeded();
        tag_add(&mut store, 3, " Fresh ", 400).unwrap();
        assert_eq!(get(&store, 3).unwrap().tags, vec!["fresh".to_string()]);
        tag_add(&mut store, 3, "fresh", 401).unwrap();
        assert_eq!(get(&store, 3).unwrap().tags.len(), 1);
        tag_remove(&mut store, 3, "FRESH", 402).unwrap();
        assert!(get(&store, 3).unwrap().tags.is_empty());
        let changed = rename_tag(&mut store, "pets", "animals", 500).unwrap();
        assert_eq!(changed, 2);
        let tags = all_tags(&store);
        assert!(tags.iter().any(|(t, c)| t == "animals" && *c == 2));
        assert!(!tags.iter().any(|(t, _)| t == "pets"));
    }

    #[test]
    fn rename_tag_merges_without_duplicates() {
        let mut store = seeded();
        // Note 2 has both "pets" and "home"; renaming pets -> home
        // must leave exactly one "home".
        rename_tag(&mut store, "pets", "home", 500).unwrap();
        assert_eq!(get(&store, 2).unwrap().tags, vec!["home".to_string()]);
    }

    #[test]
    fn duplicate_copies_content_with_new_id() {
        let mut store = seeded();
        let copy = duplicate(&mut store, 2, 800).unwrap();
        assert_ne!(copy.id, 2);
        assert_eq!(copy.title, "alpha note");
        assert_eq!(copy.body, "dogs and more");
        assert_eq!(copy.created, 800);
        assert_eq!(store.notes.len(), 4);
    }

    #[test]
    fn pin_toggle_flips() {
        let mut store = seeded();
        assert!(toggle_pin(&mut store, 1, 100).unwrap().pinned);
        assert!(!toggle_pin(&mut store, 1, 101).unwrap().pinned);
    }

    #[test]
    fn import_export_round_trip_merges_with_new_ids() {
        let mut source = seeded();
        delete(&mut source, 3, 400).unwrap();
        let text = export_json(&source);
        let mut dest = Store::new();
        add(&mut dest, "Existing", "", vec![], 1);
        let count = import_json(&mut dest, &text, 900).unwrap();
        assert_eq!(count, 2);
        assert_eq!(dest.notes.len(), 3);
        assert_eq!(dest.trash.len(), 1);
        // No id collisions with the pre-existing note (id 1).
        let mut ids: Vec<u64> = dest.notes.iter().map(|n| n.id).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), 3);
        assert!(import_json(&mut dest, "not json", 1).is_err());
    }

    #[test]
    fn export_note_text_shape() {
        let store = seeded();
        assert_eq!(
            export_note_text(&store, 1).unwrap(),
            "Beta note\n\nbody about cats"
        );
    }

    #[test]
    fn stats_counts_everything() {
        let mut store = seeded();
        let _ = set_pinned(&mut store, 1, true, 50);
        delete(&mut store, 3, 400).unwrap();
        let s = stats(&store);
        assert_eq!(s.notes, 2);
        assert_eq!(s.trash, 1);
        assert_eq!(s.pinned, 1);
        assert_eq!(s.tags, 2); // pets, home
        assert!(s.total_words > 0);
        assert!(s.total_chars > 0);
    }

    #[test]
    fn sort_parse_names() {
        assert_eq!(Sort::parse("title"), Some(Sort::TitleAsc));
        assert_eq!(Sort::parse("Modified"), Some(Sort::ModifiedDesc));
        assert_eq!(Sort::parse("created-desc"), Some(Sort::CreatedDesc));
        assert_eq!(Sort::parse("bogus"), None);
    }
}
