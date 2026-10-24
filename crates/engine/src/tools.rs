//! The helper programs that come with Ezoo Download: yt-dlp (finds the video
//! links) and ffmpeg (joins video + audio), both from their GitHub releases. They live in the "tools" folder
//! of the install folder. Once a day, silently, Ezoo Download checks for new
//! versions and updates them, and puts them back if one went missing.

use crate::mux::hide_window;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

const YTDLP_URL: &str = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe";
/// ffmpeg builds published on GitHub (rolling release "latest")
const FFMPEG_RELEASE_API: &str = "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/tags/latest";

#[derive(serde::Deserialize)]
struct GhAsset {
    name: String,
    browser_download_url: String,
    #[serde(default)]
    updated_at: String,
}

#[derive(serde::Deserialize)]
struct GhRelease {
    assets: Vec<GhAsset>,
}

/// Windows 7 / 8: the official yt-dlp.exe needs Windows 10, and `yt-dlp -U`
/// would replace a working copy with it. A community build for Windows 7 is
/// used there instead (its release must contain an .exe with "win7" in the
/// name). Set EZOO_YTDLP_URL to use any other direct download address.
const YTDLP_WIN7_RELEASE_API: &str = "https://api.github.com/repos/nicolaasjan/yt-dlp/releases/latest";

#[derive(serde::Deserialize)]
struct GhTagRelease {
    #[serde(default)]
    tag_name: String,
    assets: Vec<GhAsset>,
}

/// The Windows 7 build of yt-dlp for this program's bitness (64-bit first).
fn pick_ytdlp_win7(assets: &[GhAsset]) -> Option<&GhAsset> {
    let is_win7 = |a: &&GhAsset| {
        let n = a.name.to_ascii_lowercase();
        n.contains("win7") && n.ends_with(".exe")
    };
    let is_32 = |a: &GhAsset| a.name.to_ascii_lowercase().contains("x86");
    let wants_32 = !cfg!(target_pointer_width = "64");
    assets
        .iter()
        .filter(is_win7)
        .find(|a| is_32(*a) == wants_32)
        .or_else(|| assets.iter().find(|a| is_win7(a)))
}

/// The newest stable 64-bit Windows build: "ffmpeg-n7.1-latest-win64-gpl-7.1.zip"
/// (the highest n<version>), else the master build.
fn pick_ffmpeg(assets: &[GhAsset]) -> Option<&GhAsset> {
    let re = regex::Regex::new(r"^ffmpeg-n([0-9.]+)-latest-win64-gpl-[0-9.]+\.zip$").ok()?;
    let key = |v: &str| v.split('.').map(|p| p.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    assets
        .iter()
        .filter_map(|a| re.captures(&a.name).map(|c| (key(&c[1]), a)))
        .max_by(|x, y| x.0.cmp(&y.0))
        .map(|(_, a)| a)
        .or_else(|| assets.iter().find(|a| a.name == "ffmpeg-master-latest-win64-gpl.zip"))
}

fn exe(name: &str) -> String {
    if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_string()
    }
}

/// Folders searched for the tools, best first.
pub fn tool_dirs() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Some(dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf)) {
        v.push(dir.join("tools"));
        v.push(dir);
    }
    if let Some(p) = directories::ProjectDirs::from("com", "Ezoo", "EzooDownload") {
        v.push(p.data_dir().join("tools"));
    }
    v
}

/// A tool shipped with the app (not one somewhere on PATH).
pub fn bundled(name: &str) -> Option<PathBuf> {
    tool_dirs().into_iter().map(|d| d.join(exe(name))).find(|p| p.exists())
}

/// Where new copies go: the install folder's "tools" when we may write
/// there, else our data folder.
fn writable_dir(name: &str) -> Option<PathBuf> {
    // keep updating the copy that is already used
    if let Some(p) = bundled(name) {
        if let Some(dir) = p.parent() {
            if can_write(dir) {
                return Some(dir.to_path_buf());
            }
        }
    }
    tool_dirs().into_iter().find(|d| std::fs::create_dir_all(d).is_ok() && can_write(d))
}

