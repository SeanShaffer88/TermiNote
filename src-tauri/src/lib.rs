use std::{
    fs,
    fs::File,
    path::{Path, PathBuf},
    sync::Mutex,
};
#[cfg(windows)]
use std::process::Command;
use tauri::{
    AppHandle, Emitter, Manager, State, WindowEvent,
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
};
use terminote_core::{AppSettings, ImportResult, Note, NoteStore, SortMode};

#[cfg(windows)]
mod updater;

struct AppState {
    store: Mutex<NoteStore>,
    settings: Mutex<AppSettings>,
    data_dir: PathBuf,
    instance_lock: Mutex<Option<File>>,
    update_path: Mutex<Option<PathBuf>>,
}

fn with_store<T>(
    state: &State<'_, AppState>,
    action: impl FnOnce(&mut NoteStore) -> Result<T, String>,
) -> Result<T, String> {
    let mut store = state
        .store
        .lock()
        .map_err(|_| "The notebook is busy. Try again.".to_string())?;
    action(&mut store)
}

#[tauri::command]
fn list_notes(state: State<'_, AppState>) -> Result<Vec<Note>, String> {
    let sort = state
        .settings
        .lock()
        .map_err(|_| "Settings are busy. Try again.".to_string())?
        .sort;
    with_store(&state, |store| Ok(store.list("", None, false, sort)))
}

#[tauri::command]
fn add_note(
    title: String,
    body: String,
    tags: Vec<String>,
    state: State<'_, AppState>,
) -> Result<Note, String> {
    with_store(&state, |store| store.add(&title, &body, &tags).map_err(|e| e.to_string()))
}

#[tauri::command]
fn update_note(
    id: u64,
    title: String,
    body: String,
    tags: Vec<String>,
    state: State<'_, AppState>,
) -> Result<Option<Note>, String> {
    with_store(&state, |store| {
        let updated = store
            .update(id, &title, &body, &tags)
            .map_err(|e| e.to_string())?;
        if updated.is_some() {
            let _ = store.remove_recovery_draft(id);
        }
        Ok(updated)
    })
}

#[tauri::command]
fn write_recovery_draft(
    id: u64,
    title: String,
    body: String,
    tags: Vec<String>,
    state: State<'_, AppState>,
) -> Result<(), String> {
    with_store(&state, |store| {
        let source = store
            .get(id)
            .or_else(|| store.get_trashed(id))
            .ok_or_else(|| "Note no longer exists.".to_string())?;
        store
            .write_recovery_draft(source, &title, &body, &tags)
            .map_err(|error| error.to_string())
    })
}

#[tauri::command]
fn list_recovery_drafts(state: State<'_, AppState>) -> Result<Vec<Note>, String> {
    terminote_core::load_recovery_drafts(&state.data_dir).map_err(|error| error.to_string())
}

#[tauri::command]
fn recover_draft(id: u64, state: State<'_, AppState>) -> Result<Option<Note>, String> {
    with_store(&state, |store| store.recover_draft(id).map_err(|error| error.to_string()))
}

#[tauri::command]
fn discard_recovery_draft(id: u64, state: State<'_, AppState>) -> Result<(), String> {
    with_store(&state, |store| {
        store
            .remove_recovery_draft(id)
            .map_err(|error| error.to_string())
    })
}

#[tauri::command]
fn move_to_trash(id: u64, state: State<'_, AppState>) -> Result<bool, String> {
    with_store(&state, |store| store.move_to_trash(id).map_err(|e| e.to_string()))
}

#[tauri::command]
fn restore_note(id: u64, state: State<'_, AppState>) -> Result<bool, String> {
    with_store(&state, |store| store.restore(id).map_err(|e| e.to_string()))
}

#[tauri::command]
fn list_trash(state: State<'_, AppState>) -> Result<Vec<Note>, String> {
    with_store(&state, |store| Ok(store.trash.clone()))
}

