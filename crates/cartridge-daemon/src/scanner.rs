use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;

use cartridge_core::Manifest;

/// A cartridge found during a volume scan.
#[derive(Debug)]
pub struct FoundCartridge {
    pub manifest: Manifest,
    pub folder: String,
}

/// Check whether a drive has physical media inserted.
///
/// For card readers without a card, `read_dir` fails.
/// This is the key filter the user asked about: we never
/// attempt to scan an empty card-reader slot.
pub fn is_media_present(drive: char) -> bool {
    let root = wide_root(drive);
    Path::new(&root).read_dir().is_ok()
}

/// Scan a drive's root for folders containing a valid `manifest.json`.
///
/// Returns all valid cartridges found. Errors (bad JSON, missing
/// fields, unreadable folders) are logged to stderr and skipped.
pub fn scan_drive(drive: char, verbose: bool) -> Vec<FoundCartridge> {
    let root = wide_root(drive);
    let root_path = Path::new(&root);

    let entries = match root_path.read_dir() {
        Ok(e) => e,
        Err(_) => {
            if verbose {
                eprintln!(
                    "  [scan] {}: cannot read root directory (no media?)",
                    root
                );
            }
            return Vec::new();
        }
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
            Err(e) => {
                eprintln!(
                    "  [scan] WARN: cannot read {}: {}",
                    manifest_path.display(),
                    e
                );
                continue;
            }
        };

        let manifest = match Manifest::from_json_str(&contents) {
            Ok(m) => m,
            Err(e) => {
                eprintln!(
                    "  [scan] WARN: invalid manifest in {}: {}",
                    manifest_path.display(),
                    e
                );
                continue;
            }
        };

        if let Err(e) = manifest.validate() {
            eprintln!(
                "  [scan] WARN: manifest validation failed in {}: {}",
                manifest_path.display(),
                e
            );
            continue;
        }

        let folder = path
            .file_name()
            .map(|f| f.to_string_lossy().to_string())
            .unwrap_or_else(|| "unknown".to_string());

        if verbose {
            println!(
                "  [scan] Found cartridge {} (id={}) in folder '{}'",
                manifest.title,
                manifest.cartridge_id,
                folder
            );
        }

        found.push(FoundCartridge { manifest, folder });
    }

    found
}

/// Build a wide-string root path like `"F:\"`.
fn wide_root(drive: char) -> String {
    format!("{}:\\", drive)
}

/// Enumerate all currently-connected logical drives.
pub fn enumerate_drives() -> Vec<char> {
    let mask = unsafe { windows_sys::Win32::Storage::FileSystem::GetLogicalDrives() };
    let mut drives = Vec::new();
    for bit in 0..26 {
        if mask & (1 << bit) != 0 {
            drives.push((b'A' + bit as u8) as char);
        }
    }
    drives
}

/// Convert a Rust string to a null-terminated wide string for Win32.
pub fn to_wide(s: &str) -> Vec<u16> {
    OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
}
