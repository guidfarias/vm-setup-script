#!/bin/bash
# =============================================================================
# setup-vps.sh — Configuração completa de VPS (sistema + backup) em 1 arquivo
# RunCloud / CIPNET — Autor: Guilherme Farias
#
# Junta em um único script os dois passos que antes eram scripts separados:
#   1) "setup"  — configuração inicial do servidor (pacotes, timezone, shell,
#                 neovim, chave SSH). Equivalente ao antigo configura_vps.sh.
#   2) "backup" — instala e agenda o backup para S3 (restic + tar.gz semanal).
#                 Equivalente ao antigo instalar_backup.sh + configura_backup.sh.
#
# Não baixa nada da internet durante a execução: o script de backup e o
# wrapper `rr` ficam embutidos aqui dentro e são gravados em /usr/local/bin.
#
# Uso:
#   sudo bash setup-vps.sh              # roda os dois passos (padrão)
#   sudo bash setup-vps.sh setup        # só a configuração inicial da VPS
#   sudo bash setup-vps.sh backup       # só a instalação do backup
#   sudo bash setup-vps.sh --help
#
# Ver USO.md para o passo a passo comentado.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CORES / LOG (compartilhado pelos dois passos)
# ---------------------------------------------------------------------------

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error() { echo -e "${RED}[ERRO]${NC} $1"; }
log_step()  { echo; echo -e "${CYAN}==> $1${NC}"; }
die()       { log_error "$1"; exit 1; }

append_once() {
    local line="$1" file="$2"
    grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

# ---------------------------------------------------------------------------
# ARGUMENTOS
# ---------------------------------------------------------------------------

RUN_SETUP=true
RUN_BACKUP=true
APPLY_LIFECYCLE=true
RUN_FIRST_BACKUP="ask"   # ask | yes | no

print_help() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
}

for arg in "$@"; do
    case "${arg}" in
        setup)          RUN_SETUP=true;  RUN_BACKUP=false ;;
        backup)         RUN_SETUP=false; RUN_BACKUP=true ;;
        all)            RUN_SETUP=true;  RUN_BACKUP=true ;;
        --no-lifecycle) APPLY_LIFECYCLE=false ;;
        --run-now)      RUN_FIRST_BACKUP="yes" ;;
        --skip-run)     RUN_FIRST_BACKUP="no" ;;
        --help|-h)      print_help; exit 0 ;;
        *) die "Argumento desconhecido: ${arg} (use: setup | backup | all | --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Este script precisa ser executado como root (use: sudo bash $0)."

# =============================================================================
# PASSO 1 — CONFIGURAÇÃO INICIAL DA VPS
# =============================================================================

step_setup() {
    log_step "PASSO 1/2 — Configuração inicial do sistema"

    log_info "Atualizando pacotes..."
    apt-get update -y || die "Falha ao atualizar pacotes"
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || die "Falha ao fazer upgrade"

    log_info "Configurando timezone para America/Sao_Paulo..."
    timedatectl set-timezone America/Sao_Paulo

    log_info "Gerando locale en_GB.UTF-8 (formato de hora 24h)..."
    apt-get install -y locales || die "Falha ao instalar pacote locales"
    locale-gen en_GB.UTF-8 || die "Falha ao gerar locale en_GB.UTF-8"
    localectl set-locale LC_TIME=en_GB.UTF-8

    log_info "Instalando pacotes essenciais..."
    apt-get install -y \
        traceroute plocate wget curl neovim net-tools htop tmux git unzip \
        gnupg ca-certificates software-properties-common ncdu iotop nmap \
        bat ripgrep \
        || die "Falha na instalação de pacotes essenciais"

    log_info "Instalando duf (df mais visual)..."
    local duf_version="0.8.1"
    if wget -q "https://github.com/muesli/duf/releases/download/v${duf_version}/duf_${duf_version}_linux_amd64.deb" -O /tmp/duf.deb \
        && dpkg -i /tmp/duf.deb; then
        log_info "duf instalado."
    else
        log_warn "Falha ao instalar duf (não crítico, seguindo)."
    fi
    rm -f /tmp/duf.deb

    configure_neovim
    configure_bash
    install_ssh_key

    log_info "Configuração inicial concluída. Hostname: $(hostname) | IP: $(hostname -I | awk '{print $1}')"
}

configure_neovim() {
    log_info "Configurando Neovim como editor padrão..."
    mkdir -p /root/.config/nvim
    cat > /root/.config/nvim/init.vim << 'EOF'
set number
set norelativenumber
set mouse=
set expandtab
set tabstop=4
set shiftwidth=4
set autoindent
set smartindent
set cursorline
set termguicolors
set background=dark
syntax enable
set encoding=utf-8
set scrolloff=8
set signcolumn=yes
set updatetime=300
set timeoutlen=500
colorscheme habamax
hi Normal guibg=#161616 guifg=#f2f4f8
hi CursorLine guibg=#262626
hi LineNr guifg=#525252 guibg=#161616
hi CursorLineNr guifg=#78a9ff guibg=#262626 gui=bold
hi Comment guifg=#6f6f6f gui=italic
hi Statement guifg=#ee5396 gui=bold
hi Type guifg=#3ddbd9
hi String guifg=#33b1ff
hi Function guifg=#be95ff
hi Constant guifg=#ff7eb6
hi PreProc guifg=#42be65
hi Special guifg=#ff6f00
hi Identifier guifg=#82cfff
hi Visual guibg=#393939
hi Search guibg=#42be65 guifg=#161616
hi IncSearch guibg=#ee5396 guifg=#161616
hi StatusLine guibg=#262626 guifg=#f2f4f8
hi StatusLineNC guibg=#1c1c1c guifg=#6f6f6f
hi VertSplit guibg=#161616 guifg=#393939
hi Pmenu guibg=#262626 guifg=#f2f4f8
hi PmenuSel guibg=#393939 guifg=#78a9ff
set nolist
set listchars=tab:→\ ,trail:·,nbsp:␣
set ignorecase
set smartcase
set incsearch
set hlsearch
set nobackup
set nowritebackup
set noswapfile
nnoremap <C-s> :w<CR>
inoremap <C-s> <Esc>:w<CR>a
EOF
    update-alternatives --set editor /usr/bin/nvim 2>/dev/null \
        || update-alternatives --install /usr/bin/editor editor /usr/bin/nvim 100

    mkdir -p /etc/skel/.config/nvim
    cp /root/.config/nvim/init.vim /etc/skel/.config/nvim/init.vim
}

configure_bash() {
    log_info "Aplicando melhorias no bash prompt e aliases..."
    touch /root/.bashrc

    # Remove aliases antigos que atrapalham copiar/colar ou comandos esperados.
    sed -i "/^alias cat='batcat --paging=never'$/d" /root/.bashrc
    sed -i "/^alias vim='nvim'$/d" /root/.bashrc
    sed -i "/^alias vi='nvim'$/d" /root/.bashrc

    append_once "alias nv='nvim'" /root/.bashrc
    append_once "export EDITOR='nvim'" /root/.bashrc
    append_once "export VISUAL='nvim'" /root/.bashrc

    if ! grep -q "PS1 customizado" /root/.bashrc; then
        cat >> /root/.bashrc << 'EOF'

# PS1 customizado
export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# Aliases úteis
alias ll='ls -lah --color=auto'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias df='df -h'
alias free='free -h'
alias ..='cd ..'
alias ...='cd ../..'
alias bat='batcat'
alias ccat='batcat --paging=never'
alias rg='rg --smart-case'

# History melhorado
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S "
export HISTCONTROL=ignoredups:erasedups
EOF
    fi
    append_once "alias bat='batcat'" /root/.bashrc
    append_once "alias ccat='batcat --paging=never'" /root/.bashrc
    append_once "alias rg='rg --smart-case'" /root/.bashrc

    cp /root/.bashrc /etc/skel/.bashrc
}

