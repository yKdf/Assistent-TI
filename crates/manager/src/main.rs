#![cfg_attr(all(windows, not(test)), windows_subsystem = "windows")]

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
fn run(args: &[String]) -> Result<()> {
    let exe = std::env::current_exe()?;
    let saved = exe
        .parent()
        .context("Pasta do aplicativo indisponível")?
        .join("server-url.txt");
    if args
        .first()
        .is_some_and(|arg| arg == "--check-server" || arg == "--configure")
    {
        anyhow::ensure!(args.len() == 2, "Informe exatamente uma URL de servidor");
        let url = validate(args[1].trim())?;
        if args[0] == "--configure" {
            let temporary = saved.with_extension("tmp");
            std::fs::write(&temporary, url.as_str())?;
            std::fs::rename(temporary, saved)?;
        }
        return Ok(());
    }
    anyhow::ensure!(args.len() <= 1, "Informe somente a URL do servidor");
    let server = args
        .first()
        .cloned()
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

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Err(error) = run(&args) {
        let installer_command = args
            .first()
            .is_some_and(|arg| arg == "--check-server" || arg == "--configure");
        #[cfg(windows)]
        if !installer_command {
            #[link(name = "user32")]
            extern "system" {
                fn MessageBoxW(
                    window: *mut std::ffi::c_void,
                    text: *const u16,
                    caption: *const u16,
                    flags: u32,
                ) -> i32;
            }
            let text: Vec<u16> = format!("Não foi possível abrir o Assistente TI.\n\n{error}")
                .encode_utf16()
                .chain(Some(0))
                .collect();
            let title: Vec<u16> = "Assistente TI\0".encode_utf16().collect();
            unsafe {
                MessageBoxW(std::ptr::null_mut(), text.as_ptr(), title.as_ptr(), 0x10);
            }
        }
        #[cfg(not(windows))]
        {
            let _ = installer_command;
            eprintln!("{error}");
        }
        std::process::exit(1);
    }
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
    #[test]
    fn installer_validation_has_no_browser_side_effect() {
        assert!(run(&["--check-server".into(), "https://ti.example.com".into()]).is_ok());
        assert!(run(&["--check-server".into(), "http://example.com".into()]).is_err());
        assert!(run(&[
            "--check-server".into(),
            "https://ti.example.com".into(),
            "extra".into()
        ])
        .is_err());
    }
}
