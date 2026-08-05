use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::CoreError;

/// Current manifest format version.
/// Increment this when making breaking schema changes.
pub const FORMAT_VERSION: u32 = 1;

/// Where save data lives for this cartridge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SaveMode {
    /// Saves stored on the card itself — take your progress with you.
    OnCard,
    /// Saves stored locally on the host machine, keyed by cartridge_id.
    Local,
}

impl SaveMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            SaveMode::OnCard => "on_card",
            SaveMode::Local => "local",
        }
    }
}

/// Checksum of game data files, computed once at cartridge creation time.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Cksum {
    /// Algorithm used (e.g. "blake3").
    pub algorithm: String,
    /// Hex-encoded digest.
    pub digest: String,
}

/// The manifest — a JSON file placed in each game folder on physical media.
///
/// Fields use `#[serde(rename = "camelCase")]` so the JSON looks clean:
/// `execPath`, `saveMode`, `createdAt`, etc.
///
/// All file paths are **relative to the manifest's own directory** (the game root folder).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    /// Manifest format version. The current version is [`FORMAT_VERSION`].
    pub format_version: u32,

    /// Unique identifier for this cartridge. Generated once at creation time.
    /// Two copies of the same game on different cards get different IDs.
    pub cartridge_id: Uuid,

    /// Human-readable game title.
    pub title: String,

    /// Optional version string of the game (e.g. "1.5.78").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,

    /// Target platform. Currently always "pc" for Windows.
    #[serde(default = "default_platform")]
    pub platform: String,

    /// Relative path to the game's icon image.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon_path: Option<String>,

    /// Relative path to the game's cover/box art.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_path: Option<String>,

    /// Relative path to the game executable (e.g. "data/hl2.exe").
    pub exec_path: String,

    /// Optional command-line arguments passed to the executable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exec_args: Option<Vec<String>>,

    /// Working directory for the game process, relative to manifest dir.
    /// If unset, defaults to the directory containing the executable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,

    /// Where save data is stored: on the card or on the host machine.
    pub save_mode: SaveMode,

    /// Relative path to the save directory within the game folder.
    /// Only meaningful when `save_mode` is `OnCard`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub save_path: Option<String>,

    /// Timestamp of cartridge creation (UTC).
    pub created_at: DateTime<Utc>,

    /// Checksum of all game data files, computed once at creation time.
    /// Can be verified later via a manual integrity check.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checksum: Option<Cksum>,
}

fn default_platform() -> String {
    "pc".to_string()
}

impl Manifest {
    // ---------------------------------------------------------------------------
    // Constructors
    // ---------------------------------------------------------------------------

    /// Create a new manifest with sensible defaults.
    ///
    /// `title` is the display name.
    /// `exec_path` is relative to the manifest directory (e.g. `"data/game.exe"`).
    /// `save_mode` controls where saves live.
    pub fn new(title: String, exec_path: String, save_mode: SaveMode) -> Self {
        Self {
            format_version: FORMAT_VERSION,
            cartridge_id: Uuid::new_v4(),
            title,
            version: None,
            platform: default_platform(),
            icon_path: None,
            cover_path: None,
            exec_path,
            exec_args: None,
            cwd: None,
            save_mode,
            save_path: None,
            created_at: Utc::now(),
            checksum: None,
        }
    }

    // ---------------------------------------------------------------------------
    // Serialization
    // ---------------------------------------------------------------------------

    /// Serialize the manifest to a pretty-printed JSON string.
    pub fn to_json(&self) -> Result<String, CoreError> {
        Ok(serde_json::to_string_pretty(self)?)
    }

    /// Serialize the manifest to a compact JSON byte vector.
    pub fn to_json_bytes(&self) -> Result<Vec<u8>, CoreError> {
        Ok(serde_json::to_vec(self)?)
    }

    /// Deserialize a manifest from a JSON byte slice.
    pub fn from_json(data: &[u8]) -> Result<Self, CoreError> {
        Ok(serde_json::from_slice(data)?)
    }

    /// Deserialize a manifest from a JSON string.
    pub fn from_json_str(s: &str) -> Result<Self, CoreError> {
        Ok(serde_json::from_str(s)?)
    }

    // ---------------------------------------------------------------------------
    // Validation
    // ---------------------------------------------------------------------------