install_ssh_key() {
    log_info "Instalando chave SSH do Guilherme Farias..."
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    curl -fs https://sshid.io/guilhermefarias >> /root/.ssh/authorized_keys
    sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
}

# =============================================================================
# PASSO 2 — BACKUP (restic + tar.gz semanal → S3)
# =============================================================================

RESTIC_VERSION="0.17.3"
SCRIPT_DEST="/usr/local/bin/restic-backup.sh"
RR_DEST="/usr/local/bin/rr"
ENV_DIR="/etc/restic"
ENV_FILE="${ENV_DIR}/env"
CRON_FILE="/etc/cron.d/restic-backup"
CRON_LOG="/var/log/restic-cron.log"
CRON_SCHEDULE="30 2 * * 1-5"
LIFECYCLE_DAYS="30"
ENV_IS_TEMPLATE=false

step_backup() {
    log_step "PASSO 2/2 — Instalação do backup (restic + tar.gz → S3)"

    local arch restic_arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64|amd64)  restic_arch="amd64" ;;
        aarch64|arm64) restic_arch="arm64" ;;
        *) die "Arquitetura não suportada: ${arch}" ;;
    esac

    backup_install_packages
    backup_install_awscli "${restic_arch}"
    backup_install_restic "${restic_arch}"
    backup_write_scripts
    backup_create_env_template
    backup_configure_cron
    backup_apply_lifecycle
    backup_run_first

    print_backup_summary
}

