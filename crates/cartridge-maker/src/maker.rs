use std::fs;
use std::io::{self, BufRead, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{bail, Context};
use blake3::Hasher;
use cartridge_core::{Cksum, Manifest, SaveMode};
use colored::*;
use indicatif::{ProgressBar, ProgressStyle};
use walkdir::WalkDir;

/// Create a cartridge on the target volume.
///
/// # Arguments
/// * `game_source` — path to the folder containing the game files.
/// * `card_root` — path to the target volume (e.g. `F:\`).
/// * `name` — display name; falls back to the source folder name.
/// * `exec` — relative path to the executable; auto-detected if `None`.
/// * `save_mode` — `OnCard` or `Local`.
/// * `icon_source` — optional path to an icon image to copy.
/// * `cover_source` — optional path to a cover image to copy.
pub fn make(
    game_source: &str,
    card_root: &str,
    name: Option<&str>,
    exec: Option<&str>,
    save_mode: SaveMode,
    icon_source: Option<&str>,
    cover_source: Option<&str>,
    non_interactive: bool,
) -> anyhow::Result<()> {
    let started = Instant::now();

    // -----------------------------------------------------------------------
    // 1. Validate inputs
    // -----------------------------------------------------------------------
    let game_dir = PathBuf::from(game_source);
    if !game_dir.exists() {
        bail!("game source path does not exist: {}", game_source);
    }
    if !game_dir.is_dir() {
        bail!("game source path is not a directory: {}", game_source);
    }

    let card_dir = PathBuf::from(card_root);
    if !card_dir.exists() {
        bail!("card path does not exist: {}", card_root);
    }
    if !card_dir.is_dir() {
        bail!("card path is not a directory: {}", card_root);
    }

    // -----------------------------------------------------------------------
    // 2. Determine game name
    // -----------------------------------------------------------------------
    let game_name = name
        .map(|n| n.to_string())
        .unwrap_or_else(|| {
            game_dir
                .file_name()
                .map(|f| f.to_string_lossy().to_string())
                .unwrap_or_else(|| "Unknown Game".to_string())
        });

    // Sanitize: replace characters that are problematic in folder names on Windows
    let game_name = sanitize_folder_name(&game_name);

    println!(
        "{} {}",
        "▶ Game:".bold(),
        game_name.bright_white().bold()
    );

    // -----------------------------------------------------------------------
    // 3. Detect or accept executable path
    // -----------------------------------------------------------------------
    let exec_rel = if let Some(e) = exec {
        let rel = e.replace('\\', "/");
        let abs = game_dir.join(&rel);
        if !abs.exists() {
            bail!(
                "specified executable not found at: {} (resolved to: {})",
                e,
                abs.display()
            );
        }
        println!("{} {}", "▶ Exec:".bold(), rel.dimmed());
        rel
    } else {
        let found = auto_detect_exe(&game_dir, non_interactive)?;
        let stripped = found
            .strip_prefix(&game_dir)
            .with_context(|| format!("failed to strip prefix from: {}", found.display()))?;
        #[cfg(windows)]
        let rel = stripped.to_string_lossy().replace('\\', "/");
        #[cfg(not(windows))]
        let rel = stripped.to_string_lossy().into_owned();
        println!(
            "{} {} {}",
            "▶ Exec:".bold(),
            rel.dimmed(),
            "(auto-detected)".dimmed()
        );
        rel
    };

    // -----------------------------------------------------------------------
    // 4. Prepare target directories
    // -----------------------------------------------------------------------
    let cartridge_dir = card_dir.join(&game_name);
    let data_dir = cartridge_dir.join("data");
    let saves_dir = cartridge_dir.join("saves");

    if cartridge_dir.exists() {
        println!(
            "{} Target folder '{}' already exists. Removing...",
            "⚠".yellow(),
            cartridge_dir.display()
        );
        fs::remove_dir_all(&cartridge_dir)
            .with_context(|| format!("failed to remove: {}", cartridge_dir.display()))?;
    }

    fs::create_dir_all(&data_dir)
        .with_context(|| format!("failed to create data dir: {}", data_dir.display()))?;

    if save_mode == SaveMode::OnCard {
        fs::create_dir_all(&saves_dir)
            .with_context(|| format!("failed to create saves dir: {}", saves_dir.display()))?;
    }

    // -----------------------------------------------------------------------
    // 5. Copy game files and compute blake3 checksum in one pass
    // -----------------------------------------------------------------------
    println!("{} Copying game files...", "⏳".bold());

    let file_count = count_files(&game_dir);
    let pb = ProgressBar::new(file_count as u64);
    pb.set_style(
        ProgressStyle::with_template(
            "{spinner:.green} [{elapsed_precise}] [{wide_bar:.cyan/blue}] {pos}/{len} files ({bytes_per_sec}, {eta})",
        )
        .unwrap()
        .progress_chars("#>-"),
    );

    let mut hasher = Hasher::new();
    let mut copied = 0usize;
    let mut total_bytes: u64 = 0;

    for entry in WalkDir::new(&game_dir)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let path = entry.path();
        let relative = path
            .strip_prefix(&game_dir)
            .unwrap_or(path);

        // We already handled the executable separately — it was detected in game_dir
        // but still needs to be copied. Every file in game_dir gets copied.

        let dest = data_dir.join(relative);

        if path.is_dir() {
            fs::create_dir_all(&dest)
                .with_context(|| format!("failed to create dir: {}", dest.display()))?;
        } else {
            // Stream file: read in 64KiB chunks, hash each chunk, write to dest.
            // This avoids loading the entire file into memory (critical for large games).
            let src_file = fs::File::open(path)
                .with_context(|| format!("failed to open: {}", path.display()))?;
            let dest_file = fs::File::create(&dest)
                .with_context(|| format!("failed to create: {}", dest.display()))?;
            let mut reader = io::BufReader::with_capacity(64 * 1024, src_file);
            let mut writer = io::BufWriter::with_capacity(64 * 1024, dest_file);
            let mut buf = [0u8; 64 * 1024];
            loop {
                let n = reader.read(&mut buf)
                    .with_context(|| format!("failed to read: {}", path.display()))?;
                if n == 0 {
                    break;
                }
                hasher.update(&buf[..n]);
                writer.write_all(&buf[..n])
                    .with_context(|| format!("failed to write: {}", dest.display()))?;
                total_bytes += n as u64;
            }
            writer.flush()
                .with_context(|| format!("failed to flush: {}", dest.display()))?;
            copied += 1;
            pb.set_position(copied as u64);
        }
    }

    pb.finish_and_clear();

    let digest = hasher.finalize();
    let digest_hex = digest.to_hex().to_string();

    println!(
        "{} Copied {} files ({} bytes)",
        "✓".green(),
        copied.to_string().bold(),
        format_bytes(total_bytes).bold(),
    );
    println!(
        "{} blake3 checksum: {}",
        "✓".green(),
        digest_hex.dimmed()
    );

    // -----------------------------------------------------------------------
    // 6. Copy optional icon / cover
    // -----------------------------------------------------------------------
    let icon_path = if let Some(src) = icon_source {
        copy_asset_file(src, &cartridge_dir, "icon")?;
        Some(asset_rel_path(src, "icon"))
    } else {
        None
    };

    let cover_path = if let Some(src) = cover_source {
        copy_asset_file(src, &cartridge_dir, "cover")?;
        Some(asset_rel_path(src, "cover"))
    } else {
        None
    };

    // -----------------------------------------------------------------------
    // 7. Build and write manifest
    // -----------------------------------------------------------------------
    let mut manifest = Manifest::new(game_name.clone(), exec_rel.clone(), save_mode);
    manifest.version = None; // user can edit later
    manifest.icon_path = icon_path;
    manifest.cover_path = cover_path;
    // exec_args, cwd — left as None for now (can be edited in manifest manually)
    manifest.save_path = if save_mode == SaveMode::OnCard {
        Some("saves".to_string())
    } else {
        None
    };
    manifest.checksum = Some(Cksum {
        algorithm: "blake3".to_string(),
        digest: digest_hex,
    });

    // Validate before writing
    manifest
        .validate()
        .with_context(|| "generated manifest failed validation")?;

    let manifest_path = cartridge_dir.join("manifest.json");
    let json = manifest.to_json()?;
    fs::write(&manifest_path, json)
        .with_context(|| format!("failed to write manifest: {}", manifest_path.display()))?;

    // -----------------------------------------------------------------------
    // 8. Summary
    // -----------------------------------------------------------------------
    let elapsed = started.elapsed();
    println!();
    println!("{}", "══════════════════════════════════════".dimmed());
    println!(
        "{} Cartridge created successfully!",
        "✓".green().bold()
    );
    println!(
        "{} ID:       {}",
        "•".dimmed(),
        manifest.cartridge_id.to_string().bright_white()
    );
    println!(
        "{} Location: {}",
        "•".dimmed(),
        cartridge_dir.display().to_string().bright_white()
    );
    println!(
        "{} Size:     {}  |  Files: {}  |  Time: {:.1}s",
        "•".dimmed(),
        format_bytes(total_bytes),
        copied,
        elapsed.as_secs_f64()
    );
    println!(
        "{} Save:     {}",
        "•".dimmed(),
        match save_mode {
            SaveMode::OnCard => "on card (portable)".green(),
            SaveMode::Local => "local (host machine)".yellow(),
        }
    );
    println!(
        "{} Verify:   cartridge-maker verify {}",
        "•".dimmed(),
        cartridge_dir.display()
    );
    println!("{}", "══════════════════════════════════════".dimmed());

    Ok(())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Auto-detect the real game executable, ignoring known utility binaries.
///
/// Strategy:
/// 1. Collect all `.exe` files (root first, then recursive up to depth 3).
/// 2. Filter out known non-game executables (UnityCrashHandler, uninstallers, etc.).
/// 3. Prefer candidates whose base name matches the game folder name.
/// 4. Prefer root-level candidates over deeper ones.
/// 5. Among remaining, prefer the largest file (game exes tend to be large).
fn auto_detect_exe(game_dir: &Path, non_interactive: bool) -> anyhow::Result<PathBuf> {
    let folder_name = game_dir
        .file_name()
        .map(|n| n.to_string_lossy().to_lowercase())
        .unwrap_or_default();

    let mut candidates: Vec<(PathBuf, u32, u64)> = Vec::new();

    // Collect root-level .exe files
    if let Ok(iter) = fs::read_dir(game_dir) {
        for entry in iter.flatten() {
            let path = entry.path();
            if path.is_file() && is_exe(&path) && !is_blacklisted(&path) {
                // Priority 0 = root level
                let score = score_candidate(&path, &folder_name, 0);
                let size = path.metadata().map(|m| m.len()).unwrap_or(0);
                candidates.push((path, score, size));
            }
        }
    }

    // Collect recursive .exe files (depth 1–3), skipping root (already collected)
    for entry in WalkDir::new(game_dir)
        .min_depth(1)
        .max_depth(3)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let path = entry.path().to_path_buf();
        if path.is_file() && is_exe(&path) && !is_blacklisted(&path) {
            // Priority 1 = nested
            let score = score_candidate(&path, &folder_name, 1);
            let size = path.metadata().map(|m| m.len()).unwrap_or(0);
            candidates.push((path, score, size));
        }
    }

    if candidates.is_empty() {
        bail!(
            "no suitable .exe found in '{}' (excluding UnityCrashHandler, uninstallers, etc.). \
             Specify one with --exec <path>.",
            game_dir.display()
        );
    }

    // Sort: highest score first, then largest file first
    candidates.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| b.2.cmp(&a.2)));

    // Single clear winner — use it
    if candidates.len() == 1 {
        return Ok(candidates[0].0.clone());
    }

    // Non-interactive: auto-pick best candidate (highest score, largest file)
    if non_interactive {
        return Ok(candidates[0].0.clone());
    }

    // Multiple candidates — show top N and let user choose
    let top: Vec<&(PathBuf, u32, u64)> = candidates.iter().take(9).collect();
    println!();
    println!(
        "{}",
        "Multiple executables found. Choose one:".yellow().bold()
    );
    for (i, (path, _score, size)) in top.iter().enumerate() {
        let relative = path
            .strip_prefix(game_dir)
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| path.display().to_string());
        println!(
            "  [{}] {}  ({})",
            (i + 1).to_string().green().bold(),
            relative,
            format_bytes(*size)
        );
    }
    println!("  [0] Skip — I'll use --exec manually");

    let choice = loop {
        print!("{} ", ">".bold());
        io::stdout().flush().ok();
        let mut line = String::new();
        io::stdin().lock().read_line(&mut line)?;
        let trimmed = line.trim();
        if let Ok(n) = trimmed.parse::<usize>() {
            if n == 0 {
                bail!("no executable selected. Use --exec to specify one.");
            }
            if n <= top.len() {
                break n;
            }
        }
        println!(
            "{} Enter a number between 0 and {}",
            "⚠".yellow(),
            top.len()
        );
    };

    Ok(top[choice - 1].0.clone())
}

