//! One note: a title, a body, tags, a pin flag and timestamps.
//!
//! Organisation is by tags only. There are deliberately no folders
//! anywhere in TermiNote.

use crate::json::{self, Json};

/// The longest a single tag may be, in characters.
pub const MAX_TAG_LEN: usize = 40;

#[derive(Debug, Clone, PartialEq)]
pub struct Note {
    pub id: u64,
    pub title: String,
    pub body: String,
    pub tags: Vec<String>,
    pub pinned: bool,
    /// Unix seconds when the note was created.
    pub created: u64,
    /// Unix seconds when the note was last changed.
    pub modified: u64,
}

impl Note {
    pub fn new(id: u64, title: &str, body: &str, tags: Vec<String>, now: u64) -> Self {
        Note {
            id,
            title: title.to_string(),
            body: body.to_string(),
            tags: normalize_tags(tags),
            pinned: false,
            created: now,
            modified: now,
        }
    }

    pub fn to_json(&self) -> Json {
        Json::Obj(vec![
            ("id".to_string(), Json::Num(self.id as f64)),
            ("title".to_string(), Json::Str(self.title.clone())),
            ("body".to_string(), Json::Str(self.body.clone())),
            (
                "tags".to_string(),
                Json::Arr(self.tags.iter().map(|t| Json::Str(t.clone())).collect()),
            ),
            ("pinned".to_string(), Json::Bool(self.pinned)),
            ("created".to_string(), Json::Num(self.created as f64)),
            ("modified".to_string(), Json::Num(self.modified as f64)),
        ])
    }

    /// Read a note from JSON. Returns `None` when the value is not an
    /// object with a usable id; missing text fields default to empty
    /// so a partly-written file still loads what it can.
    pub fn from_json(value: &Json) -> Option<Note> {
        let fields = json::as_obj(value)?;
        let id = json::as_u64(json::get(fields, "id")?)?;
        let title = json::get(fields, "title")
            .and_then(json::as_str)
            .unwrap_or("")
            .to_string();
        let body = json::get(fields, "body")
            .and_then(json::as_str)
            .unwrap_or("")
            .to_string();
        let tags = json::get(fields, "tags")
            .map(json::as_str_arr)
            .unwrap_or_default();
        let pinned = json::get(fields, "pinned")
            .and_then(json::as_bool)
            .unwrap_or(false);
        let created = json::get(fields, "created")
            .and_then(json::as_u64)
            .unwrap_or(0);
        let modified = json::get(fields, "modified")
            .and_then(json::as_u64)
            .unwrap_or(created);
        Some(Note {
            id,
            title,
            body,
            tags: normalize_tags(tags),
            pinned,
            created,
            modified,
        })
    }

    /// Word count of title + body, where a word is a run of
    /// non-whitespace.
    pub fn word_count(&self) -> usize {
        self.title.split_whitespace().count() + self.body.split_whitespace().count()
    }

    /// Character count of title + body (Unicode scalar values).
    pub fn char_count(&self) -> usize {
        self.title.chars().count() + self.body.chars().count()
    }
}

/// Normalise one tag: trim, lowercase, cap at [`MAX_TAG_LEN`]
/// characters. Returns an empty string for a tag with nothing in it,
/// which callers drop.
pub fn normalize_tag(raw: &str) -> String {
    let trimmed = raw.trim().to_lowercase();
    trimmed.chars().take(MAX_TAG_LEN).collect()
}

/// Normalise a tag list: normalise each tag, drop empties and
/// duplicates, keeping first-seen order.
pub fn normalize_tags(raw: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for tag in raw {
        let tag = normalize_tag(&tag);
        if !tag.is_empty() && !out.contains(&tag) {
            out.push(tag);
        }
    }
    out
}

/// Split a comma-separated tag list (the CLI `--tags a,b` and GUI
/// tags-field shape) into normalised tags.
pub fn parse_tag_list(text: &str) -> Vec<String> {
    normalize_tags(text.split(',').map(str::to_string).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_are_trimmed_lowercased_and_deduped() {
        let tags = normalize_tags(vec![
            "  Work ".into(),
            "work".into(),
            "".into(),
            "   ".into(),
            "Ideas".into(),
            "IDEAS".into(),
        ]);
        assert_eq!(tags, vec!["work".to_string(), "ideas".to_string()]);
    }

    #[test]
    fn tags_are_capped_at_forty_characters() {
        let long = "x".repeat(60);
        let tags = normalize_tags(vec![long]);
        assert_eq!(tags[0].chars().count(), MAX_TAG_LEN);
    }

    #[test]
    fn comma_list_parsing_normalises() {
        assert_eq!(
            parse_tag_list(" Work, ,ideas ,WORK"),
            vec!["work".to_string(), "ideas".to_string()]
        );
        assert_eq!(parse_tag_list(""), Vec::<String>::new());
    }

    #[test]
    fn note_json_round_trip() {
        let note = Note {
            id: 9,
            title: "Shopping".into(),
            body: "Milk\nEggs".into(),
            tags: vec!["home".into()],
            pinned: true,
            created: 100,
            modified: 200,
        };
        let back = Note::from_json(&note.to_json()).unwrap();
        assert_eq!(back, note);
    }

    #[test]
    fn counts_words_and_chars() {
        let note = Note::new(1, "Two words", "three more words here", vec![], 0);
        assert_eq!(note.word_count(), 6);
        assert_eq!(
            note.char_count(),
            "Two words".len() + "three more words here".len()
        );
    }
}
