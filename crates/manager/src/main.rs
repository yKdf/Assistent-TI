use anyhow::{Context, Result};
use std::{path::PathBuf, process::Command};

fn validate(server: &str) -> Result<url::Url> {
    let url = url::Url::parse(server)?;
    anyhow::ensure!(
        url.scheme() == "https"
            || (url.scheme() == "http"
                && matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"))),
        "Use HTTPS ou localhost"
    );
    anyhow::ensure!(
        url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && url.path() == "/",
        "Informe somente a origem do servidor"
    );
    Ok(url)
}
fn main() -> Result<()> {
    let exe = std::env::current_exe()?;
    let saved = exe
        .parent()
        .context("Pasta do aplicativo indisponível")?
        .join("server-url.txt");
    let server = std::env::args()
        .nth(1)
        .or_else(|| std::fs::read_to_string(saved).ok())
        .context("Uso: assist-manager https://ti.suaempresa.com.br")?;
    let url = validate(server.trim())?;
    let argument = format!("--app={url}");
    #[cfg(windows)]
    let browsers: Vec<PathBuf> = ["ProgramFiles(x86)", "ProgramFiles", "LOCALAPPDATA"]
        .iter()
        .filter_map(std::env::var_os)
        .map(|p| PathBuf::from(p).join("Microsoft/Edge/Application/msedge.exe"))
        .collect();
    #[cfg(not(windows))]
    let browsers: Vec<PathBuf> = [
        "microsoft-edge",
        "microsoft-edge-stable",
        "chromium",
        "chromium-browser",
        "google-chrome",
    ]
    .iter()
    .map(PathBuf::from)
    .collect();
    for browser in browsers {
        if Command::new(browser).arg(&argument).spawn().is_ok() {
            return Ok(());
        }
    }
    anyhow::bail!("Instale Microsoft Edge no Windows, ou Chromium/Edge/Chrome no Linux. O aplicativo usa o painel em uma janela própria.")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_trusted_url_schemes() {
        assert!(validate("https://ti.example.com").is_ok());
        assert!(validate("http://localhost:8080").is_ok());
        for bad in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "http://example.com",
            "https://user:pass@example.com",
            "https://example.com/?token=123",
        ] {
            assert!(validate(bad).is_err());
        }
    }
}
