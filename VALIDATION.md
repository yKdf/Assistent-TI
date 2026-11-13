# Validação da versão 0.1.0

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
- Sessão de tela, controle e transferência de arquivos via RustDesk. A central gera o link de conexão; essas funções dependem do RustDesk instalado/configurado separadamente.
- Escala, disponibilidade, múltiplos administradores e requisitos de produção de uma suíte RMM.

Nenhum serviço foi instalado neste computador, nenhuma ação de reboot foi executada e nenhum servidor externo recebeu a telemetria de teste.