    /// Validate the manifest, returning an error if any invariant is violated.
    pub fn validate(&self) -> Result<(), CoreError> {
        // title must be non-empty
        if self.title.trim().is_empty() {
            return Err(CoreError::Validation("title must not be empty".into()));
        }

        // exec_path must be non-empty and relative (no leading / or drive letter)
        if self.exec_path.trim().is_empty() {
            return Err(CoreError::Validation("exec_path must not be empty".into()));
        }
        self.ensure_relative("exec_path", &self.exec_path)?;

        // Optional path fields must be relative
        if let Some(ref p) = self.icon_path {
            self.ensure_relative("icon_path", p)?;
        }
        if let Some(ref p) = self.cover_path {
            self.ensure_relative("cover_path", p)?;
        }
        if let Some(ref p) = self.cwd {
            self.ensure_relative("cwd", p)?;
        }
        if let Some(ref p) = self.save_path {
            self.ensure_relative("save_path", p)?;
        }

        // If save_mode is OnCard, save_path should be set
        if self.save_mode == SaveMode::OnCard && self.save_path.is_none() {
            return Err(CoreError::Validation(
                "save_path must be set when save_mode is 'on_card'".into(),
            ));
        }

        // format_version should match the current version
        if self.format_version != FORMAT_VERSION {
            return Err(CoreError::Validation(format!(
                "unsupported format_version: {}. Expected: {}",
                self.format_version, FORMAT_VERSION
            )));
        }

        Ok(())
    }

    /// Validate that a path does not look absolute (no drive letter, no leading `/` or `\`).
    fn ensure_relative(&self, field: &str, path: &str) -> Result<(), CoreError> {
        // Windows absolute: starts with a drive letter like "C:" or "D:"
        if path.len() >= 2 && path.as_bytes()[1] == b':' {
            return Err(CoreError::Validation(format!(
                "{field} must be a relative path, got: {path}"
            )));
        }
        // Unix absolute or UNC
        if path.starts_with('/') || path.starts_with('\\') {
            return Err(CoreError::Validation(format!(
                "{field} must be a relative path, got: {path}"
            )));
        }
        if path
            .replace('\\', "/")
            .split('/')
            .any(|component| component == "..")
        {
            return Err(CoreError::Validation(format!(
                "{field} must not escape the cartridge directory, got: {path}"
            )));
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_manifest_roundtrip() {
        let m = Manifest::new("Test Game".into(), "data/game.exe".into(), SaveMode::OnCard);
        let json = m.to_json().unwrap();
        let m2 = Manifest::from_json_str(&json).unwrap();
        assert_eq!(m.cartridge_id, m2.cartridge_id);
        assert_eq!(m.title, m2.title);
        assert_eq!(m.exec_path, m2.exec_path);
        assert_eq!(m.save_mode, m2.save_mode);
    }

    #[test]
    fn test_validate_empty_title() {
        let m = Manifest::new("".into(), "data/game.exe".into(), SaveMode::Local);
        assert!(m.validate().is_err());
    }

    #[test]
    fn test_validate_absolute_exec_path() {
        let mut m = Manifest::new("Game".into(), "C:\\data\\game.exe".into(), SaveMode::Local);
        // Ensure we're testing the right thing
        m.exec_path = "C:\\data\\game.exe".to_string();
        assert!(m.validate().is_err());
    }

    #[test]
    fn test_validate_parent_path() {
        let mut m = Manifest::new("Test".into(), "data/../game.exe".into(), SaveMode::Local);
        assert!(m.validate().is_err());
        m.exec_path = "data/game.exe".into();
        m.cwd = Some("../outside".into());
        assert!(m.validate().is_err());
    }

    #[test]
    fn test_validate_oncard_no_save_path() {
        let m = Manifest::new("Game".into(), "data/game.exe".into(), SaveMode::OnCard);
        assert!(m.validate().is_err());
    }

    #[test]
    fn test_validate_valid_oncard() {
        let mut m = Manifest::new("Game".into(), "data/game.exe".into(), SaveMode::OnCard);
        m.save_path = Some("saves".into());
        assert!(m.validate().is_ok());
    }

    #[test]
    fn test_json_field_names_are_camelcase() {
        let mut m = Manifest::new("Game".into(), "data/game.exe".into(), SaveMode::OnCard);
        m.save_path = Some("saves".into());
        m.exec_args = Some(vec!["--test".into()]);
        m.checksum = Some(Cksum {
            algorithm: "blake3".into(),
            digest: "abc123".into(),
        });
        let json = m.to_json().unwrap();

        assert!(json.contains("\"cartridgeId\""));
        assert!(json.contains("\"formatVersion\""));
        assert!(json.contains("\"createdAt\""));
        assert!(json.contains("\"execPath\""));
        assert!(json.contains("\"execArgs\""));
        assert!(json.contains("\"saveMode\""));
        assert!(json.contains("\"savePath\""));
    }
}