fn can_write(dir: &Path) -> bool {
    let probe = dir.join(".ezoo-write-test");
    let ok = std::fs::write(&probe, b"x").is_ok();
    let _ = std::fs::remove_file(&probe);
    ok
}

fn due(stamp: &Path, every: Duration) -> bool {
    std::fs::metadata(stamp)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| SystemTime::now().duration_since(t).ok())
        .map(|age| age > every)
        .unwrap_or(true)
}

async fn download(client: &reqwest::Client, url: &str, dest: &Path) -> anyhow::Result<()> {
    let mut resp = client
        .get(url)
        .header(reqwest::header::USER_AGENT, crate::config::DEFAULT_USER_AGENT)
        .send()
        .await?
        .error_for_status()?;
    use std::io::Write;
    let tmp = dest.with_extension("download");
    let mut file = std::fs::File::create(&tmp)?;
    let mut total = 0usize;
    while let Some(chunk) = resp.chunk().await? {
        file.write_all(&chunk)?;
        total += chunk.len();
    }
    drop(file);
    if total < 1024 {
        let _ = std::fs::remove_file(&tmp);
        anyhow::bail!("the download of {url} was too small");
    }
    replace(&tmp, dest)
}

/// Put `new` in place of `target`, even if `target` is running right now
/// (Windows lets us rename a running program, not delete it).
fn replace(new: &Path, target: &Path) -> anyhow::Result<()> {
    if target.exists() {
        let old = target.with_extension("old");
        let _ = std::fs::remove_file(&old);
        if std::fs::remove_file(target).is_err() {
            std::fs::rename(target, &old)?;
        }
    }
    std::fs::rename(new, target)?;
    Ok(())
}

/// yt-dlp missing: get it. Present: `yt-dlp -U` (at most once a day).
async fn yt_dlp(client: &reqwest::Client, data_dir: &Path) {
    if cfg!(windows) && crate::system::is_legacy_windows() && std::env::var_os("EZOO_YTDLP_URL").is_none() {
        let _ = yt_dlp_win7(client, data_dir).await;
        return;
    }
    if bundled("yt-dlp").is_none() {
        if cfg!(windows) {
            if let Some(dir) = writable_dir("yt-dlp") {
                let url = std::env::var("EZOO_YTDLP_URL")
                    .ok()
                    .filter(|u| u.starts_with("https://"))
                    .unwrap_or_else(|| YTDLP_URL.to_string());
                let _ = download(client, &url, &dir.join(exe("yt-dlp"))).await;
            }
        }
        return;
    }
    let stamp = data_dir.join("yt-dlp-updated");
    if !due(&stamp, Duration::from_secs(20 * 3600)) {
        return;
    }
    let Some(tool) = bundled("yt-dlp") else { return };
    let ok = tokio::task::spawn_blocking(move || {
        let mut cmd = Command::new(&tool);
        cmd.arg("-U");
        hide_window(&mut cmd);
        cmd.output().map(|o| o.status.success()).unwrap_or(false)
    })
    .await
    .unwrap_or(false);
    if ok {
        let _ = std::fs::write(&stamp, b"ok");
    }
}

/// Windows 7 / 8: install or update yt-dlp from the Windows 7 build. The
/// release tag is remembered next to the program (no `yt-dlp -U` here).
async fn yt_dlp_win7(client: &reqwest::Client, data_dir: &Path) -> anyhow::Result<()> {
    let present = bundled("yt-dlp");
    let stamp = data_dir.join("yt-dlp-updated");
    if present.is_some() && !due(&stamp, Duration::from_secs(20 * 3600)) {
        return Ok(());
    }
    let text = client
        .get(YTDLP_WIN7_RELEASE_API)
        .header(reqwest::header::USER_AGENT, crate::config::DEFAULT_USER_AGENT)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;
    let release: GhTagRelease = serde_json::from_str(&text)?;
    let Some(asset) = pick_ytdlp_win7(&release.assets) else {
        anyhow::bail!("no Windows 7 build of yt-dlp in the release");
    };
    if !asset.browser_download_url.starts_with("https://github.com/") {
        anyhow::bail!("unexpected yt-dlp download address");
    }
    let Some(dir) = writable_dir("yt-dlp") else { return Ok(()) };
    let version_file = dir.join("yt-dlp-version.txt");
    let latest = format!("{} {}", release.tag_name, asset.name);
    if present.is_some() && std::fs::read_to_string(&version_file).unwrap_or_default().trim() == latest {
        let _ = std::fs::write(&stamp, b"ok");
        return Ok(());
    }
    download(client, &asset.browser_download_url, &dir.join(exe("yt-dlp"))).await?;
    std::fs::write(&version_file, &latest)?;
    let _ = std::fs::write(&stamp, b"ok");
    Ok(())
}

