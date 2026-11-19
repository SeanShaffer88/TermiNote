#![allow(non_snake_case)]

use dioxus::prelude::*;
use gloo_timers::future::TimeoutFuture;
use serde::Serialize;
use terminote_core::{AppSettings, ImportResult, Note, SortMode, markdown::MarkdownFormat};
use wasm_bindgen::prelude::*;
use wasm_bindgen::closure::Closure;
use wasm_bindgen::JsCast;

static CSS: Asset = asset!("/assets/styles.css");

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = ["window", "__TAURI__", "core"], js_name = invoke)]
    async fn tauri_invoke(command: &str, args: JsValue) -> JsValue;
    #[wasm_bindgen(js_namespace = ["window", "__TAURI__", "event"], js_name = listen)]
    async fn tauri_listen(
        event: &str,
        callback: &Closure<dyn FnMut(JsValue)>,
    ) -> JsValue;
}

#[derive(Serialize)]
struct NoteArgs<'a> {
    id: u64,
    title: &'a str,
    body: &'a str,
    tags: &'a [String],
}

#[derive(Serialize)]
struct IdArgs {
    id: u64,
}

#[derive(Serialize)]
struct PinArgs {
    id: u64,
    pinned: bool,
}

#[derive(Serialize)]
struct ReorderArgs {
    ids: Vec<u64>,
}

#[derive(Serialize)]
struct CloseRequestArgs<'a> {
    action: &'a str,
    remember: bool,
}

#[derive(Serialize)]
struct PathArgs<'a> {
    path: &'a str,
}

#[derive(Serialize)]
struct RenameTagArgs<'a> {
    old: &'a str,
    new: &'a str,
}

#[derive(Serialize)]
struct TagArgs<'a> {
    tag: &'a str,
}

#[derive(Clone)]
struct PendingSave {
    note: Note,
    revision: u64,
    saving: bool,
}

