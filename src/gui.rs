//! The Windows GUI. On other platforms `run` reports that the
//! window is Windows-only (the CLI works everywhere).

#[cfg(not(windows))]
pub fn run() -> Result<(), String> {
    Err("the TermiNote window is only available on Windows; use the command line here".to_string())
}

#[cfg(windows)]
pub fn run() -> Result<(), String> {
    windows::run()
}

/// Window text for help, shared by the GUI's Help dialog. Plain
/// words, and the same text the program shows with F1.
pub const HELP_TEXT: &str = "\
TermiNote - quick help

WHAT IT IS
TermiNote is a simple notepad. Every note has a title and a body.
Notes are organised with tags. There are no folders, on purpose.

THE MAIN WINDOW
- The list in the middle shows note TITLES only. Click a title to
  open that note in the editor on the right.
- The sidebar on the left lists your tags. Click a tag to see only
  the notes with that tag. \"All notes\" shows everything and
  \"Untagged\" shows notes with no tag.
- Type in the search box to find notes by title, body or tag.

WRITING
- \"Add note\" (or Ctrl+N) starts a new note.
- Type the title in the top box, tags in the next box (separate
  tags with commas, like: work, ideas), and the note itself in the
  big box.
- Notes save themselves as you type. The bottom bar shows when the
  last save happened. Ctrl+S saves right away.
- A- and A+ make the text smaller or bigger.
- \"Pin\" keeps a note at the top of the list.

DELETING AND UNDOING
- \"Delete\" moves a note to the trash; it is not gone for good.
- \"Undo delete\" (or Ctrl+Shift+Z) brings back the last note you
  deleted.
- \"Delete all\" moves every note to the trash. The command line
  (restore, trash, empty-trash) can bring trashed notes back or
  remove them for good.

FILES
- Drag a .txt or .md file onto the window to make it a note.
- Drag a TermiNote .json export onto the window to import it.

KEYS
Ctrl+N new note - Ctrl+S save now - Ctrl+F search - Delete deletes
the selected note (it asks first) - F1 this help - Ctrl+Z undoes
typing in the editor - Ctrl+Shift+Z undoes a delete.

YOUR DATA
Everything is stored in one local JSON file on this computer. No
account, no internet, nothing is sent anywhere.";

/// About text, shown by the About button.
pub fn about_text() -> String {
    format!(
        "TermiNote {}\n\nA dark terminal-themed notepad.\nNotes with titles, bodies and tags, stored locally.\n\nFree software, MIT licence.\nCopyright (c) 2026 Sean Shaffer\nhttps://github.com/SeanShaffer88/TermiNote\n\nNo update checker is included in this version; TermiNote works fully offline.",
        env!("CARGO_PKG_VERSION")
    )
}

#[cfg(windows)]
#[allow(dead_code)] // FFI structs and constants: some fields/items exist for layout or future use.
mod windows {
    use std::cell::{Cell, RefCell};
    use std::ffi::c_void;
    use std::path::PathBuf;

    use crate::gui::{about_text, HELP_TEXT};
    use crate::json::{self, Json};
    use crate::note::parse_tag_list;
    use crate::ops::{self, Filter, Sort};
    use crate::store::{self, Store};
    use crate::time;

    type Hwnd = *mut c_void;
    type Hdc = *mut c_void;

    // ---- Control ids ----
    const ID_TAGS_LABEL: usize = 119;
    const ID_TAGS_LIST: usize = 100;
    const ID_STATUS: usize = 118;
    const ID_SEARCH: usize = 101;
    const ID_ADD: usize = 102;
    const ID_DELETE_ALL: usize = 103;
    const ID_NOTES_LIST: usize = 104;
    const ID_TITLE: usize = 105;
    const ID_TAGS_EDIT: usize = 106;
    const ID_BODY: usize = 107;
    const ID_COUNTS: usize = 108;
    const ID_FONT_DOWN: usize = 109;
    const ID_FONT_UP: usize = 110;
    const ID_PIN: usize = 111;
    const ID_DUPLICATE: usize = 112;
    const ID_DELETE: usize = 113;
    const ID_CLOSE_EDITOR: usize = 114;
    const ID_UNDO_DELETE: usize = 115;
    const ID_HELP: usize = 116;
    const ID_ABOUT: usize = 117;
    const ID_SAVED: usize = 121;
    const ID_SORT_LABEL: usize = 122;

    const AUTOSAVE_TIMER: usize = 1;
    const AUTOSAVE_MS: u32 = 600;

    // ---- Messages and styles ----
    const WM_CREATE: u32 = 0x0001;
    const WM_DESTROY: u32 = 0x0002;
    const WM_SIZE: u32 = 0x0005;
    const WM_CLOSE: u32 = 0x0010;
    const WM_GETMINMAXINFO: u32 = 0x0024;
    const WM_DRAWITEM: u32 = 0x002B;
    const WM_MEASUREITEM: u32 = 0x002C;
    const WM_SETFONT: u32 = 0x0030;
    const WM_KEYDOWN: u32 = 0x0100;
    const WM_COMMAND: u32 = 0x0111;
    const WM_TIMER: u32 = 0x0113;
    const WM_CTLCOLOREDIT: u32 = 0x0133;
    const WM_CTLCOLORLISTBOX: u32 = 0x0134;
    const WM_CTLCOLORBTN: u32 = 0x0135;
    const WM_CTLCOLORSTATIC: u32 = 0x0138;
    const WM_DROPFILES: u32 = 0x0233;

    const WS_POPUP: u32 = 0x8000_0000;
    const WS_CHILD: u32 = 0x4000_0000;
    const WS_VISIBLE: u32 = 0x1000_0000;
    const WS_TABSTOP: u32 = 0x0001_0000;
    const WS_VSCROLL: u32 = 0x0020_0000;
    const WS_HSCROLL: u32 = 0x0010_0000;
    const WS_BORDER: u32 = 0x0080_0000;
    const WS_OVERLAPPEDWINDOW: u32 = 0x00CF_0000;
    const CW_USEDEFAULT: i32 = -2147483648; // 0x80000000

    const ES_AUTOHSCROLL: u32 = 0x0080;
    const ES_MULTILINE: u32 = 0x0004;
    const ES_AUTOVSCROLL: u32 = 0x0040;
    const ES_WANTRETURN: u32 = 0x1000;
    const BS_OWNERDRAW: u32 = 0x000B;
    const LBS_NOTIFY: u32 = 0x0001;
    const LBS_OWNERDRAWFIXED: u32 = 0x0010;
    const LBS_HASSTRINGS: u32 = 0x0040;

    const LB_ADDSTRING: u32 = 0x0180;
    const LB_RESETCONTENT: u32 = 0x0184;
    const LB_SETCURSEL: u32 = 0x0186;
    const LB_GETCURSEL: u32 = 0x0188;
    const LB_GETTEXT: u32 = 0x0189;
    const LB_GETTEXTLEN: u32 = 0x018A;
    const LB_SETITEMHEIGHT: u32 = 0x01A0;
    const EM_SETCUEBANNER: u32 = 0x1501;
    const LBN_SELCHANGE: usize = 1;
    const EN_CHANGE: usize = 0x0300;

    const MB_OK: u32 = 0x0;
    const MB_YESNO: u32 = 0x4;
    const MB_ICONINFORMATION: u32 = 0x40;
    const MB_ICONQUESTION: u32 = 0x20;
    const MB_ICONWARNING: u32 = 0x30;
    const IDYES: i32 = 6;

    const SW_SHOW: i32 = 5;
    const COLOR_BG: u32 = 0x000C_0C0C; // #0C0C0C as COLORREF (BGR)
    const COLOR_PANEL: u32 = 0x0014_1414;
    const COLOR_RED: u32 = 0x0023_11E8; // #E81123 as COLORREF (BGR)
    const COLOR_WHITE: u32 = 0x00FF_FFFF;
    const TRANSPARENT: i32 = 1;

