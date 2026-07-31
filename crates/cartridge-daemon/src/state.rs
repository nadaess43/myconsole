use std::collections::HashMap;
use uuid::Uuid;

/// A cartridge known to the daemon.
#[derive(Debug, Clone)]
pub struct CartridgeEntry {
    pub cartridge_id: Uuid,
    pub title: String,
    pub drive: char,
    pub folder: String,
}

/// Tracks which drives have cartridges and when drives were last seen.
pub struct DaemonState {
    /// All known cartridges, keyed by UUID.
    pub cartridges: HashMap<Uuid, CartridgeEntry>,
    /// Which cartridge UUIDs are on each drive letter.
    pub drive_to_ids: HashMap<char, Vec<Uuid>>,
    /// When a drive was last reported as connected.
    pub drive_last_seen: HashMap<char, std::time::Instant>,
    /// Whether to print diagnostics.
    pub verbose: bool,
}

impl DaemonState {
    pub fn new(verbose: bool) -> Self {
        Self {
            cartridges: HashMap::new(),
            drive_to_ids: HashMap::new(),
            drive_last_seen: HashMap::new(),
            verbose,
        }
    }

    /// Register a cartridge found on a drive. Returns `true` if this is a newly seen cartridge.
    pub fn insert_cartridge(
        &mut self,
        cartridge_id: Uuid,
        title: String,
        drive: char,
        folder: String,
    ) -> bool {
        if self.cartridges.contains_key(&cartridge_id) {
            return false; // already known
        }
        self.cartridges.insert(
            cartridge_id,
            CartridgeEntry {
                cartridge_id,
                title,
                drive,
                folder,
            },
        );
        self.drive_to_ids
            .entry(drive)
            .or_default()
            .push(cartridge_id);
        true
    }

    /// Remove all cartridges for a disconnected drive. Returns the removed entries.
    pub fn remove_drive(&mut self, drive: char) -> Vec<CartridgeEntry> {
        let ids = self.drive_to_ids.remove(&drive).unwrap_or_default();
        let mut removed = Vec::new();
        for id in &ids {
            if let Some(entry) = self.cartridges.remove(id) {
                removed.push(entry);
            }
        }
        self.drive_last_seen.remove(&drive);
        removed
    }

    /// Record that a drive was seen at this moment.
    pub fn touch_drive(&mut self, drive: char) {
        self.drive_last_seen
            .insert(drive, std::time::Instant::now());
    }

    /// Returns true if the drive has not been seen for 3+ seconds.
    pub fn is_drive_stale(&self, drive: char) -> bool {
        match self.drive_last_seen.get(&drive) {
            Some(ts) => ts.elapsed() >= std::time::Duration::from_secs(3),
            None => true, // never seen → treat as stale
        }
    }

    /// Get the set of drive letters that currently have cartridges registered.
    pub fn active_drives(&self) -> Vec<char> {
        self.drive_to_ids.keys().copied().collect()
    }
}
