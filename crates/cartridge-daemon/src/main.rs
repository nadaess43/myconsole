//! Cartridge Daemon — polling-only edition.
//!
//! No WM_DEVICECHANGE, no hidden window, no WndProc.
//! Just a straightforward 1‑second polling loop: enumerate drives,
//! diff against known state, emit cartridge events.

mod detector;
mod scanner;
mod state;

use std::collections::HashSet;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::time::Duration;

use colored::*;
use state::DaemonState;
use uuid::Uuid;

// ── IPC event file ──

struct EventWriter {
    inner: Option<BufWriter<File>>,
}

impl EventWriter {
    fn open(path: Option<&str>) -> Self {
        let inner = path.and_then(|p| File::create(p).ok().map(BufWriter::new));
        Self { inner }
    }

    fn log(&mut self, event_type: &str, id: &Uuid, title: &str, drive: char, folder: &str) {
        if let Some(ref mut w) = self.inner {
            let line = serde_json::json!({
                "type": event_type,
                "id": id.to_string(),
                "title": title,
                "drive": drive.to_string(),
                "folder": folder,
            });
            let _ = writeln!(w, "{}", line);
            let _ = w.flush();
        }
    }
}

// ── Args ──

fn parse_args() -> (bool, Option<String>) {
    let args: Vec<String> = std::env::args().collect();
    let mut verbose = false;
    let mut events_file = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--verbose" | "-v" => verbose = true,
            "--events-file" if i + 1 < args.len() => {
                events_file = Some(args[i + 1].clone());
                i += 1;
            }
            _ => {}
        }
        i += 1;
    }
    (verbose, events_file)
}

// ── Main ──

fn main() {
    let (verbose, events_file) = parse_args();
    let mut events = EventWriter::open(events_file.as_deref());

    println!("{}", "Cartridge Daemon v0.2.0 (polling)".cyan().bold());
    if verbose {
        println!("{}", "  verbose mode ON".dimmed());
    }

    let mut state = DaemonState::new(verbose);
    let mut polled: HashSet<char> = HashSet::new();

    // ── Initial scan ──
    for drive in scanner::enumerate_drives() {
        if scanner::is_media_present(drive) {
            scan_and_register(drive, &mut state, verbose, &mut events);
            polled.insert(drive);
            state.touch_drive(drive);
        }
    }

    if state.cartridges.is_empty() {
        println!(
            "{} No cartridges found. Insert a cartridge or use cartridge-maker first.",
            "ℹ".dimmed()
        );
    }
    println!("{} Polling every 1s...  Ctrl+C to stop.\n", "⏳".bold());

    // ── Main loop ──
    let mut tick: u64 = 0;
    loop {
        std::thread::sleep(Duration::from_secs(1));
        tick += 1;
        let current = scanner::enumerate_drives();

        // Detect removed drives (debounced: require 3s absence)
        for drive in state.active_drives() {
            if !current.contains(&drive) || !scanner::is_media_present(drive) {
                if state.is_drive_stale(drive) {
                    polled.remove(&drive);
                    let removed = state.remove_drive(drive);
                    for entry in &removed {
                        println!(
                            "{} Removed:  \"{}\"  ({})",
                            "–".red().bold(),
                            entry.title.bright_white(),
                            entry.cartridge_id.to_string().dimmed()
                        );
                        events.log("removed", &entry.cartridge_id, &entry.title, drive, &entry.folder);
                    }
                    if verbose && removed.is_empty() {
                        println!("  (drive {} had no known cartridges)", drive);
                    }
                } else if verbose {
                    println!("  [poll] Drive {}: media absent, waiting...", drive);
                }
            } else {
                state.touch_drive(drive);
            }
        }

        // Detect new drives
        for drive in &current {
            if !state.active_drives().contains(drive) && !polled.contains(drive) {
                if !scanner::is_media_present(*drive) {
                    if verbose {
                        eprintln!("  [poll] Drive {}: in drive list but read_dir failed — will retry", drive);
                    }
                    continue;
                }
                if verbose {
                    println!("  [poll] New drive {}: scanning...", drive);
                }
                scan_and_register(*drive, &mut state, verbose, &mut events);
                if state.active_drives().contains(drive) {
                    polled.insert(*drive);
                    state.touch_drive(*drive);
                }
            }
        }

        // Sweep polled: remove drives that disappeared
        for drive in polled.clone() {
            if !current.contains(&drive) || !scanner::is_media_present(drive) {
                polled.remove(&drive);
            }
        }

        // Periodic rescan of active drives (every 10s) — catches new cartridges
        // written by the launcher / cartridge-maker without re-insertion.
        if tick % 10 == 0 {
            for drive in state.active_drives() {
                if current.contains(&drive) && scanner::is_media_present(drive) {
                    scan_and_register(drive, &mut state, verbose, &mut events);
                    state.touch_drive(drive);
                }
            }
        }
    }
}

fn scan_and_register(drive: char, state: &mut DaemonState, verbose: bool, events: &mut EventWriter) {
    if verbose {
        eprintln!("  [scan] Scanning drive {}: ...", drive);
    }

    let found = scanner::scan_drive(drive, verbose);

    let found_ids: HashSet<Uuid> = found
        .iter()
        .map(|cartridge| cartridge.manifest.cartridge_id)
        .collect();
    let known_ids = state.drive_to_ids.get(&drive).cloned().unwrap_or_default();
    for id in known_ids {
        if !found_ids.contains(&id) {
            if let Some(entry) = state.remove_cartridge(id) {
                events.log("removed", &entry.cartridge_id, &entry.title, drive, &entry.folder);
                if verbose {
                    eprintln!("  [scan] Removed stale cartridge '{}'", entry.title);
                }
            }
        }
    }

    for cartridge in &found {
        let id = cartridge.manifest.cartridge_id;
        let title = cartridge.manifest.title.clone();
        let folder = cartridge.folder.clone();

        if state.insert_cartridge(id, title.clone(), drive, folder.clone()) {
            println!(
                "{} Inserted: \"{}\"  ({})  on {}:\\{}",
                "+".green().bold(),
                title.bright_white(),
                id.to_string().dimmed(),
                drive,
                folder
            );
            events.log("inserted", &id, &title, drive, &folder);
        } else if state.update_cartridge(id, title.clone(), folder.clone()) {
            events.log("updated", &id, &title, drive, &folder);
            if verbose {
                eprintln!("  [scan] Updated cartridge '{}'", title);
            }
        } else if verbose {
            eprintln!("  [scan] Cartridge {} already known, skipped", title);
        }
    }

    if verbose && found.is_empty() {
        eprintln!("  [scan] Drive {}: no cartridge folders found", drive);
    }
}