    const TTM_ADDTOOLW: u32 = 0x0432; // WM_USER + 50
    const TTF_IDISHWND: u32 = 0x0001;
    const TTF_SUBCLASS: u32 = 0x0010;

    const VK_F1: usize = 0x70;
    const VK_DELETE: usize = 0x2E;
    const VK_CONTROL: i32 = 0x11;
    const VK_SHIFT: i32 = 0x10;

    #[repr(C)]
    struct Point {
        x: i32,
        y: i32,
    }

    #[repr(C)]
    struct Rect {
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
    }

    #[repr(C)]
    struct Msg {
        hwnd: Hwnd,
        message: u32,
        w_param: usize,
        l_param: isize,
        time: u32,
        pt: Point,
    }

    type WndProc = unsafe extern "system" fn(Hwnd, u32, usize, isize) -> isize;

    #[repr(C)]
    struct WndClassExW {
        cb_size: u32,
        style: u32,
        lpfn_wnd_proc: WndProc,
        cb_cls_extra: i32,
        cb_wnd_extra: i32,
        h_instance: *mut c_void,
        h_icon: *mut c_void,
        h_cursor: *mut c_void,
        hbr_background: *mut c_void,
        lpsz_menu_name: *const u16,
        lpsz_class_name: *const u16,
        h_icon_sm: *mut c_void,
    }

    #[repr(C)]
    struct DrawItem {
        ctl_type: u32,
        ctl_id: u32,
        item_id: u32,
        item_action: u32,
        item_state: u32,
        hwnd_item: Hwnd,
        hdc: Hdc,
        rc_item: Rect,
        item_data: usize,
    }

    #[repr(C)]
    struct MeasureItem {
        ctl_type: u32,
        ctl_id: u32,
        item_id: u32,
        item_width: u32,
        item_height: u32,
        item_data: usize,
    }

    #[repr(C)]
    struct MinMaxInfo {
        pt_reserved: Point,
        pt_max_size: Point,
        pt_max_position: Point,
        pt_min_track_size: Point,
        pt_max_track_size: Point,
    }

    #[repr(C)]
    struct ToolInfoW {
        cb_size: u32,
        u_flags: u32,
        hwnd: Hwnd,
        u_id: usize,
        rect: Rect,
        hinst: *mut c_void,
        lpsz_text: *const u16,
        l_param: isize,
        lp_reserved: *mut c_void,
    }

    #[repr(C)]
    struct InitCommonControlsEx {
        dw_size: u32,
        dw_icc: u32,
    }

    // Documented 64-bit layouts; a mistake fails the Windows build.
    #[cfg(target_pointer_width = "64")]
    const _: () = assert!(std::mem::size_of::<WndClassExW>() == 80);
    #[cfg(target_pointer_width = "64")]
    const _: () = assert!(std::mem::size_of::<DrawItem>() == 64);
    #[cfg(target_pointer_width = "64")]
    const _: () = assert!(std::mem::size_of::<ToolInfoW>() == 72);

    #[link(name = "user32")]
    extern "system" {
        fn RegisterClassExW(wc: *const WndClassExW) -> u16;
        fn CreateWindowExW(
            ex_style: u32,
            class_name: *const u16,
            window_name: *const u16,
            style: u32,
            x: i32,
            y: i32,
            w: i32,
            h: i32,
            parent: Hwnd,
            menu: *mut c_void,
            instance: *mut c_void,
            param: *mut c_void,
        ) -> Hwnd;
        fn DefWindowProcW(hwnd: Hwnd, msg: u32, w: usize, l: isize) -> isize;
        fn GetMessageW(msg: *mut Msg, hwnd: Hwnd, min: u32, max: u32) -> i32;
        fn TranslateMessage(msg: *const Msg) -> i32;
        fn DispatchMessageW(msg: *const Msg) -> isize;
        fn PostQuitMessage(code: i32);
        fn DestroyWindow(hwnd: Hwnd) -> i32;
        fn ShowWindow(hwnd: Hwnd, cmd: i32) -> i32;
        fn MoveWindow(hwnd: Hwnd, x: i32, y: i32, w: i32, h: i32, repaint: i32) -> i32;
        fn SendMessageW(hwnd: Hwnd, msg: u32, w: usize, l: isize) -> isize;
        fn SetTimer(hwnd: Hwnd, id: usize, ms: u32, proc: *mut c_void) -> usize;
        fn KillTimer(hwnd: Hwnd, id: usize) -> i32;
        fn MessageBoxW(hwnd: Hwnd, text: *const u16, caption: *const u16, kind: u32) -> i32;
        fn GetWindowTextW(hwnd: Hwnd, text: *mut u16, max: i32) -> i32;
        fn GetWindowTextLengthW(hwnd: Hwnd) -> i32;
        fn SetWindowTextW(hwnd: Hwnd, text: *const u16) -> i32;
        fn GetDlgItem(hwnd: Hwnd, id: i32) -> Hwnd;
        fn SetFocus(hwnd: Hwnd) -> Hwnd;
        fn GetFocus() -> Hwnd;
        fn GetKeyState(vk: i32) -> i16;
        fn GetClientRect(hwnd: Hwnd, rect: *mut Rect) -> i32;
        fn GetWindowRect(hwnd: Hwnd, rect: *mut Rect) -> i32;
        fn FillRect(hdc: Hdc, rect: *const Rect, brush: *mut c_void) -> i32;
        fn DrawTextW(hdc: Hdc, text: *const u16, count: i32, rect: *mut Rect, format: u32) -> i32;
        fn SetTextColor(hdc: Hdc, color: u32) -> u32;
        fn SetBkColor(hdc: Hdc, color: u32) -> u32;
        fn SetBkMode(hdc: Hdc, mode: i32) -> i32;
        fn SelectObject(hdc: Hdc, obj: *mut c_void) -> *mut c_void;
        fn GetDpiForWindow(hwnd: Hwnd) -> u32;
        fn LoadCursorW(instance: *mut c_void, name: *const u16) -> *mut c_void;
    }

    #[link(name = "gdi32")]
    extern "system" {
        fn CreateSolidBrush(color: u32) -> *mut c_void;
        fn CreateFontW(
            height: i32,
            width: i32,
            escapement: i32,
            orientation: i32,
            weight: i32,
            italic: u32,
            underline: u32,
            strike_out: u32,
            charset: u32,
            out_precision: u32,
            clip_precision: u32,
            quality: u32,
            pitch_and_family: u32,
            face: *const u16,
        ) -> *mut c_void;
        fn DeleteObject(obj: *mut c_void) -> i32;
        fn TextOutW(hdc: Hdc, x: i32, y: i32, text: *const u16, count: i32) -> i32;
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetModuleHandleW(name: *const u16) -> *mut c_void;
    }

    #[link(name = "shell32")]
    extern "system" {
        fn DragAcceptFiles(hwnd: Hwnd, accept: i32);
        fn DragQueryFileW(drop: *mut c_void, index: u32, file: *mut u16, cch: u32) -> u32;
        fn DragFinish(drop: *mut c_void);
    }

    #[link(name = "comctl32")]
    extern "system" {
        fn InitCommonControlsEx(init: *const InitCommonControlsEx) -> i32;
    }

    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// Persisted GUI settings (settings.json beside the data file).
    #[derive(Debug, Clone)]
    struct Settings {
        font_size: i32,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        last_note: u64,
        last_tag: String,
        sort: String,
    }

    impl Default for Settings {
        fn default() -> Self {
            Settings {
                font_size: 16,
                x: 0,
                y: 0,
                w: 0,
                h: 0,
                last_note: 0,
                last_tag: "all".to_string(),
                sort: "modified".to_string(),
            }
        }
    }

