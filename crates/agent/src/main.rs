use anyhow::{Context, Result};
use assist_protocol::*;
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use sysinfo::{Disks, System};

#[derive(Clone, Serialize, Deserialize)]
struct Config {
    server: String,
    #[serde(default)]
    node_id: String,
    #[serde(default)]
    token: String,
    #[serde(default)]
    support_id: Option<String>,
    #[serde(default)]
    update_public_key: Option<String>,
    #[serde(default)]
    allow_reboot: bool,
    #[serde(default)]
    installed_sequence: u64,
}
#[derive(Default, Serialize, Deserialize)]
struct Journal {
    seen: Vec<String>,
    pending: Vec<CommandResult>,
}
fn root() -> PathBuf {
    std::env::var_os("ASSIST_AGENT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(
                std::env::var_os("ProgramData").unwrap_or_else(|| "C:\\ProgramData".into()),
            )
            .join("AssistenteTI")
        })
}
fn read_config(dir: &Path) -> Result<Config> {
    let mut config: Config = serde_json::from_slice(&fs::read(dir.join("config.json"))?)?;
    config.server = config.server.trim_end_matches('/').to_string();
    let url = reqwest::Url::parse(&config.server)?;
    anyhow::ensure!(
        url.scheme() == "https"
            || (url.scheme() == "http"
                && matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"))),
        "Use HTTPS; HTTP permitido somente em localhost"
    );
    anyhow::ensure!(
        url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
            && url.path() == "/",
        "Use apenas a origem do servidor, sem credenciais ou caminho"
    );
    if let Some(id) = &config.support_id {
        anyhow::ensure!(
            !id.is_empty() && id.len() <= 20 && id.bytes().all(|c| c.is_ascii_digit()),
            "ID RustDesk inválido"
        );
    }
    if let Some(key) = &config.update_public_key {
        anyhow::ensure!(hex::decode(key)?.len() == 32, "Chave pública inválida");
    }
    Ok(config)
}
fn atomic_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let tmp = path.with_extension("tmp");
    let mut file = fs::File::create(&tmp)?;
    file.write_all(&serde_json::to_vec_pretty(value)?)?;
    file.sync_all()?;
    drop(file);
    fs::rename(tmp, path)?;
    Ok(())
}
fn client() -> Result<Client> {
    Ok(Client::builder()
        .timeout(Duration::from_secs(25))
        .connect_timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(format!("AssistenteTI/{VERSION}"))
        .build()?)
}
fn log(dir: &Path, message: &str) {
    let path = dir.join("agent.log");
    if fs::metadata(&path)
        .map(|m| m.len() > 2_000_000)
        .unwrap_or(false)
    {
        let _ = fs::rename(&path, dir.join("agent.previous.log"));
    }
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{} {}", now(), message);
    }
}
fn metrics(system: &mut System, config: &Config) -> Metrics {
    system.refresh_all();
    let disks = Disks::new_with_refreshed_list();
    let mut disk_total = 0u64;
    let mut disk_used = 0u64;
    for disk in disks.iter().filter(|d| !d.is_removable()) {
        disk_total = disk_total.saturating_add(disk.total_space());
        disk_used =
            disk_used.saturating_add(disk.total_space().saturating_sub(disk.available_space()));
    }
    let mut processes: Vec<_> = system
        .processes()
        .iter()
        .map(|(pid, p)| ProcessInfo {
            pid: pid.as_u32(),
            name: p.name().to_string_lossy().chars().take(200).collect(),
            cpu: p.cpu_usage(),
            memory: p.memory(),
        })
        .collect();
    processes.sort_by_key(|p| std::cmp::Reverse(p.memory));
    processes.truncate(100);
    Metrics {
        hostname: System::host_name().unwrap_or_else(|| "Windows".into()),
        os: System::long_os_version().unwrap_or_default(),
        cpu: system.global_cpu_usage().clamp(0.0, 100.0),
        memory_used: system.used_memory(),
        memory_total: system.total_memory(),
        disk_used,
        disk_total,
        uptime: System::uptime(),
        processes,
        version: VERSION.into(),
        support_id: config.support_id.clone(),
    }
}
fn execute(action: &Action, config: &Config) -> Result<String> {
    match action {
        Action::Refresh => Ok("Inventário será atualizado no próximo heartbeat".into()),
        Action::Reboot => {
            anyhow::ensure!(
                config.allow_reboot,
                "Reinicialização remota desabilitada pelo administrador local"
            );
            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                let shutdown = PathBuf::from(
                    std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into()),
                )
                .join("System32/shutdown.exe");
                let status = std::process::Command::new(shutdown)
                    .args([
                        "/r",
                        "/t",
                        "60",
                        "/c",
                        "Reinicialização solicitada pelo suporte de TI. Salve seu trabalho.",
                    ])
                    .creation_flags(0x08000000)
                    .status()?;
                anyhow::ensure!(status.success(), "O Windows rejeitou a reinicialização");
                Ok("Reinicialização agendada pelo Windows para daqui a 60 segundos".into())
            }
            #[cfg(not(windows))]
            {
                anyhow::bail!("Reinicialização disponível somente no agente Windows");
            }
        }
    }
}
fn stage_update(dir: &Path, config: &Config, client: &Client, release: &Release) -> Result<()> {
    let Some(key) = &config.update_public_key else {
        return Ok(());
    };
    if release.sequence <= config.installed_sequence
        || dir.join("pending.json").exists()
        || dir.join("installing.json").exists()
    {
        return Ok(());
    }
    if fs::read_to_string(dir.join("failed-sequence"))
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        == Some(release.sequence)
    {
        return Ok(());
    }
    anyhow::ensure!(
        release.sha256.len() == 64 && release.sha256.bytes().all(|b| b.is_ascii_hexdigit()),
        "Hash de release inválido"
    );
    let response = client
        .get(format!("{}/api/releases/{}", config.server, release.sha256))
        .bearer_auth(&config.token)
        .send()?
        .error_for_status()?;
    anyhow::ensure!(
        response.content_length().unwrap_or(0) <= 100_000_000,
        "Release maior que 100 MB"
    );
    let mut binary = Vec::new();
    response.take(100_000_001).read_to_end(&mut binary)?;
    anyhow::ensure!(binary.len() <= 100_000_000, "Release maior que 100 MB");
    release.verify(key, &binary, config.installed_sequence)?;
    let path = dir.join("update.exe");
    let mut file = fs::File::create(path)?;
    file.write_all(&binary)?;
    file.sync_all()?;
    atomic_json(&dir.join("pending.json"), release)?;
    log(
        dir,
        "Atualização assinada preparada; aguardando tarefa de instalação",
    );
    Ok(())
}
fn run(stop: Arc<AtomicBool>) -> Result<()> {
    let dir = root();
    let config = read_config(&dir)?;
    anyhow::ensure!(!config.token.is_empty(), "Agente ainda não cadastrado");
    let http = client()?;
    let mut system = System::new_all();
    let journal_path = dir.join("journal.json");
    let mut journal: Journal = if journal_path.exists() {
        serde_json::from_slice(&fs::read(&journal_path)?)?
    } else {
        Journal::default()
    };
    log(&dir, &format!("Agente {VERSION} iniciado"));
    std::thread::sleep(Duration::from_secs(1));
    while !stop.load(Ordering::Relaxed) {
        let payload = Heartbeat {
            metrics: metrics(&mut system, &config),
            results: journal.pending.clone(),
        };
        let response = http
            .post(format!("{}/api/heartbeat", config.server))
            .bearer_auth(&config.token)
            .json(&payload)
            .send()
            .and_then(|r| r.error_for_status())
            .and_then(|r| r.json::<HeartbeatReply>());
        match response {
            Ok(reply) => {
                journal.pending.clear();
                atomic_json(&journal_path, &journal)?;
                atomic_json(
                    &dir.join("health.json"),
                    &serde_json::json!({"time":now(),"version":VERSION}),
                )?;
                for command in reply.commands {
                    if command.node_id != config.node_id
                        || command.expires < now()
                        || journal.seen.contains(&command.id)
                    {
                        continue;
                    }
                    // Persist receipt BEFORE the side effect: a crash never replays a reboot.
                    journal.seen.push(command.id.clone());
                    if journal.seen.len() > 1000 {
                        journal.seen.remove(0);
                    }
                    atomic_json(&journal_path, &journal)?;
                    let result = execute(&command.action, &config);
                    let (ok, message) = match result {
                        Ok(m) => (true, m),
                        Err(e) => (false, e.to_string()),
                    };
                    log(&dir, &format!("Operação {}: {}", command.id, message));
                    journal.pending.push(CommandResult {
                        id: command.id,
                        ok,
                        message,
                    });
                    atomic_json(&journal_path, &journal)?;
                }
                if let Some(release) = reply.release {
                    if let Err(e) = stage_update(&dir, &config, &http, &release) {
                        log(&dir, &format!("Atualização rejeitada: {e}"));
                    }
                }
            }
            Err(e) => log(
                &dir,
                &format!(
                    "Servidor indisponível ou credencial rejeitada: {}",
                    e.without_url()
                ),
            ),
        }
        for _ in 0..15 {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    }
    log(&dir, "Serviço interrompido pelo administrador");
    Ok(())
}
fn enroll() -> Result<()> {
    let dir = root();
    let mut config = read_config(&dir)?;
    anyhow::ensure!(
        config.token.is_empty(),
        "Agente já cadastrado. Desinstale e revogue antes de cadastrar novamente"
    );
    let mut code = String::new();
    std::io::stdin().read_line(&mut code)?;
    let credentials: Credentials = client()?
        .post(format!("{}/api/enroll", config.server))
        .json(&Enrollment {
            code: code.trim().into(),
            hostname: System::host_name().unwrap_or_else(|| "Windows".into()),
        })
        .send()?
        .error_for_status()?
        .json()?;
    config.node_id = credentials.node_id;
    config.token = credentials.token;
    if let Some(path) = std::env::var_os("ASSIST_SUPPORT_CONFIG") {
        let path = std::path::PathBuf::from(path);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        atomic_json(
            &path,
            &serde_json::json!({
                "server": config.server,
                "node_id": config.node_id,
                "token": credentials.support_token,
                "unattended": true
            }),
        )?;
    }
    atomic_json(&dir.join("config.json"), &config)?;
    println!("Computador cadastrado com sucesso.");
    Ok(())
}
fn verify_update() -> Result<()> {
    let dir = root();
    let config = read_config(&dir)?;
    let manifest = if dir.join("installing.json").exists() {
        dir.join("installing.json")
    } else {
        dir.join("pending.json")
    };
    let release: Release = serde_json::from_slice(&fs::read(manifest)?)?;
    release.verify(
        config
            .update_public_key
            .as_deref()
            .context("Atualizações não configuradas")?,
        &fs::read(dir.join("update.exe"))?,
        config.installed_sequence,
    )?;
    println!(
        "Release válida: {} (sequência {})",
        release.version, release.sequence
    );
    Ok(())
}
#[cfg(windows)]
mod service {
    use super::*;
    use windows_service::{
        define_windows_service,
        service::{
            ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
            ServiceType,
        },
        service_control_handler::{self, ServiceControlHandlerResult},
        service_dispatcher,
    };
    define_windows_service!(entry, service_main);
    pub fn start() -> Result<()> {
        service_dispatcher::start("AssistenteTINode", entry)?;
        Ok(())
    }
    fn service_main(_: Vec<std::ffi::OsString>) {
        if let Err(e) = main() {
            log(&root(), &format!("Erro de serviço: {e}"));
        }
    }
    fn main() -> Result<()> {
        let stop = Arc::new(AtomicBool::new(false));
        let signal = stop.clone();
        let handle =
            service_control_handler::register("AssistenteTINode", move |control| match control {
                ServiceControl::Stop | ServiceControl::Shutdown => {
                    signal.store(true, Ordering::Relaxed);
                    ServiceControlHandlerResult::NoError
                }
                ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
                _ => ServiceControlHandlerResult::NotImplemented,
            })?;
        handle.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Running,
            controls_accepted: ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        })?;
        let result = run(stop);
        handle.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Stopped,
            controls_accepted: ServiceControlAccept::empty(),
            exit_code: ServiceExitCode::Win32(if result.is_ok() { 0 } else { 1 }),
            checkpoint: 0,
            wait_hint: Duration::default(),
            process_id: None,
        })?;
        result
    }
}
fn main() -> Result<()> {
    match std::env::args().nth(1).as_deref() {
        Some("enroll") => enroll(),
        Some("verify-update") => verify_update(),
        Some("run") => run(Arc::new(AtomicBool::new(false))),
        Some("version") => {
            println!("{VERSION}");
            Ok(())
        }
        #[cfg(windows)]
        Some("service") => service::start(),
        _ => anyhow::bail!("Uso: assist-agent enroll | run | service | verify-update | version"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reboot_is_opt_in() {
        let config = Config {
            server: String::new(),
            node_id: String::new(),
            token: String::new(),
            support_id: None,
            update_public_key: None,
            allow_reboot: false,
            installed_sequence: 0,
        };
        assert!(execute(&Action::Reboot, &config).is_err());
        assert!(execute(&Action::Refresh, &config).is_ok());
    }
}