#[tauri::command]
fn delete_forever(id: u64, state: State<'_, AppState>) -> Result<bool, String> {
    with_store(&state, |store| store.delete_forever(id).map_err(|e| e.to_string()))
}

#[tauri::command]
fn empty_trash(state: State<'_, AppState>) -> Result<usize, String> {
    with_store(&state, |store| store.empty_trash().map_err(|e| e.to_string()))
}

#[tauri::command]
fn export_notes(path: String, state: State<'_, AppState>) -> Result<usize, String> {
    with_store(&state, |store| {
        let text = store.export_json().map_err(|error| error.to_string())?;
        use std::io::Write;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|error| error.to_string())?;
        file.write_all(text.as_bytes())
            .map_err(|error| error.to_string())?;
        Ok(store.notes.len())
    })
}

#[tauri::command]
fn import_notes(path: String, state: State<'_, AppState>) -> Result<ImportResult, String> {
    with_store(&state, |store| {
        let text = fs::read_to_string(&path).map_err(|error| error.to_string())?;
        store.import_json(&text).map_err(|error| error.to_string())
    })
}

#[tauri::command]
fn add_markdown_file(path: String, state: State<'_, AppState>) -> Result<Note, String> {
    with_store(&state, |store| {
        let source = Path::new(&path);
        let name = source
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| "Invalid file path.".to_string())?;
        let extension = source
            .extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if extension != "md" && extension != "txt" {
            return Err("Only .md and .txt files can be added.".into());
        }
        let text = fs::read_to_string(source).map_err(|error| error.to_string())?;
        if text.len() > 5 * 1024 * 1024 {
            return Err("File is larger than 5 MB.".into());
        }
        if text.trim().is_empty() {
            return Err("File is empty.".into());
        }
        store
            .import_file_text(&text, name)
            .map_err(|error| error.to_string())
    })
}