    impl Settings {
        fn load(path: &std::path::Path) -> Settings {
            let mut settings = Settings::default();
            let Ok(text) = std::fs::read_to_string(path) else {
                return settings;
            };
            let Some(value) = json::parse(&text) else {
                return settings;
            };
            let Some(fields) = json::as_obj(&value) else {
                return settings;
            };
            if let Some(n) = json::get(fields, "font_size").and_then(json::as_i64) {
                settings.font_size = (n as i32).clamp(10, 40);
            }
            if let Some(n) = json::get(fields, "x").and_then(json::as_i64) {
                settings.x = n as i32;
            }
            if let Some(n) = json::get(fields, "y").and_then(json::as_i64) {
                settings.y = n as i32;
            }
            if let Some(n) = json::get(fields, "w").and_then(json::as_i64) {
                settings.w = n as i32;
            }
            if let Some(n) = json::get(fields, "h").and_then(json::as_i64) {
                settings.h = n as i32;
            }
            if let Some(n) = json::get(fields, "last_note").and_then(json::as_u64) {
                settings.last_note = n;
            }
            if let Some(s) = json::get(fields, "last_tag").and_then(json::as_str) {
                settings.last_tag = s.to_string();
            }
            if let Some(s) = json::get(fields, "sort").and_then(json::as_str) {
                if Sort::parse(s).is_some() {
                    settings.sort = s.to_string();
                }
            }
            settings
        }

        fn save(&self, path: &std::path::Path) {
            let value = Json::Obj(vec![
                ("font_size".into(), Json::Num(self.font_size as f64)),
                ("x".into(), Json::Num(self.x as f64)),
                ("y".into(), Json::Num(self.y as f64)),
                ("w".into(), Json::Num(self.w as f64)),
                ("h".into(), Json::Num(self.h as f64)),
                ("last_note".into(), Json::Num(self.last_note as f64)),
                ("last_tag".into(), Json::Str(self.last_tag.clone())),
                ("sort".into(), Json::Str(self.sort.clone())),
            ]);
            if let Some(parent) = path.parent() {
                if !parent.as_os_str().is_empty() {
                    let _ = std::fs::create_dir_all(parent);
                }
            }
            let _ = std::fs::write(path, json::stringify(&value));
        }
    }

    /// Tag-sidebar selection: all notes, untagged only, or one tag.
    #[derive(Debug, Clone, PartialEq)]
    enum TagSel {
        All,
        Untagged,
        Tag(String),
    }

    impl TagSel {
        fn setting_name(&self) -> String {
            match self {
                TagSel::All => "all".to_string(),
                TagSel::Untagged => "untagged".to_string(),
                TagSel::Tag(t) => format!("tag:{t}"),
            }
        }

        fn from_setting(text: &str) -> TagSel {
            if text == "untagged" {
                TagSel::Untagged
            } else if let Some(tag) = text.strip_prefix("tag:") {
                if tag.is_empty() {
                    TagSel::All
                } else {
                    TagSel::Tag(tag.to_string())
                }
            } else {
                TagSel::All
            }
        }
    }

    struct App {
        hwnd: Hwnd,
        store: Store,
        data_path: PathBuf,
        settings_path: PathBuf,
        settings: Settings,
        was_corrupt: bool,
        // Controls.
        tags_list: Hwnd,
        status: Hwnd,
        search: Hwnd,
        notes_list: Hwnd,
        title_edit: Hwnd,
        tags_edit: Hwnd,
        body_edit: Hwnd,
        counts: Hwnd,
        saved_label: Hwnd,
        sort_label: Hwnd,
        pin_btn: Hwnd,
        tooltip: Hwnd,
        font: *mut c_void,
        black_brush: *mut c_void,
        panel_brush: *mut c_void,
        red_brush: *mut c_void,
        // View state.
        tag_sel: TagSel,
        tag_rows: Vec<TagSel>,
        shown_ids: Vec<u64>,
        current_id: Option<u64>,
        last_deleted: Option<u64>,
        sort: Sort,
    }

    thread_local! {
        static APP: RefCell<Option<App>> = const { RefCell::new(None) };
        /// Set while the editor is being filled programmatically, so
        /// EN_CHANGE does not treat our own writes as user edits.
        static LOADING: Cell<bool> = const { Cell::new(false) };
    }

    fn get_text(hwnd: Hwnd) -> String {
        let len = unsafe { GetWindowTextLengthW(hwnd) };
        if len <= 0 {
            return String::new();
        }
        let mut buf = vec![0u16; (len + 1) as usize];
        let read = unsafe { GetWindowTextW(hwnd, buf.as_mut_ptr(), buf.len() as i32) };
        if read <= 0 {
            return String::new();
        }
        String::from_utf16_lossy(&buf[..read as usize])
    }

    fn set_text(hwnd: Hwnd, text: &str) {
        let w = wide(text);
        unsafe { SetWindowTextW(hwnd, w.as_ptr()) };
    }

    fn set_font(hwnd: Hwnd, font: *mut c_void) {
        unsafe { SendMessageW(hwnd, WM_SETFONT, font as usize, 1) };
    }

    fn make_font(pixel_height: i32) -> *mut c_void {
        let face = wide("Consolas");
        unsafe {
            CreateFontW(
                -pixel_height.abs().max(8),
                0,
                0,
                0,
                400, // FW_NORMAL
                0,
                0,
                0,
                1,    // DEFAULT_CHARSET
                0,    // OUT_DEFAULT_PRECIS
                0,    // CLIP_DEFAULT_PRECIS
                0,    // DEFAULT_QUALITY
                0x31, // FIXED_PITCH | FF_MODERN
                face.as_ptr(),
            )
        }
    }

    fn control(parent: Hwnd, class: &str, text: &str, style: u32, id: usize) -> Hwnd {
        let class_w = wide(class);
        let text_w = wide(text);
        unsafe {
            CreateWindowExW(
                0,
                class_w.as_ptr(),
                text_w.as_ptr(),
                WS_CHILD | WS_VISIBLE | style,
                0,
                0,
                10,
                10,
                parent,
                id as *mut c_void,
                GetModuleHandleW(std::ptr::null()),
                std::ptr::null_mut(),
            )
        }
    }

    fn add_tooltip(app: &App, target: Hwnd, text: &str) {
        if app.tooltip.is_null() || target.is_null() {
            return;
        }
        let text_w = wide(text);
        let mut info: ToolInfoW = unsafe { std::mem::zeroed() };
        info.cb_size = std::mem::size_of::<ToolInfoW>() as u32;
        info.u_flags = TTF_IDISHWND | TTF_SUBCLASS;
        info.hwnd = app.hwnd;
        info.u_id = target as usize;
        info.lpsz_text = text_w.as_ptr();
        unsafe {
            SendMessageW(
                app.tooltip,
                TTM_ADDTOOLW,
                0,
                &info as *const ToolInfoW as isize,
            );
        }
    }

    fn confirm(hwnd: Hwnd, text: &str) -> bool {
        let text_w = wide(text);
        let caption = wide("TermiNote");
        let answer = unsafe {
            MessageBoxW(
                hwnd,
                text_w.as_ptr(),
                caption.as_ptr(),
                MB_YESNO | MB_ICONQUESTION,
            )
        };
        answer == IDYES
    }

    fn info_box(hwnd: Hwnd, text: &str, warning: bool) {
        let text_w = wide(text);
        let caption = wide("TermiNote");
        let kind = if warning {
            MB_OK | MB_ICONWARNING
        } else {
            MB_OK | MB_ICONINFORMATION
        };
        unsafe { MessageBoxW(hwnd, text_w.as_ptr(), caption.as_ptr(), kind) };
    }

    fn scale(app: &App, value: i32) -> i32 {
        let dpi = unsafe { GetDpiForWindow(app.hwnd) };
        let dpi = if dpi == 0 { 96 } else { dpi } as i32;
        value * dpi / 96
    }

    // ---- Refresh helpers ----

