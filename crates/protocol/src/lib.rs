use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()
}
pub fn hash(data: impl AsRef<[u8]>) -> String { hex::encode(Sha256::digest(data.as_ref())) }

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProcessInfo { pub pid: u32, pub name: String, pub cpu: f32, pub memory: u64 }
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct Metrics {
    pub hostname: String, pub os: String, pub cpu: f32, pub memory_used: u64,
    pub memory_total: u64, pub disk_used: u64, pub disk_total: u64, pub uptime: u64,
    pub processes: Vec<ProcessInfo>, pub version: String, pub support_id: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Action { Refresh, Reboot }
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Command {
    pub id: String, pub node_id: String, pub action: Action, pub created: u64,
    pub expires: u64, pub status: String, pub result: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CommandResult { pub id: String, pub ok: bool, pub message: String }
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Heartbeat { pub metrics: Metrics, pub results: Vec<CommandResult> }
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HeartbeatReply { pub commands: Vec<Command>, pub release: Option<Release> }
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Enrollment { pub code: String, pub hostname: String }
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Credentials { pub node_id: String, pub token: String }

// Signature covers every field affecting installation, in an unambiguous format.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Release { pub version: String, pub sequence: u64, pub sha256: String, pub signature: String }
impl Release {
    pub fn signed_bytes(&self) -> Vec<u8> {
        format!("assist-ti-release-v1\n{}\n{}\n{}\n", self.version, self.sequence, self.sha256).into_bytes()
    }
    pub fn verify(&self, public_key: &str, binary: &[u8], installed_sequence: u64) -> anyhow::Result<()> {
        use ed25519_dalek::{Signature, VerifyingKey};
        anyhow::ensure!(self.sequence > installed_sequence, "Release antiga ou já instalada");
        anyhow::ensure!(self.sha256 == hash(binary), "Hash do binário inválido");
        let key: [u8; 32] = hex::decode(public_key)?.try_into().map_err(|_| anyhow::anyhow!("Chave inválida"))?;
        let signature = Signature::from_slice(&hex::decode(&self.signature)?)?;
        VerifyingKey::from_bytes(&key)?.verify_strict(&self.signed_bytes(), &signature)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    #[test] fn signed_updates_reject_tampering_and_rollback() {
        let key = SigningKey::from_bytes(&[42; 32]);
        let bytes = b"binary";
        let mut r = Release { version: "0.2.0".into(), sequence: 2, sha256: hash(bytes), signature: String::new() };
        r.signature = hex::encode(key.sign(&r.signed_bytes()).to_bytes());
        let public = hex::encode(key.verifying_key().to_bytes());
        assert!(r.verify(&public, bytes, 1).is_ok());
        assert!(r.verify(&public, b"modified", 1).is_err());
        assert!(r.verify(&public, bytes, 2).is_err());
        r.version = "9.9.9".into();
        assert!(r.verify(&public, bytes, 1).is_err());
    }
}