backup_install_packages() {
    log_info "Verificando dependências do sistema (cliente de banco + utilitários)..."
    export DEBIAN_FRONTEND=noninteractive

    # NUNCA instalar 'mysql-client' (pacote da Oracle): conflita com o cliente
    # MariaDB que o RunCloud já usa. Se mysqldump/mysql já existem, não mexe em
    # nada; senão instala 'mariadb-client', que é o cliente correto e compatível.
    if command -v mysqldump &>/dev/null && command -v mysql &>/dev/null; then
        log_info "Cliente de banco já presente ($(command -v mysqldump))."
    else
        log_info "Instalando mariadb-client (cliente de banco compatível)..."
        apt-get update -y || log_warn "apt-get update falhou (seguindo mesmo assim)."
        apt-get install -y mariadb-client \
            || die "Falha ao instalar mariadb-client."
    fi

    local missing=() cmd
    for cmd in gzip tar bzip2 unzip curl; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    dpkg -s ca-certificates &>/dev/null || missing+=("ca-certificates")

    if (( ${#missing[@]} > 0 )); then
        log_info "Instalando utilitários faltantes: ${missing[*]}"
        apt-get update -y || log_warn "apt-get update falhou (seguindo mesmo assim)."
        apt-get install -y "${missing[@]}" || die "Falha ao instalar: ${missing[*]}"
    fi
}

backup_install_awscli() {
    local restic_arch="$1"
    if command -v aws &>/dev/null && aws --version 2>&1 | grep -q "aws-cli/2"; then
        log_info "AWS CLI v2 já instalado."
        return 0
    fi
    log_info "Instalando AWS CLI v2..."
    local awsurl
    case "${restic_arch}" in
        amd64) awsurl="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
        arm64) awsurl="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
    esac
    curl -fsSL "${awsurl}" -o /tmp/awscliv2.zip || die "Falha ao baixar o AWS CLI."
    rm -rf /tmp/aws
    unzip -q /tmp/awscliv2.zip -d /tmp/ || die "Falha ao descompactar o AWS CLI."
    /tmp/aws/install --update || die "Falha ao instalar o AWS CLI."
    rm -rf /tmp/aws /tmp/awscliv2.zip
}

backup_install_restic() {
    local restic_arch="$1"
    if command -v restic &>/dev/null && restic version 2>/dev/null | grep -q "restic ${RESTIC_VERSION}"; then
        log_info "restic ${RESTIC_VERSION} já instalado."
        return 0
    fi
    log_info "Instalando restic ${RESTIC_VERSION}..."
    local url="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${restic_arch}.bz2"
    curl -fsSL "${url}" -o "/tmp/restic.bz2" || die "Falha ao baixar o restic."
    bunzip2 -f "/tmp/restic.bz2" || die "Falha ao descompactar o restic."
    mv /tmp/restic /usr/local/bin/restic
    chmod +x /usr/local/bin/restic
}

# Grava o script de backup e o wrapper `rr` embutidos neste arquivo (heredocs
# abaixo) em /usr/local/bin — não depende de internet além dos passos acima.
backup_write_scripts() {
    log_info "Instalando ${SCRIPT_DEST} e ${RR_DEST}..."

    cat > "${SCRIPT_DEST}" << 'BACKUP_SCRIPT_EOF'
#!/bin/bash
# =============================================================================
# restic-backup.sh — Backup completo de /home para S3 (restic + tar.gz)
# RunCloud / CIPNET
#
# O que este script faz:
#   1. Carrega variáveis de /etc/restic/env (valida permissões 600/root)
#   2. Valida pré-requisitos (binários, credenciais, espaço em disco)
#   3. Faz dump de todos os bancos MySQL em ${DB_DUMP_DIR}
#      (credenciais via arquivo temporário — NÃO vazam no `ps aux`)
#   4. Faz backup incremental do /home completo com restic
#   5. Gera .tar.gz por aplicação e envia ao S3 (dia configurável / FORCE_ARCHIVE)
#   6. Aplica retenção (forget --prune)
#   7. Executa check de integridade semanal
#   8. (Opcional) Testa restore de amostra: --test-restore
#
# Uso:
#   bash restic-backup.sh                  # backup normal
#   bash restic-backup.sh --dry-run        # simula, nada é enviado
#   bash restic-backup.sh --check          # força check de integridade
#   bash restic-backup.sh --test-restore   # testa restauração de amostra
#   FORCE_ARCHIVE=true bash restic-backup.sh
#
# ⚠️  IMPORTANTE — RECUPERAÇÃO DE DESASTRE:
#   A RESTIC_PASSWORD é a ÚNICA forma de ler os backups restic. Se o servidor
#   for perdido/reprovisionado e você não tiver essa senha guardada EM OUTRO
#   LUGAR (gerenciador de senhas, cofre, etc.), TODOS os backups restic ficam
#   irrecuperáveis. Guarde-a fora do servidor. O mesmo vale para as chaves AWS.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURAÇÃO — defaults (sobrescritos pelo /etc/restic/env)
# ---------------------------------------------------------------------------

RESTIC_ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/env}"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

S3_BUCKET="${S3_BUCKET:-runcloud-backup-cipcloud}"
S3_PREFIX="${S3_PREFIX:-$(hostname -s)}"
RESTIC_S3_PREFIX="${RESTIC_S3_PREFIX:-Restic/${S3_PREFIX}}"

RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"

# Diretório de origem do backup (permite testar sem tocar em /home real)
BACKUP_SOURCE="${BACKUP_SOURCE:-/home}"

DB_DUMP_DIR="${DB_DUMP_DIR:-/home/backups/db}"

MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_HOST="${MYSQL_HOST:-localhost}"

KEEP_DAILY="${KEEP_DAILY:-5}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-4}"

# Segunda-feira (o cron roda seg-sex; 0=domingo nunca executaria).
CHECK_DAY="${CHECK_DAY:-1}"
# Aceita valor fixo (ex.: 5G) ou percentual (ex.: 10%). Percentual escala com o repo.
CHECK_DATA_SUBSET="${CHECK_DATA_SUBSET:-10%}"

# Espaço livre mínimo (em MB) exigido em DB_DUMP_DIR antes de dumpar os bancos.
MIN_FREE_MB="${MIN_FREE_MB:-2048}"

LOG_FILE="${LOG_FILE:-/var/log/restic-backup.log}"
LOG_MAX_LINES="${LOG_MAX_LINES:-5000}"

# Lock para evitar duas execuções simultâneas (cron sobreposto).
LOCK_FILE="${LOCK_FILE:-/var/run/restic-backup.lock}"

DRY_RUN=false
FORCE_CHECK=false
TEST_RESTORE=false

ENABLE_WEEKLY_ARCHIVES="${ENABLE_WEEKLY_ARCHIVES:-true}"
ARCHIVE_DAY="${ARCHIVE_DAY:-5}"
ARCHIVE_S3_PREFIX="${ARCHIVE_S3_PREFIX:-Snapshots}"
ARCHIVE_KEEP_WEEKS="${ARCHIVE_KEEP_WEEKS:-1}"

# ---------------------------------------------------------------------------
# ALERTAS (opcional) — Healthchecks.io (dead man's switch)
# ---------------------------------------------------------------------------
# Defina HEALTHCHECK_URL no /etc/restic/env para ativar. Deixe vazio p/ desligar.
# O script sinaliza início (/start), sucesso e falha (/fail) automaticamente.
# É a forma mais confiável de descobrir que o backup PAROU de rodar.
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

# ---------------------------------------------------------------------------
# STATUS PARA MONITORAMENTO (JSON gravado no S3 em Monitoramento/<host>.json)
# ---------------------------------------------------------------------------
# Preenchido ao longo da execução e gravado SEMPRE no final (sucesso ou falha),
# inclusive em falha precoce. O MCP/painel lê esses JSONs para ver a frota sem
# conectar em servidor nenhum. Arquivo local de status (fallback / auditoria):
STATUS_LOCAL_FILE="${STATUS_LOCAL_FILE:-/var/log/restic-status.json}"
# Prefixo (pasta) no S3 onde os JSONs de status são gravados.
STATUS_S3_PREFIX="${STATUS_S3_PREFIX:-Monitoramento}"
STATUS_SCRIPT_VERSION="2026-07"

STATUS_STARTED_AT=""          # ISO8601 do início
STATUS_DB_OK=0
STATUS_DB_FAIL=0
STATUS_ARCHIVE_RAN="false"
STATUS_ARCHIVE_APPS_OK=0
STATUS_ARCHIVE_APPS_FAIL=0
STATUS_SNAPSHOT_ID=""
STATUS_REPO_SIZE=""
STATUS_SNAPSHOTS_TOTAL=""
STATUS_CHECK_RAN="false"
STATUS_ERRORS=()              # array de mensagens de erro/aviso relevantes
STATUS_WRITTEN="false"        # evita escrever duas vezes

# Registra uma mensagem no array de erros do status (para o JSON).
status_add_error() {
    STATUS_ERRORS+=("$*")
}

# ---------------------------------------------------------------------------
# ESTADO INTERNO / LIMPEZA
# ---------------------------------------------------------------------------

EXCLUDE_FILE=""
MYSQL_DEFAULTS_FILE=""
RESTORE_TEST_DIR=""
REPO_EXISTS="false"

cleanup() {
    # Preserva o código de saída original: como este é o trap de EXIT, o status
    # do último comando aqui viraria o exit do script. `return 0` garante que
    # um backup bem-sucedido não seja reportado como falha ao cron.
    local exit_code=$?

    # Publica o status de monitoramento SEMPRE (sucesso, falha parcial ou falha
    # precoce). Classificação:
    #   - exit != 0                    → "error"   (abortou; ex.: restic ausente)
    #   - exit == 0 mas houve erros    → "partial" (ex.: 1 banco falhou no dump)
    #   - exit == 0 e sem erros        → "success"
    # write_status é no-op em dry-run/test-restore e nunca deixa o script falhar.
    local overall="success"
    if (( exit_code != 0 )); then
        overall="error"
    elif (( ${#STATUS_ERRORS[@]} > 0 )); then
        overall="partial"
    fi
    # (declare -F: em saídas precoces como --help, write_status ainda não existe)
    if declare -F write_status &>/dev/null; then
        write_status "${overall}" || true
    fi

    [[ -n "${EXCLUDE_FILE}" ]]        && rm -f "${EXCLUDE_FILE}"
    [[ -n "${MYSQL_DEFAULTS_FILE}" ]] && rm -f "${MYSQL_DEFAULTS_FILE}"
    [[ -n "${RESTORE_TEST_DIR}" ]]    && rm -rf "${RESTORE_TEST_DIR}"
    return "${exit_code}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# FUNÇÕES DE LOG
# ---------------------------------------------------------------------------

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    # Garante que o diretório do log exista antes do primeiro write. Se o log
    # não for gravável, ainda mostra no stdout/stderr (não deixa o backup mudo).
    local logdir
    logdir="$(dirname "${LOG_FILE}")"
    [[ -d "${logdir}" ]] || mkdir -p "${logdir}" 2>/dev/null || true
    if [[ -w "${logdir}" || -w "${LOG_FILE}" ]]; then
        echo "${ts} [${level}] ${msg}" | tee -a "${LOG_FILE}"
    else
        echo "${ts} [${level}] ${msg}"
    fi
}

info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }

die() {
    error "$@"
    status_add_error "$*"
    notify_failure "$*"
    exit 1
}

rotate_log() {
    if [[ -f "${LOG_FILE}" ]]; then
        local lines
        lines="$(wc -l < "${LOG_FILE}")"
        if (( lines > LOG_MAX_LINES )); then
            tail -n "${LOG_MAX_LINES}" "${LOG_FILE}" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "${LOG_FILE}"
        fi
    fi
}

# ---------------------------------------------------------------------------
# ALERTAS — helpers Healthchecks.io (no-op se HEALTHCHECK_URL vazio)
# ---------------------------------------------------------------------------

notify_start() {
    [[ -z "${HEALTHCHECK_URL}" ]] && return 0
    command -v curl &>/dev/null || return 0
    curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}/start" &>/dev/null || true
}

notify_success() {
    [[ -z "${HEALTHCHECK_URL}" ]] && return 0
    command -v curl &>/dev/null || return 0
    curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}" &>/dev/null || true
}

notify_failure() {
    [[ -z "${HEALTHCHECK_URL}" ]] && return 0
    command -v curl &>/dev/null || return 0
    # Envia a mensagem de erro no corpo (aparece no painel do Healthchecks).
    curl -fsS -m 10 --retry 3 --data-raw "${1:-falha}" \
        "${HEALTHCHECK_URL}/fail" &>/dev/null || true
}

# ---------------------------------------------------------------------------
# ARGUMENTOS
# ---------------------------------------------------------------------------

for arg in "$@"; do
    case "${arg}" in
        --dry-run)      DRY_RUN=true ;;
        --check)        FORCE_CHECK=true ;;
        --test-restore) TEST_RESTORE=true ;;
        --force-archive) FORCE_ARCHIVE=true ;;
        --help|-h)
            cat <<'HELP'
Uso:
  bash restic-backup.sh                  # backup normal
  bash restic-backup.sh --dry-run        # simula, nada é enviado ao S3
  bash restic-backup.sh --check          # força check de integridade
  bash restic-backup.sh --test-restore   # testa restauração de amostra e sai
  bash restic-backup.sh --force-archive # força o compactado semanal agora
  FORCE_ARCHIVE=true bash restic-backup.sh