    fn refresh_tags(app: &mut App) {
        unsafe { SendMessageW(app.tags_list, LB_RESETCONTENT, 0, 0) };
        app.tag_rows.clear();
        let rows: Vec<(String, TagSel)> = {
            let mut rows = vec![
                ("All notes".to_string(), TagSel::All),
                ("Untagged".to_string(), TagSel::Untagged),
            ];
            for (tag, count) in ops::all_tags(&app.store) {
                rows.push((format!("{tag} ({count})"), TagSel::Tag(tag)));
            }
            rows
        };
        let mut selected = 0isize;
        for (i, (label, sel)) in rows.iter().enumerate() {
            let w = wide(label);
            unsafe { SendMessageW(app.tags_list, LB_ADDSTRING, 0, w.as_ptr() as isize) };
            if *sel == app.tag_sel {
                selected = i as isize;
            }
            app.tag_rows.push(sel.clone());
        }
        // If the selected tag vanished (renamed/deleted), fall back.
        if !app.tag_rows.contains(&app.tag_sel) {
            app.tag_sel = TagSel::All;
            selected = 0;
        }
        unsafe { SendMessageW(app.tags_list, LB_SETCURSEL, selected as usize, 0) };
    }

    fn current_filter(app: &App) -> Filter {
        let (tag, untagged) = match &app.tag_sel {
            TagSel::All => (None, false),
            TagSel::Untagged => (None, true),
            TagSel::Tag(t) => (Some(t.clone()), false),
        };
        Filter {
            search: get_text(app.search),
            tag,
            untagged_only: untagged,
            sort: Some(app.sort),
        }
    }

    /// Refill the notes listbox. The strings added are note TITLES
    /// ONLY — body text never enters the list.
    fn refresh_list(app: &mut App) {
        let notes = ops::list(&app.store, &current_filter(app));
        app.shown_ids = notes.iter().map(|n| n.id).collect();
        unsafe { SendMessageW(app.notes_list, LB_RESETCONTENT, 0, 0) };
        for note in &notes {
            let label = if note.pinned {
                format!("\u{25B6} {}", note.title)
            } else {
                note.title.clone()
            };
            let w = wide(&label);
            unsafe { SendMessageW(app.notes_list, LB_ADDSTRING, 0, w.as_ptr() as isize) };
        }
        if let Some(current) = app.current_id {
            if let Some(pos) = app.shown_ids.iter().position(|id| *id == current) {
                unsafe { SendMessageW(app.notes_list, LB_SETCURSEL, pos, 0) };
            }
        }
        let total = app.store.notes.len();
        set_text(
            app.status,
            &format!(
                "{} of {} notes - {} in trash",
                app.shown_ids.len(),
                total,
                app.store.trash.len()
            ),
        );
    }

    fn update_counts(app: &App) {
        let body = get_text(app.body_edit);
        let title = get_text(app.title_edit);
        let chars = title.chars().count() + body.chars().count();
        let words = title.split_whitespace().count() + body.split_whitespace().count();
        set_text(app.counts, &format!("{chars} characters - {words} words"));
    }

    fn update_pin_button(app: &App) {
        let pinned = app
            .current_id
            .and_then(|id| ops::get(&app.store, id).ok().map(|n| n.pinned))
            .unwrap_or(false);
        set_text(app.pin_btn, if pinned { "Unpin" } else { "Pin" });
    }

    /// Fill the editor from a note (or clear it). Guarded by LOADING
    /// so our own writes do not trigger autosave.
    fn load_editor(app: &mut App, id: Option<u64>) {
        app.current_id = id;
        LOADING.with(|l| l.set(true));
        match id.and_then(|id| ops::get(&app.store, id).ok().cloned()) {
            Some(note) => {
                set_text(app.title_edit, &note.title);
                set_text(app.tags_edit, &note.tags.join(", "));
                set_text(app.body_edit, &note.body);
            }
            None => {
                set_text(app.title_edit, "");
                set_text(app.tags_edit, "");
                set_text(app.body_edit, "");
            }
        }
        LOADING.with(|l| l.set(false));
        app.settings.last_note = id.unwrap_or(0);
        update_counts(app);
        update_pin_button(app);
    }

    /// Write the editor back into the store and onto disk now.
    /// Returns true when there was a note open.
    fn save_now(app: &mut App) -> bool {
        let Some(id) = app.current_id else {
            return false;
        };
        let title = get_text(app.title_edit);
        let body = get_text(app.body_edit);
        let tags = parse_tag_list(&get_text(app.tags_edit));
        let now = time::now_unix();
        if ops::update(
            &mut app.store,
            id,
            Some(&title),
            Some(&body),
            Some(tags),
            now,
        )
        .is_err()
        {
            return false;
        }
        unsafe { KillTimer(app.hwnd, AUTOSAVE_TIMER) };
        match app.store.save(&app.data_path) {
            Ok(()) => {
                set_text(app.saved_label, &format!("Saved {}", time::hms_utc(now)));
                refresh_tags(app);
                refresh_list(app);
            }
            Err(message) => {
                set_text(app.saved_label, "Save failed");
                info_box(app.hwnd, &message, true);
            }
        }
        true
    }

    fn schedule_autosave(app: &App) {
        set_text(app.saved_label, "Saving...");
        unsafe {
            SetTimer(app.hwnd, AUTOSAVE_TIMER, AUTOSAVE_MS, std::ptr::null_mut());
        }
    }

    fn do_new_note(app: &mut App) {
        let now = time::now_unix();
        // A new note started from a tag view starts with that tag.
        let tags = match &app.tag_sel {
            TagSel::Tag(t) => vec![t.clone()],
            _ => Vec::new(),
        };
        let note = ops::add(&mut app.store, "Untitled note", "", tags, now);
        let _ = app.store.save(&app.data_path);
        app.tag_sel = TagSel::All;
        refresh_tags(app);
        refresh_list(app);
        load_editor(app, Some(note.id));
        if let Some(pos) = app.shown_ids.iter().position(|id| *id == note.id) {
            unsafe { SendMessageW(app.notes_list, LB_SETCURSEL, pos, 0) };
        }
        unsafe { SetFocus(app.title_edit) };
    }

    fn do_delete(app: &mut App, id: u64) {
        let title = ops::get(&app.store, id)
            .map(|n| n.title.clone())
            .unwrap_or_default();
        if !confirm(
            app.hwnd,
            &format!("Move \"{title}\" to the trash? You can bring it back with Undo delete."),
        ) {
            return;
        }
        let now = time::now_unix();
        if ops::delete(&mut app.store, id, now).is_ok() {
            app.last_deleted = Some(id);
            let _ = app.store.save(&app.data_path);
            if app.current_id == Some(id) {
                load_editor(app, None);
            }
            refresh_tags(app);
            refresh_list(app);
            set_text(app.saved_label, "Moved to trash");
        }
    }

    fn do_undo_delete(app: &mut App) {
        // Prefer the last note this session deleted; fall back to the
        // most recently trashed note.
        let target = app
            .last_deleted
            .filter(|id| ops::get_trashed(&app.store, *id).is_ok())
            .or_else(|| ops::list_trash(&app.store).first().map(|n| n.id));
        let Some(id) = target else {
            info_box(
                app.hwnd,
                "There is nothing in the trash to bring back.",
                false,
            );
            return;
        };
        let now = time::now_unix();
        if let Ok(note) = ops::restore(&mut app.store, id, now) {
            app.last_deleted = None;
            let _ = app.store.save(&app.data_path);
            refresh_tags(app);
            refresh_list(app);
            load_editor(app, Some(note.id));
            set_text(app.saved_label, "Note restored");
        }
    }

    fn import_one_file(app: &mut App, path: &std::path::Path) -> Result<String, String> {
        let ext = path
            .extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        let now = time::now_unix();
        match ext.as_str() {
            "txt" | "md" => {
                let body = std::fs::read_to_string(path)
                    .map_err(|e| format!("could not read {}: {e}", path.display()))?;
                let title = path
                    .file_stem()
                    .map(|s| s.to_string_lossy().into_owned())
                    .filter(|s| !s.trim().is_empty())
                    .unwrap_or_else(|| "Imported note".to_string());
                let note = ops::add(&mut app.store, &title, &body, Vec::new(), now);
                Ok(format!("Imported \"{}\" as note {}.", note.title, note.id))
            }
            "json" => {
                let text = std::fs::read_to_string(path)
                    .map_err(|e| format!("could not read {}: {e}", path.display()))?;
                let count = ops::import_json(&mut app.store, &text, now)?;
                Ok(format!("Imported {count} note(s) from the file."))
            }
            _ => Err(format!(
                "skipped {}: only .txt, .md and .json files can be dropped here",
                path.display()
            )),
        }
    }

