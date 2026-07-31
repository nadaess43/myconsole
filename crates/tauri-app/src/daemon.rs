//! Embedded cartridge daemon for the Tauri app.
//!
//! Runs the detector (WM_DEVICECHANGE hidden window) in a background thread
//! and forwards events via a channel to the Tauri frontend.
//!
//! Simplified port of `cartridge-daemon` — no console output, no Ctrl+C
//! handler (Tauri manages shutdown).

use std::collections::{HashMap, HashSet};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use cartridge_core::Manifest;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW,
    GetMessageW, GetWindowLongPtrW, SetWindowLongPtrW,
    GWLP_USERDATA, MSG, WM_CREATE, WM_DESTROY, WS_POPUP,
};

// ── Types ──

#[derive(Debug, Clone, serde::Serialize)]
pub struct CartridgeEvent {
    pub event: String, // "inserted" | "removed"
    #[serde(rename = "cartridgeId")]
    pub cartridge_id: String,
    pub title: String,
    pub drive: char,
    pub folder: String,
}

#[derive(Debug, Clone)]
enum DriveEvent {
    Arrived(char),
    Removed(char),
}

struct CartridgeEntry {
    cartridge_id: uuid::Uuid,
    title: String,
    drive: char,
    folder: String,
}

// ── Manually-defined Win32 types not exported by windows-sys 0.59 ──

#[repr(C)]
struct WNDCLASSEXW {
    cbSize: u32,
    style: u32,
    lpfnWndProc: Option<unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT>,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: isize,
    hCursor: isize,
    hbrBackground: isize,
    lpszMenuName: *const u16,
    lpszClassName: *const u16,
    hIconSm: isize,
}

#[repr(C)]
struct CREATESTRUCTW {
    lpCreateParams: *mut std::ffi::c_void,
    hInstance: HINSTANCE,
    hMenu: isize,
    hwndParent: HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    lpszName: *const u16,
    lpszClass: *const u16,
    dwExStyle: u32,
}

#[repr(C)]
struct DevBroadcastVolumeW {
    dbcv_size: u32,
    dbcv_devicetype: u32,
    dbcv_reserved: u32,
    dbcv_unitmask: u32,
    dbcv_flags: u16,
}

const WM_DEVICECHANGE: u32 = 0x0219;
const DBT_DEVICEARRIVAL: usize = 0x8000;
const DBT_DEVICEREMOVECOMPLETE: usize = 0x8004;
const DBT_DEVTYP_VOLUME: u32 = 2;

extern "system" {
    fn GetModuleHandleW(lpModuleName: *const u16) -> HINSTANCE;
    fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) -> u16;
}

struct DetectorContext {
    sender: Sender<DriveEvent>,
}

// ── Detector (hidden window + message loop) ──

fn detector_thread(sender: Sender<DriveEvent>) {
    let ctx = Box::new(DetectorContext { sender });
    let ctx_ptr = Box::into_raw(ctx);

    let class_name = to_wide("CartridgeTauriDetector");

    let hinstance = unsafe { GetModuleHandleW(std::ptr::null()) };

    let wnd_class = WNDCLASSEXW {
        cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
        style: 0,
        lpfnWndProc: Some(wnd_proc),
        cbClsExtra: 0,
        cbWndExtra: 0,
        hInstance: hinstance,
        hIcon: 0,
        hCursor: 0,
        hbrBackground: 0,
        lpszMenuName: std::ptr::null(),
        lpszClassName: class_name.as_ptr(),
        hIconSm: 0,
    };

    unsafe {
        RegisterClassExW(&wnd_class);

        let hwnd = CreateWindowExW(
            0,
            class_name.as_ptr(),
            std::ptr::null(),
            WS_POPUP,
            0,
            0,
            1,
            1,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            hinstance,
            ctx_ptr as *mut std::ffi::c_void,
        );

        if hwnd.is_null() {
            let _ = Box::from_raw(ctx_ptr);
            return;
        }

        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) != 0 {
            DispatchMessageW(&msg);
        }

        DestroyWindow(hwnd);
    }
}

unsafe extern "system" fn wnd_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_CREATE => {
            let cs = lparam as *const CREATESTRUCTW;
            let ctx = (*cs).lpCreateParams as *mut DetectorContext;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, ctx as isize);
            return 0;
        }
        WM_DEVICECHANGE => {
            let ctx_ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
            if ctx_ptr != 0 {
                let ctx = &*(ctx_ptr as *const DetectorContext);
                handle_device_change(wparam, lparam, &ctx.sender);
            }
            return 0;
        }
        WM_DESTROY => {
            let ctx_ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
            if ctx_ptr != 0 {
                let _ = Box::from_raw(ctx_ptr as *mut DetectorContext);
            }
            return 0;
        }
        _ => {}
    }
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

fn handle_device_change(wparam: WPARAM, lparam: LPARAM, sender: &Sender<DriveEvent>) {
    let arrived = match wparam {
        w if w == DBT_DEVICEARRIVAL => true,
        w if w == DBT_DEVICEREMOVECOMPLETE => false,
        _ => return,
    };

    let hdr = lparam as *const DevBroadcastVolumeW;
    if unsafe { (*hdr).dbcv_devicetype } != DBT_DEVTYP_VOLUME {
        return;
    }

    let mask = unsafe { (*hdr).dbcv_unitmask };
    for bit in 0..26 {
        if mask & (1u32 << bit) != 0 {
            let drive = (b'A' + bit as u8) as char;
            let event = if arrived {
                DriveEvent::Arrived(drive)
            } else {
                DriveEvent::Removed(drive)
            };
            let _ = sender.send(event);
        }
    }
}

