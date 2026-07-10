#!/bin/bash
# =============================================================================
# instalar_backup_pg.sh — Instalador da solução de backup (restic + tar.gz → S3)
# CIPNET — variante para servidores com sites em /var/www e banco POSTGRESQL
#
# Para servidores RunCloud/MySQL use o instalar_backup.sh (variante original).
#
# Roda UMA vez por servidor. Faz tudo que antes era manual:
#   1. Verifica utilitários (gzip, tar, bzip2, unzip, curl) e cliente PostgreSQL
#      (pg_dump/psql/pg_dumpall/pg_restore); instala 'postgresql-client' se
#      faltar. Mostra os clusters existentes e os bancos de cada um.
#   2. Instala AWS CLI v2 (instalador oficial)
#   3. Instala restic ${RESTIC_VERSION} (versão fixada e testada)
#   4. Baixa o restic-backup.sh (variante PostgreSQL), o wrapper 'rr' e o
#      restic-restore.sh (restauração interativa) para /usr/local/bin/
#   5. Cria /etc/restic/env a partir de template com as portas dos clusters
#      detectadas. NÃO sobrescreve um env já preenchido; um env que ainda é
#      template sem credenciais (ex.: criado por engano pelo instalador MySQL)
#      É substituído, com cópia .bak.
#   6. Configura o cron em /etc/cron.d/restic-backup
#   7. (Opcional) Aplica a S3 Lifecycle Rule que expira os .tar.gz
#   8. (Opcional) Roda o primeiro backup de teste
#
# É IDEMPOTENTE: pode rodar de novo com segurança.
#
# Uso:
#   sudo bash instalar_backup_pg.sh                 # instala tudo, pergunta no fim
#   sudo bash instalar_backup_pg.sh --no-lifecycle  # não aplica a regra de S3
#   sudo bash instalar_backup_pg.sh --run-now       # roda 1º backup sem perguntar
#   sudo bash instalar_backup_pg.sh --skip-run      # não roda o 1º backup
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# PARÂMETROS DA INSTALAÇÃO (ajuste aqui se precisar)
# ---------------------------------------------------------------------------

RESTIC_VERSION="0.17.3"
GITHUB_RAW="https://raw.githubusercontent.com/guidfarias/vm-setup-script/master/configura_backup_pg.sh"
GITHUB_RAW_RR="https://raw.githubusercontent.com/guidfarias/vm-setup-script/master/rr.sh"
GITHUB_RAW_RESTORE="https://raw.githubusercontent.com/guidfarias/vm-setup-script/master/restaurar_backup.sh"

SCRIPT_DEST="/usr/local/bin/restic-backup.sh"
RR_DEST="/usr/local/bin/rr"
RESTORE_DEST="/usr/local/bin/restic-restore.sh"
ENV_DIR="/etc/restic"
ENV_FILE="${ENV_DIR}/env"
CRON_FILE="/etc/cron.d/restic-backup"
CRON_LOG="/var/log/restic-cron.log"

# Agendamento do cron: seg-sex às 02:30. Ajuste se quiser.
CRON_SCHEDULE="30 2 * * 1-5"

# Dias de retenção dos .tar.gz baixáveis (regra de lifecycle no S3).
LIFECYCLE_DAYS="30"

APPLY_LIFECYCLE=true
RUN_FIRST_BACKUP="ask"   # ask | yes | no

# ---------------------------------------------------------------------------
# CORES / LOG
# ---------------------------------------------------------------------------

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error() { echo -e "${RED}[ERRO]${NC} $1"; }
log_step()  { echo; echo -e "${CYAN}==> $1${NC}"; }

die() { log_error "$1"; exit 1; }

# ---------------------------------------------------------------------------
# ARGUMENTOS
# ---------------------------------------------------------------------------

for arg in "$@"; do
    case "${arg}" in
        --no-lifecycle) APPLY_LIFECYCLE=false ;;
        --run-now)      RUN_FIRST_BACKUP="yes" ;;
        --skip-run)     RUN_FIRST_BACKUP="no" ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -40
            exit 0
            ;;
        *) die "Argumento desconhecido: ${arg}" ;;
    esac
done

# ---------------------------------------------------------------------------
# PRÉ-CHECAGENS
# ---------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Este instalador precisa ser executado como root (use: sudo bash $0)."

# Detecta arquitetura para baixar o binário certo do restic.
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64|amd64) RESTIC_ARCH="amd64" ;;
    aarch64|arm64) RESTIC_ARCH="arm64" ;;
    *) die "Arquitetura não suportada: ${ARCH}" ;;