#[tauri::command]
fn backup_to(path: String, state: State<'_, AppState>) -> Result<usize, String> {
    let _settings = state
        .settings
        .lock()
        .map_err(|_| "Settings are busy. Try again.".to_string())?;
    let _store = state
        .store
        .lock()
        .map_err(|_| "The notebook is busy. Try again.".to_string())?;
    terminote_core::backup_data(&state.data_dir, Path::new(&path))
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn restore_from_backup(path: String, state: State<'_, AppState>) -> Result<(), String> {
    let mut settings = state
        .settings
        .lock()
        .map_err(|_| "Settings are busy. Try again.".to_string())?;
    let mut store = state
        .store
        .lock()
        .map_err(|_| "The notebook is busy. Try again.".to_string())?;
    terminote_core::restore_backup(&state.data_dir, Path::new(&path))
        .map_err(|error| error.to_string())?;
    let restored_store = NoteStore::open(&state.data_dir).map_err(|error| error.to_string())?;
    *store = restored_store;
    *settings = AppSettings::load(&state.data_dir);
    Ok(())
}

#[tauri::command]
fn all_tags(state: State<'_, AppState>) -> Result<std::collections::BTreeMap<String, usize>, String> {
    with_store(&state, |store| Ok(store.all_tags()))
}

#[tauri::command]
fn set_pinned(id: u64, pinned: bool, state: State<'_, AppState>) -> Result<bool, String> {
    with_store(&state, |store| store.set_pinned(id, pinned).map_err(|e| e.to_string()))
}

#[tauri::command]
fn rename_tag(old: String, new: String, state: State<'_, AppState>) -> Result<usize, String> {
    with_store(&state, |store| store.rename_tag(&old, &new).map_err(|e| e.to_string()))
}

#[tauri::command]
fn delete_tag(tag: String, state: State<'_, AppState>) -> Result<usize, String> {
    with_store(&state, |store| store.delete_tag(&tag).map_err(|e| e.to_string()))
}

#[tauri::command]
fn reorder_notes(ids: Vec<u64>, state: State<'_, AppState>) -> Result<(), String> {
    with_store(&state, |store| store.reorder(&ids).map_err(|e| e.to_string()))
}

#[tauri::command]
fn delete_all_notes(state: State<'_, AppState>) -> Result<usize, String> {
    with_store(&state, |store| store.delete_all().map_err(|e| e.to_string()))
}

#[tauri::command]
fn duplicate_note(id: u64, state: State<'_, AppState>) -> Result<Option<Note>, String> {
    with_store(&state, |store| store.duplicate(id).map_err(|e| e.to_string()))
}

#[tauri::command]
fn get_settings(state: State<'_, AppState>) -> Result<AppSettings, String> {
    state
        .settings
        .lock()
        .map(|settings| settings.clone())
        .map_err(|_| "Settings are busy. Try again.".to_string())
}

#[tauri::command]
fn save_settings(settings: AppSettings, state: State<'_, AppState>) -> Result<(), String> {
    settings
        .save(&state.data_dir)
        .map_err(|error| error.to_string())?;
    let mut current = state
        .settings
        .lock()
        .map_err(|_| "Settings are busy. Try again.".to_string())?;
    *current = settings;
    Ok(())
}

#[tauri::command]
fn resolve_close_request(
    action: String,
    remember: bool,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    #[cfg(windows)]
    record_tray_test_event(&format!("close-request:{action}"));
    if action == "tray"
        && !state
            .settings
            .lock()
            .map_err(|_| "Settings are busy. Try again.".to_string())?
            .minimize_to_tray
    {
        return Err("Enable the system tray option before minimizing there.".into());
    }
    if remember {
        let mut updated = state
            .settings
            .lock()
            .map_err(|_| "Settings are busy. Try again.".to_string())?
            .clone();
        updated.close_action = action.clone();
        if action == "tray" {
            updated.minimize_to_tray = true;
        }
        updated
            .save(&state.data_dir)
            .map_err(|error| error.to_string())?;
        *state
            .settings
            .lock()
            .map_err(|_| "Settings are busy. Try again.".to_string())? = updated;
    }
    match action.as_str() {
        "tray" => {
            if let Some(window) = app.get_webview_window("main") {
                window.hide().map_err(|error| error.to_string())?;
            }
        }
        "quit" => app.exit(0),
        _ => {}
    }
    Ok(())
}

#[tauri::command]
fn install_update(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    if !state
        .settings
        .lock()
        .map_err(|_| "Settings are busy. Try again.".to_string())?
        .auto_update
    {
        return Ok(());
    }
    let path = state
        .update_path
        .lock()
        .map_err(|_| "Update state is busy.".to_string())?
        .take()
        .ok_or_else(|| "No verified update is ready.".to_string())?;
    let updates = state.data_dir.join("updates");
    if path.parent() != Some(updates.as_path())
        || !path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("TermiNote-Setup-x64-") && name.ends_with(".exe"))
    {
        return Err("Update file path was rejected.".into());
    }
    if !path.is_file() {
        return Err("Update installer is missing.".into());
    }
    #[cfg(windows)]
    {
        let exe = std::env::current_exe().map_err(|error| error.to_string())?;
        launch_update_helper(&path, &exe, std::process::id())
            .map_err(|error| error.to_string())?;
        app.exit(0);
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let _ = app;
        Err("Automatic updates only run on Windows.".into())
    }
}

#[cfg(windows)]
fn launch_update_helper(
    installer: &Path,
    executable: &Path,
    process_id: u32,
) -> std::io::Result<()> {
    use std::os::windows::process::CommandExt;
    let windows_dir = std::env::var_os("WINDIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
    let powershell = windows_dir
        .join("System32")
        .join("WindowsPowerShell")
        .join("v1.0")
        .join("powershell.exe");
    let installer = powershell_literal(&installer.to_string_lossy());
    let executable = powershell_literal(&executable.to_string_lossy());
    let script = format!(
        "$ErrorActionPreference='SilentlyContinue'; Wait-Process -Id {process_id}; \
         try {{ Start-Process -FilePath {installer} \
           -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' -Wait }} \
         finally {{ Start-Process -FilePath {executable} }}"
    );
    Command::new(powershell)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-Command",
            &script,
        ])
        .creation_flags(0x08000000)
        .spawn()
        .map(|_| ())
}

