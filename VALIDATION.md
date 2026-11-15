# Validação

## Branch main — servidor HTTP na porta 80

Verificado em 14/11/2026:

- `cargo test --workspace --locked --offline`: 12 testes passaram. Os casos novos verificam bind de rede sem domínio/SSL, autenticação e sessão por HTTP, e preservação de cookies seguros quando uma origem HTTPS é explicitamente configurada.
- `bash scripts/linux/test-server-config.sh`: passou para `--http` sem domínio, porta 80, URL opcional, IPv6, capability de porta privilegiada e parâmetros inválidos.
- `bash -n scripts/linux/install-server.sh`: sem erros de sintaxe.
- `--http --print-config`: gera `ASSIST_BIND=0.0.0.0:80`, URL pública vazia e serviço executado como `assistti` com `CAP_NET_BIND_SERVICE`.

Os testes de configuração não instalaram pacotes nem alteraram serviços. A implantação do serviço em Linux ainda deve ser validada no servidor de destino. O modo HTTP está no código atualizado da branch `main`, não no pacote antigo da release 0.1.1. Nenhum proxy foi acrescentado à aplicação.

## Versão 0.2.1 — diagnóstico do instalador

O instalador detecta uma instalação anterior do Agente antes de copiar componentes e exibe a orientação de recadastro. Falhas dos scripts PowerShell agora retornam o erro original na interface do instalador.

## Versão 0.2.0 — suporte remoto próprio

O servidor usa credencial de suporte separada da credencial de telemetria, cria sessões de uma hora e conserva apenas o quadro mais recente em memória. O módulo `assist-support` captura a tela principal e aplica eventos limitados de mouse e teclado. A interface web inicia, controla e encerra a sessão. Os testes automatizados e a compilação Windows validam protocolo e integração; captura e entrada devem ser homologadas em uma VM Windows com sessão gráfica real.

## Versão 0.1.2 — instalador unificado Windows

O instalador oferece seleção independente de Manager, Agente e Servidor. A compilação do Inno Setup, a análise de sintaxe dos scripts PowerShell e os testes Rust foram executados no Windows. A instalação real de Agente/Servidor deve ser validada em uma VM Windows dedicada porque cria serviço, tarefa agendada e regra de firewall.

## Versão 0.1.1 — instalador do Manager

Verificações locais em Windows x64, em 13/11/2026:

- Nove testes Rust passaram, incluindo a validação de URL usada pelo instalador.
- Compilação otimizada dos quatro executáveis Windows concluída.
- Instalador gráfico `.exe` gerado com Inno Setup 7.1.1.
- `scripts/test-manager-installer.ps1` validou rejeição de URL HTTP externa, instalação em pasta de teste, persistência da URL, registro em Aplicativos do Windows, preservação da configuração ao reinstalar, mudança de URL e desinstalação completa.
- O teste não abriu o painel, não se conectou a um servidor externo e não instalou agente ou serviço.
- A instalação temporária e sua entrada de desinstalação foram removidas ao concluir. Logs ficam apenas em `test-output/`, fora dos pacotes e do Git.

O Manager permanece um aplicativo Rust que abre o painel no Microsoft Edge, agora com instalador gráfico e sem console ao iniciar. Os limites de validação de serviço Windows, rollback e servidor Linux descritos abaixo continuam aplicáveis até a homologação desses componentes.

## Versão 0.1.0

Executada em 13/11/2026, em ambiente Windows x64.

## Resultados observados

- `cargo test --workspace --locked --offline`: **8 testes passaram** (5 servidor, 1 agente, 1 aplicativo e 1 protocolo/assinatura).
- `cargo build --workspace --release --locked --offline`: compilação otimizada concluída dos quatro executáveis Windows.
- Scripts PowerShell: análise de sintaxe pelo parser do Windows PowerShell, sem erros; arquivos em UTF-8 com BOM para compatibilidade com PowerShell 5.1.
- Scripts Linux: `bash -n`, sem erros de sintaxe. Não foram executados em Linux neste ambiente.
- `scripts/smoke-windows.ps1 -Browser`: **passou**, usando servidor e agente reais em processos temporários, com armazenamento de teste separado.

O teste integrado verificou:

1. Login e criação de convite no servidor.
2. Cadastro do executável do agente com convite de uso único.
3. Heartbeat com memória, CPU e processos reais do computador de teste.
4. Envio e confirmação de uma ação de atualização de inventário.
5. Geração de chave de teste, assinatura de uma release real, download autenticado pelo agente e verificação da release pendente e preparada para instalação.
6. Login, lista de computadores, modal de processos, geração de convite e histórico no Chrome headless.
7. Layout com larguras de 1440 e 390 pixels; ausência de overflow horizontal da página mobile.
8. Revogação da credencial do node.

O resultado estruturado e as capturas ficam em `test-output/smoke-ba83aa9a7ed3457fa5df46a43f3ff2a8/`. Não são distribuídos nos pacotes porque contêm dados locais de teste. Os processos temporários foram encerrados, e a senha e a chave privada de teste foram removidas.

## Não validado em máquina de destino

- Execução do instalador Debian/Ubuntu, Caddy, emissão do certificado público e configuração de DNS/firewall.
- Compilação/execução do aplicativo Linux. Existe workflow de CI para Linux e Windows, ainda não executado no GitHub.
- Registro do agente como serviço SYSTEM, ACLs e tarefa agendada no Windows.
- Substituição de executável em serviço, queda de energia e rollback real. O código e os scripts estão implementados; a verificação criptográfica e a preparação da release foram testadas, mas o ciclo de instalação requer uma VM piloto.
- Transferência de arquivos durante a sessão de suporte ainda não está disponível.
- Escala, disponibilidade, múltiplos administradores e requisitos de produção de uma suíte RMM.

Nenhum serviço foi instalado neste computador, nenhuma ação de reboot foi executada e nenhum servidor externo recebeu a telemetria de teste.
