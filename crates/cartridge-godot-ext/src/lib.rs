use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cartridge_core::Manifest;
use godot::prelude::*;

// ── Scanner (ported from cartridge-daemon) ──

fn enumerate_drives() -> Vec<char> {
    let mask = unsafe { windows_sys::Win32::Storage::FileSystem::GetLogicalDrives() };
    let mut drives = Vec::new();
    for bit in 0..26 {
        if mask & (1 << bit) != 0 {
            drives.push((b'A' + bit as u8) as char);
        }
    }
    drives
}

fn is_media_present(drive: char) -> bool {
    let root = format!("{}:\\", drive);
    std::path::Path::new(&root).read_dir().is_ok()
}

/// Returns (manifest, folder_name) for each cartridge found on the drive.
fn scan_drive(drive: char) -> Vec<(Manifest, String)> {
    let root = format!("{}:\\", drive);
    let root_path = std::path::Path::new(&root);
    let entries = match root_path.read_dir() {
        Ok(e) => e,
        Err(_) => return Vec::new(),
    };
    let mut found = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let manifest_path = path.join("manifest.json");
        if !manifest_path.exists() {
            continue;
        }
        let contents = match std::fs::read_to_string(&manifest_path) {
            Ok(c) => c,
            Err(_) => continue,
        };
        let manifest = match Manifest::from_json_str(&contents) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if manifest.validate().is_err() {
            continue;
        }
        let folder = path
            .file_name()
            .map(|f| f.to_string_lossy().to_string())
            .unwrap_or_default();
        found.push((manifest, folder));
    }
    found
}

// ── Daemon state ──

#[derive(Default)]
struct DaemonState {
    /// Cartridge ID → (title, drive, folder)
    cartridges: HashMap<uuid::Uuid, (String, char, String)>,
    /// Drive → Vec<cartridge ID>
    drive_to_ids: HashMap<char, Vec<uuid::Uuid>>,
    /// Drives we've already scanned and have cartridges
    polled: HashSet<char>,
}

impl DaemonState {
    fn new() -> Self {
        Self::default()
    }

    fn active_drives(&self) -> Vec<char> {
        self.drive_to_ids.keys().copied().collect()
    }
}

// ── CartridgeDaemon (Godot class) ──

#[derive(GodotClass)]
#[class(base = Node)]
struct CartridgeDaemon {
    #[base]
    base: Base<Node>,

    state: Arc<Mutex<DaemonState>>,
    stop_flag: Arc<AtomicBool>,
}

#[godot_api]
impl INode for CartridgeDaemon {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            state: Arc::new(Mutex::new(DaemonState::new())),
            stop_flag: Arc::new(AtomicBool::new(false)),
        }
    }

    fn exit_tree(&mut self) {
        self.stop_flag.store(true, Ordering::SeqCst);
    }
}

#[godot_api]
impl CartridgeDaemon {
    #[signal]
    fn cartridge_inserted(id: GString, title: GString, drive: GString, folder: GString);

    #[signal]
    fn cartridge_removed(id: GString);

    #[func]
    fn emit_signal_cartridge_inserted(&mut self, id: GString, title: GString, drive: GString, folder: GString) {
        self.base_mut().emit_signal("cartridge_inserted", &[
            id.to_variant(),
            title.to_variant(),
            drive.to_variant(),
            folder.to_variant(),
        ]);
    }

    #[func]
    fn emit_signal_cartridge_removed(&mut self, id: GString) {
        self.base_mut().emit_signal("cartridge_removed", &[id.to_variant()]);
    }

    /// Start the background polling loop.
    #[func]
    fn start(&mut self) {
        let state = self.state.clone();
        let stop = self.stop_flag.clone();
        let instance_id = self.base().instance_id();

        std::thread::spawn(move || {
            // Initial scan
            {
                let mut s = state.lock().unwrap();
                for drive in enumerate_drives() {
                    if is_media_present(drive) {
                        for (manifest, folder) in scan_drive(drive) {
                            let id = manifest.cartridge_id;
                            if s.cartridges.contains_key(&id) {
                                continue;
                            }
                            s.cartridges
                                .insert(id, (manifest.title.clone(), drive, folder.clone()));
                            s.drive_to_ids.entry(drive).or_default().push(id);
                            s.polled.insert(drive);

                            emit_deferred(
                                instance_id,
                                "cartridge_inserted",
                                &[
                                    id.to_string().to_variant(),
                                    manifest.title.to_variant(),
                                    drive.to_string().to_variant(),
                                    folder.to_variant(),
                                ],
                            );
                        }
                    }
                }
            }

            // Main polling loop
            while !stop.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_secs(1));

                let current = enumerate_drives();
                let mut s = state.lock().unwrap();

                // Detect removed drives
                let active: Vec<char> = s.active_drives();
                for drive in &active {
                    if !current.contains(drive) || !is_media_present(*drive) {
                        s.polled.remove(drive);
                        if let Some(ids) = s.drive_to_ids.remove(drive) {
                            for id in &ids {
                                s.cartridges.remove(id);
                                emit_deferred(
                                    instance_id,
                                    "cartridge_removed",
                                    &[id.to_string().to_variant()],
                                );
                            }
                        }
                    }
                }

                // Detect new drives
                for drive in &current {
                    if s.active_drives().contains(drive) || s.polled.contains(drive) {
                        continue;
                    }
                    if !is_media_present(*drive) {
                        continue;
                    }
                    for (manifest, folder) in scan_drive(*drive) {
                        let id = manifest.cartridge_id;
                        if s.cartridges.contains_key(&id) {
                            continue;
                        }
                        s.cartridges
                            .insert(id, (manifest.title.clone(), *drive, folder.clone()));
                        s.drive_to_ids.entry(*drive).or_default().push(id);
                        s.polled.insert(*drive);

                        emit_deferred(
                            instance_id,
                            "cartridge_inserted",
                            &[
                                id.to_string().to_variant(),
                                manifest.title.to_variant(),
                                drive.to_string().to_variant(),
                                folder.to_variant(),
                            ],
                        );
                    }
                }

                // Sweep polled
                for drive in s.polled.clone() {
                    if !current.contains(&drive) || !is_media_present(drive) {
                        s.polled.remove(&drive);
                    }
                }
            }
        });
    }
}

/// Emit a signal on the main thread from a background thread via call_deferred.
fn emit_deferred(instance_id: InstanceId, signal_name: &str, args: &[Variant]) {
    let mut obj = Gd::<CartridgeDaemon>::from_instance_id(instance_id);
    let method = StringName::from(format!("emit_signal_{signal_name}"));
    obj.call_deferred(&method, args);
}

// ── GDExtension entry point ──

struct CartridgeGodotExt;

#[gdextension]
unsafe impl ExtensionLibrary for CartridgeGodotExt {}
