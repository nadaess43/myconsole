//! Cartridge manifest types, serialization, and validation.
//!
//! This crate defines the canonical data structures for the cartridge ecosystem:
//! - [`Manifest`] — the JSON file placed in each game folder on physical media.
//! - [`SaveMode`] — where save data lives (`on_card` or `local`).
//! - [`Cksum`] — integrity checksum of game data.
//!
//! The manifest is the "tablet" marker file (`manifest.json`) that the daemon scans
//! for when a physical volume is connected. It identifies the game, tells the launcher
//! what executable to run, and how to handle saves.

pub mod error;
pub mod manifest;

pub use error::CoreError;
pub use manifest::{Cksum, Manifest, SaveMode, FORMAT_VERSION};