    fn layout(app: &App, width: i32, height: i32) {
        let pad = scale(app, 8);
        let toolbar_h = scale(app, 34);
        let sidebar_w = scale(app, 176);
        let moveit = |hwnd: Hwnd, x: i32, y: i32, w: i32, h: i32| {
            if !hwnd.is_null() && w > 0 && h > 0 {
                unsafe { MoveWindow(hwnd, x, y, w, h, 1) };
            }
        };
        // Sidebar.
        let label = unsafe { GetDlgItem(app.hwnd, ID_TAGS_LABEL as i32) };
        moveit(label, pad, pad, sidebar_w, scale(app, 20));
        moveit(
            app.tags_list,
            pad,
            pad + scale(app, 24),
            sidebar_w,
            (height - scale(app, 24) - scale(app, 30) - pad).max(40),
        );
        moveit(
            app.status,
            pad,
            height - scale(app, 24),
            sidebar_w + pad,
            scale(app, 20),
        );
        // Main column.
        let main_x = sidebar_w + pad * 2;
        let main_w = (width - main_x - pad).max(120);
        let add_w = scale(app, 128);
        let delete_all_w = scale(app, 104);
        let undo_w = scale(app, 116);
        let help_w = scale(app, 64);
        let about_w = scale(app, 68);
        let gaps = pad * 5;
        let search_w =
            (main_w - add_w - delete_all_w - undo_w - help_w - about_w - gaps).max(scale(app, 90));
        let mut x = main_x;
        moveit(app.search, x, pad, search_w, toolbar_h);
        x += search_w + pad;
        let add_btn = unsafe { GetDlgItem(app.hwnd, ID_ADD as i32) };
        moveit(add_btn, x, pad, add_w, toolbar_h);
        x += add_w + pad;
        let del_all = unsafe { GetDlgItem(app.hwnd, ID_DELETE_ALL as i32) };
        moveit(del_all, x, pad, delete_all_w, toolbar_h);
        x += delete_all_w + pad;
        let undo = unsafe { GetDlgItem(app.hwnd, ID_UNDO_DELETE as i32) };
        moveit(undo, x, pad, undo_w, toolbar_h);
        x += undo_w + pad;
        let help = unsafe { GetDlgItem(app.hwnd, ID_HELP as i32) };
        moveit(help, x, pad, help_w, toolbar_h);
        x += help_w + pad;
        let about = unsafe { GetDlgItem(app.hwnd, ID_ABOUT as i32) };
        moveit(about, x, pad, about_w, toolbar_h);
        // Sort hint under the toolbar, above the list.
        let list_y = pad + toolbar_h + pad + scale(app, 20);
        moveit(
            app.sort_label,
            main_x,
            pad + toolbar_h + pad,
            main_w,
            scale(app, 18),
        );
        // Notes list: about 38% of the main width.
        let list_w = ((main_w * 38) / 100).max(scale(app, 120));
        moveit(
            app.notes_list,
            main_x,
            list_y,
            list_w,
            (height - list_y - pad).max(40),
        );
        // Editor pane.
        let ex = main_x + list_w + pad;
        let ew = (width - ex - pad).max(scale(app, 140));
        let title_h = scale(app, 30);
        let tags_h = scale(app, 26);
        moveit(app.title_edit, ex, list_y, ew, title_h);
        moveit(app.tags_edit, ex, list_y + title_h + pad, ew, tags_h);
        let body_y = list_y + title_h + tags_h + pad * 2;
        let bottom_h = scale(app, 30);
        let body_h = (height - body_y - bottom_h - pad * 2).max(40);
        moveit(app.body_edit, ex, body_y, ew, body_h);
        // Editor bottom bar.
        let by = height - bottom_h - pad;
        let counts_w = scale(app, 216);
        moveit(app.counts, ex, by + scale(app, 4), counts_w, scale(app, 20));
        let mut bx = ex + counts_w + pad;
        let small = scale(app, 44);
        let font_down = unsafe { GetDlgItem(app.hwnd, ID_FONT_DOWN as i32) };
        moveit(font_down, bx, by, small, bottom_h);
        bx += small + pad / 2;
        let font_up = unsafe { GetDlgItem(app.hwnd, ID_FONT_UP as i32) };
        moveit(font_up, bx, by, small, bottom_h);
        bx += small + pad;
        moveit(app.pin_btn, bx, by, scale(app, 64), bottom_h);
        bx += scale(app, 64) + pad / 2;
        let dup = unsafe { GetDlgItem(app.hwnd, ID_DUPLICATE as i32) };
        moveit(dup, bx, by, scale(app, 92), bottom_h);
        bx += scale(app, 92) + pad / 2;
        let del = unsafe { GetDlgItem(app.hwnd, ID_DELETE as i32) };
        moveit(del, bx, by, scale(app, 72), bottom_h);
        bx += scale(app, 72) + pad / 2;
        let close = unsafe { GetDlgItem(app.hwnd, ID_CLOSE_EDITOR as i32) };
        moveit(close, bx, by, scale(app, 72), bottom_h);
        // Saved indicator sits above the bottom bar, right-aligned area.
        moveit(
            app.saved_label,
            ex,
            body_y + body_h + pad / 2,
            ew,
            scale(app, 18),
        );
    }

    fn apply_font(app: &mut App) {
        let new_font = make_font(app.settings.font_size);
        if new_font.is_null() {
            return;
        }
        let ids = [
            ID_TAGS_LIST,
            ID_STATUS,
            ID_SEARCH,
            ID_NOTES_LIST,
            ID_TITLE,
            ID_TAGS_EDIT,
            ID_BODY,
            ID_COUNTS,
            ID_SAVED,
            ID_SORT_LABEL,
            ID_TAGS_LABEL,
            ID_ADD,
            ID_DELETE_ALL,
            ID_UNDO_DELETE,
            ID_HELP,
            ID_ABOUT,
            ID_FONT_DOWN,
            ID_FONT_UP,
            ID_PIN,
            ID_DUPLICATE,
            ID_DELETE,
            ID_CLOSE_EDITOR,
        ];
        for id in ids {
            let c = unsafe { GetDlgItem(app.hwnd, id as i32) };
            if !c.is_null() {
                set_font(c, new_font);
            }
        }
        let item_h = scale(app, app.settings.font_size + 10);
        unsafe {
            SendMessageW(app.notes_list, LB_SETITEMHEIGHT, 0, item_h as isize);
            SendMessageW(app.tags_list, LB_SETITEMHEIGHT, 0, item_h as isize);
        }
        let old = app.font;
        app.font = new_font;
        if !old.is_null() {
            unsafe { DeleteObject(old) };
        }
    }

    fn change_font_size(app: &mut App, delta: i32) {
        let next = (app.settings.font_size + delta).clamp(10, 40);
        if next != app.settings.font_size {
            app.settings.font_size = next;
            apply_font(app);
            let mut rect = Rect {
                left: 0,
                top: 0,
                right: 0,
                bottom: 0,
            };
            unsafe { GetClientRect(app.hwnd, &mut rect) };
            layout(app, rect.right, rect.bottom);
            app.settings.save(&app.settings_path);
        }
    }

