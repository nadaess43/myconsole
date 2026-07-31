mod daemon;

use std::sync::mpsc::Receiver;
use tauri::Emitter;

/// The daemon runs in background threads. This function bridges its
/// channel-based output into Tauri's event system.
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let event_rx: Receiver<daemon::CartridgeEvent> = daemon::start_daemon();

    tauri::Builder::default()
        .setup(move |app| {
            let handle = app.handle().clone();

            // Pump events from daemon into Tauri's event system
            std::thread::spawn(move || {
                for event in event_rx {
                    let event_name = match event.event.as_str() {
                        "inserted" => "cartridge-inserted",
                        "removed" => "cartridge-removed",
                        _ => continue,
                    };
                    let _ = handle.emit(event_name, &event);
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
