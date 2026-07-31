//! Cartridge Maker — burn a game folder onto physical media as a cartridge.
//!
//! Usage:
//!   cartridge-maker make <GAME_PATH> <CARD_PATH> [OPTIONS]

mod cli;
mod maker;

fn main() -> anyhow::Result<()> {
    cli::run()
}
