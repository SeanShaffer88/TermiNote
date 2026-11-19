use reqwest::{Client, Url, redirect::Policy};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::Path,
    time::Duration,
};

const LATEST_RELEASE: &str =
    "https://api.github.com/repos/SeanShaffer88/TermiNote/releases/latest";
const INSTALLER_NAME: &str = "TermiNote-Setup-x64.exe";
const MAX_INSTALLER_BYTES: usize = 50 * 1024 * 1024;

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
    digest: Option<String>,
}

pub async fn download_update(data_dir: &Path) -> Option<std::path::PathBuf> {
    check_and_download(data_dir).await.ok()
}

async fn check_and_download(data_dir: &Path) -> Result<std::path::PathBuf, String> {
    let api = Client::builder()
        .timeout(Duration::from_secs(20))
        .redirect(Policy::none())
        .user_agent(format!("TermiNote/{}", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| error.to_string())?;
    let response = api
        .get(LATEST_RELEASE)
        .send()
        .await
        .map_err(|error| error.to_string())?;
    if !response.status().is_success() {
        return Err("Release lookup failed.".into());
    }
    let release: Release = response.json().await.map_err(|error| error.to_string())?;
    if !is_update_available(&release.tag_name, env!("CARGO_PKG_VERSION")) {
        return Err("No newer release.".into());
    }
    let asset = release
        .assets
        .iter()
        .find(|asset| asset.name == INSTALLER_NAME)
        .ok_or_else(|| "Release has no x64 installer.".to_string())?;
    let url = Url::parse(&asset.browser_download_url).map_err(|error| error.to_string())?;
    if !trusted_setup_url(&url) {
        return Err("Installer URL is not trusted.".into());
    }
    let digest = parse_digest(asset.digest.as_deref())
        .ok_or_else(|| "Release has no valid installer hash.".to_string())?;

    let download = Client::builder()
        .timeout(Duration::from_secs(120))
        .redirect(Policy::custom(|attempt| {
            if attempt.previous().len() >= 5 || !trusted_download_hop(attempt.url()) {
                attempt.stop()
            } else {
                attempt.follow()
            }
        }))
        .user_agent(format!("TermiNote/{}", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| error.to_string())?;
    let response = download
        .get(url)
        .send()
        .await
        .map_err(|error| error.to_string())?;
    if !response.status().is_success()
        || response
            .content_length()
            .is_some_and(|length| length > MAX_INSTALLER_BYTES as u64)
    {
        return Err("Installer download was rejected.".into());
    }
    let mut response = response;
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|error| error.to_string())?
    {
        if bytes.len().saturating_add(chunk.len()) > MAX_INSTALLER_BYTES {
            return Err("Installer exceeds the size limit.".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() || format!("{:x}", Sha256::digest(&bytes)) != digest {
        return Err("Installer hash did not match.".into());
    }

    let updates = data_dir.join("updates");
    fs::create_dir_all(&updates).map_err(|error| error.to_string())?;
    let version = version_parts(&release.tag_name)
        .iter()
        .map(u32::to_string)
        .collect::<Vec<_>>()
        .join(".");
    let destination = updates.join(format!("TermiNote-Setup-x64-{version}.exe"));
    let partial = updates.join(format!(
        ".TermiNote-Setup-x64-{}-{}.part",
        std::process::id(),
        version
    ));
    let _ = fs::remove_file(&partial);
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&partial)
        .map_err(|error| error.to_string())?;
    if let Err(error) = file.write_all(&bytes) {
        let _ = fs::remove_file(&partial);
        return Err(error.to_string());
    }
    drop(file);
    if destination.exists() {
        fs::remove_file(&destination).map_err(|error| error.to_string())?;
    }
    fs::rename(&partial, &destination).map_err(|error| error.to_string())?;
    Ok(destination)
}

fn version_parts(value: &str) -> Vec<u32> {
    value
        .trim_start_matches(|ch| ch == 'v' || ch == 'V')
        .split(['+', '-'])
        .next()
        .unwrap_or_default()
        .split('.')
        .map(|part| part.parse::<u32>().unwrap_or(0))
        .collect()
}

fn is_update_available(latest: &str, current: &str) -> bool {
    let latest = version_parts(latest);
    let current = version_parts(current);
    for index in 0..latest.len().max(current.len()) {
        let left = latest.get(index).copied().unwrap_or(0);
        let right = current.get(index).copied().unwrap_or(0);
        if left != right {
            return left > right;
        }
    }
    false
}

fn trusted_setup_url(url: &Url) -> bool {
    let Some(segments) = url
        .path_segments()
        .map(|segments| segments.collect::<Vec<_>>())
    else {
        return false;
    };
    trusted_https_url(url)
        && url.host_str().is_some_and(|host| host.eq_ignore_ascii_case("github.com"))
        && segments.len() == 6
        && segments[0] == "SeanShaffer88"
        && segments[1] == "TermiNote"
        && segments[2] == "releases"
        && segments[3] == "download"
        && !segments[4].is_empty()
        && segments[5] == INSTALLER_NAME
}

fn trusted_download_hop(url: &Url) -> bool {
    if !trusted_https_url(url) {
        return false;
    }
    match url.host_str().map(str::to_ascii_lowercase) {
        Some(host) if host == "github.com" => trusted_setup_url(url),
        Some(host) => {
            host == "release-assets.githubusercontent.com"
                || host == "objects.githubusercontent.com"
        }
        None => false,
    }
}

fn trusted_https_url(url: &Url) -> bool {
    url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port_or_known_default() == Some(443)
        && url.fragment().is_none()
}

fn parse_digest(raw: Option<&str>) -> Option<String> {
    let value = raw?.strip_prefix("sha256:")?;
    (value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then(|| value.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_comparison_handles_prefixes_and_length() {
        assert!(is_update_available("v0.9.0", "0.8.2"));
        assert!(!is_update_available("0.8.2", "v0.8.2"));
        assert!(!is_update_available("0.8", "0.8.0"));
    }

    #[test]
    fn installer_links_must_point_at_the_exact_release_asset() {
        let valid = Url::parse(
            "https://github.com/SeanShaffer88/TermiNote/releases/download/v0.9.0/TermiNote-Setup-x64.exe",
        )
        .unwrap();
        let wrong_repo = Url::parse(
            "https://github.com/other/TermiNote/releases/download/v0.9.0/TermiNote-Setup-x64.exe",
        )
        .unwrap();
        assert!(trusted_setup_url(&valid));
        assert!(!trusted_setup_url(&wrong_repo));
    }

    #[test]
    fn redirect_hosts_and_protocol_are_restricted() {
        let https_asset = Url::parse(
            "https://release-assets.githubusercontent.com/download/installer.exe",
        )
        .unwrap();
        let http_asset = Url::parse(
            "http://release-assets.githubusercontent.com/download/installer.exe",
        )
        .unwrap();
        let lookalike = Url::parse(
            "https://release-assets.githubusercontent.com.evil.test/download/installer.exe",
        )
        .unwrap();
        assert!(trusted_download_hop(&https_asset));
        assert!(!trusted_download_hop(&http_asset));
        assert!(!trusted_download_hop(&lookalike));
    }

    #[test]
    fn digest_parser_requires_a_sha256_hex_digest() {
        assert!(parse_digest(Some(&format!("sha256:{}", "a".repeat(64)))).is_some());
        assert!(parse_digest(Some("sha256:bad")).is_none());
        assert!(parse_digest(None).is_none());
    }
}