HELP
            exit 0
            ;;
        *)
            echo "Argumento desconhecido: ${arg}" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# CARREGA VARIÁVEIS EXTERNAS (com verificação de segurança das permissões)
# ---------------------------------------------------------------------------

load_env_file() {
    if [[ ! -f "${RESTIC_ENV_FILE}" ]]; then
        warn "Arquivo ${RESTIC_ENV_FILE} não encontrado. Usando variáveis do ambiente."
        return 0
    fi

    # O env contém a senha do root do MySQL e a RESTIC_PASSWORD.
    # Recusa carregar se estiver legível por outros usuários.
    # Suporta stat do GNU (Linux, -c) e do BSD (macOS, -f).
    local perms owner
    perms="$(stat -c '%a' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || stat -f '%Lp' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || echo '???')"
    owner="$(stat -c '%U' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || stat -f '%Su' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || echo '???')"

    if [[ "${perms}" == "???" ]]; then
        warn "Não foi possível verificar permissões de ${RESTIC_ENV_FILE} (stat indisponível). Prosseguindo."
    elif [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
        die "Permissões inseguras em ${RESTIC_ENV_FILE} (${perms}). Corrija com: chmod 600 ${RESTIC_ENV_FILE}"
    fi
    if [[ "${owner}" != "???" && "${owner}" != "root" && "${owner}" != "$(id -un)" ]]; then
        warn "Dono de ${RESTIC_ENV_FILE} é '${owner}' (esperado root)."
    fi

    # shellcheck source=/dev/null
    source "${RESTIC_ENV_FILE}"

    # Reaplica defaults para variáveis que o env pode ter deixado vazias.
    AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-sa-east-1}"
    CHECK_DATA_SUBSET="${CHECK_DATA_SUBSET:-10%}"

    info "Variáveis carregadas de ${RESTIC_ENV_FILE} (perms ${perms}, dono ${owner})"
}

# ---------------------------------------------------------------------------
# VALIDAÇÕES
# ---------------------------------------------------------------------------

require_cmd() {
    # require_cmd <binário> <dica de instalação>
    if ! command -v "$1" &>/dev/null; then
        error "'$1' não encontrado. ${2:-}"
        return 1
    fi
    return 0
}