/// Known utility / non-game executables that should never be auto-selected.
const BLACKLIST: &[&str] = &[
    "unitycrashhandler64",
    "unitycrashhandler32",
    "crashhandler",
    "unins000",
    "uninstall",
    "uninst",
    "setup",
    "install",
    "vcredist_x86",
    "vcredist_x64",
    "dxsetup",
    "dotnetfx",
];

fn is_exe(path: &Path) -> bool {
    path.extension()
        .map(|e| e.eq_ignore_ascii_case("exe"))
        .unwrap_or(false)
}

fn is_blacklisted(path: &Path) -> bool {
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    BLACKLIST.iter().any(|b| stem.starts_with(b))
}

/// Score a candidate exe. Higher = better.
fn score_candidate(path: &Path, folder_name: &str, depth: u32) -> u32 {
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().to_lowercase())
        .unwrap_or_default();

    let mut score: u32 = 0;

    // +100 if base name matches the folder name (e.g. "Worldbox" ≈ "worldbox v0.51.2")
    if folder_name.contains(&stem) || stem.contains(folder_name) {
        score += 100;
    }

    // +10 if at root level (not nested)
    if depth == 0 {
        score += 10;
    }

    // +1 for shorter path depth (shallower files are likelier)
    score += (3u32).saturating_sub(depth);

    score
}