/// ffmpeg: compare with the newest release build and replace it when
/// there's a newer one (or when it's missing).
///
/// Not on Windows 7 / 8: the newest rolling builds may need Windows 10, so
/// the ffmpeg.exe that came with the setup (a Windows 7 compatible build) is
/// kept as it is. ffmpeg is only used to join video and audio ("-c copy").
async fn ffmpeg(client: &reqwest::Client, data_dir: &Path) -> anyhow::Result<()> {
    if !cfg!(windows) || crate::system::is_legacy_windows() {
        return Ok(());
    }
    let present = bundled("ffmpeg");
    let stamp = data_dir.join("ffmpeg-checked");
    if present.is_some() && !due(&stamp, Duration::from_secs(20 * 3600)) {
        return Ok(());
    }
    let text = client
        .get(FFMPEG_RELEASE_API)
        .header(reqwest::header::USER_AGENT, crate::config::DEFAULT_USER_AGENT)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;
    let release: GhRelease = serde_json::from_str(&text)?;
    let Some(asset) = pick_ffmpeg(&release.assets) else {
        anyhow::bail!("no ffmpeg build in the release");
    };
    // name + date: changes whenever a new build is published
    let latest = format!("{} {}", asset.name, asset.updated_at);
    let zip_url = asset.browser_download_url.clone();
    if !zip_url.starts_with("https://github.com/") {
        anyhow::bail!("unexpected ffmpeg download address");
    }
    let Some(dir) = writable_dir("ffmpeg") else { return Ok(()) };
    let version_file = dir.join("ffmpeg-version.txt");
    let current = std::fs::read_to_string(&version_file).unwrap_or_default();
    if present.is_some() && current.trim() == latest {
        let _ = std::fs::write(&stamp, b"ok");
        return Ok(());
    }
    // download the zip, unpack ffmpeg.exe from it (built-in unzip: tar.exe is
    // missing on Windows 7 and 8)
    let work = std::env::temp_dir().join(format!("ezoo-ffmpeg-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work)?;
    let zip = work.join("ffmpeg.zip");
    download(client, &zip_url, &zip).await?;
    let (zip2, out2) = (zip.clone(), work.join(exe("ffmpeg")));
    let unpacked = tokio::task::spawn_blocking(move || extract_named(&zip2, &exe("ffmpeg"), &out2).is_ok())
        .await
        .unwrap_or(false);
    let found = unpacked.then(|| find_file(&work, &exe("ffmpeg"))).flatten();
    let result = match found {
        Some(f) => {
            let staged = dir.join("ffmpeg.new");
            std::fs::copy(&f, &staged)?;
            replace(&staged, &dir.join(exe("ffmpeg")))?;
            std::fs::write(&version_file, &latest)?;
            let _ = std::fs::write(&stamp, b"ok");
            Ok(())
        }
        None => Err(anyhow::anyhow!("ffmpeg.exe was not found in the download")),
    };
    let _ = std::fs::remove_dir_all(&work);
    result
}

/// Take the file called `wanted` (wherever it is inside the zip) out to `dest`.
fn extract_named(zip_path: &Path, wanted: &str, dest: &Path) -> anyhow::Result<()> {
    let mut archive = zip::ZipArchive::new(std::io::BufReader::new(std::fs::File::open(zip_path)?))?;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        if entry.is_dir() {
            continue;
        }
        let name = entry.name().replace('\\', "/");
        let file = name.rsplit('/').next().unwrap_or("");
        if file.eq_ignore_ascii_case(wanted) {
            let mut out = std::fs::File::create(dest)?;
            std::io::copy(&mut entry, &mut out)?;
            return Ok(());
        }
    }
    anyhow::bail!("{wanted} is not in the archive")
}

fn find_file(dir: &Path, name: &str) -> Option<PathBuf> {
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let p = entry.path();
        if p.is_dir() {
            if let Some(f) = find_file(&p, name) {
                return Some(f);
            }
        } else if p.file_name().map(|n| n.eq_ignore_ascii_case(name)).unwrap_or(false) {
            return Some(p);
        }
    }
    None
}

