#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod app {
    use anyhow::{Context, Result};
    use enigo::{Button, Coordinate, Direction, Enigo, Keyboard, Mouse, Settings};
    use reqwest::blocking::Client;
    use serde::Deserialize;
    use std::{io::Cursor, path::PathBuf, thread, time::Duration};
    use xcap::{image::ImageFormat, Monitor};

    struct ActiveIndicator;
    impl ActiveIndicator {
        fn show() -> Self {
            #[cfg(windows)]
            unsafe {
                #[link(name = "kernel32")]
                extern "system" {
                    fn AllocConsole() -> i32;
                    fn SetConsoleTitleW(title: *const u16) -> i32;
                }
                let title: Vec<u16> = "ASSISTENTE TI — SUPORTE REMOTO ATIVO\0"
                    .encode_utf16()
                    .collect();
                AllocConsole();
                SetConsoleTitleW(title.as_ptr());
            }
            Self
        }
    }
    impl Drop for ActiveIndicator {
        fn drop(&mut self) {
            #[cfg(windows)]
            unsafe {
                #[link(name = "kernel32")]
                extern "system" {
                    fn FreeConsole() -> i32;
                }
                FreeConsole();
            }
        }
    }

    #[derive(Deserialize)]
    struct Config {
        server: String,
        node_id: String,
        token: String,
        unattended: bool,
    }

    #[derive(Deserialize)]
    struct Pending {
        session_id: Option<String>,
    }

    #[derive(Deserialize)]
    #[serde(tag = "type", rename_all = "snake_case")]
    enum Input {
        MouseMove { x: i32, y: i32 },
        MouseButton { button: String },
        Scroll { delta: i32 },
        Text { text: String },
        Key { code: u16 },
        End,
    }

    fn config_path() -> PathBuf {
        std::env::var_os("ASSIST_SUPPORT_CONFIG")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(r"C:\ProgramData\AssistenteTISupport\config.json"))
    }

    fn request(client: &Client, config: &Config, path: &str) -> reqwest::blocking::RequestBuilder {
        client
            .get(format!("{}{path}", config.server))
            .bearer_auth(&config.token)
            .header("X-Assist-Node", &config.node_id)
    }

    fn frame() -> Result<Vec<u8>> {
        let monitor = Monitor::all()?
            .into_iter()
            .find(|m| m.is_primary().unwrap_or(false))
            .context("Nenhum monitor principal")?;
        let image = monitor.capture_image()?;
        let image = if image.width() > 1440 {
            let height = image.height() * 1440 / image.width();
            xcap::image::imageops::resize(
                &image,
                1440,
                height,
                xcap::image::imageops::FilterType::Triangle,
            )
        } else {
            image
        };
        let mut bytes = Cursor::new(Vec::new());
        image.write_to(&mut bytes, ImageFormat::Jpeg)?;
        Ok(bytes.into_inner())
    }

    fn apply(enigo: &mut Enigo, input: Input) -> Result<bool> {
        match input {
            Input::MouseMove { x, y } => enigo.move_mouse(x, y, Coordinate::Abs)?,
            Input::MouseButton { button } => {
                let button = match button.as_str() {
                    "right" => Button::Right,
                    "middle" => Button::Middle,
                    _ => Button::Left,
                };
                enigo.button(button, Direction::Click)?;
            }
            Input::Scroll { delta } => enigo.scroll(delta.clamp(-20, 20), enigo::Axis::Vertical)?,
            Input::Text { text } => enigo.text(&text.chars().take(500).collect::<String>())?,
            Input::Key { code } => enigo.raw(code, Direction::Click)?,
            Input::End => return Ok(false),
        }
        Ok(true)
    }

    fn session(client: &Client, config: &Config, id: &str) -> Result<()> {
        let _indicator = ActiveIndicator::show();
        let mut enigo = Enigo::new(&Settings::default()).map_err(|e| anyhow::anyhow!("{e}"))?;
        client
            .post(format!("{}/api/support/client/{id}/active", config.server))
            .bearer_auth(&config.token)
            .header("X-Assist-Node", &config.node_id)
            .send()?
            .error_for_status()?;
        loop {
            let image = frame()?;
            client
                .post(format!("{}/api/support/client/{id}/frame", config.server))
                .bearer_auth(&config.token)
                .header("X-Assist-Node", &config.node_id)
                .header("Content-Type", "image/jpeg")
                .body(image)
                .send()?
                .error_for_status()?;
            let inputs: Vec<Input> =
                request(client, config, &format!("/api/support/client/{id}/inputs"))
                    .send()?
                    .error_for_status()?
                    .json()?;
            for input in inputs {
                if !apply(&mut enigo, input)? {
                    return Ok(());
                }
            }
            thread::sleep(Duration::from_millis(700));
        }
    }

    pub fn run() -> Result<()> {
        let config: Config = serde_json::from_slice(&std::fs::read(config_path())?)?;
        anyhow::ensure!(config.unattended, "Suporte não assistido desabilitado");
        let client = Client::builder().timeout(Duration::from_secs(15)).build()?;
        loop {
            let pending = request(&client, &config, "/api/support/client/pending")
                .send()
                .and_then(|r| r.error_for_status())
                .and_then(|r| r.json::<Pending>());
            if let Ok(Pending {
                session_id: Some(id),
            }) = pending
            {
                let _ = session(&client, &config, &id);
            }
            thread::sleep(Duration::from_secs(3));
        }
    }
}

#[cfg(windows)]
fn main() -> anyhow::Result<()> {
    app::run()
}

#[cfg(not(windows))]
fn main() {
    eprintln!("O módulo de suporte remoto está disponível para Windows nesta versão.");
}
