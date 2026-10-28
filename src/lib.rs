//! TermiNote library: the data model, the JSON store, every
//! operation, the command line, and (on Windows) the GUI.
//!
//! The GUI and CLI are thin shells over [`ops`]; all behaviour lives
//! there so the two can never drift apart.

pub mod cli;
pub mod gui;
pub mod json;
pub mod note;
pub mod ops;
pub mod store;

pub use note::Note;
pub use ops::{Filter, Sort, Stats};
pub use store::Store;

/// Current time as unix seconds. Kept tiny and in one place so
/// operations themselves stay deterministic (they take `now` as a
/// parameter).
pub mod time {
    pub fn now_unix() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }

    /// Format unix seconds as `HH:MM:SS` in UTC. Used for the GUI's
    /// "Saved HH:MM:SS" indicator; UTC keeps it dependency-free and
    /// unambiguous in logs.
    pub fn hms_utc(unix: u64) -> String {
        let secs = unix % 60;
        let mins = (unix / 60) % 60;
        let hours = (unix / 3600) % 24;
        format!("{hours:02}:{mins:02}:{secs:02}")
    }
}

#[cfg(test)]
mod tests {
    use super::time;

    #[test]
    fn hms_formats() {
        assert_eq!(time::hms_utc(0), "00:00:00");
        assert_eq!(time::hms_utc(3661), "01:01:01");
        assert_eq!(time::hms_utc(86399), "23:59:59");
    }
}