#[cfg(windows)]
fn powershell_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[tauri::command]
fn start_update_check(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    #[cfg(windows)]
    {
        let enabled = state
            .settings
            .lock()
            .map_err(|_| "Settings are busy. Try again.".to_string())?
            .auto_update;
        if enabled {
            let data_dir = state.data_dir.clone();
            tauri::async_runtime::spawn(async move {
                if let Some(path) = updater::download_update(&data_dir).await {
                    if let Ok(mut ready) = app.state::<AppState>().update_path.lock() {
                        *ready = Some(path);
                        let _ = app.emit("terminote-update-ready", ());
                    }
                }
            });
        }
    }
    #[cfg(not(windows))]
    let _ = (app, state);
    Ok(())
}

#[cfg(windows)]
fn record_tray_test_event(message: &str) {
    let Some(path) = std::env::var_os("TERMINOTE_TRAY_TEST_LOG") else {
        return;
    };
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(path) {
        use std::io::Write;
        let _ = writeln!(file, "{message}");
    }
}

fn restore_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let show = window.show();
        #[cfg(windows)]
        record_tray_test_event(if show.is_ok() { "restore:show-ok" } else { "restore:show-error" });
        let _ = show;
        let _ = window.unminimize();
        let _ = window.set_focus();
    } else {
        #[cfg(windows)]
        record_tray_test_event("restore:window-missing");
    }
}

fn install_tray(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let open = MenuItem::with_id(app, "open", "Open TermiNote", true, None::<&str>)?;
    let new_note = MenuItem::with_id(app, "new-note", "New note", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &new_note, &quit])?;
    let icon = app
        .default_window_icon()
        .cloned()
        .ok_or("The app icon is required for the system tray")?;
    TrayIconBuilder::new()
        .icon(icon)
        .tooltip("TermiNote")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| {
            #[cfg(windows)]
            record_tray_test_event(&format!("menu:{}", event.id().as_ref()));
            match event.id().as_ref() {
            "open" => restore_window(app),
            "new-note" => {
                let state = app.state::<AppState>();
                if let Ok(mut store) = state.store.lock() {
                    if let Ok(note) = store.add("Untitled note", "", &[]) {
                        let _ = app.emit("terminote-new-note", note.id);
                    }
                }
                restore_window(app);
            }
            "quit" => {
                let result = app.emit("terminote-quit-requested", ());
                #[cfg(windows)]
                record_tray_test_event(if result.is_ok() { "menu:quit-emitted" } else { "menu:quit-emit-error" });
                let _ = result;
            }
            _ => {}
            }
        })
        .on_tray_icon_event(|tray, event| {
            #[cfg(windows)]
            match event {
                TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } => record_tray_test_event("tray:left-up"),
                TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Down, .. } => record_tray_test_event("tray:left-down"),
                _ => record_tray_test_event("tray:other"),
            }
            if matches!(
                event,
                TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                }
            ) {
                restore_window(tray.app_handle());
            }
        })
        .build(app)?;
    Ok(())
}