// ── Scanner ──

fn is_media_present(drive: char) -> bool {
    let root = format!("{}:\\", drive);
    std::path::Path::new(&root).read_dir().is_ok()
}

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

// ── Helper ──

fn to_wide(s: &str) -> Vec<u16> {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
}

// ── Public API ──

/// Spawn the daemon and return an event receiver. The daemon runs in
/// background threads for the lifetime of the receiver.
///
/// Panics on Win32 API failure.
pub fn start_daemon() -> Receiver<CartridgeEvent> {
    let (detector_tx, detector_rx) = channel::<DriveEvent>();
    let (event_tx, event_rx) = channel::<CartridgeEvent>();

    // ── Spawn detector thread (Win32 message loop) ──
    std::thread::spawn(move || detector_thread(detector_tx));

    // ── Spawn coordinator thread ──
    std::thread::spawn(move || {
        coordinator_loop(detector_rx, event_tx);
    });

    event_rx
}

/// The coordinator: receives drive events from the detector, debounces them,
/// scans for cartridge manifests, and emits CartridgeEvent.
fn coordinator_loop(
    rx: Receiver<DriveEvent>,
    tx: Sender<CartridgeEvent>,
) {
    let mut cartridges: HashMap<uuid::Uuid, CartridgeEntry> = HashMap::new();
    let mut drive_to_ids: HashMap<char, Vec<uuid::Uuid>> = HashMap::new();
    let mut pending: HashMap<char, Instant> = HashMap::new();
    let mut polled: HashSet<char> = HashSet::new();

    // Initial scan
    for drive in enumerate_drives() {
        if is_media_present(drive) {
            scan_and_emit(drive, &mut cartridges, &mut drive_to_ids, &tx);
            polled.insert(drive);
        }
    }

    loop {
        match rx.recv_timeout(Duration::from_secs(2)) {
            Ok(DriveEvent::Arrived(drive)) => {
                pending.insert(drive, Instant::now());
            }
            Ok(DriveEvent::Removed(drive)) => {
                pending.remove(&drive);
                polled.remove(&drive);
                if let Some(ids) = drive_to_ids.remove(&drive) {
                    for id in &ids {
                        if let Some(entry) = cartridges.remove(id) {
                            let _ = tx.send(CartridgeEvent {
                                event: "removed".into(),
                                cartridge_id: id.to_string(),
                                title: entry.title,
                                drive: entry.drive,
                                folder: entry.folder,
                            });
                        }
                    }
                }
            }
            Err(RecvTimeoutError::Timeout) => {
                let now = Instant::now();

                // Process ripe pending drives
                let ripe: Vec<char> = pending
                    .iter()
                    .filter(|(_, ts)| now.duration_since(**ts) >= Duration::from_millis(500))
                    .map(|(d, _)| *d)
                    .collect();

                for drive in ripe {
                    pending.remove(&drive);
                    if is_media_present(drive) {
                        scan_and_emit(drive, &mut cartridges, &mut drive_to_ids, &tx);
                        polled.insert(drive);
                    }
                }

                // Polling fallback: detect removed drives
                // Some card readers keep the drive letter even after media removal,
                // so we must also check `is_media_present`.
                let current = enumerate_drives();
                for drive in polled.clone() {
                    if !current.contains(&drive) || !is_media_present(drive) {
                        polled.remove(&drive);
                        // Also fire removal events for cartridges on this drive
                        // (if WM_DEVICECHANGE didn't already catch it)
                        if let Some(ids) = drive_to_ids.remove(&drive) {
                            for id in &ids {
                                if let Some(entry) = cartridges.remove(id) {
                                    let _ = tx.send(CartridgeEvent {
                                        event: "removed".into(),
                                        cartridge_id: id.to_string(),
                                        title: entry.title,
                                        drive: entry.drive,
                                        folder: entry.folder,
                                    });
                                }
                            }
                        }
                    }
                }

                // Polling fallback: detect new drives
                for drive in &current {
                    if !drive_to_ids.contains_key(drive)
                        && !pending.contains_key(drive)
                        && !polled.contains(drive)
                    {
                        if is_media_present(*drive) {
                            scan_and_emit(*drive, &mut cartridges, &mut drive_to_ids, &tx);
                            polled.insert(*drive);
                        }
                    }
                }
            }
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

fn scan_and_emit(
    drive: char,
    cartridges: &mut HashMap<uuid::Uuid, CartridgeEntry>,
    drive_to_ids: &mut HashMap<char, Vec<uuid::Uuid>>,
    tx: &Sender<CartridgeEvent>,
) {
    for (manifest, folder) in scan_drive(drive) {
        let id = manifest.cartridge_id;
        if cartridges.contains_key(&id) {
            continue;
        }
        cartridges.insert(
            id,
            CartridgeEntry {
                cartridge_id: id,
                title: manifest.title.clone(),
                drive,
                folder: folder.clone(),
            },
        );
        drive_to_ids.entry(drive).or_default().push(id);
        let _ = tx.send(CartridgeEvent {
            event: "inserted".into(),
            cartridge_id: id.to_string(),
            title: manifest.title,
            drive,
            folder,
        });
    }
}