async fn resolve_close_request(action: &str, remember: bool) -> Result<(), String> {
    let args = serde_wasm_bindgen::to_value(&CloseRequestArgs { action, remember })
        .map_err(|error| error.to_string())?;
    let value = tauri_invoke("resolve_close_request", args).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn install_update() -> Result<(), String> {
    let value = tauri_invoke("install_update", JsValue::NULL).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn start_update_check() {
    let _ = tauri_invoke("start_update_check", JsValue::NULL).await;
}

async fn invoke_path<T: serde::de::DeserializeOwned>(
    command: &str,
    path: &str,
) -> Result<T, String> {
    let args = serde_wasm_bindgen::to_value(&PathArgs { path })
        .map_err(|error| error.to_string())?;
    let value = tauri_invoke(command, args).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn rename_tag(old: &str, new: &str) -> Result<usize, String> {
    let args = serde_wasm_bindgen::to_value(&RenameTagArgs { old, new })
        .map_err(|error| error.to_string())?;
    let value = tauri_invoke("rename_tag", args).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn delete_tag(tag: &str) -> Result<usize, String> {
    let args =
        serde_wasm_bindgen::to_value(&TagArgs { tag }).map_err(|error| error.to_string())?;
    let value = tauri_invoke("delete_tag", args).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn set_note_pinned(id: u64, pinned: bool) -> Result<bool, String> {
    let args = serde_wasm_bindgen::to_value(&PinArgs { id, pinned })
        .map_err(|error| error.to_string())?;
    let value = tauri_invoke("set_pinned", args).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn save_note_order(ids: Vec<u64>) -> Result<(), String> {
    let args = serde_wasm_bindgen::to_value(&ReorderArgs { ids })
        .map_err(|error| error.to_string())?;
    let value = tauri_invoke("reorder_notes", args).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn load_notes() -> Result<Vec<Note>, String> {
    let value = tauri_invoke("list_notes", JsValue::NULL).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn load_trash() -> Result<Vec<Note>, String> {
    let value = tauri_invoke("list_trash", JsValue::NULL).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn load_settings() -> Result<AppSettings, String> {
    let value = tauri_invoke("get_settings", JsValue::NULL).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn load_recovery_drafts() -> Result<Vec<Note>, String> {
    let value = tauri_invoke("list_recovery_drafts", JsValue::NULL).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn recover_draft(id: u64) -> Result<Option<Note>, String> {
    let args = serde_wasm_bindgen::to_value(&IdArgs { id })
        .map_err(|error| error.to_string())?;
    let value = tauri_invoke("recover_draft", args).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn discard_recovery_draft(id: u64) -> Result<(), String> {
    let args = serde_wasm_bindgen::to_value(&IdArgs { id })
        .map_err(|error| error.to_string())?;
    let value = tauri_invoke("discard_recovery_draft", args).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn save_settings(settings: &AppSettings) -> Result<(), String> {
    let args = serde_wasm_bindgen::to_value(&SettingsArgs { settings })
        .map_err(|error| error.to_string())?;
    let value = tauri_invoke("save_settings", args).await;
    serde_wasm_bindgen::from_value::<()>(value).map_err(|error| error.to_string())
}

#[derive(Serialize)]
struct SettingsArgs<'a> {
    settings: &'a AppSettings,
}

async fn add_note(title: &str, body: &str) -> Result<Note, String> {
    let args = serde_wasm_bindgen::to_value(&AddArgs {
        title,
        body,
        tags: &[],
    })
    .map_err(|error| error.to_string())?;
    let value = tauri_invoke("add_note", args).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

#[derive(Serialize)]
struct AddArgs<'a> {
    title: &'a str,
    body: &'a str,
    tags: &'a [String],
}

async fn invoke_id(command: &str, id: u64) -> Result<bool, String> {
    let args = serde_wasm_bindgen::to_value(&IdArgs { id })
        .map_err(|error| error.to_string())?;
    let value = tauri_invoke(command, args).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn empty_trash() -> Result<usize, String> {
    let value = tauri_invoke("empty_trash", JsValue::NULL).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn delete_all_notes() -> Result<usize, String> {
    let value = tauri_invoke("delete_all_notes", JsValue::NULL).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

async fn persist_note(note: &Note) -> Result<Note, String> {
    let args = NoteArgs {
        id: note.id,
        title: &note.title,
        body: &note.body,
        tags: &note.tags,
    };
    let args = serde_wasm_bindgen::to_value(&args).map_err(|error| error.to_string())?;
    let value = tauri_invoke("update_note", args).await;
    let saved: Option<Note> =
        serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())?;
    saved.ok_or_else(|| "Note no longer exists.".into())
}

async fn persist_recovery_draft(note: &Note) -> Result<(), String> {
    let args = NoteArgs {
        id: note.id,
        title: &note.title,
        body: &note.body,
        tags: &note.tags,
    };
    let args = serde_wasm_bindgen::to_value(&args).map_err(|error| error.to_string())?;
    let value = tauri_invoke("write_recovery_draft", args).await;
    serde_wasm_bindgen::from_value(value).map_err(|error| error.to_string())
}

fn queue_note_save(
    mut pending: Signal<std::collections::HashMap<u64, PendingSave>>,
    mut notes: Signal<Vec<Note>>,
    mut status: Signal<String>,
    note: Note,
) {
    let id = note.id;
    let start_worker = {
        let mut pending_saves = pending.write();
        if let Some(item) = pending_saves.get_mut(&id) {
            item.note = note;
            item.revision = item.revision.wrapping_add(1);
            if item.saving {
                false
            } else {
                item.saving = true;
                true
            }
        } else {
            pending_saves.insert(
                id,
                PendingSave {
                    note,
                    revision: 1,
                    saving: true,
                },
            );
            true
        }
    };
    status.set("Saving…".into());
    if !start_worker {
        return;
    }
    spawn(async move {
        loop {
            let current = pending.read().get(&id).cloned();
            let Some(current) = current else {
                break;
            };
            let save_result = persist_note(&current.note).await;
            match save_result {
                Ok(saved) => {
                    let completed = {
                        let mut pending_saves = pending.write();
                        if pending_saves
                            .get(&id)
                            .is_some_and(|item| item.revision == current.revision)
                        {
                            pending_saves.remove(&id);
                            true
                        } else {
                            false
                        }
                    };
                    if !completed {
                        continue;
                    }
                    if let Some(item) = notes.write().iter_mut().find(|item| item.id == saved.id) {
                        item.modified = saved.modified;
                    }
                    status.set("Saved".into());
                }
                Err(error) => {
                    if pending
                        .read()
                        .get(&id)
                        .is_some_and(|item| item.revision != current.revision)
                    {
                        continue;
                    }
                    let recovered = persist_recovery_draft(&current.note).await.is_ok();
                    let completed = {
                        let mut pending_saves = pending.write();
                        if pending_saves
                            .get(&id)
                            .is_some_and(|item| item.revision == current.revision)
                        {
                            pending_saves.remove(&id);
                            true
                        } else {
                            false
                        }
                    };
                    if !completed {
                        continue;
                    }
                    status.set(if recovered {
                        format!("Save failed; recovery draft kept ({error})")
                    } else {
                        format!("Save failed: {error}")
                    });
                }
            }
            break;
        }
    });
}

async fn flush_pending_saves(pending: Signal<std::collections::HashMap<u64, PendingSave>>) {
    for _ in 0..40 {
        if pending.read().is_empty() {
            return;
        }
        TimeoutFuture::new(50).await;
    }
    let notes: Vec<Note> = pending
        .read()
        .values()
        .map(|item| item.note.clone())
        .collect();
    for note in notes {
        let _ = persist_recovery_draft(&note).await;
    }
}

#[derive(Clone, Copy)]
enum ConfirmAction {
    DeleteAll,
    EmptyTrash,
    DeleteForever(u64),
    RestoreBackup,
}

#[derive(Clone, Copy, PartialEq)]
enum EditorMode {
    Edit,
    Split,
    Preview,
}

#[derive(Clone)]
struct ChecklistItem {
    checked: bool,
    text: String,
}

fn parse_checklist(body: &str) -> Option<Vec<ChecklistItem>> {
    let mut items = Vec::new();
    for line in body.lines().filter(|line| !line.trim().is_empty()) {
        let (checked, text) = if let Some(text) = line.strip_prefix("- [ ] ") {
            (false, text)
        } else if let Some(text) = line.strip_prefix("- [x] ").or_else(|| line.strip_prefix("- [X] ")) {
            (true, text)
        } else {
            return None;
        };
        items.push(ChecklistItem {
            checked,
            text: text.to_string(),
        });
    }
    (!items.is_empty()).then_some(items)
}

fn serialize_checklist(items: &[ChecklistItem]) -> String {
    if items.is_empty() {
        return "- [ ] ".into();
    }
    items
        .iter()
        .map(|item| {
            format!(
                "- [{}] {}",
                if item.checked { "x" } else { " " },
                item.text
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn checklist_editor(
    id: u64,
    items: Vec<ChecklistItem>,
    active_note: Signal<Option<Note>>,
    notes: Signal<Vec<Note>>,
    status: Signal<String>,
    pending: Signal<std::collections::HashMap<u64, PendingSave>>,
    mut new_item: Signal<String>,
) -> Element {
    let items_for_add = items.clone();
    rsx! {
        div { class: "checklist-editor",
            div { class: "checklist-add",
                input {
                    class: "checklist-add-input",
                    value: "{new_item}",
                    placeholder: "Add items",
                    oninput: move |event| new_item.set(event.value())
                }
                button {
                    class: "format-button",
                    title: "Add item",
                    onclick: move |_| {
                        let text = new_item.read().trim().to_string();
                        if text.is_empty() { return; }
                        let mut changed = items_for_add.clone();
                        if changed.len() == 1 && changed[0].text.is_empty() && !changed[0].checked {
                            changed[0].text = text;
                        } else {
                            changed.push(ChecklistItem { checked: false, text });
                        }
                        replace_note_body(active_note, notes, status, pending, id, serialize_checklist(&changed));
                        new_item.set(String::new());
                    },
                    "✓"
                }
            }
            for (index, item) in items.iter().enumerate() {
                {
                    let checkbox_items = items.clone();
                    let text_items = items.clone();
                    let remove_items = items.clone();
                    let text = item.text.clone();
                    let checked = item.checked;
                    rsx! {
                        div { class: "checklist-row", key: "{id}-{index}",
                            input {
                                class: "checklist-box",
                                r#type: "checkbox",
                                checked,
                                onchange: move |_| {
                                    let mut changed = checkbox_items.clone();
                                    changed[index].checked = !changed[index].checked;
                                    replace_note_body(active_note, notes, status, pending, id, serialize_checklist(&changed));
                                }
                            }
                            input {
                                class: if checked { "checklist-text completed" } else { "checklist-text" },
                                value: "{text}",
                                placeholder: "List item",
                                oninput: move |event| {
                                    let mut changed = text_items.clone();
                                    changed[index].text = event.value();
                                    replace_note_body(active_note, notes, status, pending, id, serialize_checklist(&changed));
                                }
                            }
                            button {
                                class: "checklist-delete",
                                title: "Delete item",
                                onclick: move |_| {
                                    let mut changed = remove_items.clone();
                                    changed.remove(index);
                                    replace_note_body(active_note, notes, status, pending, id, serialize_checklist(&changed));
                                },
                                "×"
                            }
                        }
                    }
                }
            }
        }
    }
}

fn change_setting(
    mut settings: Signal<AppSettings>,
    mut status: Signal<String>,
    change: impl FnOnce(&mut AppSettings) + 'static,
) {
    let mut updated = settings.read().clone();
    change(&mut updated);
    settings.set(updated.clone());
    spawn(async move {
        status.set(match save_settings(&updated).await {
            Ok(()) => "Settings saved".into(),
            Err(_) => "Could not save settings".into(),
        });
    });
}

fn set_sort_mode(
    mut settings: Signal<AppSettings>,
    mut status: Signal<String>,
    sort: SortMode,
) {
    let mut updated = settings.read().clone();
    updated.sort = sort;
    settings.set(updated.clone());
    spawn(async move {
        status.set(match save_settings(&updated).await {
            Ok(()) => "Settings saved".into(),
            Err(_) => "Could not save settings".into(),
        });
    });
}

fn format_note_body(
    mut active_note: Signal<Option<Note>>,
    mut notes: Signal<Vec<Note>>,
    status: Signal<String>,
    pending: Signal<std::collections::HashMap<u64, PendingSave>>,
    id: u64,
    format: MarkdownFormat,
) {
    let Some(mut note) = active_note.read().clone() else {
        return;
    };
    if note.id != id {
        return;
    }
    let element = web_sys::window()
        .and_then(|window| window.document())
        .and_then(|document| document.get_element_by_id(&format!("body-{id}")))
        .and_then(|element| element.dyn_into::<web_sys::HtmlTextAreaElement>().ok());
    let (start, end) = element
        .as_ref()
        .and_then(|textarea| {
            Some((
                textarea.selection_start().ok()?? as usize,
                textarea.selection_end().ok()?? as usize,
            ))
        })
        .filter(|(start, end)| start < end)
        .map(|(start, end)| {
            (
                utf16_to_byte(&note.body, start),
                utf16_to_byte(&note.body, end),
            )
        })
        .unwrap_or((0, note.body.len()));
    let edit = terminote_core::markdown::apply_format(&note.body, start, end, format);
    let selection = (edit.start, edit.end);
    note.body = edit.text;
    if let Some(textarea) = element {
        textarea.set_value(&note.body);
        let _ = textarea.set_selection_range(
            byte_to_utf16(&note.body, selection.0) as u32,
            byte_to_utf16(&note.body, selection.1) as u32,
        );
    }
    active_note.set(Some(note.clone()));
    if let Some(listed) = notes.write().iter_mut().find(|item| item.id == id) {
        listed.body = note.body.clone();
    }
    queue_note_save(pending, notes, status, note);
}

fn replace_note_body(
    mut active_note: Signal<Option<Note>>,
    mut notes: Signal<Vec<Note>>,
    status: Signal<String>,
    pending: Signal<std::collections::HashMap<u64, PendingSave>>,
    id: u64,
    body: String,
) {
    let Some(mut note) = active_note.read().clone() else {
        return;
    };
    if note.id != id {
        return;
    }
    note.body = body;
    active_note.set(Some(note.clone()));
    if let Some(listed) = notes.write().iter_mut().find(|item| item.id == id) {
        listed.body = note.body.clone();
    }
    queue_note_save(pending, notes, status, note);
}

fn set_pin_state(
    mut notes: Signal<Vec<Note>>,
    mut active_note: Signal<Option<Note>>,
    mut status: Signal<String>,
    id: u64,
    pinned: bool,
) {
    spawn(async move {
        match set_note_pinned(id, pinned).await {
            Ok(true) => {
                if let Some(note) = notes.write().iter_mut().find(|note| note.id == id) {
                    note.pinned = pinned;
                }
                let opened_note = active_note.read().clone();
                if let Some(mut note) = opened_note.filter(|note| note.id == id) {
                    note.pinned = pinned;
                    active_note.set(Some(note));
                }
                status.set(if pinned { "Pinned" } else { "Unpinned" }.into());
            }
            Ok(false) => status.set("Note no longer exists".into()),
            Err(error) => status.set(format!("Could not update pin: {error}")),
        }
    });
}

fn move_note(
    mut notes: Signal<Vec<Note>>,
    mut status: Signal<String>,
    id: u64,
    delta: isize,
) {
    let mut ordered = notes.read().clone();
    let Some(index) = ordered.iter().position(|note| note.id == id) else {
        return;
    };
    let target = index.saturating_add_signed(delta);
    if target >= ordered.len() {
        return;
    }
    ordered.swap(index, target);
    for (position, note) in ordered.iter_mut().enumerate() {
        note.order = position as i64;
    }
    let ids = ordered.iter().map(|note| note.id).collect::<Vec<_>>();
    notes.set(ordered);
    status.set("Saving order…".into());
    spawn(async move {
        match save_note_order(ids).await {
            Ok(()) => status.set("Order saved".into()),
            Err(error) => {
                if let Ok(loaded) = load_notes().await {
                    notes.set(loaded);
                }
                status.set(format!("Could not reorder notes: {error}"));
            }
        }
    });
}

fn move_note_before(
    mut notes: Signal<Vec<Note>>,
    mut status: Signal<String>,
    id: u64,
    target_id: u64,
) {
    let mut ordered = notes.read().clone();
    let Some(from) = ordered.iter().position(|note| note.id == id) else {
        return;
    };
    let Some(target) = ordered.iter().position(|note| note.id == target_id) else {
        return;
    };
    if from == target {
        return;
    }
    let item = ordered.remove(from);
    let insertion = if from < target { target - 1 } else { target };
    ordered.insert(insertion, item);
    for (position, note) in ordered.iter_mut().enumerate() {
        note.order = position as i64;
    }
    let ids = ordered.iter().map(|note| note.id).collect::<Vec<_>>();
    notes.set(ordered);
    status.set("Saving order…".into());
    spawn(async move {
        match save_note_order(ids).await {
            Ok(()) => status.set("Order saved".into()),
            Err(error) => {
                if let Ok(loaded) = load_notes().await {
                    notes.set(loaded);
                }
                status.set(format!("Could not reorder notes: {error}"));
            }
        }
    });
}

fn utf16_to_byte(text: &str, index: usize) -> usize {
    let mut units = 0;
    for (byte, ch) in text.char_indices() {
        if units >= index {
            return byte;
        }
        units += ch.len_utf16();
        if units >= index {
            return byte + ch.len_utf8();
        }
    }
    text.len()
}

fn byte_to_utf16(text: &str, index: usize) -> usize {
    text.get(..index.min(text.len()))
        .unwrap_or(text)
        .encode_utf16()
        .count()
}

fn format_modified(timestamp: i64) -> String {
    let date = js_sys::Date::new(&JsValue::from_f64(timestamp as f64 * 1000.0));
    let now = js_sys::Date::new_0();
    if date.get_time().is_nan() {
        return timestamp.to_string();
    }
    let hour = date.get_hours();
    let minute = date.get_minutes();
    let twelve_hour = match hour % 12 {
        0 => 12,
        value => value,
    };
    let clock = format!(
        "{twelve_hour}:{minute:02} {}",
        if hour >= 12 { "PM" } else { "AM" }
    );
    if date.get_full_year() == now.get_full_year()
        && date.get_month() == now.get_month()
        && date.get_date() == now.get_date()
    {
        return clock;
    }
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let month = MONTHS
        .get(date.get_month() as usize)
        .copied()
        .unwrap_or("???");
    if date.get_full_year() == now.get_full_year() {
        format!("{month} {}", date.get_date())
    } else {
        format!("{month} {}, {}", date.get_date(), date.get_full_year())
    }
}

fn sort_label(sort: SortMode) -> &'static str {
    match sort {
        SortMode::ModifiedDesc => "Date",
        SortMode::TitleAsc => "Title",
        SortMode::CreatedDesc => "Created",
        SortMode::Manual => "Manual",
    }
}

pub fn App() -> Element {
    let mut notes = use_signal(Vec::<Note>::new);
    let mut trash = use_signal(Vec::<Note>::new);
    let mut settings = use_signal(AppSettings::default);
    let mut active_note = use_signal(|| None::<Note>);
    let mut query = use_signal(String::new);
    let mut show_search = use_signal(|| false);
    let mut find_open = use_signal(|| false);
    let mut replace_open = use_signal(|| false);
    let mut find_query = use_signal(String::new);
    let mut replace_query = use_signal(String::new);
    let mut selected_tag = use_signal(|| None::<String>);
    let mut show_tags = use_signal(|| true);
    let mut show_menu = use_signal(|| false);
    let mut show_sort_menu = use_signal(|| false);
    let mut show_settings = use_signal(|| false);
    let mut show_trash = use_signal(|| false);
    let mut confirm_action = use_signal(|| None::<ConfirmAction>);
    let mut editor_mode = use_signal(|| EditorMode::Edit);
    let mut close_prompt = use_signal(|| false);
    let mut remember_close = use_signal(|| false);
    let mut backup_path = use_signal(String::new);
    let mut file_path = use_signal(String::new);
    let mut rename_from = use_signal(String::new);
    let mut rename_to = use_signal(String::new);
    let list_entry = use_signal(String::new);
    let mut recovery_drafts = use_signal(Vec::<Note>::new);
    let mut recovery_note = use_signal(|| None::<Note>);
    let mut dragging_note = use_signal(|| None::<u64>);
    let pending_saves = use_signal(std::collections::HashMap::<u64, PendingSave>::new);
    let mut status = use_signal(|| "Loading notes…".to_string());

    use_hook(|| {
        let mut close_dialog = close_prompt;
        let close_listener = Closure::wrap(Box::new(move |_event: JsValue| {
            close_dialog.set(true);
        }) as Box<dyn FnMut(JsValue)>);
        let mut note_list = notes;
        let mut active = active_note;
        let mut message = status;
        let new_note_listener = Closure::wrap(Box::new(move |event: JsValue| {
            let id = js_sys::Reflect::get(&event, &JsValue::from_str("payload"))
                .ok()
                .and_then(|payload| serde_wasm_bindgen::from_value::<u64>(payload).ok());
            if let Some(id) = id {
                spawn(async move {
                    match load_notes().await {
                        Ok(loaded) => {
                            if let Some(note) = loaded.iter().find(|note| note.id == id).cloned() {
                                active.set(Some(note));
                            }
                            note_list.set(loaded);
                            message.set("New note".into());
                        }
                        Err(error) => message.set(format!("Could not load new note: {error}")),
                    }
                });
            }
        }) as Box<dyn FnMut(JsValue)>);
        let mut note_list = notes;
        let mut active = active_note;
        let mut message = status;
        let file_drop_listener = Closure::wrap(Box::new(move |event: JsValue| {
            let paths = js_sys::Reflect::get(&event, &JsValue::from_str("payload"))
                .ok()
                .and_then(|payload| serde_wasm_bindgen::from_value::<Vec<String>>(payload).ok())
                .unwrap_or_default();
            if paths.is_empty() {
                return;
            }
            spawn(async move {
                for path in paths {
                    match invoke_path::<Note>("add_markdown_file", &path).await {
                        Ok(note) => {
                            note_list.write().insert(0, note.clone());
                            active.set(Some(note));
                            message.set("File imported".into());
                        }
                        Err(error) => message.set(format!("Could not import file: {error}")),
                    }
                }
            });
        }) as Box<dyn FnMut(JsValue)>);
        let pending_queue = pending_saves;
        let mut quit_status = status;
        let quit_listener = Closure::wrap(Box::new(move |_event: JsValue| {
            spawn(async move {
                flush_pending_saves(pending_queue).await;
                if let Err(error) = resolve_close_request("quit", false).await {
                    quit_status.set(format!("Could not quit: {error}"));
                }
            });
        }) as Box<dyn FnMut(JsValue)>);
        let pending_queue = pending_saves;
        let mut update_status = status;
        let update_listener = Closure::wrap(Box::new(move |_event: JsValue| {
            spawn(async move {
                flush_pending_saves(pending_queue).await;
                if let Err(error) = install_update().await {
                    update_status.set(format!("Could not install update: {error}"));
                }
            });
        }) as Box<dyn FnMut(JsValue)>);
        spawn(async move {
            let _ = tauri_listen("terminote-close-requested", &close_listener).await;
            close_listener.forget();
        });
        spawn(async move {
            let _ = tauri_listen("terminote-new-note", &new_note_listener).await;
            new_note_listener.forget();
        });
        spawn(async move {
            let _ = tauri_listen("tauri://file-drop", &file_drop_listener).await;
            file_drop_listener.forget();
        });
        spawn(async move {
            let _ = tauri_listen("terminote-quit-requested", &quit_listener).await;
            quit_listener.forget();
        });
        spawn(async move {
            let _ = tauri_listen("terminote-update-ready", &update_listener).await;
            update_listener.forget();
        });

        let mut note_list = notes;
        let mut active = active_note;
        let mut message = status;
        let mut confirmation = confirm_action;
        let mut settings_view = show_settings;
        let mut trash_view = show_trash;
        let mut search_view = show_search;
        let mut find_panel = find_open;
        let mut replace_panel = replace_open;
        let pending_queue = pending_saves;
        let document = web_sys::window().and_then(|window| window.document());
        let search_document = document.clone();
        let keyboard_listener = Closure::wrap(Box::new(move |event: web_sys::KeyboardEvent| {
            let control = event.ctrl_key() || event.meta_key();
            let key = event.key().to_lowercase();
            if control && event.shift_key() && key == "d" {
                event.prevent_default();
                confirmation.set(Some(ConfirmAction::DeleteAll));
            } else if control && event.shift_key() && key == "n" {
                event.prevent_default();
                spawn(async move {
                    match add_note("To-Do List", "- [ ] ").await {
                        Ok(note) => {
                            note_list.write().insert(0, note.clone());
                            active.set(Some(note));
                            message.set("Saved".into());
                        }
                        Err(error) => message.set(format!("Could not add list: {error}")),
                    }
                });
            } else if control && key == "n" {
                event.prevent_default();
                spawn(async move {
                    match add_note("Untitled note", "").await {
                        Ok(note) => {
                            note_list.write().insert(0, note.clone());
                            active.set(Some(note));
                            message.set("Saved".into());
                        }
                        Err(error) => message.set(format!("Could not add note: {error}")),
                    }
                });
            } else if control && key == "f" {
                event.prevent_default();
                if active.read().is_some() {
                    find_panel.set(true);
                } else {
                    search_view.set(true);
                }
                let document = search_document.clone();
                spawn(async move {
                    TimeoutFuture::new(25).await;
                    if let Some(input) = document
                        .as_ref()
                        .and_then(|document| {
                            document
                                .get_element_by_id("note-find-input")
                                .or_else(|| document.get_element_by_id("search-input"))
                        })
                        .and_then(|element| element.dyn_into::<web_sys::HtmlInputElement>().ok())
                    {
                        let _ = input.focus();
                    }
                });
            } else if control && key == "h" && active.read().is_some() {
                event.prevent_default();
                find_panel.set(true);
                replace_panel.set(true);
                let document = search_document.clone();
                spawn(async move {
                    TimeoutFuture::new(25).await;
                    if let Some(input) = document
                        .as_ref()
                        .and_then(|document| document.get_element_by_id("note-find-input"))
                        .and_then(|element| element.dyn_into::<web_sys::HtmlInputElement>().ok())
                    {
                        let _ = input.focus();
                    }
                });
            } else if key == "f5" {
                let current_note = active.read().clone();
                if let Some(mut note) = current_note {
                    event.prevent_default();
                    if !note.body.is_empty() && !note.body.ends_with('\n') {
                        note.body.push('\n');
                    }
                    let timestamp = (js_sys::Date::new_0().get_time() / 1000.0) as i64;
                    note.body.push_str(&format_modified(timestamp));
                    if let Some(item) = note_list.write().iter_mut().find(|item| item.id == note.id) {
                        item.body = note.body.clone();
                    }
                    active.set(Some(note.clone()));
                    queue_note_save(pending_queue, note_list, message, note);
                }
            } else if key == "escape" {
                if *find_panel.read() {
                    find_panel.set(false);
                    replace_panel.set(false);
                } else {
                    active.set(None);
                }
                settings_view.set(false);
                trash_view.set(false);
            }
        }) as Box<dyn FnMut(web_sys::KeyboardEvent)>);
        if let Some(document) = document {
            let _ = document.add_event_listener_with_callback(
                "keydown",
                keyboard_listener.as_ref().unchecked_ref(),
            );
            keyboard_listener.forget();
        }
    });

    use_effect(move || {
        spawn(async move {
            match (load_notes().await, load_settings().await) {
                (Ok(loaded), Ok(saved_settings)) => {
                    let count = loaded.len();
                    let drafts = load_recovery_drafts()
                        .await
                        .unwrap_or_default()
                        .into_iter()
                        .filter(|draft| {
                            loaded
                                .iter()
                                .find(|note| note.id == draft.id)
                                .is_none_or(|note| draft.modified > note.modified)
                        })
                        .collect::<Vec<_>>();
                    if let Some(draft) = drafts.first() {
                        recovery_note.set(Some(draft.clone()));
                    }
                    recovery_drafts.set(drafts);
                    let check_updates = saved_settings.auto_update;
                    notes.set(loaded);
                    settings.set(saved_settings);
                    status.set(format!("{count} notes loaded"));
                    if check_updates {
                        spawn(start_update_check());
                    }
                }
                (Err(error), _) | (_, Err(error)) => {
                    status.set(format!("Could not load TermiNote data: {error}"));
                }
            }
        });
    });

    let all_tags = {
        let mut tags = std::collections::BTreeMap::<String, usize>::new();
        for note in notes.read().iter() {
            for tag in &note.tags {
                *tags.entry(tag.clone()).or_default() += 1;
            }
        }
        tags
    };
    let tag_rows: Vec<(String, usize, bool)> = all_tags
        .iter()
        .map(|(tag, count)| {
            (
                tag.clone(),
                *count,
                selected_tag.read().as_ref() == Some(tag),
            )
        })
        .collect();
    let search = query.read().to_lowercase();
    let tag_filter = selected_tag.read().clone();
    let mut visible: Vec<Note> = notes
        .read()
        .iter()
        .filter(|note| {
            let matches_search = search.is_empty()
                || note.title.to_lowercase().contains(&search)
                || note.body.to_lowercase().contains(&search)
                || note.tags.iter().any(|tag| tag.contains(&search));
            let matches_tag = match tag_filter.as_deref() {
                Some("") => note.tags.is_empty(),
                Some(tag) => note.tags.iter().any(|value| value == tag),
                None => true,
            };
            matches_search && matches_tag
        })
        .cloned()
        .collect();
    let sort = settings.read().sort;
    visible.sort_by(|left, right| {
        let pin_order = right.pinned.cmp(&left.pinned);
        if pin_order != std::cmp::Ordering::Equal {
            return pin_order;
        }
        match sort {
            SortMode::ModifiedDesc => right.modified.cmp(&left.modified),
            SortMode::TitleAsc => left.title.to_lowercase().cmp(&right.title.to_lowercase()),
            SortMode::CreatedDesc => right.created.cmp(&left.created),
            SortMode::Manual => left.order.cmp(&right.order),
        }
    });

    rsx! {
        link { rel: "stylesheet", href: CSS }
        main { class: "app-shell",
            if *show_settings.read() {
                header { class: "home-header",
                    h1 { "Settings" }
                    button {
                        class: "icon-button",
                        title: "Back",
                        onclick: move |_| show_settings.set(false),
                        "←"
                    }
                }
            } else if *show_trash.read() {
                header { class: "home-header",
                    h1 { "Recycle Bin" }
                    button {
                        class: "icon-button",
                        title: "Back",
                        onclick: move |_| show_trash.set(false),
                        "←"
                    }
                }
            } else {
                header { class: "home-header",
                    h1 { "My Notes" }
                    if *show_search.read() {
                        input {
                            id: "search-input",
                            class: "search",
                            aria_label: "Search notes",
                            placeholder: "Search notes",
                            value: "{query}",
                            oninput: move |event| query.set(event.value())
                        }
                    }
                    button {
                        class: "icon-button",
                        title: "Search notes",
                        onclick: move |_| {
                            let next = !*show_search.read();
                            show_search.set(next);
                        },
                        "⌕"
                    }
                    button {
                        class: "icon-button",
                        title: if *show_tags.read() { "Hide note tags" } else { "Show note tags" },
                        onclick: move |_| {
                            let next = !*show_tags.read();
                            show_tags.set(next);
                        },
                        "☰"
                    }
                    button {
                        class: "icon-button",
                        title: "More actions",
                        onclick: move |_| {
                            let next = !*show_menu.read();
                            show_menu.set(next);
                        },
                        "⋮"
                    }
                    button {
                        class: "icon-button",
                        title: "Settings",
                        onclick: move |_| show_settings.set(true),
                        "⚙"
                    }
                }
            }

            datalist { id: "tag-suggestions",
                for tag in all_tags.keys() {
                    option { value: "{tag}" }
                }
            }

            if !*show_settings.read() && !*show_trash.read() && *show_tags.read() && !all_tags.is_empty() {
                section { class: "tag-panel",
                    button {
                        class: "tag-panel-title",
                        onclick: move |_| selected_tag.set(None),
                        span { "›" }
                        span { "Note Tags" }
                    }
                    for (tag_name, count, selected) in tag_rows {
                        button {
                            class: if selected { "tag-row selected" } else { "tag-row" },
                            key: "{tag_name}",
                            onclick: move |_| selected_tag.set(Some(tag_name.clone())),
                            span { class: "tag-icon", "◆" }
                            span { "{tag_name}" }
                            span { class: "tag-count", "{count}" }
                        }
                    }
                    button {
                        class: "tag-row",
                        onclick: move |_| selected_tag.set(Some(String::new())),
                        span { class: "tag-icon", "◆" }
                        span { "Untagged" }
                        span { class: "tag-count", "{notes.read().iter().filter(|note| note.tags.is_empty()).count()}" }
                    }
                }
            }

            if !*show_settings.read() && !*show_trash.read() {
              div { class: "command-row",
                button {
                    class: "command",
                    onclick: move |_| async move {
                        match add_note("Untitled note", "").await {
                            Ok(note) => {
                                notes.write().insert(0, note.clone());
                                active_note.set(Some(note));
                                status.set("Saved".into());
                            }
                            Err(error) => status.set(format!("Could not add note: {error}")),
                        }
                    },
                    span { class: "command-icon", "+" }
                    span { "Add note" }
                    span { class: "shortcut", "Ctrl+N" }
                }
                if *show_menu.read() {
                    div { class: "menu-popover",
                        button {
                            class: "menu-item",
                            onclick: move |_| async move {
                                show_menu.set(false);
                                match load_trash().await {
                                    Ok(loaded) => {
                                        trash.set(loaded);
                                        show_trash.set(true);
                                    }
                                    Err(error) => status.set(format!("Could not open Trash: {error}")),
                                }
                            },
                            "▤  Recycle Bin"
                        }
                        button {
                            class: "menu-item",
                            onclick: move |_| async move {
                                show_menu.set(false);
                                match add_note("To-Do List", "- [ ] ").await {
                                    Ok(note) => {
                                        notes.write().insert(0, note.clone());
                                        active_note.set(Some(note));
                                        status.set("Saved".into());
                                    }
                                    Err(error) => status.set(format!("Could not add list: {error}")),
                                }
                            },
                            "☑  New to-do list"
                        }
                        button {
                            class: "menu-item",
                            onclick: move |_| {
                                show_menu.set(false);
                                confirm_action.set(Some(ConfirmAction::DeleteAll));
                            },
                            "▧  Delete all notes"
                        }
                    }
                }
              }
            }

            if *show_settings.read() {
                section { class: "settings-panel",
                    p { "Sort order" }
                    label { class: "setting-choice",
                        input {
                            r#type: "radio",
                            name: "sort",
                            checked: settings.read().sort == SortMode::ModifiedDesc,
                            onchange: move |_| change_setting(settings, status, |value| value.sort = SortMode::ModifiedDesc)
                        }
                        "Newest changed first"
                    }
                    label { class: "setting-choice",
                        input {
                            r#type: "radio",
                            name: "sort",
                            checked: settings.read().sort == SortMode::TitleAsc,
                            onchange: move |_| change_setting(settings, status, |value| value.sort = SortMode::TitleAsc)
                        }
                        "Title A to Z"
                    }
                    label { class: "setting-choice",
                        input {
                            r#type: "radio",
                            name: "sort",
                            checked: settings.read().sort == SortMode::CreatedDesc,
                            onchange: move |_| change_setting(settings, status, |value| value.sort = SortMode::CreatedDesc)
                        }
                        "Newest created first"
                    }
                    label { class: "setting-choice",
                        input {
                            r#type: "radio",
                            name: "sort",
                            checked: settings.read().sort == SortMode::Manual,
                            onchange: move |_| change_setting(settings, status, |value| value.sort = SortMode::Manual)
                        }
                        "My drag order"
                    }

                    p { "Text size" }
                    div { class: "text-size-control",
                        button {
                            class: "text-size-button",
                            title: "Smaller text",
                            onclick: move |_| change_setting(settings, status, |value| value.text_size = (value.text_size - 1.0).clamp(12.0, 28.0)),
                            "A−"
                        }
                        span { "{settings.read().text_size as i32} pt — new notes open at this size; A− / A+ in the editor change it too." }
                        button {
                            class: "text-size-button",
                            title: "Bigger text",
                            onclick: move |_| change_setting(settings, status, |value| value.text_size = (value.text_size + 1.0).clamp(12.0, 28.0)),
                            "A+"
                        }
                    }

                    p { "System tray" }
                    div { class: "setting-choice setting-toggle",
                        span { "Minimize to the system tray" }
                        button {
                            class: if settings.read().minimize_to_tray { "toggle on" } else { "toggle" },
                            onclick: move |_| change_setting(settings, status, |value| value.minimize_to_tray = !value.minimize_to_tray),
                            if settings.read().minimize_to_tray { "ON" } else { "OFF" }
                        }
                    }
                    p { class: "settings-hint", "The tray icon can restore TermiNote, start a note, or quit." }

                    p { "When I click the X button" }
                    for (action, label) in [("ask", "Ask every time"), ("quit", "Quit TermiNote"), ("tray", "Minimize to the system tray")] {
                        label { class: "setting-choice",
                            input {
                                r#type: "radio",
                                name: "close-action",
                                checked: settings.read().close_action == action,
                                disabled: action == "tray" && !settings.read().minimize_to_tray,
                                onchange: move |_| change_setting(settings, status, move |value| value.close_action = action.into())
                            }
                            "{label}"
                        }
                    }

                    p { "Manage tags" }
                    div { class: "tag-rename-row",
                        input {
                            class: "editor-tags",
                            value: "{rename_from}",
                            placeholder: "Existing tag",
                            list: "tag-suggestions",
                            oninput: move |event| rename_from.set(event.value())
                        }
                        input {
                            class: "editor-tags",
                            value: "{rename_to}",
                            placeholder: "New tag name",
                            oninput: move |event| rename_to.set(event.value())
                        }
                        button {
                            class: "cancel-button",
                            onclick: move |_| async move {
                                let old = rename_from.read().trim().to_string();
                                let new = rename_to.read().trim().to_string();
                                if old.is_empty() || new.is_empty() {
                                    status.set("Enter both tag names".into());
                                } else {
                                    match rename_tag(&old, &new).await {
                                        Ok(count) => {
                                            if let Ok(items) = load_notes().await { notes.set(items); }
                                            status.set(format!("Renamed tag on {count} notes"));
                                            rename_from.set(String::new());
                                            rename_to.set(String::new());
                                        }
                                        Err(error) => status.set(format!("Could not rename tag: {error}")),
                                    }
                                }
                            },
                            "Rename tag"
                        }
                    }
                    for (tag_name, count) in all_tags.iter() {
                        {
                            let tag_for_delete = tag_name.clone();
                            rsx! {
                                div { class: "managed-tag", key: "{tag_name}",
                                    span { "{tag_name} · {count}" }
                                    button {
                                        class: "delete-button",
                                        title: "Remove tag from all notes",
                                        onclick: move |_| {
                                            let tag = tag_for_delete.clone();
                                            async move {
                                                match delete_tag(&tag).await {
                                                    Ok(count) => {
                                                        if let Ok(items) = load_notes().await { notes.set(items); }
                                                        status.set(format!("Removed tag from {count} notes"));
                                                    }
                                                    Err(error) => status.set(format!("Could not remove tag: {error}")),
                                                }
                                            }
                                        },
                                        "×"
                                    }
                                }
                            }
                        }
                    }

                    p { "Updates" }
                    div { class: "setting-choice setting-toggle",
                        span { "Install updates automatically" }
                        button {
                            class: if settings.read().auto_update { "toggle on" } else { "toggle" },
                            onclick: move |_| change_setting(settings, status, |value| value.auto_update = !value.auto_update),
                            if settings.read().auto_update { "ON" } else { "OFF" }
                        }
                    }
                    p { "Backups" }
                    input {
                        class: "editor-title path-input",
                        value: "{backup_path}",
                        placeholder: "Backup folder path",
                        oninput: move |event| backup_path.set(event.value())
                    }
                    div { class: "data-actions",
                        button {
                            class: "cancel-button",
                            onclick: move |_| async move {
                                let path = backup_path.read().trim().to_string();
                                if path.is_empty() {
                                    status.set("Enter a backup folder path".into());
                                } else {
                                    match invoke_path::<usize>("backup_to", &path).await {
                                        Ok(count) => status.set(format!("Backed up {count} items")),
                                        Err(error) => status.set(format!("Backup failed: {error}")),
                                    }
                                }
                            },
                            "Create backup"
                        }
                        button {
                            class: "delete-button",
                            disabled: backup_path.read().trim().is_empty(),
                            onclick: move |_| confirm_action.set(Some(ConfirmAction::RestoreBackup)),
                            "Restore backup"
                        }
                    }
                    p { "Import or export" }
                    input {
                        class: "editor-title path-input",
                        value: "{file_path}",
                        placeholder: "Markdown, text, or JSON file path",
                        oninput: move |event| file_path.set(event.value())
                    }
                    div { class: "data-actions",
                        button {
                            class: "cancel-button",
                            onclick: move |_| async move {
                                let path = file_path.read().trim().to_string();
                                if path.is_empty() {
                                    status.set("Enter a file path".into());
                                } else {
                                    match invoke_path::<usize>("export_notes", &path).await {
                                        Ok(count) => status.set(format!("Exported {count} notes")),
                                        Err(error) => status.set(format!("Export failed: {error}")),
                                    }
                                }
                            },
                            "Export JSON"
                        }
                        button {
                            class: "cancel-button",
                            onclick: move |_| async move {
                                let path = file_path.read().trim().to_string();
                                if path.is_empty() {
                                    status.set("Enter a file path".into());
                                } else {
                                    match invoke_path::<ImportResult>("import_notes", &path).await {
                                        Ok(result) => {
                                            if let Ok(items) = load_notes().await { notes.set(items); }
                                            status.set(format!("Imported {}; skipped {}", result.imported, result.skipped));
                                        }
                                        Err(error) => status.set(format!("Import failed: {error}")),
                                    }
                                }
                            },
                            "Import JSON"
                        }
                        button {
                            class: "cancel-button",
                            onclick: move |_| async move {
                                let path = file_path.read().trim().to_string();
                                if path.is_empty() {
                                    status.set("Enter a file path".into());
                                } else {
                                    match invoke_path::<Note>("add_markdown_file", &path).await {
                                        Ok(note) => {
                                            notes.write().insert(0, note.clone());
                                            active_note.set(Some(note));
                                            status.set("File imported".into());
                                        }
                                        Err(error) => status.set(format!("Import failed: {error}")),
                                    }
                                }
                            },
                            "Add .md / .txt"
                        }
                    }
                    p { class: "settings-hint", "Your settings use TermiNote’s existing settings.json format." }
                    p { class: "saved-status", "{status}" }
                }
            } else if *show_trash.read() {
                div { class: "notes-heading",
                    span { "{trash.read().len()} Items" }
                    button {
                        class: "sort-button",
                        disabled: trash.read().is_empty(),
                        onclick: move |_| confirm_action.set(Some(ConfirmAction::EmptyTrash)),
                        "Empty Trash"
                    }
                }
                div { class: "note-list trash-list",
                    if trash.read().is_empty() {
                        div { class: "empty-state", h2 { "Trash is empty" } }
                    }
                    for note in trash.read().iter() {
                        {
                            let id = note.id;
                            let title = note.title.clone();
                            let preview = note.body.lines().next().unwrap_or("").to_string();
                            let mut trashed = trash;
                            let mut live = notes;
                            let mut status = status;
                            rsx! {
                                article { class: "trash-card", key: "{id}",
                                    div { class: "trash-copy",
                                        strong { "{title}" }
                                        if !preview.is_empty() { p { class: "note-preview", "{preview}" } }
                                    }
                                    div { class: "trash-actions",
                                        button {
                                            class: "icon-button",
                                            title: "Restore note",
                                            onclick: move |_| async move {
                                                match invoke_id("restore_note", id).await {
                                                    Ok(true) => {
                                                        trashed.write().retain(|item| item.id != id);
                                                        if let Ok(items) = load_notes().await { live.set(items); }
                                                        status.set("Note restored".into());
                                                    }
                                                    Ok(false) => status.set("Note is no longer in Trash".into()),
                                                    Err(error) => status.set(format!("Could not restore note: {error}")),
                                                }
                                            },
                                            "↶"
                                        }
                                        button {
                                            class: "delete-button",
                                            title: "Delete permanently",
                                            onclick: move |_| confirm_action.set(Some(ConfirmAction::DeleteForever(id))),
                                            "▣"
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                p { class: "saved-status", "{status}" }
            } else {
                div { class: "notes-heading",
                    span { "{visible.len()} Items" }
                    div { class: "sort-control",
                        button {
                            class: "sort-button",
                            onclick: move |_| {
                                let next = !*show_sort_menu.read();
                                show_sort_menu.set(next);
                            },
                            "☰ {sort_label(settings.read().sort)}"
                        }
                        if *show_sort_menu.read() {
                            div { class: "sort-popover",
                                for (mode, label) in [
                                    (SortMode::ModifiedDesc, "Newest changed"),
                                    (SortMode::TitleAsc, "Title A to Z"),
                                    (SortMode::CreatedDesc, "Newest created"),
                                    (SortMode::Manual, "My drag order"),
                                ] {
                                    button {
                                        class: if settings.read().sort == mode { "sort-option selected" } else { "sort-option" },
                                        onclick: move |_| {
                                            set_sort_mode(settings, status, mode);
                                            show_sort_menu.set(false);
                                        },
                                        "{label}"
                                    }
                                }
                            }
                        }
                    }
                }
                div { class: "note-list",
                    if visible.is_empty() {
                        div { class: "empty-state",
                            h2 { if notes.read().is_empty() { "No notes yet" } else { "Nothing matches" } }
                            p { "Select + to write a note." }
                        }
                    }
                    for note in visible {
                        {
                            let id = note.id;
                            let is_open = active_note.read().as_ref().is_some_and(|current| current.id == id);
                            let kind_note = note.clone();
                            let title_note = note.clone();
                            let title_seed = note.clone();
                            let tags_seed = note.clone();
                            let body_seed = note.clone();
                                            let pin_target = !note.pinned;
                                            let numbered_body = terminote_core::markdown::to_numbered_list(&note.body);
                                            let bullet_body = terminote_core::markdown::to_bullet_list(&note.body);
                                            let toc_body = terminote_core::markdown::insert_toc(&note.body);
                            rsx! {
                                article {
                                    class: if is_open { "note-card expanded" } else { "note-card" },
                                    key: "{id}",
                                    draggable: settings.read().sort == SortMode::Manual,
                                    ondragstart: move |_| dragging_note.set(Some(id)),
                                    ondragover: move |event| event.prevent_default(),
                                    ondrop: move |event| {
                                        event.prevent_default();
                                        if let Some(source) = *dragging_note.read() {
                                            move_note_before(notes, status, source, id);
                                        }
                                        dragging_note.set(None);
                                    },
                                    ondragend: move |_| dragging_note.set(None),
                                    div { class: "note-summary",
                                        button {
                                            class: "note-kind",
                                            title: "Open note",
                                            onclick: move |_| active_note.set(Some(kind_note.clone())),
                                                if note.body.contains("- [ ]") || note.body.contains("- [x]") || note.body.contains("- [X]") { "☑" } else { "✎" }
                                        }
                                        div { class: "note-copy",
                                            button {
                                                class: "note-title",
                                                    onclick: move |_| {
                                                        if is_open {
                                                            active_note.set(None);
                                                        } else {
                                                            active_note.set(Some(title_note.clone()));
                                                        }
                                                    },
                                                "{note.title}"
                                            }
                                            if !note.body.is_empty() {
                                                p { class: "note-preview", "{note.body.lines().next().unwrap_or(\"\")}" }
                                            }
                                        }
                                        time { class: "note-time", "{format_modified(note.modified)}" }
                                        button {
                                            class: if note.pinned { "pin-button active" } else { "pin-button" },
                                            title: if note.pinned { "Unpin note" } else { "Pin note" },
                                            onclick: move |_| set_pin_state(notes, active_note, status, id, pin_target),
                                            if note.pinned { "◆" } else { "◇" }
                                        }
                                        if settings.read().sort == SortMode::Manual {
                                            button {
                                                class: "order-button",
                                                title: "Move note up",
                                                onclick: move |_| move_note(notes, status, id, -1),
                                                "↑"
                                            }
                                            button {
                                                class: "order-button",
                                                title: "Move note down",
                                                onclick: move |_| move_note(notes, status, id, 1),
                                                "↓"
                                            }
                                        }
                                    }
                                    if is_open {
                                        {
                                            let mut title_edit = active_note;
                                            let mut tags_edit = active_note;
                                            let mut body_edit = active_note;
                                            let mut title_list = notes;
                                            let mut tags_list = notes;
                                            let mut body_list = notes;
                                            let title_status = status;
                                            let tags_status = status;
                                            let body_status = status;
                                            let preview_html = terminote_core::markdown::markdown_html(&note.body);
                                            let mode = *editor_mode.read();
                                            let find_text = find_query.read().clone();
                                            let replace_text = replace_query.read().clone();
                                            let find_count = if find_text.is_empty() { 0 } else { note.body.matches(&find_text).count() };
                                            let replace_one_body = note.body.replacen(&find_text, &replace_text, 1);
                                            let replace_all_body = note.body.replace(&find_text, &replace_text);
                                            let bold_active = active_note;
                                            let italic_active = active_note;
                                            let strike_active = active_note;
                                            let code_active = active_note;
                                            let heading_active = active_note;
                                            let link_active = active_note;
                                            let quote_active = active_note;
                                            let checklist_active = active_note;
                                            let bold_notes = notes;
                                            let italic_notes = notes;
                                            let strike_notes = notes;
                                            let code_notes = notes;
                                            let heading_notes = notes;
                                            let link_notes = notes;
                                            let quote_notes = notes;
                                            let checklist_notes = notes;
                                            rsx! {
                                                div { class: "inline-editor",
                                                    input {
                                                        class: "editor-title",
                                                        value: "{note.title}",
                                                        oninput: move |event| {
                                                            let value = event.value();
                                                            let mut updated = title_edit.read().clone().unwrap_or_else(|| title_seed.clone());
                                                            updated.title = value.clone();
                                                            title_edit.set(Some(updated.clone()));
                                                            if let Some(item) = title_list.write().iter_mut().find(|item| item.id == updated.id) {
                                                                item.title = value;
                                                            }
                                                            queue_note_save(pending_saves, notes, title_status, updated);
                                                        }
                                                    }
                                                    input {
                                                        class: "editor-tags",
                                                        value: "{note.tags.join(\", \")}",
                                                        placeholder: "Tags",
                                                        list: "tag-suggestions",
                                                        oninput: move |event| {
                                                            let value = event.value();
                                                            let tags = terminote_core::parse_tags(&value);
                                                            let mut updated = tags_edit.read().clone().unwrap_or_else(|| tags_seed.clone());
                                                            updated.tags = tags;
                                                            tags_edit.set(Some(updated.clone()));
                                                            if let Some(item) = tags_list.write().iter_mut().find(|item| item.id == updated.id) {
                                                                item.tags = updated.tags.clone();
                                                            }
                                                            queue_note_save(pending_saves, notes, tags_status, updated);
                                                        }
                                                    }
                                                    if *find_open.read() {
                                                        div { class: "note-find",
                                                            input {
                                                                id: "note-find-input",
                                                                class: "find-input",
                                                                value: "{find_query}",
                                                                placeholder: "Find in note",
                                                                oninput: move |event| find_query.set(event.value())
                                                            }
                                                            span { class: "find-count", "{find_count} matches" }
                                                            if *replace_open.read() {
                                                                input {
                                                                    class: "find-input",
                                                                    value: "{replace_query}",
                                                                    placeholder: "Replace with",
                                                                    oninput: move |event| replace_query.set(event.value())
                                                                }
                                                                button {
                                                                    class: "format-button",
                                                                    disabled: find_text.is_empty(),
                                                                    onclick: move |_| replace_note_body(active_note, notes, status, pending_saves, id, replace_one_body.clone()),
                                                                    "Replace"
                                                                }
                                                                button {
                                                                    class: "format-button",
                                                                    disabled: find_text.is_empty(),
                                                                    onclick: move |_| replace_note_body(active_note, notes, status, pending_saves, id, replace_all_body.clone()),
                                                                    "All"
                                                                }
                                                            }
                                                            button {
                                                                class: "format-button",
                                                                title: "Close find",
                                                                onclick: move |_| find_open.set(false),
                                                                "×"
                                                            }
                                                        }
                                                    }
                                                    div { class: "editor-toolbar",
                                                        button { class: if mode == EditorMode::Edit { "editor-tab active" } else { "editor-tab" }, onclick: move |_| editor_mode.set(EditorMode::Edit), "EDIT" }
                                                        button { class: if mode == EditorMode::Split { "editor-tab active" } else { "editor-tab" }, onclick: move |_| editor_mode.set(EditorMode::Split), "SPLIT" }
                                                        button { class: if mode == EditorMode::Preview { "editor-tab active" } else { "editor-tab" }, onclick: move |_| editor_mode.set(EditorMode::Preview), "PREVIEW" }
                                                        span { class: "toolbar-divider" }
                                                        button { class: "format-button", title: "Bold", onclick: move |_| format_note_body(bold_active, bold_notes, status, pending_saves, id, MarkdownFormat::Bold), "B" }
                                                        button { class: "format-button", title: "Italic", onclick: move |_| format_note_body(italic_active, italic_notes, status, pending_saves, id, MarkdownFormat::Italic), "I" }
                                                        button { class: "format-button", title: "Strikethrough", onclick: move |_| format_note_body(strike_active, strike_notes, status, pending_saves, id, MarkdownFormat::Strike), "S" }
                                                        button { class: "format-button", title: "Code", onclick: move |_| format_note_body(code_active, code_notes, status, pending_saves, id, MarkdownFormat::Code), "</>" }
                                                        button { class: "format-button", title: "Heading", onclick: move |_| format_note_body(heading_active, heading_notes, status, pending_saves, id, MarkdownFormat::Heading), "H" }
                                                        button { class: "format-button", title: "Link", onclick: move |_| format_note_body(link_active, link_notes, status, pending_saves, id, MarkdownFormat::Link), "LINK" }
                                                        button { class: "format-button", title: "Quote", onclick: move |_| format_note_body(quote_active, quote_notes, status, pending_saves, id, MarkdownFormat::Quote), ">" }
                                                        button { class: "format-button", title: "Checklist", onclick: move |_| format_note_body(checklist_active, checklist_notes, status, pending_saves, id, MarkdownFormat::Checklist), "☑" }
                                                        button {
                                                            class: "format-button",
                                                            title: "Toggle numbered list",
                                                            onclick: move |_| replace_note_body(active_note, notes, status, pending_saves, id, numbered_body.clone()),
                                                            "1."
                                                        }
                                                        button {
                                                            class: "format-button",
                                                            title: "Toggle bullet list",
                                                            onclick: move |_| replace_note_body(active_note, notes, status, pending_saves, id, bullet_body.clone()),
                                                            "•"
                                                        }
                                                        button {
                                                            class: "format-button",
                                                            title: "Insert table of contents",
                                                            onclick: move |_| replace_note_body(active_note, notes, status, pending_saves, id, toc_body.clone()),
                                                            "TOC"
                                                        }
                                                        button {
                                                            class: "format-button",
                                                            title: "Find and replace",
                                                            onclick: move |_| {
                                                                find_open.set(true);
                                                                replace_open.set(true);
                                                            },
                                                            "FIND"
                                                        }
                                                    }
                                                    div { class: if mode == EditorMode::Split { "editor-content split" } else { "editor-content" },
                                                        if mode != EditorMode::Preview {
                                                            if let Some(items) = parse_checklist(&note.body) {
                                                                {checklist_editor(id, items, active_note, notes, status, pending_saves, list_entry)}
                                                            } else {
                                                                textarea {
                                                                    id: "body-{id}",
                                                                    class: "editor-body",
                                                                    value: "{note.body}",
                                                                    placeholder: "Write a note…",
                                                                    style: format!("font-size: {}pt", settings.read().text_size),
                                                                    oninput: move |event| {
                                                                        let value = event.value();
                                                                        let mut updated = body_edit.read().clone().unwrap_or_else(|| body_seed.clone());
                                                                        updated.body = value.clone();
                                                                        body_edit.set(Some(updated.clone()));
                                                                        if let Some(item) = body_list.write().iter_mut().find(|item| item.id == updated.id) {
                                                                            item.body = value;
                                                                        }
                                                                        queue_note_save(pending_saves, notes, body_status, updated);
                                                                    }
                                                                }
                                                            }
                                                        }
                                                        if mode != EditorMode::Edit {
                                                            div { class: "markdown-preview", dangerous_inner_html: preview_html }
                                                        }
                                                    }
                                                    div { class: "editor-footer",
                                                        span { class: "saved-status", "{note.body.split_whitespace().count()} words · {note.body.encode_utf16().count()} chars" }
                                                        span { class: "saved-status", "{status}" }
                                                        button {
                                                            class: "delete-button",
                                                            title: "Move note to Trash",
                                                            onclick: move |_| async move {
                                                                match invoke_id("move_to_trash", id).await {
                                                                    Ok(true) => {
                                                                        notes.write().retain(|item| item.id != id);
                                                                        active_note.set(None);
                                                                        status.set("Moved to Trash".into());
                                                                    }
                                                                    Ok(false) => status.set("Note no longer exists".into()),
                                                                    Err(error) => status.set(format!("Could not move note: {error}")),
                                                                }
                                                            },
                                                            "▣"
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                button {
                    class: "add-fab",
                    title: "Add note",
                    onclick: move |_| async move {
                        match add_note("Untitled note", "").await {
                            Ok(note) => {
                                notes.write().insert(0, note.clone());
                                active_note.set(Some(note));
                                status.set("Saved".into());
                            }
                            Err(error) => status.set(format!("Could not add note: {error}")),
                        }
                    },
                    "+"
                }
            }
            if *close_prompt.read() {
                div { class: "confirm-backdrop",
                    section { class: "confirm-dialog",
                        h2 { "Close TermiNote?" }
                        p { "Keep it running in the system tray, or quit now." }
                        div { class: "setting-choice setting-toggle",
                            span { "Remember this choice" }
                            button {
                                class: if *remember_close.read() { "toggle on" } else { "toggle" },
                                onclick: move |_| {
                                    let next = !*remember_close.read();
                                    remember_close.set(next);
                                },
                                if *remember_close.read() { "ON" } else { "OFF" }
                            }
                        }
                        div { class: "confirm-actions",
                            button {
                                class: "cancel-button",
                                onclick: move |_| {
                                    close_prompt.set(false);
                                    remember_close.set(false);
                                },
                                "Cancel"
                            }
                            button {
                                class: "cancel-button",
                                onclick: move |_| async move {
                                    match resolve_close_request("tray", *remember_close.read()).await {
                                        Ok(()) => close_prompt.set(false),
                                        Err(error) => status.set(format!("Could not minimize: {error}")),
                                    }
                                    remember_close.set(false);
                                },
                                "Minimize to tray"
                            }
                            button {
                                class: "confirm-button",
                                onclick: move |_| async move {
                                    flush_pending_saves(pending_saves).await;
                                    match resolve_close_request("quit", *remember_close.read()).await {
                                        Ok(()) => close_prompt.set(false),
                                        Err(error) => status.set(format!("Could not quit: {error}")),
                                    }
                                    remember_close.set(false);
                                },
                                "Quit"
                            }
                        }
                    }
                }
            }
            if let Some(draft) = recovery_note.read().clone() {
                div { class: "confirm-backdrop",
                    section { class: "confirm-dialog",
                        h2 { "Recover unsaved note?" }
                        p { "A newer recovery draft exists for “{draft.title}”. Recover it or discard the draft." }
                        div { class: "confirm-actions",
                            button {
                                class: "cancel-button",
                                onclick: move |_| recovery_note.set(None),
                                "Later"
                            }
                            button {
                                class: "cancel-button",
                                onclick: move |_| async move {
                                    match discard_recovery_draft(draft.id).await {
                                        Ok(()) => {
                                            recovery_drafts.write().retain(|item| item.id != draft.id);
                                            recovery_note.set(recovery_drafts.read().first().cloned());
                                            status.set("Recovery draft discarded".into());
                                        }
                                        Err(error) => status.set(format!("Could not discard draft: {error}")),
                                    }
                                },
                                "Discard draft"
                            }
                            button {
                                class: "confirm-button",
                                onclick: move |_| async move {
                                    match recover_draft(draft.id).await {
                                        Ok(Some(note)) => {
                                            if let Ok(items) = load_notes().await { notes.set(items); }
                                            recovery_drafts.write().retain(|item| item.id != draft.id);
                                            recovery_note.set(recovery_drafts.read().first().cloned());
                                            active_note.set(Some(note));
                                            status.set("Recovery draft restored".into());
                                        }
                                        Ok(None) => status.set("Recovery draft is no longer available".into()),
                                        Err(error) => status.set(format!("Could not recover draft: {error}")),
                                    }
                                },
                                "Recover"
                            }
                        }
                    }
                }
            }
            if let Some(action) = *confirm_action.read() {
                div { class: "confirm-backdrop",
                    section { class: "confirm-dialog",
                        h2 {
                            match action {
                                ConfirmAction::DeleteAll => "Delete all notes?",
                                ConfirmAction::EmptyTrash => "Empty the trash?",
                                ConfirmAction::DeleteForever(_) => "Delete this note for good?",
                                ConfirmAction::RestoreBackup => "Restore this backup?",
                            }
                        }
                        p {
                            match action {
                                ConfirmAction::DeleteAll => "Notes move to Trash. You can restore them later.",
                                ConfirmAction::EmptyTrash | ConfirmAction::DeleteForever(_) => "This cannot be undone.",
                                ConfirmAction::RestoreBackup => "Live notes will be replaced. A safety backup of the current notebook will be kept.",
                            }
                        }
                        div { class: "confirm-actions",
                            button {
                                class: "cancel-button",
                                onclick: move |_| confirm_action.set(None),
                                "Cancel"
                            }
                            button {
                                class: "confirm-button",
                                onclick: move |_| async move {
                                    confirm_action.set(None);
                                    match action {
                                        ConfirmAction::DeleteAll => {
                                            match delete_all_notes().await {
                                                Ok(count) => {
                                                    notes.set(Vec::new());
                                                    match load_trash().await {
                                                        Ok(items) => trash.set(items),
                                                        Err(error) => status.set(format!("Moved notes, but could not refresh Trash: {error}")),
                                                    }
                                                    status.set(format!("Moved {count} notes to Trash"));
                                                }
                                                Err(error) => status.set(format!("Delete failed: {error}")),
                                            }
                                        }
                                        ConfirmAction::EmptyTrash => {
                                            match empty_trash().await {
                                                Ok(_) => {
                                                    trash.set(Vec::new());
                                                    status.set("Trash emptied".into());
                                                }
                                                Err(error) => status.set(format!("Could not empty Trash: {error}")),
                                            }
                                        }
                                        ConfirmAction::DeleteForever(id) => {
                                            match invoke_id("delete_forever", id).await {
                                                Ok(true) => {
                                                    trash.write().retain(|item| item.id != id);
                                                    status.set("Note deleted permanently".into());
                                                }
                                                Ok(false) => status.set("Note no longer exists in Trash".into()),
                                                Err(error) => status.set(format!("Could not delete note: {error}")),
                                            }
                                        }
                                        ConfirmAction::RestoreBackup => {
                                            let path = backup_path.read().trim().to_string();
                                            if path.is_empty() {
                                                status.set("Enter a backup folder path".into());
                                            } else {
                                                flush_pending_saves(pending_saves).await;
                                                match invoke_path::<()>("restore_from_backup", &path).await {
                                                    Ok(()) => {
                                                        if let Ok(items) = load_notes().await { notes.set(items); }
                                                        if let Ok(items) = load_trash().await { trash.set(items); }
                                                        if let Ok(saved) = load_settings().await { settings.set(saved); }
                                                        active_note.set(None);
                                                        status.set("Backup restored; current notes were kept in a safety backup".into());
                                                    }
                                                    Err(error) => status.set(format!("Restore failed: {error}")),
                                                }
                                            }
                                        }
                                    }
                                },
                                "Confirm"
                            }
                        }
                    }
                }
            }
        }
    }
}