pub fn run() {
    let exe = std::env::current_exe().unwrap_or_default();
    let environment = std::env::vars().collect::<std::collections::HashMap<_, _>>();
    let data_dir = terminote_core::resolve_data_dir(&environment, &exe);
    let store = NoteStore::open(&data_dir)
        .unwrap_or_else(|error| panic!("Could not open the TermiNote notebook: {error}"));
    let settings = AppSettings::load(&data_dir);

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.unminimize();
                let _ = window.set_focus();
            }
        }))
        .plugin(
            tauri_plugin_window_state::Builder::default()
                .with_state_flags(
                    tauri_plugin_window_state::StateFlags::SIZE
                        | tauri_plugin_window_state::StateFlags::POSITION
                        | tauri_plugin_window_state::StateFlags::MAXIMIZED,
                )
                .build(),
        )
        .manage(AppState {
            store: Mutex::new(store),
            settings: Mutex::new(settings.clone()),
            data_dir: data_dir.clone(),
            instance_lock: Mutex::new(None),
            update_path: Mutex::new(None),
        })
        .setup(move |app| {
            let lock = terminote_core::acquire_data_lock(&data_dir)?;
            *app.state::<AppState>()
                .instance_lock
                .lock()
                .map_err(|_| std::io::Error::other("Could not lock the notebook state"))? =
                Some(lock);
            if let (Some(window), Some(placement)) = (
                app.get_webview_window("main"),
                settings.window_placement.as_ref(),
            ) {
                if (200..=20000).contains(&placement.width)
                    && (150..=20000).contains(&placement.height)
                {
                    let _ = window.set_size(tauri::PhysicalSize::new(
                        placement.width,
                        placement.height,
                    ));
                    if let Ok(monitors) = window.available_monitors() {
                        let right = i64::from(placement.left) + i64::from(placement.width);
                        let bottom = i64::from(placement.top) + i64::from(placement.height);
                        let visible = monitors.iter().any(|monitor| {
                            let pos = monitor.position();
                            let size = monitor.size();
                            let mx = i64::from(pos.x);
                            let my = i64::from(pos.y);
                            let mr = mx + i64::from(size.width);
                            let mb = my + i64::from(size.height);
                            i64::from(placement.left) < mr
                                && right > mx
                                && i64::from(placement.top) < mb
                                && bottom > my
                        });
                        if visible {
                            let _ = window.set_position(tauri::PhysicalPosition::new(
                                placement.left,
                                placement.top,
                            ));
                        }
                    }
                    if placement.maximized {
                        let _ = window.maximize();
                    }
                }
            }
            install_tray(app)?;
            if let Some(window) = app.get_webview_window("main") {
                let app_handle = app.handle().clone();
                let event_window = window.clone();
                window.on_window_event(move |event| match event {
                    WindowEvent::CloseRequested { api, .. } => {
                        let state = app_handle.state::<AppState>();
                        let (action, tray_enabled) = state
                            .settings
                            .lock()
                            .map(|settings| {
                                (settings.close_action.clone(), settings.minimize_to_tray)
                            })
                            .unwrap_or_else(|_| ("ask".into(), false));
                        api.prevent_close();
                        if action == "tray" && tray_enabled {
                            let _ = event_window.hide();
                        } else if action == "quit" || action == "tray" {
                            let _ = app_handle.emit("terminote-quit-requested", ());
                        } else {
                            let _ = app_handle.emit("terminote-close-requested", ());
                        }
                    }
                    WindowEvent::Resized(_) => {
                        let state = app_handle.state::<AppState>();
                        let hide_to_tray = state
                            .settings
                            .lock()
                            .map(|settings| settings.minimize_to_tray)
                            .unwrap_or(false);
                        if hide_to_tray && event_window.is_minimized().unwrap_or(false) {
                            let _ = event_window.hide();
                        }
                    }
                    _ => {}
                });
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_notes,
            add_note,
            update_note,
            write_recovery_draft,
            list_recovery_drafts,
            recover_draft,
            discard_recovery_draft,
            move_to_trash,
            restore_note,
            list_trash,
            delete_forever,
            empty_trash,
            export_notes,
            import_notes,
            add_markdown_file,
            backup_to,
            restore_from_backup,
            all_tags,
            set_pinned,
            rename_tag,
            delete_tag,
            reorder_notes,
            delete_all_notes,
            duplicate_note,
            get_settings,
            save_settings,
            resolve_close_request,
            install_update,
            start_update_check
        ])
        .run(tauri::generate_context!())
        .expect("error while running TermiNote");
}
