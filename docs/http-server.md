# Servidor sem SSL, somente HTTP na porta 80

Na cópia atualizada do repositório no servidor Linux:

```bash
git pull --ff-only
sudo bash scripts/linux/install-server.sh --http
```

Esse modo inicia o próprio servidor Rust em **`0.0.0.0:80`**. Não precisa de domínio, certificado ou proxy instalado junto com a aplicação. Não instala nem configura Caddy, Nginx ou Traefik.

Abra **`http://IP-DO-SERVIDOR/`** para acessar o painel. Se já existir um proxy externo, configure-o separadamente para encaminhar ao IP do servidor na porta 80.

## Configuração gerada

```ini
# /etc/assist-ti/server.env
ASSIST_BIND=0.0.0.0:80
ASSIST_PUBLIC_URL=
```

`ASSIST_PUBLIC_URL` é opcional. Vazio ou com uma origem `http://...`, o login web funciona diretamente por HTTP. Se o acesso externo usar HTTPS no seu proxy, você pode definir essa URL com `https://...` para marcar o cookie como `Secure`; o servidor continuará recebendo HTTP na porta 80, sem certificado:

```bash
sudo bash scripts/linux/install-server.sh --http --public-url https://ti.suaempresa.com.br
```

Os cabeçalhos `Forwarded` e `X-Forwarded-*` não mudam essa configuração automaticamente. Nenhum proxy é executado pela aplicação. HTTP direto não criptografa o tráfego; use a rede privada entre o servidor e seu proxy externo.

O serviço roda como usuário `assistti`. A unidade systemd recebe somente a capability `CAP_NET_BIND_SERVICE` necessária para abrir a porta 80 sem executar como root.

Para selecionar uma interface específica ou outra porta:

```bash
sudo bash scripts/linux/install-server.sh --http --bind 10.0.0.20:80
```

Para apenas conferir a configuração, sem instalar:

```bash
bash scripts/linux/install-server.sh --http --print-config
```

## Se a porta 80 já estiver ocupada

Confira com `sudo ss -ltnp`. Dois programas não podem escutar no mesmo endereço e porta. Se o seu proxy estiver na mesma máquina e já usar a porta 80, escolha outro IP local ou use `--bind 127.0.0.1:8080` para o backend.

Se a instalação antiga usava **Caddy exclusivamente para o Assistente TI**, libere a porta com `sudo systemctl disable --now caddy` antes de instalar o modo HTTP. Se o Caddy atende outros sites, preserve-os e remova apenas a configuração antiga do Assistente TI, ou escolha outro endereço/porta. O instalador não para proxies existentes automaticamente.

## Verificar e atualizar

Se aparecer `Could not get lock /var/lib/dpkg/lock-frontend` com `unattended-upgr`, o Debian está instalando atualizações automáticas. O instalador atualizado aguarda até 10 minutos pela liberação desse bloqueio na etapa de instalar dependências. Não remova os arquivos de lock nem encerre a atualização à força. Se o prazo terminar, aguarde a atualização concluir e execute novamente o instalador com as mesmas opções.

Essa interrupção acontece antes de configurar e iniciar o servidor; por isso, `curl http://127.0.0.1/health` pode retornar conexão recusada. Depois de concluir a instalação, verifique o serviço com os comandos abaixo.

```bash
sudo systemctl status assist-ti
sudo journalctl -u assist-ti -n 100 --no-pager
curl http://127.0.0.1/health
```

Se escolheu um IP específico, use esse endereço no `curl`. Repita o instalador com `--http` após atualizar o código; dados e senha existentes são preservados. O arquivo de configuração é regravado com as opções informadas.

O Manager e os agentes continuam exigindo HTTPS para endereços remotos; utilize neles a URL do seu proxy externo. O navegador pode acessar diretamente o painel HTTP. A versão 0.1.2 e a branch `main` incluem o modo HTTP do servidor.