esac
log_info "Arquitetura detectada: ${ARCH} → restic_${RESTIC_ARCH}"

# ---------------------------------------------------------------------------
# DETECÇÃO DOS CLUSTERS POSTGRESQL
# ---------------------------------------------------------------------------

# Portas dos clusters ONLINE, separadas por espaço (fallback: 5432).
detect_pg_ports() {
    local ports=""
    if command -v pg_lsclusters &>/dev/null; then
        ports="$(pg_lsclusters -h 2>/dev/null | awk '$4 ~ /online/ {print $3}' \
                 | sort -n | tr '\n' ' ' | sed 's/ *$//')"
    fi
    echo "${ports:-5432}"
}

# Mostra os clusters e os bancos de cada um — ajuda a identificar qual cluster
# está de fato em uso (comum ter um cluster vazio sobrando de upgrade do pgdg).
show_pg_clusters() {
    command -v pg_lsclusters &>/dev/null || return 0
    echo
    log_info "Clusters PostgreSQL neste servidor:"
    pg_lsclusters || true
    local port dbs
    for port in $(detect_pg_ports); do
        dbs="$(sudo -n -u postgres psql -X -p "${port}" -Atqc \
            "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY datname;" \
            2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true)"
        log_info "  porta ${port}: bancos de usuário → ${dbs:-<nenhum — cluster vazio>}"
    done
    echo
    log_warn "Confira acima qual cluster tem os bancos reais. Depois ajuste PG_PORTS"
    log_warn "no ${ENV_FILE} — clusters vazios podem ficar de fora."
}

# ---------------------------------------------------------------------------
# 1. DEPENDÊNCIAS DO SISTEMA
# ---------------------------------------------------------------------------

