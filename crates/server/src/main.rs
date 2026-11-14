use argon2::{password_hash::SaltString, Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use assist_protocol::*;
use axum::{
    extract::{DefaultBodyLimit, Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use rand::{rngs::OsRng, RngCore};
use redb::{Database, ReadableTable, TableDefinition};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, VecDeque},
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex},
};

const TABLE: TableDefinition<&str, &str> = TableDefinition::new("state");
#[derive(Clone, Serialize, Deserialize)]
struct Node {
    id: String,
    name: String,
    token_hash: String,
    enabled: bool,
    last_seen: u64,
    metrics: Metrics,
    history: Vec<Value>,
}
#[derive(Clone, Serialize, Deserialize)]
struct Invite {
    hash: String,
    expires: u64,
}
#[derive(Clone, Default, Serialize, Deserialize)]
struct Records {
    nodes: Vec<Node>,
    invites: Vec<Invite>,
    commands: Vec<Command>,
    audit: Vec<Value>,
}
struct Storage {
    db: Database,
    records: Records,
    committed: Records,
}
impl Storage {
    fn open(path: &std::path::Path) -> anyhow::Result<Self> {
        let db = Database::create(path)?;
        let records = {
            let txn = db.begin_write()?;
            let records = {
                let table = txn.open_table(TABLE)?;
                let item = table.get("records")?;
                match item {
                    Some(v) => serde_json::from_str(v.value())?,
                    None => Records::default(),
                }
            };
            txn.commit()?;
            records
        };
        Ok(Self {
            db,
            committed: records.clone(),
            records,
        })
    }
    fn save(&mut self) -> anyhow::Result<()> {
        match self.persist() {
            Ok(()) => {
                self.committed = self.records.clone();
                Ok(())
            }
            Err(e) => {
                self.records = self.committed.clone();
                Err(e)
            }
        }
    }
    fn persist(&self) -> anyhow::Result<()> {
        let json = serde_json::to_string(&self.records)?;
        let txn = self.db.begin_write()?;
        {
            let mut table = txn.open_table(TABLE)?;
            table.insert("records", json.as_str())?;
        }
        txn.commit()?;
        Ok(())
    }
    fn audit(&mut self, event: &str, target: &str) {
        self.records
            .audit
            .push(json!({"time": now(), "actor": "admin", "event": event, "target": target}));
        if self.records.audit.len() > 5000 {
            self.records.audit.remove(0);
        }
    }
}
struct App {
    storage: Mutex<Storage>,
    sessions: Mutex<HashMap<String, u64>>,
    attempts: Mutex<VecDeque<u64>>,
    password_hash: String,
    secure: bool,
    release_dir: PathBuf,
}
type Shared = Arc<App>;
#[derive(Debug)]
struct ApiError(StatusCode, &'static str);
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({"error": self.1}))).into_response()
    }
}
type Api<T> = Result<T, ApiError>;
fn bad() -> ApiError {
    ApiError(StatusCode::BAD_REQUEST, "Dados inválidos")
}
fn denied() -> ApiError {
    ApiError(StatusCode::UNAUTHORIZED, "Autenticação necessária")
}
fn internal(e: impl std::fmt::Display) -> ApiError {
    tracing::error!("{e}");
    ApiError(
        StatusCode::INTERNAL_SERVER_ERROR,
        "Erro ao persistir operação",
    )
}
fn random() -> String {
    let mut bytes = [0; 32];
    OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}
