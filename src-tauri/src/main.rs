#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if terminote_core::cli::is_cli_args(&args) {
        #[cfg(windows)]
        attach_console();
        let exe = std::env::current_exe().unwrap_or_default();
        let environment = std::env::vars().collect::<std::collections::HashMap<_, _>>();
        let data_dir = terminote_core::resolve_data_dir(&environment, &exe);
        let _lock = match terminote_core::acquire_data_lock(&data_dir) {
            Ok(lock) => lock,
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        };
        std::process::exit(terminote_core::cli::run_cli(&args, &data_dir));
    }
    terminote_lib::run();
}

#[cfg(windows)]
fn attach_console() {
    use windows_sys::Win32::System::Console::{ATTACH_PARENT_PROCESS, AllocConsole, AttachConsole};
    unsafe {
        if AttachConsole(ATTACH_PARENT_PROCESS) == 0 {
            let _ = AllocConsole();
        }
    }
}

