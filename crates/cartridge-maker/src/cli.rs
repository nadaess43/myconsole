use cartridge_core::SaveMode;
use clap::{Parser, Subcommand};

use crate::maker;

/// Cartridge Maker — burn games onto physical media (SD cards, USB drives).
///
/// Takes a folder containing game files and creates a cartridge structure
/// on the target volume. A manifest.json is written alongside the game data.
#[derive(Parser, Debug)]
#[command(
    name = "cartridge-maker",
    version,
    about = "Burn games onto physical media as cartridges",
    long_about = None
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand, Debug)]
pub enum Commands {
    /// Create a new cartridge on the target volume.
    ///
    /// Copies game files from GAME_PATH into a named folder on CARD_PATH,
    /// computes a blake3 checksum, and writes a manifest.json.
    Make {
        /// Path to the source game folder containing the game files.
        game_path: String,

        /// Path to the target volume root (e.g. "F:\" or "D:\my_card").
        card_path: String,

        /// Display name of the game (default: the source folder name).
        #[arg(short, long)]
        name: Option<String>,

        /// Relative path to the game executable inside the game folder
        /// (e.g. "bin/game.exe"). If omitted, auto-detected.
        #[arg(short, long)]
        exec: Option<String>,

        /// Where to store save data: "on_card" (default) or "local".
        #[arg(short, long, default_value = "on_card")]
        save_mode: String,

        /// Path to an icon image (.jpg/.png) to copy into the cartridge.
        #[arg(long)]
        icon: Option<String>,

        /// Path to a cover/box art image to copy into the cartridge.
        #[arg(long)]
        cover: Option<String>,

        /// Non-interactive: auto-pick best exe instead of showing a menu.
        #[arg(long, default_value_t = false)]
        non_interactive: bool,
    },
}

pub fn run() -> anyhow::Result<()> {
    let cli = Cli::parse();

    match &cli.command {
        Commands::Make {
            game_path,
            card_path,
            name,
            exec,
            save_mode,
            icon,
            cover,
            non_interactive,
        } => {
            let save_mode = parse_save_mode(save_mode)?;
            maker::make(
                game_path,
                card_path,
                name.as_deref(),
                exec.as_deref(),
                save_mode,
                icon.as_deref(),
                cover.as_deref(),
                *non_interactive,
            )?;
        }
    }

    Ok(())
}

fn parse_save_mode(raw: &str) -> anyhow::Result<SaveMode> {
    match raw.to_lowercase().as_str() {
        "on_card" | "oncard" => Ok(SaveMode::OnCard),
        "local" => Ok(SaveMode::Local),
        other => anyhow::bail!(
            "invalid save_mode: '{}'. Expected 'on_card' or 'local'.",
            other
        ),
    }
}