fn client(headers: &HeaderMap) -> Api<()> {
    if headers.get("x-assist-client").and_then(|v| v.to_str().ok()) != Some("1") {
        return Err(ApiError(
            StatusCode::FORBIDDEN,
            "Cabeçalho de proteção ausente",
        ));
    }
    Ok(())
}
fn session(headers: &HeaderMap) -> Option<String> {
    headers
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .find_map(|s| s.trim().strip_prefix("assist_session=").map(hash))
}
fn admin(app: &App, headers: &HeaderMap) -> Api<()> {
    client(headers)?;
    let id = session(headers).ok_or_else(denied)?;
    let mut sessions = app.sessions.lock().unwrap();
    sessions.retain(|_, expires| *expires > now());
    if sessions.contains_key(&id) {
        Ok(())
    } else {
        Err(denied())
    }
}
fn node_id(storage: &Storage, headers: &HeaderMap) -> Api<String> {
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .ok_or_else(denied)?;
    let hashed = hash(token);
    storage
        .records
        .nodes
        .iter()
        .find(|n| n.enabled && n.token_hash == hashed)
        .map(|n| n.id.clone())
        .ok_or_else(denied)
}
fn public_node(n: &Node) -> Value {
    json!({"id":n.id,"name":n.name,"enabled":n.enabled,"last_seen":n.last_seen,"online":n.enabled && now().saturating_sub(n.last_seen)<90,"metrics":n.metrics,"history":n.history})
}
fn cookie(app: &App, token: &str, age: u64) -> String {
    format!(
        "assist_session={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={age}{}",
        if app.secure { "; Secure" } else { "" }
    )
}
#[derive(Deserialize)]
struct Login {
    password: String,
}
async fn login(
    State(app): State<Shared>,
    headers: HeaderMap,
    Json(input): Json<Login>,
) -> Api<Response> {
    client(&headers)?;
    if input.password.len() > 1024 {
        return Err(bad());
    }
    {
        let mut attempts = app.attempts.lock().unwrap();
        while attempts
            .front()
            .is_some_and(|t| now().saturating_sub(*t) > 60)
        {
            attempts.pop_front();
        }
        if attempts.len() >= 10 {
            return Err(ApiError(
                StatusCode::TOO_MANY_REQUESTS,
                "Aguarde um minuto antes de tentar novamente",
            ));
        }
        attempts.push_back(now());
    }
    let encoded = app.password_hash.clone();
    let valid = tokio::task::spawn_blocking(move || {
        PasswordHash::new(&encoded).ok().is_some_and(|hash| {
            Argon2::default()
                .verify_password(input.password.as_bytes(), &hash)
                .is_ok()
        })
    })
    .await
    .map_err(internal)?;
    let mut store = app.storage.lock().unwrap();
    store.audit(if valid { "login" } else { "login_failed" }, "admin");
    store.save().map_err(internal)?;
    if !valid {
        return Err(denied());
    }
    let token = random();
    let mut sessions = app.sessions.lock().unwrap();
    sessions.retain(|_, expires| *expires > now());
    if sessions.len() >= 100 {
        return Err(ApiError(
            StatusCode::TOO_MANY_REQUESTS,
            "Limite de sessões atingido",
        ));
    }
    sessions.insert(hash(&token), now() + 28800);
    Ok((
        [(header::SET_COOKIE, cookie(&app, &token, 28800))],
        Json(json!({"ok": true})),
    )
        .into_response())
}
async fn logout(State(app): State<Shared>, headers: HeaderMap) -> Api<Response> {
    admin(&app, &headers)?;
    if let Some(id) = session(&headers) {
        app.sessions.lock().unwrap().remove(&id);
    }
    Ok((
        [(header::SET_COOKIE, cookie(&app, "", 0))],
        Json(json!({"ok":true})),
    )
        .into_response())
}
async fn nodes(State(app): State<Shared>, headers: HeaderMap) -> Api<Json<Value>> {
    admin(&app, &headers)?;
    let store = app.storage.lock().unwrap();
    Ok(Json(
        json!({"nodes": store.records.nodes.iter().map(public_node).collect::<Vec<_>>(),"version":VERSION}),
    ))
}
async fn invite(State(app): State<Shared>, headers: HeaderMap) -> Api<Json<Value>> {
    admin(&app, &headers)?;
    let code = random();
    let expires = now() + 900;
    let mut store = app.storage.lock().unwrap();
    store.records.invites.retain(|i| i.expires > now());
    if store.records.invites.len() >= 100 {
        return Err(ApiError(
            StatusCode::TOO_MANY_REQUESTS,
            "Limite de convites ativos atingido",
        ));
    }
    store.records.invites.push(Invite {
        hash: hash(&code),
        expires,
    });
    store.audit("enrollment_created", "one_use");
    store.save().map_err(internal)?;
    Ok(Json(json!({"code":code,"expires":expires})))
}
async fn enroll(
    State(app): State<Shared>,
    Json(input): Json<Enrollment>,
) -> Api<Json<Credentials>> {
    if input.hostname.is_empty() || input.hostname.len() > 200 || input.code.len() != 64 {
        return Err(bad());
    }
    let mut store = app.storage.lock().unwrap();
    let hashed = hash(input.code);
    let index = store
        .records
        .invites
        .iter()
        .position(|i| i.hash == hashed && i.expires > now())
        .ok_or_else(denied)?;
    let id = random();
    let token = random();
    store.records.invites.remove(index);
    store.records.nodes.push(Node {
        id: id.clone(),
        name: input.hostname,
        token_hash: hash(&token),
        enabled: true,
        last_seen: 0,
        metrics: Metrics::default(),
        history: vec![],
    });
    store.audit("node_enrolled", &id);
    store.save().map_err(internal)?;
    Ok(Json(Credentials { node_id: id, token }))
}
fn current_release(app: &App) -> Option<Release> {
    let bytes = std::fs::read(app.release_dir.join("release.json")).ok()?;
    serde_json::from_slice(&bytes).ok()
}
async fn heartbeat(
    State(app): State<Shared>,
    headers: HeaderMap,
    Json(input): Json<Heartbeat>,
) -> Api<Json<HeartbeatReply>> {
    if input.metrics.processes.len() > 500
        || input.results.len() > 100
        || !input.metrics.cpu.is_finite()
        || !(0.0..=100.0).contains(&input.metrics.cpu)
        || input.metrics.hostname.len() > 200
        || input.metrics.version.len() > 100
        || input.metrics.os.len() > 500
        || input.metrics.memory_used > input.metrics.memory_total
        || input.metrics.disk_used > input.metrics.disk_total
    {
        return Err(bad());
    }
    if input
        .metrics
        .support_id
        .as_ref()
        .is_some_and(|id| id.len() > 20 || id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()))
    {
        return Err(bad());
    }
    let mut store = app.storage.lock().unwrap();
    let id = node_id(&store, &headers)?;
    for result in input.results {
        if let Some(cmd) = store
            .records
            .commands
            .iter_mut()
            .find(|c| c.node_id == id && c.id == result.id && c.status == "dispatched")
        {
            cmd.status = if result.ok { "completed" } else { "failed" }.into();
            cmd.result = Some(result.message.chars().take(1000).collect());
        }
    }
    let node = store.records.nodes.iter_mut().find(|n| n.id == id).unwrap();
    node.last_seen = now();
    node.history.push(
        json!({"time":now(),"cpu":input.metrics.cpu,"memory_used":input.metrics.memory_used}),
    );
    if node.history.len() > 120 {
        node.history.remove(0);
    }
    node.metrics = input.metrics;
    let mut commands = vec![];
    for cmd in store
        .records
        .commands
        .iter_mut()
        .filter(|c| c.node_id == id)
    {
        if (cmd.status == "queued" || cmd.status == "dispatched") && cmd.expires < now() {
            cmd.status = if cmd.status == "queued" {
                "expired"
            } else {
                "unknown"
            }
            .into();
        }
        if cmd.status == "queued" {
            cmd.status = "dispatched".into();
            commands.push(cmd.clone());
        }
    }
    store.save().map_err(internal)?;
    Ok(Json(HeartbeatReply {
        commands,
        release: current_release(&app),
    }))
}
#[derive(Deserialize)]
struct CommandInput {
    action: Action,
    confirmation: Option<String>,
}
async fn command(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<CommandInput>,
) -> Api<Json<Command>> {
    admin(&app, &headers)?;
    let mut store = app.storage.lock().unwrap();
    let node = store
        .records
        .nodes
        .iter()
        .find(|n| n.id == id && n.enabled)
        .ok_or(ApiError(StatusCode::NOT_FOUND, "Computador não encontrado"))?;
    if input.action == Action::Reboot && input.confirmation.as_deref() != Some(node.name.as_str()) {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "Confirme o nome do computador",
        ));
    }
    if now().saturating_sub(node.last_seen) >= 90 {
        return Err(ApiError(StatusCode::CONFLICT, "Computador offline"));
    }
    if store.records.commands.iter().any(|c| {
        c.node_id == id && (c.status == "queued" || c.status == "dispatched") && c.expires > now()
    }) {
        return Err(ApiError(
            StatusCode::CONFLICT,
            "Aguarde a operação pendente",
        ));
    }
    let cmd = Command {
        id: random(),
        node_id: id.clone(),
        action: input.action,
        created: now(),
        expires: now() + 180,
        status: "queued".into(),
        result: None,
    };
    store.audit(
        "command_created",
        &format!("{id}:{:?}:{}", cmd.action, cmd.id),
    );
    store.records.commands.push(cmd.clone());
    if store.records.commands.len() > 5000 {
        store.records.commands.remove(0);
    }
    store.save().map_err(internal)?;
    Ok(Json(cmd))
}
async fn revoke(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Api<Json<Value>> {
    admin(&app, &headers)?;
    let mut store = app.storage.lock().unwrap();
    let node = store
        .records
        .nodes
        .iter_mut()
        .find(|n| n.id == id)
        .ok_or(ApiError(StatusCode::NOT_FOUND, "Computador não encontrado"))?;
    node.enabled = false;
    for cmd in store
        .records
        .commands
        .iter_mut()
        .filter(|c| c.node_id == id && c.status == "queued")
    {
        cmd.status = "cancelled".into();
    }
    store.audit("node_revoked", &id);
    store.save().map_err(internal)?;
    Ok(Json(json!({"ok":true})))
}
async fn support(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Api<Json<Value>> {
    admin(&app, &headers)?;
    let mut store = app.storage.lock().unwrap();
    let node = store
        .records
        .nodes
        .iter()
        .find(|n| n.id == id && n.enabled)
        .ok_or(ApiError(StatusCode::NOT_FOUND, "Computador não encontrado"))?;
    let support_id = node.metrics.support_id.clone().ok_or(ApiError(
        StatusCode::CONFLICT,
        "Configure o ID RustDesk no agente",
    ))?;
    store.audit("support_link_opened", &id);
    store.save().map_err(internal)?;
    Ok(Json(
        json!({"url":format!("rustdesk://connection/new/{support_id}")}),
    ))
}
async fn activity(State(app): State<Shared>, headers: HeaderMap) -> Api<Json<Value>> {
    admin(&app, &headers)?;
    let store = app.storage.lock().unwrap();
    let mut commands = store.records.commands.clone();
    for c in &mut commands {
        if c.expires < now() && (c.status == "queued" || c.status == "dispatched") {
            c.status = if c.status == "queued" {
                "expired"
            } else {
                "unknown"
            }
            .into();
        }
    }
    Ok(Json(
        json!({"audit":store.records.audit.iter().rev().take(200).collect::<Vec<_>>(),"commands":commands.iter().rev().take(200).collect::<Vec<_>>()}),
    ))
}
async fn download(
    State(app): State<Shared>,
    headers: HeaderMap,
    Path(digest): Path<String>,
) -> Api<Response> {
    {
        let store = app.storage.lock().unwrap();
        node_id(&store, &headers)?;
    }
    if digest.len() != 64 || !digest.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(bad());
    }
    let path = app.release_dir.join(format!("{digest}.exe"));
    let bytes = tokio::fs::read(path)
        .await
        .map_err(|_| ApiError(StatusCode::NOT_FOUND, "Release não encontrada"))?;
    Ok(([(header::CONTENT_TYPE, "application/octet-stream")], bytes).into_response())
}
async fn security(request: axum::extract::Request, next: axum::middleware::Next) -> Response {
    let mut response = next.run(request).await;
    let h = response.headers_mut();
    h.insert("x-content-type-options", "nosniff".parse().unwrap());
    h.insert("x-frame-options", "DENY".parse().unwrap());
    h.insert("referrer-policy", "no-referrer".parse().unwrap());
    h.insert("cache-control", "no-store".parse().unwrap());
    h.insert("content-security-policy","default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'".parse().unwrap());
    response
}
fn router(app: Shared) -> Router {
    Router::new()
        .route(
            "/",
            get(|| async { Html(include_str!("../../../web/index.html")) }),
        )
        .route(
            "/app.js",
            get(|| async {
                (
                    [(
                        header::CONTENT_TYPE,
                        "application/javascript; charset=utf-8",
                    )],
                    include_str!("../../../web/app.js"),
                )
            }),
        )
        .route(
            "/app.css",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
                    include_str!("../../../web/app.css"),
                )
            }),
        )
        .route(
            "/health",
            get(|| async { Json(json!({"status":"ok","version":VERSION})) }),
        )
        .route("/api/login", post(login))
        .route("/api/logout", post(logout))
        .route("/api/nodes", get(nodes))
        .route("/api/invites", post(invite))
        .route("/api/enroll", post(enroll))
        .route("/api/heartbeat", post(heartbeat))
        .route("/api/nodes/{id}/commands", post(command))
        .route("/api/nodes/{id}/revoke", post(revoke))
        .route("/api/nodes/{id}/support", post(support))
        .route("/api/activity", get(activity))
        .route("/api/releases/{digest}", get(download))
        .layer(DefaultBodyLimit::max(256 * 1024))
        .layer(axum::middleware::from_fn(security))
        .with_state(app)
}
// The public origin is explicit: untrusted Forwarded headers never change cookie security.
fn listener_config(bind: &str, public_url: &str) -> anyhow::Result<(SocketAddr, bool)> {
    let address: SocketAddr = bind.parse()?;
    let secure =
        if public_url.is_empty() {
            false
        } else {
            let url = url::Url::parse(public_url)?;
            anyhow::ensure!(
            url.host_str().is_some() && url.username().is_empty() && url.password().is_none()
                && url.path() == "/" && url.query().is_none() && url.fragment().is_none(),
            "ASSIST_PUBLIC_URL deve conter somente a origem pública, sem credenciais ou caminho"
        );
            anyhow::ensure!(
                matches!(url.scheme(), "http" | "https"),
                "ASSIST_PUBLIC_URL deve usar HTTP ou HTTPS"
            );
            url.scheme() == "https"
        };
    Ok((address, secure))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();
    let data = PathBuf::from(std::env::var("ASSIST_DATA").unwrap_or_else(|_| "data".into()));
    std::fs::create_dir_all(&data)?;
    std::fs::create_dir_all(data.join("releases"))?;
    let password_file = std::env::var("ASSIST_ADMIN_PASSWORD_FILE")
        .unwrap_or_else(|_| "data/admin-password".into());
    let password = std::fs::read_to_string(&password_file)
        .map_err(|e| anyhow::anyhow!("Configure ASSIST_ADMIN_PASSWORD_FILE: {e}"))?;
    let password = password.trim_end_matches(['\r', '\n']);
    anyhow::ensure!(
        password.len() >= 14,
        "Use senha administrativa com pelo menos 14 caracteres"
    );
    let password_hash = Argon2::default()
        .hash_password(password.as_bytes(), &SaltString::generate(&mut OsRng))
        .map_err(|e| anyhow::anyhow!("{e}"))?
        .to_string();
    let (address, secure) = listener_config(
        &std::env::var("ASSIST_BIND").unwrap_or_else(|_| "127.0.0.1:8080".into()),
        &std::env::var("ASSIST_PUBLIC_URL").unwrap_or_default(),
    )?;
    let app = Arc::new(App {
        storage: Mutex::new(Storage::open(&data.join("assist.redb"))?),
        sessions: Mutex::new(HashMap::new()),
        attempts: Mutex::new(VecDeque::new()),
        password_hash,
        secure,
        release_dir: data.join("releases"),
    });
    let listener = tokio::net::TcpListener::bind(address).await?;
    tracing::info!("Assistente TI escutando em {address}");
    axum::serve(listener, router(app))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, http::Request};
    use http_body_util::BodyExt;
    use tower::ServiceExt;
    #[test]
    fn http_listener_does_not_require_ssl_or_a_public_domain() {
        assert_eq!(
            listener_config("0.0.0.0:80", "").unwrap(),
            ("0.0.0.0:80".parse().unwrap(), false)
        );
        assert!(
            !listener_config("0.0.0.0:80", "http://192.168.1.20")
                .unwrap()
                .1
        );
        assert!(
            !listener_config("[::]:80", "http://ti.example.com")
                .unwrap()
                .1
        );
        assert_eq!(
            listener_config("0.0.0.0:80", "https://ti.example.com").unwrap(),
            ("0.0.0.0:80".parse().unwrap(), true)
        );
        assert!(
            listener_config("[::]:80", "https://ti.example.com:8443/")
                .unwrap()
                .1
        );
        assert!(!listener_config("127.0.0.1:8080", "").unwrap().1);
        assert!(
            !listener_config("127.0.0.1:80", "http://localhost")
                .unwrap()
                .1
        );
        for origin in [
            "ftp://ti.example.com",
            "https://",
            "https://user:pass@ti.example.com",
            "https://ti.example.com/panel",
            "https://ti.example.com?x=1",
            "https://ti.example.com#x",
        ] {
            assert!(listener_config("0.0.0.0:80", origin).is_err(), "{origin}");
        }
    }
    #[tokio::test]
    async fn http_session_cookie_does_not_require_tls() {
        let dir = tempfile::tempdir().unwrap();
        let mut shared = app(&dir);
        let mutable = Arc::get_mut(&mut shared).unwrap();
        mutable.secure = listener_config("0.0.0.0:80", "").unwrap().1;
        mutable.password_hash = Argon2::default()
            .hash_password(b"http-test-password", &SaltString::generate(&mut OsRng))
            .unwrap()
            .to_string();
        let response = router(shared.clone())
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("http://192.168.1.20/api/login")
                    .header("content-type", "application/json")
                    .header("x-assist-client", "1")
                    .body(Body::from(r#"{"password":"http-test-password"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let cookie = response
            .headers()
            .get(header::SET_COOKIE)
            .unwrap()
            .to_str()
            .unwrap();
        assert!(cookie.contains("HttpOnly"));
        assert!(!cookie.contains("; Secure"));
        let authenticated = router(shared)
            .oneshot(
                Request::builder()
                    .uri("http://192.168.1.20/api/nodes")
                    .header("x-assist-client", "1")
                    .header("cookie", cookie.split(';').next().unwrap())
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(authenticated.status(), StatusCode::OK);
    }
    #[tokio::test]
    async fn proxy_headers_cannot_downgrade_secure_cookie() {
        let dir = tempfile::tempdir().unwrap();
        let mut shared = app(&dir);
        let mutable = Arc::get_mut(&mut shared).unwrap();
        mutable.secure = listener_config("0.0.0.0:80", "https://ti.example.com")
            .unwrap()
            .1;
        mutable.password_hash = Argon2::default()
            .hash_password(b"proxy-test-password", &SaltString::generate(&mut OsRng))
            .unwrap()
            .to_string();
        let response = router(shared)
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("http://127.0.0.1:80/api/login")
                    .header("content-type", "application/json")
                    .header("x-assist-client", "1")
                    .header("host", "internal-server")
                    .header("x-forwarded-proto", "http")
                    .header("x-forwarded-host", "untrusted.example")
                    .body(Body::from(r#"{"password":"proxy-test-password"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let cookie = response
            .headers()
            .get(header::SET_COOKIE)
            .unwrap()
            .to_str()
            .unwrap();
        assert!(cookie.contains("; Secure") && cookie.contains("HttpOnly"));
        assert!(!cookie.contains("Domain="));
    }
    fn app(dir: &tempfile::TempDir) -> Shared {
        Arc::new(App {
            storage: Mutex::new(Storage::open(&dir.path().join("test.redb")).unwrap()),
            sessions: Mutex::new(HashMap::from([(hash("session"), now() + 300)])),
            attempts: Mutex::new(VecDeque::new()),
            password_hash: String::new(),
            secure: false,
            release_dir: dir.path().into(),
        })
    }
    async fn request(
        app: Shared,
        method: &str,
        path: &str,
        body: Value,
        auth: Option<&str>,
        cookie: bool,
    ) -> (StatusCode, Value) {
        let mut req = Request::builder()
            .method(method)
            .uri(path)
            .header("content-type", "application/json")
            .header("x-assist-client", "1");
        if let Some(token) = auth {
            req = req.header("authorization", format!("Bearer {token}"));
        }
        if cookie {
            req = req.header("cookie", "assist_session=session");
        }
        let response = router(app)
            .oneshot(req.body(Body::from(body.to_string())).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        (status, serde_json::from_slice(&bytes).unwrap())
    }
    #[tokio::test]
    async fn authentication_enrollment_revocation_and_persistence() {
        let dir = tempfile::tempdir().unwrap();
        let app = app(&dir);
        assert_eq!(
            request(app.clone(), "GET", "/api/nodes", json!({}), None, false)
                .await
                .0,
            StatusCode::UNAUTHORIZED
        );
        let (_, invite) = request(app.clone(), "POST", "/api/invites", json!({}), None, true).await;
        let enrollment = json!({"code":invite["code"],"hostname":"PC-01"});
        let (status, creds) = request(
            app.clone(),
            "POST",
            "/api/enroll",
            enrollment.clone(),
            None,
            false,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            request(app.clone(), "POST", "/api/enroll", enrollment, None, false)
                .await
                .0,
            StatusCode::UNAUTHORIZED
        );
        let token = creds["token"].as_str().unwrap();
        let hb = json!({"metrics":Metrics::default(),"results":[]});
        assert_eq!(
            request(
                app.clone(),
                "POST",
                "/api/heartbeat",
                hb.clone(),
                Some(token),
                false
            )
            .await
            .0,
            StatusCode::OK
        );
        assert_eq!(
            request(
                app.clone(),
                "POST",
                &format!("/api/nodes/{}/revoke", creds["node_id"].as_str().unwrap()),
                json!({}),
                None,
                true
            )
            .await
            .0,
            StatusCode::OK
        );
        assert_eq!(
            request(
                app.clone(),
                "POST",
                "/api/heartbeat",
                hb,
                Some(token),
                false
            )
            .await
            .0,
            StatusCode::UNAUTHORIZED
        );
        drop(app);
        let stored = Storage::open(&dir.path().join("test.redb")).unwrap();
        assert_eq!(stored.records.nodes.len(), 1);
        assert!(!stored.records.nodes[0].enabled);
        assert_ne!(stored.records.nodes[0].token_hash, token);
    }
    #[tokio::test]
    async fn commands_delivered_once_and_scoped_to_node() {
        let dir = tempfile::tempdir().unwrap();
        let app = app(&dir);
        {
            let mut s = app.storage.lock().unwrap();
            for id in ["a", "b"] {
                s.records.nodes.push(Node {
                    id: id.into(),
                    name: id.into(),
                    token_hash: hash(id),
                    enabled: true,
                    last_seen: now(),
                    metrics: Metrics::default(),
                    history: vec![],
                });
            }
        }
        assert_eq!(
            request(
                app.clone(),
                "POST",
                "/api/nodes/a/commands",
                json!({"action":"reboot","confirmation":"wrong"}),
                None,
                true
            )
            .await
            .0,
            StatusCode::BAD_REQUEST
        );
        let (_, cmd) = request(
            app.clone(),
            "POST",
            "/api/nodes/a/commands",
            json!({"action":"refresh"}),
            None,
            true,
        )
        .await;
        let hb = json!({"metrics":Metrics::default(),"results":[]});
        let (_, reply) = request(
            app.clone(),
            "POST",
            "/api/heartbeat",
            hb.clone(),
            Some("a"),
            false,
        )
        .await;
        assert_eq!(reply["commands"].as_array().unwrap().len(), 1);
        let (_, reply) = request(app.clone(), "POST", "/api/heartbeat", hb, Some("a"), false).await;
        assert!(reply["commands"].as_array().unwrap().is_empty());
        request(app.clone(),"POST","/api/heartbeat",json!({"metrics":Metrics::default(),"results":[{"id":cmd["id"],"ok":true,"message":"forged"}]}),Some("b"),false).await;
        assert_eq!(
            app.storage.lock().unwrap().records.commands[0].status,
            "dispatched"
        );
    }
    #[tokio::test]
    async fn csrf_header_required() {
        let dir = tempfile::tempdir().unwrap();
        let response = router(app(&dir))
            .oneshot(
                Request::builder()
                    .uri("/api/nodes")
                    .header("cookie", "assist_session=session")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn login_cookie_logout_and_rate_limit() {
        let dir = tempfile::tempdir().unwrap();
        let mut shared = app(&dir);
        let mutable = Arc::get_mut(&mut shared).unwrap();
        mutable.secure = true;
        mutable.password_hash = Argon2::default()
            .hash_password(b"test-password-long", &SaltString::generate(&mut OsRng))
            .unwrap()
            .to_string();
        let response = router(shared.clone())
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/login")
                    .header("content-type", "application/json")
                    .header("x-assist-client", "1")
                    .body(Body::from(r#"{"password":"test-password-long"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let cookie = response
            .headers()
            .get(header::SET_COOKIE)
            .unwrap()
            .to_str()
            .unwrap()
            .to_owned();
        assert!(
            cookie.contains("HttpOnly")
                && cookie.contains("Secure")
                && cookie.contains("SameSite=Strict")
        );
        let cookie_pair = cookie.split(';').next().unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(header::COOKIE, cookie_pair.parse().unwrap());
        headers.insert("x-assist-client", "1".parse().unwrap());
        assert!(admin(&shared, &headers).is_ok());
        logout(State(shared.clone()), headers.clone())
            .await
            .unwrap();
        assert!(admin(&shared, &headers).is_err());
        shared
            .attempts
            .lock()
            .unwrap()
            .extend(std::iter::repeat_n(now(), 10));
        let (status, _) = request(
            shared,
            "POST",
            "/api/login",
            json!({"password":"wrong"}),
            None,
            false,
        )
        .await;
        assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    }

    #[tokio::test]
    async fn expired_invites_and_commands_are_not_executed() {
        let dir = tempfile::tempdir().unwrap();
        let shared = app(&dir);
        let code = random();
        {
            let mut store = shared.storage.lock().unwrap();
            store.records.invites.push(Invite {
                hash: hash(&code),
                expires: now() - 1,
            });
            store.records.nodes.push(Node {
                id: "node".into(),
                name: "node".into(),
                token_hash: hash("token"),
                enabled: true,
                last_seen: now(),
                metrics: Metrics::default(),
                history: vec![],
            });
            store.records.commands.push(Command {
                id: "expired".into(),
                node_id: "node".into(),
                action: Action::Reboot,
                created: now() - 300,
                expires: now() - 1,
                status: "queued".into(),
                result: None,
            });
        }
        assert_eq!(
            request(
                shared.clone(),
                "POST",
                "/api/enroll",
                json!({"code":code,"hostname":"test"}),
                None,
                false
            )
            .await
            .0,
            StatusCode::UNAUTHORIZED
        );
        let (_, reply) = request(
            shared.clone(),
            "POST",
            "/api/heartbeat",
            json!({"metrics":Metrics::default(),"results":[]}),
            Some("token"),
            false,
        )
        .await;
        assert!(reply["commands"].as_array().unwrap().is_empty());
        let (_, nodes) = request(shared.clone(), "GET", "/api/nodes", json!({}), None, true).await;
        assert!(nodes["nodes"][0].get("token_hash").is_none());
        assert_eq!(
            shared.storage.lock().unwrap().records.commands[0].status,
            "expired"
        );
    }
}