install_system_packages() {
    log_step "1/8 — Verificando pacotes do sistema"
    export DEBIAN_FRONTEND=noninteractive

    ensure_pg_client
    show_pg_clusters

    # Utilitários necessários → pacote que os fornece.
    # Para estes utilitários o nome do comando == nome do pacote no apt.
    local util_cmds="gzip tar bzip2 unzip curl"
    local missing=()
    local cmd
    for cmd in ${util_cmds}; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    # ca-certificates não tem um binário próprio; verifica pelo dpkg.
    if ! dpkg -s ca-certificates &>/dev/null; then
        missing+=("ca-certificates")
    fi

    if (( ${#missing[@]} == 0 )); then
        log_info "Todos os utilitários já presentes. Nenhuma instalação de pacote necessária."
        return 0
    fi

    log_info "Instalando utilitários faltantes: ${missing[*]}"
    apt-get update -y || log_warn "apt-get update falhou (seguindo mesmo assim)."
    apt-get install -y "${missing[@]}" \
        || die "Falha ao instalar utilitários: ${missing[*]}"
    log_info "Utilitários instalados."
}

# Garante o cliente PostgreSQL (pg_dump, psql, pg_dumpall, pg_restore).
# Em servidores que já rodam o Postgres (caso normal), os binários já existem
# junto com o pacote do servidor — não instala nada.
ensure_pg_client() {
    if command -v pg_dump &>/dev/null && command -v psql &>/dev/null \
        && command -v pg_dumpall &>/dev/null && command -v pg_restore &>/dev/null; then
        log_info "Cliente PostgreSQL já presente ($(command -v pg_dump))."
    else
        log_warn "Cliente PostgreSQL (pg_dump/psql) ausente. Instalando 'postgresql-client'."
        apt-get update -y || log_warn "apt-get update falhou (seguindo mesmo assim)."
        apt-get install -y postgresql-client \
            || die "Falha ao instalar postgresql-client. Instale manualmente: apt-get install -y postgresql-client"
        command -v pg_dump &>/dev/null \
            || die "pg_dump ainda ausente após instalação. Verifique manualmente."
        log_info "Cliente PostgreSQL instalado: $(command -v pg_dump)"
    fi

    # pg_dump precisa ser >= versão do cluster mais novo (dump de cluster mais
    # novo com cliente antigo falha). NÃO usa `pg_dump --version` para checar:
    # o wrapper /usr/bin/pg_dump escolhe a versão pelo cluster da porta 5432 e
    # engana. Compara a versão mais nova INSTALADA em /usr/lib/postgresql — que
    # é a que o script de backup usa automaticamente.
    if command -v pg_lsclusters &>/dev/null; then
        local newest cli
        newest="$(pg_lsclusters -h 2>/dev/null | awk '{print $1}' | sort -V | tail -1)"
        cli="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 \
               | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)"
        [[ -n "${cli}" ]] || cli="$(pg_dump --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
        if [[ -n "${newest}" && -n "${cli}" ]] \
            && [[ "$(printf '%s\n%s\n' "${cli}" "${newest}" | sort -V | tail -1)" != "${cli}" ]]; then
            log_warn "Cliente PostgreSQL mais novo instalado é ${cli}, mas há cluster versão ${newest}."
            log_warn "Instale: apt-get install -y postgresql-client-${newest}"
        else
            log_info "Cliente PostgreSQL ${cli} cobre todos os clusters (o backup usa a versão mais nova instalada)."
        fi
    fi
}

# ---------------------------------------------------------------------------
# 2. AWS CLI v2
# ---------------------------------------------------------------------------

install_awscli() {
    log_step "2/8 — Instalando AWS CLI v2"
    if command -v aws &>/dev/null && aws --version 2>&1 | grep -q "aws-cli/2"; then
        log_info "AWS CLI v2 já instalado ($(aws --version 2>&1)). Pulando."
        return 0
    fi

    local awszip="/tmp/awscliv2.zip"
    local awsurl
    case "${RESTIC_ARCH}" in
        amd64) awsurl="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
        arm64) awsurl="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
    esac

    curl -fsSL "${awsurl}" -o "${awszip}" || die "Falha ao baixar o AWS CLI."
    rm -rf /tmp/aws
    unzip -q "${awszip}" -d /tmp/ || die "Falha ao descompactar o AWS CLI."
    # --update torna a reinstalação idempotente.
    /tmp/aws/install --update || die "Falha ao instalar o AWS CLI."
    rm -rf /tmp/aws "${awszip}"
    log_info "AWS CLI instalado: $(aws --version 2>&1)"
}

# ---------------------------------------------------------------------------
# 3. RESTIC (versão fixada)
# ---------------------------------------------------------------------------

install_restic() {
    log_step "3/8 — Instalando restic ${RESTIC_VERSION}"
    if command -v restic &>/dev/null && restic version 2>/dev/null | grep -q "restic ${RESTIC_VERSION}"; then
        log_info "restic ${RESTIC_VERSION} já instalado. Pulando."
        return 0
    fi

    local url="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${RESTIC_ARCH}.bz2"
    local tmp="/tmp/restic_${RESTIC_VERSION}.bz2"

    curl -fsSL "${url}" -o "${tmp}" || die "Falha ao baixar o restic de ${url}"
    bunzip2 -f "${tmp}" || die "Falha ao descompactar o restic."
    mv "/tmp/restic_${RESTIC_VERSION}" /usr/local/bin/restic
    chmod +x /usr/local/bin/restic
    log_info "restic instalado: $(restic version 2>&1 | head -1)"
}

# ---------------------------------------------------------------------------
# 4. SCRIPT DE BACKUP (variante PostgreSQL)
# ---------------------------------------------------------------------------

install_backup_script() {
    log_step "4/8 — Baixando o script de backup (PostgreSQL)"
    curl -fsSL "${GITHUB_RAW}" -o "${SCRIPT_DEST}" \
        || die "Falha ao baixar o script de ${GITHUB_RAW}"
    chmod +x "${SCRIPT_DEST}"
    bash -n "${SCRIPT_DEST}" || die "O script baixado tem erro de sintaxe. Abortando."
    log_info "Script instalado em ${SCRIPT_DEST} (sintaxe OK)."

    # Wrapper 'rr': permite rodar 'rr snapshots' sem exportar variáveis à mão.
    if curl -fsSL "${GITHUB_RAW_RR}" -o "${RR_DEST}" && bash -n "${RR_DEST}"; then
        chmod +x "${RR_DEST}"
        log_info "Wrapper 'rr' instalado em ${RR_DEST} (use: rr snapshots)."
    else
        log_warn "Não foi possível instalar o wrapper 'rr' (não crítico)."
        rm -f "${RR_DEST}"
    fi

    # Restauração interativa: menu para restaurar arquivos, sites e bancos.
    if curl -fsSL "${GITHUB_RAW_RESTORE}" -o "${RESTORE_DEST}" && bash -n "${RESTORE_DEST}"; then
        chmod +x "${RESTORE_DEST}"
        log_info "Restauração interativa instalada em ${RESTORE_DEST} (use: sudo restic-restore.sh)."
    else
        log_warn "Não foi possível instalar o restic-restore.sh (não crítico)."
        rm -f "${RESTORE_DEST}"
    fi
}

# ---------------------------------------------------------------------------
# 5. ARQUIVO DE VARIÁVEIS (/etc/restic/env)
# ---------------------------------------------------------------------------

create_env_template() {
    log_step "5/8 — Configurando ${ENV_FILE}"
    mkdir -p "${ENV_DIR}"
    chmod 700 "${ENV_DIR}"

    if [[ -f "${ENV_FILE}" ]]; then
        if grep -q "SUA_ACCESS_KEY" "${ENV_FILE}"; then
            # Ainda é template sem credenciais (ex.: criado por engano pelo
            # instalador MySQL) — pode substituir com segurança.
            local bak
            bak="${ENV_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
            cp -p "${ENV_FILE}" "${bak}"
            log_warn "Env existente ainda é um template sem credenciais — substituindo"
            log_warn "pelo template PostgreSQL (cópia do antigo em ${bak})."
        else
            log_warn "${ENV_FILE} já existe com credenciais — NÃO será sobrescrito."
            chmod 600 "${ENV_FILE}"
            chown root:root "${ENV_FILE}"
            if ! grep -q "^PG_PORTS=" "${ENV_FILE}"; then
                log_warn "⚠  Este env não tem PG_PORTS (veio da variante MySQL?). Ajuste-o:"
                log_warn "   PG_PORTS='$(detect_pg_ports)'  |  BACKUP_SOURCE='/var/www'  |  DB_DUMP_DIR='/var/backups/db'"
            fi
            return 0
        fi
    fi

    local detected_ports
    detected_ports="$(detect_pg_ports)"

    # Cria o template. IMPORTANTE: senhas com ASPAS SIMPLES (o script faz
    # `source` com set -u; $ dentro de aspas duplas quebraria o backup).
    cat > "${ENV_FILE}" << 'ENVTEMPLATE'
# /etc/restic/env — PREENCHA os valores marcados com SUA_... e SEU_...
# Senhas: use ASPAS SIMPLES ' ' (protege $ * espaço). Ver README.

AWS_ACCESS_KEY_ID='SUA_ACCESS_KEY'
AWS_SECRET_ACCESS_KEY='SUA_SECRET_KEY'
AWS_DEFAULT_REGION='us-east-1'

S3_BUCKET='SEU_BUCKET_S3'
S3_PREFIX="$(hostname -s)"
RESTIC_S3_PREFIX="Restic/$(hostname -s)"
RESTIC_PASSWORD='SUA_SENHA_RESTIC_FORTE'

BACKUP_SOURCE='/var/www'
DB_DUMP_DIR='/var/backups/db'

# Portas dos clusters PostgreSQL a dumpar (separadas por espaço). O instalador
# preencheu com os clusters ONLINE detectados; confira com 'pg_lsclusters'
# qual tem os bancos reais e remova daqui os clusters vazios, se quiser.
PG_PORTS='__PG_PORTS__'
# PG_PASSWORD vazio → autenticação peer via sudo -u postgres (padrão do
# Ubuntu/Debian, recomendado). Se preencher, conecta via TCP em PG_HOST.
PG_USER='postgres'
PG_PASSWORD=''
PG_HOST='localhost'

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

    # Injeta as portas detectadas (heredoc é quoted para preservar o
    # "$(hostname -s)" literal, então a substituição é feita aqui).
    sed -i "s/__PG_PORTS__/${detected_ports}/" "${ENV_FILE}"

    chmod 600 "${ENV_FILE}"
    chown root:root "${ENV_FILE}"
    log_warn "Template criado em ${ENV_FILE} (PG_PORTS='${detected_ports}')."
    log_warn "EDITE-O AGORA e preencha as credenciais reais:  nano ${ENV_FILE}"
    ENV_IS_TEMPLATE=true
}

# ---------------------------------------------------------------------------
# 6. CRON (/etc/cron.d/restic-backup)
# ---------------------------------------------------------------------------

configure_cron() {
    log_step "6/8 — Configurando cron em ${CRON_FILE}"
    # /etc/cron.d exige o campo de usuário (root). PATH garante restic/aws no PATH.
    cat > "${CRON_FILE}" << EOF
# Backup restic + tar.gz → S3 (/var/www + PostgreSQL, CIPNET). Gerado por instalar_backup_pg.sh.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
${CRON_SCHEDULE} root ${SCRIPT_DEST} >> ${CRON_LOG} 2>&1
EOF
    chmod 644 "${CRON_FILE}"
    log_info "Cron configurado: '${CRON_SCHEDULE}' (seg-sex 02:30) → ${CRON_LOG}"
}

# ---------------------------------------------------------------------------
# 7. LIFECYCLE S3 (expira os .tar.gz baixáveis)
# ---------------------------------------------------------------------------

apply_lifecycle() {
    log_step "7/8 — Aplicando S3 Lifecycle (expira Snapshots/ após ${LIFECYCLE_DAYS} dias)"

    if [[ "${APPLY_LIFECYCLE}" != "true" ]]; then
        log_info "Lifecycle desativado por --no-lifecycle. Pulando."
        return 0
    fi
    if [[ "${ENV_IS_TEMPLATE:-false}" == "true" ]]; then
        log_warn "Lifecycle PULADO: ${ENV_FILE} ainda é template (sem credenciais reais)."
        log_warn "Depois de preencher o env, rode:  sudo bash $0 --skip-run"
        return 0
    fi

    # Carrega credenciais só para esta operação.
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
        log_info "Lifecycle aplicada ao bucket ${S3_BUCKET} (prefixo ${ARCHIVE_S3_PREFIX:-Snapshots}/, ${LIFECYCLE_DAYS} dias)."
    else
        log_warn "Falha ao aplicar lifecycle. Verifique credenciais/permissões (s3:PutLifecycleConfiguration)."
    fi
    rm -f "${lifecycle_json}"
}

# ---------------------------------------------------------------------------
# 8. PRIMEIRO BACKUP
# ---------------------------------------------------------------------------

run_first_backup() {
    log_step "8/8 — Primeiro backup"

    if [[ "${ENV_IS_TEMPLATE:-false}" == "true" ]]; then
        log_warn "Primeiro backup PULADO: preencha ${ENV_FILE} primeiro."
        return 0
    fi

    local do_run="${RUN_FIRST_BACKUP}"
    if [[ "${do_run}" == "ask" ]]; then
        echo -ne "${YELLOW}Rodar o primeiro backup agora (FORCE_ARCHIVE=true)? [s/N]: ${NC}"
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

# ---------------------------------------------------------------------------
# RESUMO FINAL
# ---------------------------------------------------------------------------

print_final() {
    echo
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}INSTALAÇÃO CONCLUÍDA (variante PostgreSQL)${NC}"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "Host:        ${CYAN}$(hostname -s)${NC}"
    echo -e "restic:      ${CYAN}$(restic version 2>&1 | head -1)${NC}"
    echo -e "aws-cli:     ${CYAN}$(aws --version 2>&1)${NC}"
    echo -e "Script:      ${CYAN}${SCRIPT_DEST}${NC}"
    echo -e "Env:         ${CYAN}${ENV_FILE}${NC}"
    echo -e "Cron:        ${CYAN}${CRON_FILE} (${CRON_SCHEDULE})${NC}"
    echo -e "Clusters:    ${CYAN}PG_PORTS detectados: $(detect_pg_ports)${NC}"
    [[ -x "${RR_DEST}" ]] && echo -e "Wrapper:     ${CYAN}${RR_DEST}  (ex.: rr snapshots)${NC}"
    [[ -x "${RESTORE_DEST}" ]] && echo -e "Restauração: ${CYAN}sudo restic-restore.sh  (menu interativo)${NC}"
    echo

    if [[ "${ENV_IS_TEMPLATE:-false}" == "true" ]]; then
        echo -e "${YELLOW}⚠  AÇÃO NECESSÁRIA:${NC}"
        echo -e "   1. Edite as credenciais:   ${CYAN}nano ${ENV_FILE}${NC}"
        echo -e "      (confira também o PG_PORTS — remova clusters vazios se quiser)"
        echo -e "   2. Rode de novo p/ aplicar lifecycle e 1º backup:"
        echo -e "                               ${CYAN}sudo bash $0${NC}"
    else
        echo -e "Listar snapshots:                ${CYAN}rr snapshots${NC}"
        echo -e "Restaurar (menu interativo):     ${CYAN}sudo restic-restore.sh${NC}"
        echo -e "Teste de restore quando quiser:  ${CYAN}${SCRIPT_DEST} --test-restore${NC}"
    fi
    echo
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main() {
    log_info "=== Instalador de backup PostgreSQL (restic ${RESTIC_VERSION}) — $(hostname -s) ==="
    install_system_packages
    install_awscli
    install_restic
    install_backup_script
    create_env_template
    configure_cron
    apply_lifecycle
    run_first_backup
    print_final
}

main
