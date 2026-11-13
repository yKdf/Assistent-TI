use anyhow::{Context, Result};
use assist_protocol::{hash, Release};
use ed25519_dalek::{Signer, SigningKey};
use std::{fs, io::Write, path::Path};

fn private_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}
fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("keygen") if args.len()==3=>{
            let key=SigningKey::generate(&mut rand::rngs::OsRng);
            private_file(Path::new(&args[2]),hex::encode(key.to_bytes()).as_bytes())?;
            println!("Chave pública (configure no instalador): {}",hex::encode(key.verifying_key().to_bytes()));
        }
        Some("sign") if args.len()==7=>{
            let key_bytes:[u8;32]=hex::decode(fs::read_to_string(&args[2])?.trim())?.try_into().map_err(|_|anyhow::anyhow!("Chave inválida"))?;
            let key=SigningKey::from_bytes(&key_bytes);
            let binary=fs::read(&args[3])?;
            anyhow::ensure!(binary.starts_with(b"MZ"),"A release deve ser um executável Windows");
            let version=&args[4];anyhow::ensure!(!version.is_empty()&&version.len()<100&&!version.contains(['\n','\r']),"Versão inválida");
            let sequence=args[5].parse::<u64>().context("Sequência deve ser um inteiro crescente")?;
            anyhow::ensure!(sequence>0,"Sequência deve ser maior que zero");
            let dest=Path::new(&args[6]);fs::create_dir_all(dest)?;
            let mut release=Release {version:version.clone(),sequence,sha256:hash(&binary),signature:String::new()};
            release.signature=hex::encode(key.sign(&release.signed_bytes()).to_bytes());
            fs::write(dest.join(format!("{}.exe",release.sha256)),binary)?;
            fs::write(dest.join("release.json.tmp"),serde_json::to_vec_pretty(&release)?)?;
            fs::rename(dest.join("release.json.tmp"),dest.join("release.json"))?;
            println!("Release {} / sequência {} pronta em {}",version,sequence,dest.display());
        }
        _=>anyhow::bail!("Uso:\n  assist-release keygen caminho/assinatura.key\n  assist-release sign chave.key assist-agent.exe VERSAO SEQUENCIA pasta-saida"),
    }
    Ok(())
}