    fn create_controls(app: &mut App) {
        let hwnd = app.hwnd;
        let base = WS_TABSTOP;
        control(hwnd, "STATIC", "TAGS", 0, ID_TAGS_LABEL);
        app.tags_list = control(
            hwnd,
            "LISTBOX",
            "",
            base | WS_VSCROLL | WS_BORDER | LBS_NOTIFY,
            ID_TAGS_LIST,
        );
        app.status = control(hwnd, "STATIC", "", 0, ID_STATUS);
        app.search = control(
            hwnd,
            "EDIT",
            "",
            base | WS_BORDER | ES_AUTOHSCROLL,
            ID_SEARCH,
        );
        let cue = wide("Search notes");
        unsafe {
            SendMessageW(app.search, EM_SETCUEBANNER, 1, cue.as_ptr() as isize);
        }
        control(hwnd, "BUTTON", "Add note", base | BS_OWNERDRAW, ID_ADD);
        control(hwnd, "BUTTON", "Delete all", base, ID_DELETE_ALL);
        control(hwnd, "BUTTON", "Undo delete", base, ID_UNDO_DELETE);
        control(hwnd, "BUTTON", "Help", base, ID_HELP);
        control(hwnd, "BUTTON", "About", base, ID_ABOUT);
        app.sort_label = control(
            hwnd,
            "STATIC",
            "Notes - titles only - newest first",
            0,
            ID_SORT_LABEL,
        );
        app.notes_list = control(
            hwnd,
            "LISTBOX",
            "",
            base | WS_VSCROLL | WS_BORDER | LBS_NOTIFY | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS,
            ID_NOTES_LIST,
        );
        app.title_edit = control(
            hwnd,
            "EDIT",
            "",
            base | WS_BORDER | ES_AUTOHSCROLL,
            ID_TITLE,
        );
        let title_cue = wide("Note title");
        unsafe {
            SendMessageW(
                app.title_edit,
                EM_SETCUEBANNER,
                1,
                title_cue.as_ptr() as isize,
            );
        }
        app.tags_edit = control(
            hwnd,
            "EDIT",
            "",
            base | WS_BORDER | ES_AUTOHSCROLL,
            ID_TAGS_EDIT,
        );
        let tags_cue = wide("Tags, separated by commas");
        unsafe {
            SendMessageW(
                app.tags_edit,
                EM_SETCUEBANNER,
                1,
                tags_cue.as_ptr() as isize,
            );
        }
        app.body_edit = control(
            hwnd,
            "EDIT",
            "",
            base | WS_BORDER
                | WS_VSCROLL
                | WS_HSCROLL
                | ES_MULTILINE
                | ES_AUTOVSCROLL
                | ES_WANTRETURN,
            ID_BODY,
        );
        app.counts = control(hwnd, "STATIC", "0 characters - 0 words", 0, ID_COUNTS);
        control(hwnd, "BUTTON", "A-", base, ID_FONT_DOWN);
        control(hwnd, "BUTTON", "A+", base, ID_FONT_UP);
        app.pin_btn = control(hwnd, "BUTTON", "Pin", base, ID_PIN);
        control(hwnd, "BUTTON", "Duplicate", base, ID_DUPLICATE);
        control(hwnd, "BUTTON", "Delete", base, ID_DELETE);
        control(hwnd, "BUTTON", "Close", base, ID_CLOSE_EDITOR);
        app.saved_label = control(hwnd, "STATIC", "", 0, ID_SAVED);

        // Tooltip control: one per window, tools added per control.
        let init = InitCommonControlsEx {
            dw_size: std::mem::size_of::<InitCommonControlsEx>() as u32,
            dw_icc: 0x0000_003F, // ICC_WIN95_CLASSES (includes tooltips)
        };
        unsafe { InitCommonControlsEx(&init) };
        let class = wide("tooltips_class32");
        app.tooltip = unsafe {
            CreateWindowExW(
                8, // WS_EX_TOPMOST
                class.as_ptr(),
                std::ptr::null(),
                WS_POPUP | 0x01 | 0x02, // TTS_ALWAYSTIP | TTS_NOPREFIX
                0,
                0,
                0,
                0,
                hwnd,
                std::ptr::null_mut(),
                GetModuleHandleW(std::ptr::null()),
                std::ptr::null_mut(),
            )
        };
        let tips: [(usize, &str); 19] = [
            (ID_TAGS_LIST, "Filter notes by tag. Tags are the only organisation in TermiNote."),
            (ID_STATUS, "How many notes are shown, and how many are in the trash."),
            (ID_SEARCH, "Search note titles, bodies and tags (Ctrl+F)."),
            (ID_ADD, "Add a new note (Ctrl+N)."),
            (ID_DELETE_ALL, "Move every note to the trash. Notes can be restored from the trash."),
            (ID_UNDO_DELETE, "Bring back the last deleted note (Ctrl+Shift+Z)."),
            (ID_HELP, "Show the built-in help (F1)."),
            (ID_ABOUT, "About TermiNote: version and licence."),
            (ID_NOTES_LIST, "Your notes, titles only. Click one to open it. Delete key deletes after asking."),
            (ID_TITLE, "The note's title. This is what the list shows."),
            (ID_TAGS_EDIT, "Tags for this note, separated by commas. Tags organise notes; there are no folders."),
            (ID_BODY, "The note itself. It saves automatically as you type."),
            (ID_COUNTS, "Character and word count for the open note."),
            (ID_FONT_DOWN, "Make the text smaller."),
            (ID_FONT_UP, "Make the text bigger."),
            (ID_PIN, "Pin this note to the top of the list, or unpin it."),
            (ID_DUPLICATE, "Make a copy of this note."),
            (ID_DELETE, "Move this note to the trash. Undo delete can bring it back."),
            (ID_CLOSE_EDITOR, "Close the editor (the note is already saved)."),
        ];
        for (id, text) in tips {
            let target = unsafe { GetDlgItem(hwnd, id as i32) };
            add_tooltip(app, target, text);
        }
    }

