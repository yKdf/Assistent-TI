# Assistente TI

Central de gerenciamento remoto com **servidor, agente e aplicativo em Rust**. Agente para Windows 10/11 x64; servidor para Linux; aplicativo de gerenciamento para Windows e Linux. O painel web é servido pelo próprio servidor e usa os mesmos recursos do aplicativo.

Esta é uma primeira versão para validar em um grupo piloto. Não é uma suíte RMM completa. O suporte de tela e controle usa uma instalação separada do **RustDesk**; não há captura oculta de tela, shell remoto nem contorno da autoridade do administrador local.

Baixe os arquivos prontos em [Releases no GitHub](https://github.com/yKdf/Assistent-TI/releases/latest):

- **`AssistenteTI-Manager-Setup-0.1.1-windows-x64.exe`**: instalador gráfico do aplicativo de gerenciamento Windows. Não exige PowerShell nem administrador.
- `AssistenteTI-windows-0.1.1.zip`: agente, gerenciador, ferramenta de assinatura e scripts de instalação Windows.
- `AssistenteTI-source-0.1.1.zip`: projeto completo, painel e instalador do servidor Linux.
- `SHA256SUMS.txt`: hashes dos downloads.

O código está em [yKdf/Assistent-TI](https://github.com/yKdf/Assistent-TI). Resultados dos testes e limites de verificação: [VALIDATION.md](VALIDATION.md).

## Recursos implementados

- Login administrativo; senha derivada com Argon2id durante a execução; sessão HttpOnly de 8 horas e limitação de tentativas.
- Convites de uso único com validade de 15 minutos; token individual por node; revogação imediata no servidor.
- CPU, RAM, discos fixos, sistema operacional, tempo ligado, versão e até 100 processos de maior consumo de memória.
- Heartbeat aproximadamente a cada 15 segundos; estado offline após 90 segundos; até 120 amostras recentes por computador.
- Atualizar inventário e reiniciar o Windows com aviso de 60 segundos. Reiniciar exige habilitação no instalador e confirmação do nome no painel.
- Fila persistente, expiração de comandos, deduplicação no agente e resultados. Comando já despachado não é reenviado; se a resposta se perder, fica com resultado não confirmado, evitando reinicializações repetidas.
- Serviço Windows automático, recuperação após falha, pasta e controle do serviço restritos a SYSTEM/Administradores.
- Atualização automática do agente: SHA-256, assinatura Ed25519, sequência crescente, instalação por tarefa administrativa e rollback se não houver heartbeat da nova versão em 90 segundos.
- Histórico de até 5.000 eventos de auditoria e 5.000 comandos; interface mostra os 200 últimos.
- Abertura de sessão RustDesk pelo ID configurado no agente.

## Estrutura

```text
crates/protocol  Mensagens compartilhadas e verificação de assinatura
crates/server    API HTTP, banco transacional redb, sessões, fila e painel
crates/agent     Serviço Windows, coleta, execução de ações e download verificado
crates/manager   Aplicativo Rust que abre o painel em janela de aplicativo do navegador
crates/release   Geração de chave e assinatura de releases
web             Painel responsivo em português, sem dependências de frontend
scripts/linux   Instalação do servidor, aplicativo e publicação de releases
scripts/windows Instalação, atualização e remoção do serviço; instalação do aplicativo
```

O banco é **redb**, embutido e transacional, e não precisa de um serviço de banco separado. Nesta versão o conjunto de dados é serializado em cada transação: adequado a um piloto pequeno, sem capacidade de frota grande validada. Antes de centenas/milhares de máquinas, migrar para registros individuais, histórico particionado e testes de carga.

## 1. Instalar o servidor Linux

Requisitos: Debian 12+ ou Ubuntu 24.04+, x64, systemd, acesso à internet, DNS e portas 80/443 disponíveis. Aponte um domínio para o servidor. O instalador utiliza os pacotes oficiais da distribuição e o instalador oficial do Rust.

Copie este repositório (incluindo `Cargo.lock`, `crates` e `web`) para o servidor e execute:

```bash
sudo bash scripts/linux/install-server.sh ti.suaempresa.com.br
```

O script:

1. Instala compilador C, dependências, Rust local à conta de build e Caddy.
2. Compila servidor, aplicativo Linux e ferramenta de releases como usuário sem privilégios.
3. Solicita uma senha administrativa com pelo menos 14 caracteres, sem expô-la na linha de comando.
4. Instala o serviço `assist-ti`, dados em `/var/lib/assist-ti` e executáveis em `/opt/assist-ti`.
5. Configura Caddy para HTTPS e proxy para `127.0.0.1:8080`. Preserva o Caddyfile existente, salva uma cópia e acrescenta um import.

Acesse `https://ti.suaempresa.com.br`. O certificado depende de DNS correto e das portas 80/443 acessíveis; o script não modifica firewall, DNS ou outro proxy já ocupando essas portas. Revise conflito com Nginx/Apache antes de executar. Não exponha a porta 8080 diretamente.

```bash
sudo systemctl status assist-ti
sudo journalctl -u assist-ti -n 100 --no-pager
sudo journalctl -u caddy -n 100 --no-pager
```

Para atualizar o servidor, copie a nova árvore do projeto e execute o instalador novamente. Ele preserva a senha e os dados. O servidor e o launcher do aplicativo não se autoatualizam nesta versão; o conteúdo do painel é atualizado junto com o servidor.

### Desenvolvimento local

Instale Rust estável. No Linux, instale `build-essential pkg-config libssl-dev` para compilar todos os componentes. No Windows, use Rust MSVC com as ferramentas C++/Windows SDK, ou Rust GNU com MinGW no PATH.

Crie `data/admin-password` com uma senha de desenvolvimento de no mínimo 14 caracteres, sem adicioná-la ao Git. Depois:

```bash
cargo test --workspace --locked
cargo run -p assist-server --locked
```

Abra `http://localhost:8080`. HTTP só é aceito em loopback; nodes remotos precisam do endereço HTTPS. `ASSIST_DATA`, `ASSIST_ADMIN_PASSWORD_FILE`, `ASSIST_PUBLIC_URL` e `ASSIST_BIND` permitem configurar o servidor. `ASSIST_PUBLIC_URL=https://...` habilita o atributo Secure do cookie. O script Linux configura todas essas variáveis.

## 2. Compilar e instalar nos computadores Windows

No computador de build com Rust e ferramentas de ligação instalados:

```powershell
.\scripts\build-windows.ps1
```

Se a política padrão bloquear scripts locais, execute o arquivo com `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\build-windows.ps1`. A opção vale apenas para esse processo. A mesma forma pode ser usada para os instaladores, sem alterar a política permanente da máquina. Arquivos baixados da internet podem exigir assinatura ou desbloqueio administrativo conforme a política da organização.

Os três executáveis ficam em `dist/windows`. Copie `dist/windows/assist-agent.exe` e a pasta `scripts/windows` mantendo a estrutura, ou informe `-Binary` no instalador.

No painel, clique em **Adicionar computador** para gerar um convite. No computador a gerenciar, abra PowerShell como administrador:

```powershell
.\scripts\windows\install-agent.ps1 -Server https://ti.suaempresa.com.br
```

O instalador solicita o convite, a chave pública de atualização e o ID RustDesk opcional. Para permitir reinicialização remota, acrescente `-AllowReboot`. Sem esse parâmetro a ação será rejeitada pelo próprio agente.

```powershell
.\scripts\windows\install-agent.ps1 -Server https://ti.suaempresa.com.br -AllowReboot -Binary C:\Instalador\assist-agent.exe
```

Instalação: `C:\ProgramData\AssistenteTI`; serviço: `AssistenteTINode`; tarefa de atualização: `AssistenteTIUpdate`. Convite e token não são passados como argumentos de processo. A configuração contém o token em disco, protegido pela ACL de SYSTEM/Administradores; não compartilhe a pasta.

O serviço fica visível e pode ser parado/removido por um administrador. Usuários comuns não recebem permissão para parar o serviço ou alterar arquivos. Não existe promessa de programa impossível de finalizar: um administrador do Windows controla a máquina.

### Remover ou recadastrar

Revogue o node no painel e, como administrador:

```powershell
& "$env:ProgramData\AssistenteTI\uninstall-agent.ps1" -RemoveData
```

Sem `-RemoveData`, os dados locais permanecem para diagnóstico. Para recadastrar, remova-os explicitamente e gere um novo convite. Revogar no painel corta a comunicação, mas não desinstala software da máquina.

## 3. Aplicativo de gerenciamento

O launcher é compilado em Rust e abre uma janela dedicada do Edge/Chromium para o mesmo painel web. Não é um frontend nativo independente nem funciona offline. Assim, todas as funções web estão disponíveis no aplicativo sem duplicar telas e regras.

Windows, com Microsoft Edge instalado:

1. Baixe e abra **`AssistenteTI-Manager-Setup-0.1.1-windows-x64.exe`** em [Releases](https://github.com/yKdf/Assistent-TI/releases/latest).
2. Informe a URL HTTPS do seu servidor, por exemplo `https://ti.suaempresa.com.br`.
3. Conclua a instalação e abra **Assistente TI** pelo menu Iniciar. O atalho na área de trabalho é opcional.

A instalação é por usuário, em `%LOCALAPPDATA%\Programs\AssistenteTI`, e aparece em **Configurações → Aplicativos** para desinstalar. Reexecutar o instalador preserva a URL anterior e permite alterá-la. Não é necessário instalar Rust, Inno Setup ou executar scripts no computador que usará o Manager.

O instalador desta versão ainda não tem assinatura Authenticode. O arquivo `SHA256SUMS.txt` da release permite conferir a integridade do download.

O script anterior continua disponível como alternativa administrativa:

```powershell
.\scripts\windows\install-manager.ps1 -Server https://ti.suaempresa.com.br
```

Para gerar o `.exe` a partir do código, em um computador de build Windows com Rust:

```powershell
.\scripts\bootstrap-inno.ps1
.\scripts\build-manager-installer.ps1
```

O primeiro comando baixa uma versão fixa do [Inno Setup](https://jrsoftware.org/inno-setup/downloads), verifica SHA-256 e assinatura, e prepara o compilador em modo portátil dentro de `.toolchain/`. O segundo compila o aplicativo Rust e gera o instalador em `dist/`. Também é possível informar `-Iscc C:\caminho\ISCC.exe` para utilizar um compilador já instalado. A CI gera o instalador e os pacotes como artifacts na execução Windows.

Instalação silenciosa opcional:

```powershell
.\AssistenteTI-Manager-Setup-0.1.1-windows-x64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SERVERURL="https://ti.suaempresa.com.br"
```

Esse instalador é **somente do Manager**. O agente dos computadores gerenciados e o servidor Linux continuam usando seus respectivos scripts. Publicar os binários no GitHub não ativa atualizações dos agentes: essas releases precisam ser assinadas com a chave da organização e publicadas no servidor conforme a seção 5.

Linux, com Chromium, Edge ou Chrome instalado:

```bash
cargo build --release --locked -p assist-manager
bash scripts/linux/install-manager.sh https://ti.suaempresa.com.br ./target/release/assist-manager
```

O servidor também produz o binário Linux em `/opt/assist-ti/assist-manager`; copie-o para computadores Linux de arquitetura/distribuição compatível. O instalador cria uma entrada no menu do usuário. Também é possível executar diretamente `assist-manager https://ti.suaempresa.com.br`.

## 4. Ver a tela e dar suporte

Instale o RustDesk no computador do técnico e no node, configure as permissões de sessão e informe o ID do node no instalador do agente. Se necessário, um administrador pode editar `support_id` em `config.json` e reiniciar o serviço.

Clique em **Abrir suporte RustDesk** nos detalhes do computador. O sistema abre `rustdesk://connection/new/ID`. A conexão depende do handler de protocolo instalado e das políticas/credenciais/consentimento configurados no RustDesk. O painel não armazena senhas do RustDesk.

Para manter também o tráfego de suporte em infraestrutura própria, configure separadamente o servidor de rendezvous/relay do RustDesk e aponte os dois clientes para ele: [documentação oficial de configuração](https://rustdesk.com/docs/en/self-host/client-configuration/). O instalador deste projeto instala o servidor da central, **não** os serviços RustDesk.

Nesta versão, ver “o que está fazendo” significa consultar processos e abrir uma sessão autorizada de tela pelo RustDesk. Não há gravação de tela, registro de teclas ou histórico de navegação.

## 5. Atualizações automáticas do agente

### Gerar a chave uma vez

Em uma máquina de publicação protegida, fora do servidor exposto:

```bash
assist-release keygen assinatura.key
```

Guarde a chave privada em local restrito e com backup. No Linux o arquivo é criado com permissão 0600; no Windows use uma pasta acessível apenas ao publicador. A chave pública é exibida no terminal e deve ser fornecida ao instalar cada agente. Sem chave pública, as atualizações ficam desabilitadas. Trocar essa chave exige intervenção administrativa local nesta versão.

### Publicar uma nova versão

1. Aumente `workspace.package.version` em `Cargo.toml`, atualize `Cargo.lock` com Cargo e compile/teste o novo `assist-agent.exe`.
2. Assine usando a **mesma versão embutida no executável** e uma sequência maior que todas as anteriores:

```bash
assist-release sign assinatura.key assist-agent.exe 0.1.1 1 release-assinada
```

3. Transfira a pasta `release-assinada` ao servidor e execute:

```bash
sudo bash scripts/linux/publish-release.sh /caminho/release-assinada
```

O agente descobre o manifesto no heartbeat, baixa pelo mesmo servidor autenticado, valida assinatura/hash e prepara a troca. A tarefa agendada roda a cada 2 minutos, repete a validação, para o serviço, substitui o executável e confirma a versão pelo heartbeat. Falhas retornam à versão anterior; a sequência rejeitada não será tentada repetidamente. Publique uma sequência maior após corrigir.

Os scripts de instalação/atualização não são substituídos remotamente por esse mecanismo; mudanças neles exigem manutenção administrativa. A validação por heartbeat não substitui um rollout piloto nem testes funcionais de cada release. É necessário testar atualização, queda de energia e rollback em VMs antes de distribuir em produção.

## Operação e limites

- Uma conta administrativa compartilhada nesta versão. Ainda faltam contas individuais, MFA, RBAC, grupos e múltiplas organizações.
- Fila limitada a ações explícitas: não há terminal remoto, gerenciamento completo de serviços, pacotes, arquivos ou registro do Windows na central.
- Métricas são aproximadas; CPU precisa de duas amostras e CPU por processo pode somar vários núcleos. Os 120 pontos são apenas um histórico recente, não monitoramento de longo prazo.
- Auditoria local registra acesso, convites, revogações, ações e abertura do link RustDesk. Não é um log imutável nem uma gravação das sessões.
- A senha administrativa é lida de arquivo restrito; durante execução é mantido apenas o hash de verificação. Alterá-la exige editar o arquivo e reiniciar o serviço, invalidando todas as sessões.
- Backups: pare `assist-ti`, copie `/var/lib/assist-ti/assist.redb` e os arquivos de configuração protegidos, então inicie o serviço. Guarde releases e chave de assinatura separadamente.
- O painel não precisa de Node/npm. HTML/CSS/JS são embutidos no binário do servidor.

## Validação

`cargo test --workspace --locked` cobre autenticação obrigatória, proteção de requisições administrativas, convite de uso único, revogação, persistência, entrega única de comandos, isolamento de resultados por node, bloqueio de reboot sem permissão, URLs do launcher e verificação de releases contra adulteração/downgrade.

O workflow em `.github/workflows/ci.yml` compila e executa os testes no Windows e no Linux, e gera os binários como artifacts quando executado no GitHub. Isso não significa que a CI já foi executada. Instalação como serviço, acesso remoto, TLS público e atualização/rollback precisam de validação nas máquinas e no servidor de destino.

No Windows, `scripts/smoke-windows.ps1` inicia servidor e agente temporários, cadastra um node, confere métricas reais, executa apenas atualização de inventário, verifica uma release assinada e revoga a credencial. Com `-Browser`, usa Chrome headless para testar login, listagem, processos, convite, histórico e layout mobile. Não instala serviço ou tarefa agendada e não executa reboot. Logs e imagens ficam em `test-output/`, ignorado pelo Git; os processos temporários são encerrados ao terminar.