validate_env() {
    local errors=0

    require_cmd restic    "Instale o restic (https://restic.net)."           || errors=$((errors + 1))
    require_cmd mysqldump "apt install mysql-client -y"                       || errors=$((errors + 1))
    require_cmd mysql     "apt install mysql-client -y"                       || errors=$((errors + 1))
    require_cmd gzip      "apt install gzip -y"                               || errors=$((errors + 1))

    if [[ -z "${AWS_ACCESS_KEY_ID}" ]]; then
        error "AWS_ACCESS_KEY_ID não definido."; errors=$((errors + 1))
    fi
    if [[ -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
        error "AWS_SECRET_ACCESS_KEY não definido."; errors=$((errors + 1))
    fi
    if [[ -z "${RESTIC_PASSWORD}" ]]; then
        error "RESTIC_PASSWORD não definido."; errors=$((errors + 1))
    fi
    if [[ -z "${S3_BUCKET}" ]]; then
        error "S3_BUCKET não definido."; errors=$((errors + 1))
    fi
    if [[ ! -d "${BACKUP_SOURCE}" ]]; then
        error "Diretório de origem não existe: ${BACKUP_SOURCE}"; errors=$((errors + 1))
    fi

    (( errors == 0 )) || die "${errors} erro(s) de configuração encontrados. Abortando."
}

# Garante que só um backup rode por vez (evita corromper dumps entre execuções).
acquire_lock() {
    if ! command -v flock &>/dev/null; then
        warn "flock não encontrado (util-linux). Prosseguindo SEM proteção contra execução simultânea."
        return 0
    fi
    # Usa file descriptor 9 preso ao LOCK_FILE; flock não-bloqueante.
    exec 9>"${LOCK_FILE}" || die "Não foi possível abrir o lock ${LOCK_FILE}."
    if ! flock -n 9; then
        die "Outra execução do backup já está em andamento (lock: ${LOCK_FILE}). Abortando."
    fi
}

# ---------------------------------------------------------------------------
# EXPORTA VARIÁVEIS PARA O RESTIC
# ---------------------------------------------------------------------------

export_restic_env() {
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_DEFAULT_REGION
    export RESTIC_PASSWORD
    export RESTIC_REPOSITORY="s3:s3.${AWS_DEFAULT_REGION}.amazonaws.com/${S3_BUCKET}/${RESTIC_S3_PREFIX}"
    export RESTIC_COMPRESSION="auto"
}

# ---------------------------------------------------------------------------
# CREDENCIAIS MYSQL — arquivo temporário (não vaza no `ps aux`)
# ---------------------------------------------------------------------------

build_mysql_defaults_file() {
    MYSQL_DEFAULTS_FILE="$(mktemp)"
    chmod 600 "${MYSQL_DEFAULTS_FILE}"
    {
        echo "[client]"
        echo "user=${MYSQL_USER}"
        echo "host=${MYSQL_HOST}"
        # Só escreve a senha se houver uma (permite auth por socket sem senha).
        if [[ -n "${MYSQL_PASSWORD}" ]]; then
            echo "password=${MYSQL_PASSWORD}"
        fi
    } > "${MYSQL_DEFAULTS_FILE}"
}

# Wrappers: sempre usam o defaults-file como PRIMEIRO argumento.
mysql_cmd()     { mysql     --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" "$@"; }
mysqldump_cmd() { mysqldump --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" "$@"; }

# ---------------------------------------------------------------------------
# INICIALIZA REPOSITÓRIO (se necessário)
# ---------------------------------------------------------------------------

init_repo_if_needed() {
    if restic cat config &>/dev/null; then
        info "Repositório restic já existe em: ${RESTIC_REPOSITORY}"
        REPO_EXISTS="true"
        return 0
    fi

    info "Repositório não encontrado. Inicializando: ${RESTIC_REPOSITORY}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Pulando inicialização do repositório."
        return 0
    fi

    restic init || die "Falha ao inicializar repositório restic."
    REPO_EXISTS="true"
    info "Repositório inicializado com sucesso."
}

# ---------------------------------------------------------------------------
# DUMP DOS BANCOS MYSQL
# ---------------------------------------------------------------------------

check_disk_space() {
    # Verifica espaço livre no filesystem de DB_DUMP_DIR antes de dumpar.
    mkdir -p "${DB_DUMP_DIR}"
    local free_mb
    free_mb="$(df -Pm "${DB_DUMP_DIR}" | awk 'NR==2 {print $4}')"
    if [[ -n "${free_mb}" ]] && (( free_mb < MIN_FREE_MB )); then
        die "Espaço insuficiente em ${DB_DUMP_DIR}: ${free_mb}MB livres (< ${MIN_FREE_MB}MB exigidos)."
    fi
    info "Espaço livre em ${DB_DUMP_DIR}: ${free_mb}MB (mínimo ${MIN_FREE_MB}MB) OK."
}

dump_databases() {
    info "Iniciando dump dos bancos MySQL em ${DB_DUMP_DIR}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Pulando dump de bancos."
        return 0
    fi

    # Valida conexão com MySQL ANTES de apagar dumps antigos.
    info "Testando conexão com MySQL..."
    if ! mysql_cmd --silent -e "SELECT 1;" &>/dev/null; then
        die "Falha ao conectar no MySQL. Dumps antigos preservados."
    fi
    info "Conexão com MySQL OK."

    check_disk_space

    chmod 700 "${DB_DUMP_DIR}"
    info "Limpando dumps antigos em ${DB_DUMP_DIR}"
    find "${DB_DUMP_DIR}" -type f -name "*.sql.gz" -delete

    local db_list
    db_list="$(mysql_cmd --skip-column-names --silent -e "SHOW DATABASES;" 2>>"${LOG_FILE}" \
        | grep -Ev "^(information_schema|performance_schema|sys|mysql)$" || true)"

    if [[ -z "${db_list}" ]]; then
        warn "Nenhum banco de usuário encontrado."
        return 0
    fi

    local ok=0 fail=0
    while IFS= read -r db; do
        [[ -z "${db}" ]] && continue
        local dump_file="${DB_DUMP_DIR}/${db}.sql.gz"

        info "Dumping banco: ${db}"

        # PIPESTATUS captura a falha do mysqldump mesmo com pipe pro gzip.
        set +e
        mysqldump_cmd \
            --single-transaction \
            --quick \
            --routines \
            --triggers \
            --events \
            "${db}" 2>>"${LOG_FILE}" | gzip -9 > "${dump_file}"
        local dump_rc=${PIPESTATUS[0]}
        set -e

        if (( dump_rc == 0 )); then
            chmod 600 "${dump_file}"
            ok=$((ok + 1))
        else
            error "Falha no dump do banco: ${db} (rc=${dump_rc})"
            status_add_error "dump falhou: ${db} (rc=${dump_rc})"
            rm -f "${dump_file}"
            fail=$((fail + 1))
        fi
    done <<< "${db_list}"

    STATUS_DB_OK=${ok}
    STATUS_DB_FAIL=${fail}

    info "Dump finalizado: ${ok} banco(s) OK, ${fail} falha(s)."

    if (( fail > 0 )); then
        warn "Alguns bancos falharam no dump. Backup do ${BACKUP_SOURCE} continuará, mas revise o log."
    fi
}

# ---------------------------------------------------------------------------
# ARQUIVO DE EXCLUSÕES
# ---------------------------------------------------------------------------
# NOTA: mantidos os excludes originais. Ciente de que *.log e .git são
# excluídos do restic — se precisar do histórico git ou de logs para auditoria
# ao restaurar uma app, remova as linhas correspondentes.

build_exclude_file() {
    EXCLUDE_FILE="$(mktemp)"
    cat > "${EXCLUDE_FILE}" << 'EXCLUDES'
# Dependências e caches de projeto
node_modules
.npm
.composer/cache
.pip
__pycache__
*.pyc
*.pyo
.cache
.gradle
.m2
target

# Git e arquivos temporários
.git
*.tmp
*.swp
*.orig
~*
.DS_Store
Thumbs.db

# Logs e caches comuns
*.log
*/wp-content/cache/*
*/wp-content/upgrade/*
*/cache/*
*/tmp/*

# Arquivos de processo/sistema
*.sock
*.pid
swap
swapfile

# Lixeiras locais
.Trash
.trash

# Backups gerados por plugins WordPress
*/wp-content/ai1wm-backups/*
*/wp-content/updraft/*
*/wp-content/backups-dup-lite/*
*/wp-content/backup-db/*
*/wp-content/wpvividbackups/*
EXCLUDES
}

# ---------------------------------------------------------------------------
# BACKUP DO /HOME
# ---------------------------------------------------------------------------

run_backup() {
    info "Iniciando backup restic de ${BACKUP_SOURCE}"
    info "Repositório: ${RESTIC_REPOSITORY}"

    local restic_flags=(
        backup
        "${BACKUP_SOURCE}"
        --exclude-file="${EXCLUDE_FILE}"
        --tag "host=$(hostname -s)"
        --tag "runcloud"
        --tag "daily"
        --one-file-system
    )

    if [[ "${DRY_RUN}" == "true" ]]; then
        if [[ "${REPO_EXISTS}" != "true" ]]; then
            warn "[DRY-RUN] Repositório ainda não existe (será criado na 1ª execução real). Pulando simulação do backup."
            return 0
        fi
        warn "[DRY-RUN] Simulando backup. Nada será enviado ao S3."
        restic "${restic_flags[@]}" --dry-run
        return 0
    fi

    restic "${restic_flags[@]}" || die "Snapshot restic falhou."
    info "Backup restic finalizado com sucesso."

    # Captura o ID do snapshot recém-criado (para o status). Falha aqui não é
    # crítica — é só metadado de monitoramento.
    STATUS_SNAPSHOT_ID="$(restic snapshots latest --json 2>/dev/null \
        | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4 || true)"
}

# ---------------------------------------------------------------------------
# BACKUP SEMANAL — .tar.gz por aplicação (dia configurável ou FORCE_ARCHIVE)
# ---------------------------------------------------------------------------

run_weekly_app_archives() {
    if [[ "${ENABLE_WEEKLY_ARCHIVES}" != "true" ]]; then
        info "Arquivos compactados semanais desativados (ENABLE_WEEKLY_ARCHIVES != true)."
        return 0
    fi

    local today_dow
    today_dow="$(date +%w)"

    if [[ "${today_dow}" != "${ARCHIVE_DAY}" ]] && [[ "${FORCE_ARCHIVE:-false}" != "true" ]]; then
        info "Backup compactado semanal pulado. Configurado para o dia ${ARCHIVE_DAY} (hoje: ${today_dow})."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[DRY-RUN] Pulando geração dos compactados semanais."
        return 0
    fi

    require_cmd aws "apt install awscli -y (ou use o instalador oficial da AWS)." || {
        warn "aws cli não encontrado. Pulando compactados semanais."
        return 0
    }

    STATUS_ARCHIVE_RAN="true"

    local today base_s3_path
    today="$(date '+%Y-%m-%d')"
    base_s3_path="s3://${S3_BUCKET}/${ARCHIVE_S3_PREFIX}/${S3_PREFIX}/${today}"

    info "Iniciando backup compactado semanal por aplicação."
    info "Destino S3: ${base_s3_path}"

    # Dumps dos bancos.
    if [[ -d "${DB_DUMP_DIR}" ]]; then
        info "Gerando arquivo compactado dos dumps dos bancos."
        set +e
        tar -czf - -C "$(dirname "${DB_DUMP_DIR}")" "$(basename "${DB_DUMP_DIR}")" 2>>"${LOG_FILE}" \
            | aws s3 cp - "${base_s3_path}/databases-all.tar.gz" \
                --region "${AWS_DEFAULT_REGION}" >>"${LOG_FILE}" 2>&1
        # Captura o array inteiro de uma vez: qualquer atribuição intermediária
        # (ex.: `local x=${PIPESTATUS[0]}`) reseta PIPESTATUS.
        local rc=("${PIPESTATUS[@]}")
        set -e
        if (( rc[0] != 0 || rc[1] != 0 )); then
            warn "Falha ao gerar/enviar databases-all.tar.gz (tar=${rc[0]}, aws=${rc[1]})."
        fi
    else
        warn "Diretório de dumps não encontrado: ${DB_DUMP_DIR}"
    fi

    # Aplicações RunCloud: /home/usuario/webapps/app
    local app_count=0 fail_count=0
    while IFS= read -r app_path; do
        [[ -z "${app_path}" ]] && continue
        [[ ! -d "${app_path}" ]] && continue

        local app_name owner_name s3_file
        app_name="$(basename "${app_path}")"
        owner_name="$(basename "$(dirname "$(dirname "${app_path}")")")"  # /home/<owner>/webapps/<app>
        s3_file="${base_s3_path}/${owner_name}-${app_name}.tar.gz"

        info "Compactando: ${app_path} → ${s3_file}"

        set +e
        tar -czf - \
            --exclude="wp-content/cache" \
            --exclude="wp-content/upgrade" \
            --exclude="wp-content/ai1wm-backups" \
            --exclude="wp-content/updraft" \
            --exclude="wp-content/backups-dup-lite" \
            --exclude="wp-content/wpvividbackups" \
            --exclude="node_modules" \
            --exclude=".git" \
            -C "$(dirname "${app_path}")" "${app_name}" 2>>"${LOG_FILE}" \
            | aws s3 cp - "${s3_file}" \
                --region "${AWS_DEFAULT_REGION}" >>"${LOG_FILE}" 2>&1
        local rc=("${PIPESTATUS[@]}")
        set -e

        if (( rc[0] == 0 && rc[1] == 0 )); then
            app_count=$((app_count + 1))
        else
            warn "Falha ao compactar/enviar: ${app_path} (tar=${rc[0]}, aws=${rc[1]})"
            status_add_error "archive falhou: ${owner_name}-${app_name} (tar=${rc[0]}, aws=${rc[1]})"
            fail_count=$((fail_count + 1))
        fi
    done < <(find "${BACKUP_SOURCE}" -mindepth 3 -maxdepth 3 -type d -path "${BACKUP_SOURCE}/*/webapps/*" | sort)

    STATUS_ARCHIVE_APPS_OK=${app_count}
    STATUS_ARCHIVE_APPS_FAIL=${fail_count}

    info "Backup compactado semanal finalizado: ${app_count} aplicação(ões) OK, ${fail_count} falha(s)."

    # NOTA: a retenção/expiração dos .tar.gz é feita por uma S3 Lifecycle Rule
    # no próprio bucket (prefixo Snapshots/, expira após N dias) — configurada
    # uma única vez pelo instalar_backup.sh. Por isso o script NÃO apaga os
    # baixáveis aqui. A variável ARCHIVE_KEEP_WEEKS fica só como referência da
    # janela desejada (o valor efetivo é o "Days" da regra de lifecycle).
}

# ---------------------------------------------------------------------------
# RETENÇÃO (restic)
# ---------------------------------------------------------------------------

run_forget() {
    info "Aplicando retenção: daily=${KEEP_DAILY}, weekly=${KEEP_WEEKLY}, monthly=${KEEP_MONTHLY}"

    local forget_flags=(
        forget
        --keep-daily   "${KEEP_DAILY}"
        --keep-weekly  "${KEEP_WEEKLY}"
        --keep-monthly "${KEEP_MONTHLY}"
        --prune
        --group-by "host,paths"
    )

    if [[ "${DRY_RUN}" == "true" ]]; then
        if [[ "${REPO_EXISTS}" != "true" ]]; then
            warn "[DRY-RUN] Repositório ainda não existe. Pulando simulação da retenção."
            return 0
        fi
        warn "[DRY-RUN] Simulando retenção."
        restic "${forget_flags[@]}" --dry-run
        return 0
    fi

    restic "${forget_flags[@]}" || warn "Falha durante forget/prune. Verifique o log."
    info "Retenção finalizada."
}

# ---------------------------------------------------------------------------
# CHECK DE INTEGRIDADE
# ---------------------------------------------------------------------------

run_check() {
    local today_dow
    today_dow="$(date +%w)"

    if [[ "${FORCE_CHECK}" == "true" ]] || [[ "${today_dow}" == "${CHECK_DAY}" ]]; then
        info "Executando check de integridade. Subset: ${CHECK_DATA_SUBSET}"

        if [[ "${DRY_RUN}" == "true" ]]; then
            warn "[DRY-RUN] Pulando check."
            return 0
        fi

        STATUS_CHECK_RAN="true"
        if ! restic check --read-data-subset="${CHECK_DATA_SUBSET}"; then
            warn "restic check encontrou problemas. Rode 'restic check --read-data' completo se necessário."
            status_add_error "restic check encontrou problemas"
        fi

        info "Check finalizado."
    else
        info "Check pulado. Configurado para o dia da semana: ${CHECK_DAY} (hoje: ${today_dow})"
    fi
}

# ---------------------------------------------------------------------------
# TESTE DE RESTORE (--test-restore)
# ---------------------------------------------------------------------------
# Restaura o snapshot mais recente para um diretório temporário, validando
# de ponta a ponta que os backups são de fato recuperáveis. Não altera nada
# no repositório nem em /home.

run_test_restore() {
    info "════════════════════════════════════════════"
    info "TESTE DE RESTORE — validando recuperabilidade"
    info "════════════════════════════════════════════"

    local latest
    latest="$(restic snapshots --json 2>>"${LOG_FILE}" \
        | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4 || true)"

    if [[ -z "${latest}" ]]; then
        die "Nenhum snapshot encontrado para testar restore."
    fi
    info "Snapshot mais recente: ${latest}"

    RESTORE_TEST_DIR="$(mktemp -d)"
    info "Restaurando amostra para: ${RESTORE_TEST_DIR}"

    # Restaura apenas um subconjunto para ser rápido: o diretório de dumps.
    # (--include limita o que é materializado; ajuste conforme necessário.)
    if ! restic restore "${latest}" \
            --target "${RESTORE_TEST_DIR}" \
            --include "${DB_DUMP_DIR}" 2>>"${LOG_FILE}"; then
        die "Falha ao restaurar amostra do snapshot ${latest}."
    fi

    # Valida que ao menos um dump foi restaurado e é um gzip íntegro.
    local restored_dump
    restored_dump="$(find "${RESTORE_TEST_DIR}" -type f -name "*.sql.gz" | head -1 || true)"

    if [[ -z "${restored_dump}" ]]; then
        warn "Nenhum dump .sql.gz na amostra restaurada (talvez não haja bancos). Validando arquivos genéricos."
        local any_file
        any_file="$(find "${RESTORE_TEST_DIR}" -type f | head -1 || true)"
        [[ -z "${any_file}" ]] && die "Restore não materializou nenhum arquivo. FALHA no teste."
        info "Arquivo restaurado com sucesso: ${any_file}"
    else
        info "Validando integridade do dump restaurado: ${restored_dump}"
        if gzip -t "${restored_dump}" 2>>"${LOG_FILE}"; then
            info "Dump restaurado e íntegro (gzip -t OK): ${restored_dump}"
        else
            die "Dump restaurado está CORROMPIDO: ${restored_dump}. FALHA no teste."
        fi
    fi

    info "════════════════════════════════════════════"
    info "TESTE DE RESTORE CONCLUÍDO COM SUCESSO ✅"
    info "════════════════════════════════════════════"
}

# ---------------------------------------------------------------------------
# RESUMO
# ---------------------------------------------------------------------------

print_summary() {
    if [[ "${DRY_RUN}" == "true" && "${REPO_EXISTS}" != "true" ]]; then
        info "Resumo pulado (repositório ainda não existe)."
        return 0
    fi
    info "Resumo dos snapshots:"
    restic snapshots --compact || true

    # Coleta métricas do repositório para o status (não crítico se falhar).
    STATUS_SNAPSHOTS_TOTAL="$(restic snapshots --json 2>/dev/null \
        | grep -o '"short_id"' | wc -l | tr -d ' ' || true)"
    STATUS_REPO_SIZE="$(restic stats --mode raw-data 2>/dev/null \
        | grep -i 'Total Size' | sed 's/.*:[[:space:]]*//' || true)"
}

# ---------------------------------------------------------------------------
# STATUS JSON — grava o resultado do backup localmente e no S3
# ---------------------------------------------------------------------------

# Escapa uma string para uso seguro dentro de JSON (aspas, barra, controles).
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # barra invertida primeiro
    s="${s//\"/\\\"}"   # aspas
    s="${s//$'\t'/\\t}" # tab
    s="${s//$'\r'/\\r}" # CR
    s="${s//$'\n'/\\n}" # LF
    printf '%s' "${s}"
}

# Monta o array JSON de erros a partir de STATUS_ERRORS[].
build_errors_json() {
    local out="[" first=true e
    for e in "${STATUS_ERRORS[@]+"${STATUS_ERRORS[@]}"}"; do
        [[ "${first}" == "true" ]] && first=false || out+=","
        out+="\"$(json_escape "${e}")\""
    done
    out+="]"
    printf '%s' "${out}"
}

# Grava o JSON de status. Chamada SEMPRE no final (trap), com o status derivado
# do código de saída. Grava sempre o arquivo local; tenta o S3 se possível.
# $1 = "success" | "partial" | "error"
write_status() {
    [[ "${STATUS_WRITTEN}" == "true" ]] && return 0
    STATUS_WRITTEN="true"

    # Em modo dry-run ou test-restore não faz sentido publicar status de backup.
    [[ "${DRY_RUN}" == "true" ]] && return 0
    [[ "${TEST_RESTORE}" == "true" ]] && return 0

    local overall="$1"
    local host finished_at started errors_json
    host="$(hostname -s)"
    finished_at="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    started="${STATUS_STARTED_AT:-${finished_at}}"
    errors_json="$(build_errors_json)"

    # duração em segundos (se conseguimos parsear started).
    local dur="null" s_epoch f_epoch
    s_epoch="$(date -d "${started}" +%s 2>/dev/null || echo "")"
    f_epoch="$(date -d "${finished_at}" +%s 2>/dev/null || echo "")"
    if [[ -n "${s_epoch}" && -n "${f_epoch}" ]]; then
        dur=$(( f_epoch - s_epoch ))
    fi

    local json
    json="$(cat <<JSON
{
  "host": "$(json_escape "${host}")",
  "status": "$(json_escape "${overall}")",
  "started_at": "$(json_escape "${started}")",
  "finished_at": "$(json_escape "${finished_at}")",
  "duration_seconds": ${dur},
  "databases": { "ok": ${STATUS_DB_OK}, "failed": ${STATUS_DB_FAIL} },
  "weekly_archive": { "ran": ${STATUS_ARCHIVE_RAN}, "apps_ok": ${STATUS_ARCHIVE_APPS_OK}, "apps_failed": ${STATUS_ARCHIVE_APPS_FAIL} },
  "restic_snapshot_id": "$(json_escape "${STATUS_SNAPSHOT_ID}")",
  "repo_size": "$(json_escape "${STATUS_REPO_SIZE}")",
  "snapshots_total": "$(json_escape "${STATUS_SNAPSHOTS_TOTAL}")",
  "check_ran": ${STATUS_CHECK_RAN},
  "errors": ${errors_json},
  "script_version": "$(json_escape "${STATUS_SCRIPT_VERSION}")"
}
JSON
)"

    # 1) Grava sempre o arquivo local (auditoria / fallback).
    local status_dir
    status_dir="$(dirname "${STATUS_LOCAL_FILE}")"
    [[ -d "${status_dir}" ]] || mkdir -p "${status_dir}" 2>/dev/null || true
    printf '%s\n' "${json}" > "${STATUS_LOCAL_FILE}" 2>/dev/null || true

    # 2) Tenta enviar ao S3 (só se houver aws + credenciais + bucket).
    #    Exporta as credenciais aqui também: em falha PRECOCE (ex.: restic
    #    ausente, que aborta antes de export_restic_env), as variáveis foram
    #    lidas pelo source do env mas ainda não estavam exportadas para o aws.
    if command -v aws &>/dev/null \
        && [[ -n "${S3_BUCKET}" && -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
        local s3_dest="s3://${S3_BUCKET}/${STATUS_S3_PREFIX}/${host}.json"
        if printf '%s\n' "${json}" | aws s3 cp - "${s3_dest}" \
            --content-type "application/json" \
            --region "${AWS_DEFAULT_REGION}" &>/dev/null; then
            info "Status publicado no S3: ${s3_dest}"
        else
            warn "Não foi possível publicar o status no S3 (backup em si não é afetado)."
        fi
    else
        warn "Status gravado apenas localmente em ${STATUS_LOCAL_FILE} (aws/credenciais indisponíveis)."
    fi
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main() {
    # Marca o início o quanto antes, para o status ter timestamp mesmo se algo
    # falhar já no carregamento do env.
    STATUS_STARTED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"

    # Carrega o env PRIMEIRO: ele pode redefinir LOG_FILE e LOCK_FILE, que são
    # usados logo abaixo por rotate_log e acquire_lock.
    load_env_file

    rotate_log
    acquire_lock

    info "════════════════════════════════════════════"
    info "Backup iniciado | host: $(hostname -s) | data: $(date '+%Y-%m-%d %H:%M:%S')"
    info "════════════════════════════════════════════"

    [[ "${DRY_RUN}" == "true" ]] && warn "Modo DRY-RUN ativo."

    validate_env
    export_restic_env
    build_mysql_defaults_file

    notify_start

    # Modo teste de restore: valida e sai, sem rodar o backup.
    if [[ "${TEST_RESTORE}" == "true" ]]; then
        run_test_restore
        notify_success
        exit 0
    fi

    build_exclude_file
    init_repo_if_needed
    dump_databases
    run_backup
    run_weekly_app_archives
    run_forget
    run_check
    print_summary

    info "════════════════════════════════════════════"
    info "Backup finalizado | host: $(hostname -s) | data: $(date '+%Y-%m-%d %H:%M:%S')"
    info "════════════════════════════════════════════"

    notify_success
}

main
BACKUP_SCRIPT_EOF
    chmod +x "${SCRIPT_DEST}"
    bash -n "${SCRIPT_DEST}" || die "Script de backup gerado com erro de sintaxe."

    cat > "${RR_DEST}" << 'RR_SCRIPT_EOF'
#!/bin/bash
# =============================================================================
# rr — wrapper do restic que carrega /etc/restic/env automaticamente
# RunCloud / CIPNET
#
# Em vez de colar 3 linhas de export toda vez, use:
#   rr snapshots
#   rr restore latest --target /tmp/restauracao
#   rr check --read-data-subset=10%
#   rr stats
#
# Instalar (uma vez por servidor, como root):
#   curl -fsSL https://raw.githubusercontent.com/guidfarias/vm-setup-script/master/rr.sh -o /usr/local/bin/rr
#   chmod +x /usr/local/bin/rr
# =============================================================================

set -euo pipefail

RESTIC_ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/env}"

if [[ ! -f "${RESTIC_ENV_FILE}" ]]; then
    echo "rr: arquivo de configuração não encontrado: ${RESTIC_ENV_FILE}" >&2
    exit 1
fi

# Carrega as variáveis (bucket, senha, região, prefixo).
# shellcheck source=/dev/null
source "${RESTIC_ENV_FILE}"

# Exporta o que o restic precisa para falar com o S3 e abrir o repositório.
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION RESTIC_PASSWORD
export RESTIC_REPOSITORY="s3:s3.${AWS_DEFAULT_REGION}.amazonaws.com/${S3_BUCKET}/${RESTIC_S3_PREFIX}"

# Sem argumentos: mostra um resumo útil em vez de erro.
if [[ $# -eq 0 ]]; then
    echo "rr — wrapper do restic (repositório: ${RESTIC_REPOSITORY})"
    echo
    echo "Exemplos:"
    echo "  rr snapshots"
    echo "  rr restore latest --target /tmp/restauracao"
    echo "  rr restore latest --include '/home/USER/webapps/SITE' --target /tmp/restauracao"
    echo "  rr check --read-data-subset=10%"
    echo "  rr stats"
    echo "  rr help                 # ajuda completa do restic"
    exit 0
fi

# Repassa TODOS os argumentos para o restic real.
exec restic "$@"
RR_SCRIPT_EOF
    chmod +x "${RR_DEST}"
    bash -n "${RR_DEST}" || die "Wrapper rr gerado com erro de sintaxe."

    log_info "Scripts instalados e validados (bash -n OK)."
}

backup_create_env_template() {
    log_info "Configurando ${ENV_FILE}..."
    mkdir -p "${ENV_DIR}"
    chmod 700 "${ENV_DIR}"

    if [[ -f "${ENV_FILE}" ]]; then
        log_warn "${ENV_FILE} já existe — NÃO será sobrescrito (preserva credenciais)."
        chmod 600 "${ENV_FILE}"
        chown root:root "${ENV_FILE}"
        return 0
    fi

    cat > "${ENV_FILE}" << 'ENVTEMPLATE'
# /etc/restic/env — PREENCHA os valores marcados com SUA_... e SENHA...
# Senhas: use ASPAS SIMPLES ' ' (protege $ * espaço). Ver USO.md.

AWS_ACCESS_KEY_ID='SUA_ACCESS_KEY'
AWS_SECRET_ACCESS_KEY='SUA_SECRET_KEY'
AWS_DEFAULT_REGION='us-east-1'

S3_BUCKET='runcloud-backup-cipcloud'
S3_PREFIX="$(hostname -s)"
RESTIC_S3_PREFIX="Restic/$(hostname -s)"
RESTIC_PASSWORD='SUA_SENHA_RESTIC_FORTE'

BACKUP_SOURCE='/home'
DB_DUMP_DIR='/home/backups/db'

MYSQL_USER='root'
MYSQL_PASSWORD='SENHA_ROOT_DO_BANCO_AQUI'
MYSQL_HOST='localhost'

KEEP_DAILY='5'
KEEP_WEEKLY='4'
KEEP_MONTHLY='4'

ENABLE_WEEKLY_ARCHIVES='true'
ARCHIVE_DAY='5'
ARCHIVE_S3_PREFIX='Snapshots'
ARCHIVE_KEEP_WEEKS='1'

# 1 = segunda. Não use 0 (domingo): o cron roda apenas seg-sex.
CHECK_DAY='1'
CHECK_DATA_SUBSET='10%'

MIN_FREE_MB='2048'
LOG_FILE='/var/log/restic-backup.log'

# HEALTHCHECK_URL='https://hc-ping.com/SEU-UUID'
ENVTEMPLATE

    chmod 600 "${ENV_FILE}"
    chown root:root "${ENV_FILE}"
    log_warn "Template criado em ${ENV_FILE}. EDITE-O AGORA: nano ${ENV_FILE}"
    ENV_IS_TEMPLATE=true
}

backup_configure_cron() {
    log_info "Configurando cron em ${CRON_FILE}..."
    cat > "${CRON_FILE}" << EOF
# Backup restic + tar.gz → S3. Gerado por setup-vps.sh.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
${CRON_SCHEDULE} root ${SCRIPT_DEST} >> ${CRON_LOG} 2>&1
EOF
    chmod 644 "${CRON_FILE}"
}

backup_apply_lifecycle() {
    if [[ "${APPLY_LIFECYCLE}" != "true" ]]; then
        log_info "Lifecycle desativado por --no-lifecycle."
        return 0
    fi
    if [[ "${ENV_IS_TEMPLATE}" == "true" ]]; then
        log_warn "Lifecycle PULADO: ${ENV_FILE} ainda é template (sem credenciais reais)."
        log_warn "Depois de preencher o env, rode: sudo bash $0 backup --skip-run"
        return 0
    fi

    log_info "Aplicando S3 Lifecycle (expira Snapshots/ após ${LIFECYCLE_DAYS} dias)..."
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

    local lifecycle_json="/tmp/lifecycle-restic.json"
    cat > "${lifecycle_json}" << EOF
{
  "Rules": [
    {
      "ID": "delete-snapshots-after-${LIFECYCLE_DAYS}-days",
      "Status": "Enabled",
      "Filter": { "Prefix": "${ARCHIVE_S3_PREFIX:-Snapshots}/" },
      "Expiration": { "Days": ${LIFECYCLE_DAYS} }
    }
  ]
}
EOF
    if aws s3api put-bucket-lifecycle-configuration \
        --bucket "${S3_BUCKET}" \
        --lifecycle-configuration "file://${lifecycle_json}" \
        --region "${AWS_DEFAULT_REGION}"; then
        log_info "Lifecycle aplicada ao bucket ${S3_BUCKET}."
    else
        log_warn "Falha ao aplicar lifecycle (verifique credenciais/permissões)."
    fi
    rm -f "${lifecycle_json}"
}

backup_run_first() {
    if [[ "${ENV_IS_TEMPLATE}" == "true" ]]; then
        log_warn "Primeiro backup PULADO: preencha ${ENV_FILE} primeiro."
        return 0
    fi

    local do_run="${RUN_FIRST_BACKUP}"
    if [[ "${do_run}" == "ask" ]]; then
        echo -ne "${YELLOW}Rodar o primeiro backup agora? [s/N]: ${NC}"
        read -r ans || true
        [[ "${ans}" =~ ^[SsYy]$ ]] && do_run="yes" || do_run="no"
    fi

    if [[ "${do_run}" == "yes" ]]; then
        log_info "Executando primeiro backup (pode demorar)..."
        FORCE_ARCHIVE=true "${SCRIPT_DEST}" || log_warn "O primeiro backup retornou erro — revise ${CRON_LOG} e /var/log/restic-backup.log"
    else
        log_info "Primeiro backup não executado. Rode manualmente quando quiser:"
        log_info "  FORCE_ARCHIVE=true ${SCRIPT_DEST}"
    fi
}

print_backup_summary() {
    echo
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}BACKUP CONFIGURADO${NC}"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "Script:  ${CYAN}${SCRIPT_DEST}${NC}"
    echo -e "Env:     ${CYAN}${ENV_FILE}${NC}"
    echo -e "Cron:    ${CYAN}${CRON_FILE} (seg-sex 02:30)${NC}"
    echo -e "Wrapper: ${CYAN}rr snapshots${NC}"
    echo

    if [[ "${ENV_IS_TEMPLATE}" == "true" ]]; then
        echo -e "${YELLOW}⚠ AÇÃO NECESSÁRIA:${NC}"
        echo -e "   1. nano ${ENV_FILE}   (preencha as credenciais)"
        echo -e "   2. sudo bash $0 backup   (aplica lifecycle e roda o 1º backup)"
    else
        echo -e "Testar restauração:  ${CYAN}${SCRIPT_DEST} --test-restore${NC}"
        echo -e "Restaurar (menu):    ${CYAN}sudo restic-restore.sh${NC} (ver USO.md para instalar)"
    fi
    echo
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log_info "=== setup-vps.sh — $(hostname -s) ==="

    [[ "${RUN_SETUP}"  == "true" ]] && step_setup
    [[ "${RUN_BACKUP}" == "true" ]] && step_backup

    if [[ "${RUN_SETUP}" == "true" ]]; then
        echo
        log_warn "Recomenda-se reiniciar o servidor para aplicar tudo (timezone, locale)."
        echo -n "Deseja reiniciar agora? [Sim/Nao]: "
        read -r reboot_confirm || true
        if [[ "${reboot_confirm}" == "Sim" ]]; then
            log_info "Reiniciando servidor..."
            reboot
        else
            log_warn "Lembre-se de reiniciar manualmente: sudo reboot"
        fi
    fi
}

main