    unsafe extern "system" fn wnd_proc(hwnd: Hwnd, msg: u32, w: usize, l: isize) -> isize {
        match msg {
            WM_CREATE => {
                let data_path = store::data_file_path();
                let settings_path = store::settings_file_path();
                let settings = Settings::load(&settings_path);
                let outcome = Store::load(&data_path, time::now_unix());
                let sort = Sort::parse(&settings.sort).unwrap_or(Sort::ModifiedDesc);
                let tag_sel = TagSel::from_setting(&settings.last_tag);
                let mut app = App {
                    hwnd,
                    store: outcome.store,
                    data_path,
                    settings_path,
                    settings,
                    was_corrupt: outcome.was_corrupt,
                    tags_list: std::ptr::null_mut(),
                    status: std::ptr::null_mut(),
                    search: std::ptr::null_mut(),
                    notes_list: std::ptr::null_mut(),
                    title_edit: std::ptr::null_mut(),
                    tags_edit: std::ptr::null_mut(),
                    body_edit: std::ptr::null_mut(),
                    counts: std::ptr::null_mut(),
                    saved_label: std::ptr::null_mut(),
                    sort_label: std::ptr::null_mut(),
                    pin_btn: std::ptr::null_mut(),
                    tooltip: std::ptr::null_mut(),
                    font: std::ptr::null_mut(),
                    black_brush: CreateSolidBrush(COLOR_BG),
                    panel_brush: CreateSolidBrush(COLOR_PANEL),
                    red_brush: CreateSolidBrush(COLOR_RED),
                    tag_sel,
                    tag_rows: Vec::new(),
                    shown_ids: Vec::new(),
                    current_id: None,
                    last_deleted: None,
                    sort,
                };
                create_controls(&mut app);
                let corrupt = app.was_corrupt;
                APP.with(|slot| *slot.borrow_mut() = Some(app));
                APP.with(|slot| {
                    let mut slot = slot.borrow_mut();
                    let app = slot.as_mut().unwrap();
                    apply_font(app);
                    refresh_tags(app);
                    refresh_list(app);
                    let last = app.settings.last_note;
                    let target = if last != 0 && ops::get(&app.store, last).is_ok() {
                        Some(last)
                    } else {
                        app.shown_ids.first().copied()
                    };
                    load_editor(app, target);
                    if let Some(id) = target {
                        if let Some(pos) = app.shown_ids.iter().position(|x| *x == id) {
                            unsafe { SendMessageW(app.notes_list, LB_SETCURSEL, pos, 0) };
                        }
                    }
                });
                unsafe { DragAcceptFiles(hwnd, 1) };
                if corrupt {
                    info_box(
                        hwnd,
                        "The data file was damaged, so it was moved aside (its name now has \".corrupt-\" in it) and TermiNote started with an empty store. Nothing was deleted: the damaged file is still in the data folder.",
                        true,
                    );
                }
                0
            }
            WM_GETMINMAXINFO => {
                let info = l as *mut MinMaxInfo;
                if !info.is_null() {
                    (*info).pt_min_track_size = Point { x: 920, y: 560 };
                }
                0
            }
            WM_SIZE => {
                let width = (l & 0xFFFF) as i32;
                let height = ((l >> 16) & 0xFFFF) as i32;
                APP.with(|slot| {
                    if let Some(app) = slot.borrow().as_ref() {
                        layout(app, width, height);
                    }
                });
                0
            }
            WM_MEASUREITEM => {
                let item = l as *mut MeasureItem;
                if !item.is_null() {
                    // Both owner-drawn controls use the same row height.
                    (*item).item_height = 26;
                }
                1
            }
            WM_DRAWITEM => {
                let item = &*(l as *const DrawItem);
                APP.with(|slot| {
                    let slot = slot.borrow();
                    let Some(app) = slot.as_ref() else { return };
                    if item.ctl_id == ID_ADD as u32 {
                        // Red primary button, white text.
                        FillRect(item.hdc, &item.rc_item, app.red_brush);
                        SetTextColor(item.hdc, COLOR_WHITE);
                        SetBkMode(item.hdc, TRANSPARENT);
                        if !app.font.is_null() {
                            SelectObject(item.hdc, app.font);
                        }
                        let text = wide("Add note");
                        let mut rect = Rect {
                            left: item.rc_item.left,
                            top: item.rc_item.top,
                            right: item.rc_item.right,
                            bottom: item.rc_item.bottom,
                        };
                        DrawTextW(
                            item.hdc,
                            text.as_ptr(),
                            -1,
                            &mut rect,
                            0x0001 | 0x0004 | 0x0020, // CENTER | VCENTER | SINGLELINE
                        );
                    } else if item.ctl_id == ID_NOTES_LIST as u32 && item.item_id != u32::MAX {
                        let selected = item.item_state & 0x0001 != 0; // ODS_SELECTED
                        let brush = if selected {
                            app.red_brush
                        } else {
                            app.black_brush
                        };
                        FillRect(item.hdc, &item.rc_item, brush);
                        SetTextColor(item.hdc, COLOR_WHITE);
                        SetBkMode(item.hdc, TRANSPARENT);
                        if !app.font.is_null() {
                            SelectObject(item.hdc, app.font);
                        }
                        let len =
                            SendMessageW(item.hwnd_item, LB_GETTEXTLEN, item.item_id as usize, 0);
                        if len > 0 {
                            let mut buf = vec![0u16; (len + 1) as usize];
                            SendMessageW(
                                item.hwnd_item,
                                LB_GETTEXT,
                                item.item_id as usize,
                                buf.as_mut_ptr() as isize,
                            );
                            TextOutW(
                                item.hdc,
                                item.rc_item.left + 8,
                                item.rc_item.top + 4,
                                buf.as_ptr(),
                                len as i32,
                            );
                        }
                    }
                });
                1
            }
            WM_CTLCOLOREDIT | WM_CTLCOLORLISTBOX => APP.with(|slot| {
                let slot = slot.borrow();
                let Some(app) = slot.as_ref() else { return 0 };
                SetTextColor(w as Hdc, COLOR_WHITE);
                SetBkColor(w as Hdc, COLOR_BG);
                app.black_brush as isize
            }),
            WM_CTLCOLORSTATIC => APP.with(|slot| {
                let slot = slot.borrow();
                let Some(app) = slot.as_ref() else { return 0 };
                SetTextColor(w as Hdc, COLOR_WHITE);
                SetBkColor(w as Hdc, COLOR_BG);
                SetBkMode(w as Hdc, TRANSPARENT);
                app.black_brush as isize
            }),
            WM_CTLCOLORBTN => APP.with(|slot| {
                let slot = slot.borrow();
                let Some(app) = slot.as_ref() else { return 0 };
                SetTextColor(w as Hdc, COLOR_WHITE);
                SetBkColor(w as Hdc, COLOR_PANEL);
                app.panel_brush as isize
            }),
            WM_TIMER => {
                if w == AUTOSAVE_TIMER {
                    APP.with(|slot| {
                        if let Some(app) = slot.borrow_mut().as_mut() {
                            save_now(app);
                        }
                    });
                }
                0
            }
            WM_COMMAND => {
                let id = w & 0xFFFF;
                let code = (w >> 16) & 0xFFFF;
                handle_command(hwnd, id, code);
                0
            }
            WM_DROPFILES => {
                let drop = w as *mut c_void;
                let count = DragQueryFileW(drop, 0xFFFF_FFFF, std::ptr::null_mut(), 0);
                let mut messages: Vec<String> = Vec::new();
                APP.with(|slot| {
                    if let Some(app) = slot.borrow_mut().as_mut() {
                        let mut changed = false;
                        for i in 0..count {
                            let len = DragQueryFileW(drop, i, std::ptr::null_mut(), 0);
                            if len == 0 {
                                continue;
                            }
                            let mut buf = vec![0u16; (len + 1) as usize];
                            DragQueryFileW(drop, i, buf.as_mut_ptr(), buf.len() as u32);
                            let path = String::from_utf16_lossy(&buf[..len as usize]);
                            match import_one_file(app, std::path::Path::new(&path)) {
                                Ok(m) => {
                                    messages.push(m);
                                    changed = true;
                                }
                                Err(m) => messages.push(m),
                            }
                        }
                        if changed {
                            let _ = app.store.save(&app.data_path);
                            refresh_tags(app);
                            refresh_list(app);
                        }
                    }
                });
                DragFinish(drop);
                if !messages.is_empty() {
                    info_box(hwnd, &messages.join("\n"), false);
                }
                0
            }
            WM_CLOSE => {
                APP.with(|slot| {
                    if let Some(app) = slot.borrow_mut().as_mut() {
                        save_now(app);
                        let mut rect = Rect {
                            left: 0,
                            top: 0,
                            right: 0,
                            bottom: 0,
                        };
                        GetWindowRect(hwnd, &mut rect);
                        app.settings.x = rect.left;
                        app.settings.y = rect.top;
                        app.settings.w = (rect.right - rect.left).max(0);
                        app.settings.h = (rect.bottom - rect.top).max(0);
                        app.settings.last_note = app.current_id.unwrap_or(0);
                        app.settings.last_tag = app.tag_sel.setting_name();
                        app.settings.sort = app.sort.name().to_string();
                        let path = app.settings_path.clone();
                        app.settings.save(&path);
                    }
                });
                DestroyWindow(hwnd);
                0
            }
            WM_DESTROY => {
                APP.with(|slot| {
                    if let Some(app) = slot.borrow_mut().take() {
                        if !app.font.is_null() {
                            DeleteObject(app.font);
                        }
                        if !app.black_brush.is_null() {
                            DeleteObject(app.black_brush);
                        }
                        if !app.panel_brush.is_null() {
                            DeleteObject(app.panel_brush);
                        }
                        if !app.red_brush.is_null() {
                            DeleteObject(app.red_brush);
                        }
                    }
                });
                PostQuitMessage(0);
                0
            }
            _ => DefWindowProcW(hwnd, msg, w, l),
        }
    }

