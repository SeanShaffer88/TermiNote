#![cfg_attr(windows, windows_subsystem = "windows")]

//! TermiNote entry point.
//!
//! - No arguments: open the GUI (Windows). On other systems, print
//!   the help text instead.
//! - Any argument: run the command line (full parity with the GUI).
//!
//! The binary uses the `windows` subsystem so the GUI does not get a
//! console window. When command-line arguments are present on
//! Windows, the parent console is attached first so CLI output is
//! visible in the terminal the user typed in.

use std::process::ExitCode;

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if !argv.is_empty() {
        #[cfg(windows)]
        attach_parent_console();
        let code = terminote::cli::run(&argv);
        return ExitCode::from(code as u8);
    }
    #[cfg(windows)]
    {
        set_dpi_awareness();
        match terminote::gui::run() {
            Ok(()) => ExitCode::SUCCESS,
            Err(message) => {
                eprintln!("terminote: {message}");
                ExitCode::from(1)
            }
        }
    }
    #[cfg(not(windows))]
    {
        print!("{}", terminote::cli::HELP);
        ExitCode::SUCCESS
    }
}

/// Attach to the console of the parent process (the terminal that
/// launched us) so `println!`/`eprintln!` work in CLI mode despite
/// the `windows` subsystem. Harmless when there is no parent console.
#[cfg(windows)]
fn attach_parent_console() {
    const ATTACH_PARENT_PROCESS: u32 = 0xFFFF_FFFF;
    extern "system" {
        fn AttachConsole(process_id: u32) -> i32;
    }
    unsafe {
        AttachConsole(ATTACH_PARENT_PROCESS);
    }
}

/// Per-Monitor V2 DPI awareness, set before any window exists. The
/// value -4 is `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`.
#[cfg(windows)]
fn set_dpi_awareness() {
    extern "system" {
        fn SetProcessDpiAwarenessContext(value: isize) -> i32;
    }
    unsafe {
        SetProcessDpiAwarenessContext(-4);
    }
}