/// Count the number of files (not dirs) in a directory tree for progress bar sizing.
fn count_files(dir: &Path) -> usize {
    WalkDir::new(dir)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .count()
}

/// Format bytes to a human-readable string.
fn format_bytes(bytes: u64) -> String {
    const UNITS: &[&str] = &["B", "KB", "MB", "GB", "TB"];
    let mut size = bytes as f64;
    let mut unit_idx = 0;
    while size >= 1024.0 && unit_idx < UNITS.len() - 1 {
        size /= 1024.0;
        unit_idx += 1;
    }
    if unit_idx == 0 {
        format!("{} {}", bytes, UNITS[unit_idx])
    } else {
        format!("{:.2} {}", size, UNITS[unit_idx])
    }
}

/// Sanitize a string for use as a folder name on Windows.
fn sanitize_folder_name(name: &str) -> String {
    let forbidden = ['<', '>', ':', '"', '/', '\\', '|', '?', '*'];
    let mut result: String = name
        .chars()
        .map(|c| if forbidden.contains(&c) { '_' } else { c })
        .collect();
    result = result.trim().to_string();
    if result.is_empty() {
        result = "Unknown Game".to_string();
    }
    // Trim trailing dots/spaces (Windows constraint)
    result = result.trim_end_matches(['.', ' '].as_slice()).to_string();
    result
}

/// Copy an asset file (icon/cover) into the cartridge directory, renaming it.
fn copy_asset_file(source: &str, cartridge_dir: &Path, base_name: &str) -> anyhow::Result<()> {
    let src = Path::new(source);
    if !src.exists() {
        bail!("asset file not found: {}", source);
    }
    if !src.is_file() {
        bail!("asset path is not a file: {}", source);
    }

    let ext = src
        .extension()
        .map(|e| e.to_string_lossy().to_string())
        .unwrap_or_else(|| "png".to_string());

    let dest = cartridge_dir.join(format!("{}.{}", base_name, ext));
    fs::copy(src, &dest)
        .with_context(|| format!("failed to copy asset: {} -> {}", source, dest.display()))?;

    println!("{} Copied {} asset: {}", "✓".green(), base_name, dest.display().to_string().dimmed());

    Ok(())
}

/// Convert an absolute asset path to a relative path for the manifest.
fn asset_rel_path(source: &str, base_name: &str) -> String {
    let src = Path::new(source);
    let ext = src
        .extension()
        .map(|e| e.to_string_lossy().to_string())
        .unwrap_or_else(|| "png".to_string());
    format!("{}.{}", base_name, ext)
}