    fn handle_command(hwnd: Hwnd, id: usize, code: usize) {
        match (id, code) {
            (ID_ADD, _) => APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    do_new_note(app);
                }
            }),
            (ID_DELETE_ALL, _) => {
                let yes = APP.with(|slot| {
                    let slot = slot.borrow();
                    let Some(app) = slot.as_ref() else { return false };
                    if app.store.notes.is_empty() {
                        info_box(hwnd, "There are no notes to delete.", false);
                        return false;
                    }
                    confirm(
                        hwnd,
                        "Move EVERY note to the trash? You can restore them one at a time afterwards.",
                    )
                });
                if yes {
                    APP.with(|slot| {
                        if let Some(app) = slot.borrow_mut().as_mut() {
                            let now = time::now_unix();
                            let count = ops::delete_all(&mut app.store, now);
                            app.last_deleted = ops::list_trash(&app.store).first().map(|n| n.id);
                            let _ = app.store.save(&app.data_path);
                            load_editor(app, None);
                            refresh_tags(app);
                            refresh_list(app);
                            set_text(app.saved_label, &format!("Moved {count} notes to trash"));
                        }
                    });
                }
            }
            (ID_UNDO_DELETE, _) => APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    do_undo_delete(app);
                }
            }),
            (ID_HELP, _) => info_box(hwnd, HELP_TEXT, false),
            (ID_ABOUT, _) => info_box(hwnd, &about_text(), false),
            (ID_TAGS_LIST, LBN_SELCHANGE) => APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    let sel = unsafe { SendMessageW(app.tags_list, LB_GETCURSEL, 0, 0) };
                    if sel >= 0 {
                        if let Some(sel_tag) = app.tag_rows.get(sel as usize).cloned() {
                            app.tag_sel = sel_tag;
                            refresh_list(app);
                        }
                    }
                }
            }),
            (ID_NOTES_LIST, LBN_SELCHANGE) => APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    let sel = unsafe { SendMessageW(app.notes_list, LB_GETCURSEL, 0, 0) };
                    if sel >= 0 {
                        if let Some(id) = app.shown_ids.get(sel as usize).copied() {
                            load_editor(app, Some(id));
                        }
                    }
                }
            }),
            (ID_SEARCH, EN_CHANGE) => APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    refresh_list(app);
                }
            }),
            (ID_TITLE, EN_CHANGE) | (ID_TAGS_EDIT, EN_CHANGE) | (ID_BODY, EN_CHANGE) => {
                if !LOADING.with(|l| l.get()) {
                    APP.with(|slot| {
                        if let Some(app) = slot.borrow_mut().as_mut() {
                            if app.current_id.is_some() {
                                update_counts(app);
                                schedule_autosave(app);
                            }
                        }
                    });
                }
            }
            (ID_PIN, _) => APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    if let Some(id) = app.current_id {
                        let now = time::now_unix();
                        if ops::toggle_pin(&mut app.store, id, now).is_ok() {
                            let _ = app.store.save(&app.data_path);
                            update_pin_button(app);
                            refresh_list(app);
                            set_text(app.saved_label, "Saved");
                        }
                    }
                }
            }),
            (ID_DUPLICATE, _) => APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    if let Some(id) = app.current_id {
                        let now = time::now_unix();
                        if let Ok(copy) = ops::duplicate(&mut app.store, id, now) {
                            let _ = app.store.save(&app.data_path);
                            refresh_tags(app);
                            refresh_list(app);
                            load_editor(app, Some(copy.id));
                            set_text(app.saved_label, "Duplicated");
                        }
                    }
                }
            }),
            (ID_DELETE, _) => APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    if let Some(id) = app.current_id {
                        do_delete(app, id);
                    }
                }
            }),
            (ID_CLOSE_EDITOR, _) => APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    save_now(app);
                    load_editor(app, None);
                    unsafe { SendMessageW(app.notes_list, LB_SETCURSEL, usize::MAX, 0) };
                }
            }),
            (ID_FONT_DOWN, _) => APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    change_font_size(app, -2);
                }
            }),
            (ID_FONT_UP, _) => APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    change_font_size(app, 2);
                }
            }),
            _ => {}
        }
    }

    /// App-level shortcuts, checked in the message loop before
    /// dispatch. Returns true when the key was handled. Ctrl+Z
    /// without Shift is deliberately not intercepted, so the edit
    /// controls keep their native typing undo.
    fn handle_shortcut(msg: &Msg) -> bool {
        if msg.message != WM_KEYDOWN {
            return false;
        }
        let ctrl = unsafe { GetKeyState(VK_CONTROL) } < 0;
        let shift = unsafe { GetKeyState(VK_SHIFT) } < 0;
        let vk = msg.w_param;
        if vk == VK_F1 {
            APP.with(|slot| {
                if let Some(app) = slot.borrow().as_ref() {
                    info_box(app.hwnd, HELP_TEXT, false);
                }
            });
            return true;
        }
        if ctrl && shift && vk == 0x5A {
            // Ctrl+Shift+Z: undo delete.
            APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    do_undo_delete(app);
                }
            });
            return true;
        }
        if ctrl && vk == 0x4E {
            // Ctrl+N
            APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    do_new_note(app);
                }
            });
            return true;
        }
        if ctrl && vk == 0x53 {
            // Ctrl+S
            APP.with(|slot| {
                if let Some(app) = slot.borrow_mut().as_mut() {
                    save_now(app);
                }
            });
            return true;
        }
        if ctrl && vk == 0x46 {
            // Ctrl+F
            APP.with(|slot| {
                if let Some(app) = slot.borrow().as_ref() {
                    unsafe { SetFocus(app.search) };
                }
            });
            return true;
        }
        if vk == VK_DELETE {
            // Delete key deletes only when the notes list has focus.
            let handled = APP.with(|slot| {
                let mut slot = slot.borrow_mut();
                let Some(app) = slot.as_mut() else {
                    return false;
                };
                if unsafe { GetFocus() } != app.notes_list {
                    return false;
                }
                let sel = unsafe { SendMessageW(app.notes_list, LB_GETCURSEL, 0, 0) };
                if sel < 0 {
                    return false;
                }
                if let Some(id) = app.shown_ids.get(sel as usize).copied() {
                    do_delete(app, id);
                    return true;
                }
                false
            });
            return handled;
        }
        false
    }

    pub fn run() -> Result<(), String> {
        let instance = unsafe { GetModuleHandleW(std::ptr::null()) };
        let class_name = wide("TermiNoteWindow");
        let bg = unsafe { CreateSolidBrush(COLOR_BG) };
        let cursor = unsafe { LoadCursorW(std::ptr::null_mut(), 32512 as *const u16) };
        let wc = WndClassExW {
            cb_size: std::mem::size_of::<WndClassExW>() as u32,
            style: 0x0003, // CS_HREDRAW | CS_VREDRAW
            lpfn_wnd_proc: wnd_proc,
            cb_cls_extra: 0,
            cb_wnd_extra: 0,
            h_instance: instance,
            h_icon: std::ptr::null_mut(),
            h_cursor: cursor,
            hbr_background: bg,
            lpsz_menu_name: std::ptr::null(),
            lpsz_class_name: class_name.as_ptr(),
            h_icon_sm: std::ptr::null_mut(),
        };
        unsafe { RegisterClassExW(&wc) };

        // Restore the previous window position when there is one.
        let settings = Settings::load(&store::settings_file_path());
        let (x, y, w, h) = if settings.w > 100 && settings.h > 100 {
            (settings.x, settings.y, settings.w, settings.h)
        } else {
            (CW_USEDEFAULT, CW_USEDEFAULT, 1180, 720)
        };
        let title = wide("TermiNote");
        let hwnd = unsafe {
            CreateWindowExW(
                0,
                class_name.as_ptr(),
                title.as_ptr(),
                WS_OVERLAPPEDWINDOW,
                x,
                y,
                w,
                h,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                instance,
                std::ptr::null_mut(),
            )
        };
        if hwnd.is_null() {
            return Err("could not create the TermiNote window".to_string());
        }
        unsafe { ShowWindow(hwnd, SW_SHOW) };

        let mut msg: Msg = unsafe { std::mem::zeroed() };
        loop {
            let got = unsafe { GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) };
            if got <= 0 {
                break;
            }
            if !handle_shortcut(&msg) {
                unsafe {
                    TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
        }
        Ok(())
    }
}
