//! WM_DEVICECHANGE-based volume detector.
//!
//! Creates a hidden popup window that listens for device-arrival / device-removal
//! broadcasts.  When a volume (drive letter) appears or disappears, the detector
//! sends a `DriveEvent` through the supplied channel.
//!
//! The receiver end is typically consumed by a coordinator thread that
//! debounces events, scans for cartridge manifests, and maintains state.
//!
//! NOTE: This module is intentionally kept for future use. The current
//! `main.rs` uses polling-only mode. To switch, spawn `run_detector` in a
//! thread and feed its channel into the coordinator.

// Win32 struct fields use the standard Win32 naming convention.
#![allow(non_snake_case)]
// Types and functions in this module are reserved for future use.
#![allow(dead_code)]

use std::sync::mpsc::Sender;

// Only import what we actually use from windows-sys — avoid glob imports that
// may conflict with manually-defined structs not exported by windows-sys 0.59.
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW,
    GetMessageW, GetWindowLongPtrW, SetWindowLongPtrW,
    GWLP_USERDATA, MSG, WM_CREATE, WM_DESTROY, WS_POPUP,
};

use crate::scanner;

/// Events from the detector and polling threads.
#[derive(Debug, Clone)]
pub enum DriveEvent {
    Arrived(char),
    Removed(char),
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

// Functions not exported by windows-sys 0.59 for these features
extern "system" {
    fn GetModuleHandleW(lpModuleName: *const u16) -> HINSTANCE;
    fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) -> u16;
}

// ── Detector context ──

struct DetectorContext {
    sender: Sender<DriveEvent>,
}

/// Run the Win32 message loop on the current thread.
/// Blocks until a `WM_QUIT` message is received or the window is destroyed.
pub fn run_detector(sender: Sender<DriveEvent>) {
    let ctx = Box::new(DetectorContext { sender });
    let ctx_ptr = Box::into_raw(ctx);

    let class_name = scanner::to_wide("CartridgeDaemonDetector");

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
            WS_POPUP,              // top-level window (receives WM_DEVICECHANGE broadcasts)
            0,
            0,
            1,                     // 1×1 pixel — invisible
            1,
            std::ptr::null_mut(),  // no parent = top-level
            std::ptr::null_mut(),
            hinstance,
            ctx_ptr as *mut std::ffi::c_void,
        );

        if hwnd.is_null() {
            let _ = Box::from_raw(ctx_ptr);
            eprintln!("FATAL: CreateWindowExW failed");
            return;
        }

        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) != 0 {
            DispatchMessageW(&msg);
        }

        DestroyWindow(hwnd);
    }
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
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