/// Check both tools now (only does work when a day has passed or one is
/// missing). Never shows anything; errors just mean "try again later".
pub async fn update_all(client: reqwest::Client, data_dir: PathBuf) {
    yt_dlp(&client, &data_dir).await;
    let _ = ffmpeg(&client, &data_dir).await;
    // leftovers of earlier updates
    for dir in tool_dirs() {
        for name in ["yt-dlp", "ffmpeg"] {
            let _ = std::fs::remove_file(dir.join(exe(name)).with_extension("old"));
        }
    }
}

/// Run `update_all` now and then every few hours while the app is open.
pub fn spawn_updater(rt: &tokio::runtime::Handle, client: reqwest::Client, data_dir: PathBuf) {
    rt.spawn(async move {
        // let the app start first
        tokio::time::sleep(Duration::from_secs(20)).await;
        loop {
            update_all(client.clone(), data_dir.clone()).await;
            tokio::time::sleep(Duration::from_secs(6 * 3600)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn picks_stable_ffmpeg() {
        let a = |n: &str| GhAsset { name: n.into(), browser_download_url: String::new(), updated_at: String::new() };
        let list = vec![
            a("ffmpeg-master-latest-win64-gpl.zip"),
            a("ffmpeg-n7.1-latest-win64-gpl-7.1.zip"),
            a("ffmpeg-n7.0-latest-win64-gpl-7.0.zip"),
            a("ffmpeg-n7.1-latest-win64-gpl-shared-7.1.zip"),
            a("ffmpeg-n7.1-latest-linux64-gpl-7.1.tar.xz"),
        ];
        assert_eq!(pick_ffmpeg(&list).unwrap().name, "ffmpeg-n7.1-latest-win64-gpl-7.1.zip");
        assert_eq!(pick_ffmpeg(&list[..1]).unwrap().name, "ffmpeg-master-latest-win64-gpl.zip");
    }

    #[test]
    fn picks_win7_ytdlp() {
        let a = |n: &str| GhAsset { name: n.into(), browser_download_url: String::new(), updated_at: String::new() };
        let list = vec![a("yt-dlp.exe"), a("yt-dlp_x86_win7.exe"), a("yt-dlp_win7.exe"), a("yt-dlp_linux")];
        let got = pick_ytdlp_win7(&list).unwrap().name.clone();
        if cfg!(target_pointer_width = "64") {
            assert_eq!(got, "yt-dlp_win7.exe");
        } else {
            assert_eq!(got, "yt-dlp_x86_win7.exe");
        }
        assert!(pick_ytdlp_win7(&list[..1]).is_none());
    }

    #[test]
    fn replace_and_find() {
        let dir = std::env::temp_dir().join(format!("ezoo-tools-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("a/b")).unwrap();
        std::fs::write(dir.join("a/b/ffmpeg.exe"), b"new").unwrap();
        assert!(find_file(&dir, "FFMPEG.EXE").is_some());
        let target = dir.join("tool.exe");
        std::fs::write(&target, b"old").unwrap();
        let new = dir.join("tool.new");
        std::fs::write(&new, b"fresh").unwrap();
        replace(&new, &target).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"fresh");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
