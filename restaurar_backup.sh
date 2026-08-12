#!/bin/bash
# =============================================================================
# restic-restore.sh — Restauração INTERATIVA dos backups restic (S3)
# RunCloud / CIPNET — um único script para as 3 variantes de backup:
#   - MySQL/RunCloud  (configura_backup.sh):        /home + dumps *.sql.gz
#   - PostgreSQL      (configura_backup_pg.sh):     /var/www + porta-<n>/*.dump
#   - Dokploy         (configura_backup_dokploy.sh): /etc/dokploy + volumes +
#                                                    container-<svc>/*.dump
#
# A variante NÃO precisa ser informada: o script descobre o formato pelos
# próprios dados do snapshot (layout do DB_DUMP_DIR e BACKUP_SOURCE do env).
#
# O que o menu oferece:
#   1. Listar/escolher snapshot (padrão: latest)
#   2. Restaurar arquivo ou diretório (com navegação pelo snapshot)
#   3. Restaurar site completo (webapps RunCloud, /var/www ou Dokploy)
#   4. Restaurar banco de dados (detecta .sql.gz/.dump e conduz a importação)
#   5. Pré-visualizar conteúdo do snapshot
#   6. Check rápido de integridade do repositório
#
# Segurança:
#   - Por padrão restaura em STAGING (/tmp/restauracao-<data>-<hora>) — NUNCA
#     sobrescreve produção sem confirmação digitada ("SOBRESCREVER"/"IMPORTAR").
#   - Antes de sobrescrever arquivos ou importar banco, faz backup preventivo
#     do estado atual (guardado no staging).
#   - Restauração para o local original mostra um dry-run (prévia) antes.
#   - Nunca exibe segredos; credenciais MySQL/PG vão em arquivos temporários
#     (não vazam no `ps aux`), apagados ao sair.
#   - Reusa /etc/restic/env (mesmas variáveis do backup; exige chmod 600).
#
# Uso:
#   sudo restic-restore.sh            # menu interativo
#   sudo restic-restore.sh --help
#
# Instalar manualmente (o instalar_backup*.sh já faz isso):
#   curl -fsSL https://raw.githubusercontent.com/guidfarias/vm-setup-script/master/restaurar_backup.sh \
#     -o /usr/local/bin/restic-restore.sh && chmod +x /usr/local/bin/restic-restore.sh
# =============================================================================

# NOTA: sem `set -e` de propósito — este é um script interativo com menus;
# um comando com rc != 0 (ex.: grep sem match, conexão recusada) deve gerar
# mensagem e voltar ao menu, não matar a sessão. Os erros são tratados
# explicitamente em cada operação.
set -uo pipefail

# ---------------------------------------------------------------------------
# CONFIGURAÇÃO — defaults (o /etc/restic/env sobrescreve o que definir)
# ---------------------------------------------------------------------------

RESTIC_ENV_FILE="${RESTIC_ENV_FILE:-/etc/restic/env}"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-$(hostname -s)}"
RESTIC_S3_PREFIX="${RESTIC_S3_PREFIX:-Restic/${S3_PREFIX}}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"

BACKUP_SOURCE="${BACKUP_SOURCE:-}"
DB_DUMP_DIR="${DB_DUMP_DIR:-}"

# MySQL (variante RunCloud)
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_HOST="${MYSQL_HOST:-localhost}"

# PostgreSQL local (variante PG)
PG_USER="${PG_USER:-postgres}"
PG_PASSWORD="${PG_PASSWORD:-}"
PG_HOST="${PG_HOST:-localhost}"
PG_SYSTEM_USER="${PG_SYSTEM_USER:-postgres}"
PG_BIN_DIR="${PG_BIN_DIR:-}"

# Dokploy (Postgres em containers)
DOKPLOY_PG_FILTER="${DOKPLOY_PG_FILTER:-dokploy-postgres}"
DOCKER_VOLUMES_DIR="${DOCKER_VOLUMES_DIR:-/var/lib/docker/volumes}"

MIN_FREE_MB="${MIN_FREE_MB:-2048}"
LOCK_FILE="${LOCK_FILE:-/var/run/restic-backup.lock}"

# Específicos da restauração
RESTORE_LOG_FILE="${RESTORE_LOG_FILE:-/var/log/restic-restore.log}"
RESTORE_STAGING_BASE="${RESTORE_STAGING_BASE:-/tmp/restauracao}"
# Limite de itens exibidos por diretório na navegação (diretórios gigantes).
RESTORE_LS_LIMIT="${RESTORE_LS_LIMIT:-300}"

# Protocolo JSON de navegação do HUB. Estes valores são deliberadamente fixos:
# o cliente não escolhe limite, staging ou chave de autenticação dos tokens.
readonly HUB_API_VERSION=1
readonly HUB_NAV_LIMIT=100
readonly HUB_TOKEN_KEY_FILE="/etc/restic/hub-token.key"

# Modo não-interativo (disparado pelo HUB via hub-restore-shell). Caminhos
# fixos de propósito — precisam bater exatamente com o que hub-restore-shell
# lê; um override por ambiente aqui e não lá (ou vice-versa) quebra o wrapper.
readonly HUB_JOB_LOG_DIR="/var/log/hub-restore"
readonly HUB_JOB_STATUS_DIR="/var/lib/hub-restore"

# Restauração seletiva (issue #9): staging isolado por job, expirável em 24h.
# Caminhos fixos pelo mesmo motivo dos de cima.
readonly HUB_ITEM_STAGING_DIR="/var/lib/hub-restore/items"
readonly HUB_ITEM_LOCK_FILE="/var/lib/hub-restore/.job.lock"
readonly HUB_ITEM_TTL_SECONDS=86400
JOB_ID_RE='^[A-Za-z0-9-]{1,64}$'

# ---------------------------------------------------------------------------
# ESTADO INTERNO / LIMPEZA
# ---------------------------------------------------------------------------

SNAP_ID="latest"              # snapshot em uso (mudável pelo menu 1)
STAGING_DIR=""                # criado sob demanda; NÃO é apagado ao sair
MYSQL_DEFAULTS_FILE=""        # credenciais MySQL (temporário, chmod 600)
PGPASS_FILE=""                # credenciais PG (temporário, chmod 600)
PG_USE_SUDO=false
PG_AUTH_READY=false
PSQL_BIN="psql"; PG_DUMP_BIN="pg_dump"; PG_RESTORE_BIN="pg_restore"
PG_BINS_RESOLVED=false

# Resultados de funções (bash 3 não devolve arrays; usamos globais G_*)
G_PATHS=(); G_TYPES=(); G_SIZES=()
G_SELECTED=""
G_ITEM_TYPE=""; G_ITEM_SIZE=""

cleanup() {
    # Apaga SOMENTE os arquivos temporários de credenciais. O staging com o
    # material restaurado fica — ele é o produto da restauração.
    [[ -n "${MYSQL_DEFAULTS_FILE}" ]] && rm -f "${MYSQL_DEFAULTS_FILE}"
    [[ -n "${PGPASS_FILE}" ]]        && rm -f "${PGPASS_FILE}"
    if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
        echo
        echo "Arquivos restaurados/preventivos mantidos em: ${STAGING_DIR}"
        echo "Remova quando não precisar mais: rm -rf ${STAGING_DIR}"
    fi
}
trap cleanup EXIT
trap 'echo; warn "Interrompido pelo usuário."; exit 130' INT TERM

# ---------------------------------------------------------------------------
# LOG / SAÍDA
# ---------------------------------------------------------------------------

# Cores só quando a saída é um terminal.
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; NC=""
fi

# Grava no log SEM cores; mostra na tela COM cores. Nunca loga segredos.
log_line() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local logdir
    logdir="$(dirname "${RESTORE_LOG_FILE}")"
    [[ -d "${logdir}" ]] || mkdir -p "${logdir}" 2>/dev/null || true
    if [[ -w "${logdir}" || -w "${RESTORE_LOG_FILE}" ]]; then
        echo "${ts} [${level}] $*" >> "${RESTORE_LOG_FILE}" 2>/dev/null || true
    fi
}

info()  { echo -e "${GREEN}[INFO]${NC} $*";  log_line "INFO " "$*"; }
warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; log_line "WARN " "$*"; }
error() { echo -e "${RED}[ERRO]${NC} $*" >&2; log_line "ERROR" "$*"; }
step()  { echo; echo -e "${CYAN}==> $*${NC}"; log_line "STEP " "$*"; }

die() { error "$*"; exit 1; }

hr() { echo "────────────────────────────────────────────────────────"; }

# ---------------------------------------------------------------------------
# ENTRADA DO USUÁRIO
# ---------------------------------------------------------------------------

# prompt_read <variável> <texto> [default]
# Retorna 1 em EOF (Ctrl-D) — quem chama trata como cancelamento.
prompt_read() {
    local __var="$1" __msg="$2" __def="${3:-}"
    local __ans
    if [[ -n "${__def}" ]]; then
        read -r -p "${__msg} [${__def}]: " __ans || return 1
        __ans="${__ans:-${__def}}"
    else
        read -r -p "${__msg}: " __ans || return 1
    fi
    printf -v "${__var}" '%s' "${__ans}"
    return 0
}

# ask_yes_no <texto> <default s|n>  → rc 0 = sim
ask_yes_no() {
    local msg="$1" def="${2:-n}" ans hint
    [[ "${def}" == "s" ]] && hint="S/n" || hint="s/N"
    read -r -p "${msg} [${hint}]: " ans || return 1
    ans="${ans:-${def}}"
    [[ "${ans}" =~ ^[SsYy] ]]
}

# confirm_typed <PALAVRA> — exige digitar a palavra exata (confirmação forte).
confirm_typed() {
    local word="$1" ans
    echo -e "${YELLOW}Para confirmar, digite exatamente: ${BOLD}${word}${NC}"
    read -r -p "> " ans || return 1
    if [[ "${ans}" != "${word}" ]]; then
        warn "Confirmação não confere. Operação cancelada."
        return 1
    fi
    return 0
}

pause() { read -r -p "ENTER para continuar... " _ || true; }

# ---------------------------------------------------------------------------
# PRÉ-REQUISITOS / ENV
# ---------------------------------------------------------------------------

require_root() {
    # Restaurar dono/permissões, autenticação peer do PG e ler o env exigem
    # root. RESTIC_RESTORE_ALLOW_NONROOT=1 existe SÓ para testes com mocks.
    if [[ $EUID -ne 0 && "${RESTIC_RESTORE_ALLOW_NONROOT:-0}" != "1" ]]; then
        die "Execute como root: sudo $0"
    fi
}

load_env_file() {
    if [[ ! -f "${RESTIC_ENV_FILE}" ]]; then
        die "Arquivo ${RESTIC_ENV_FILE} não encontrado. Este servidor tem o backup instalado?"
    fi

    # Mesma validação dos scripts de backup: recusa env legível por terceiros.
    local perms owner
    perms="$(stat -c '%a' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || stat -f '%Lp' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || echo '???')"
    owner="$(stat -c '%U' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || stat -f '%Su' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || echo '???')"

    if [[ "${perms}" == "???" ]]; then
        warn "Não foi possível verificar permissões de ${RESTIC_ENV_FILE}. Prosseguindo."
    elif [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
        die "Permissões inseguras em ${RESTIC_ENV_FILE} (${perms}). Corrija com: chmod 600 ${RESTIC_ENV_FILE}"
    fi
    if [[ "${owner}" != "???" && "${owner}" != "root" && "${owner}" != "$(id -un)" ]]; then
        warn "Dono de ${RESTIC_ENV_FILE} é '${owner}' (esperado root)."
    fi

    # shellcheck source=/dev/null
    source "${RESTIC_ENV_FILE}"
    info "Variáveis carregadas de ${RESTIC_ENV_FILE} (perms ${perms})."
}

validate_env() {
    command -v restic &>/dev/null || die "'restic' não encontrado. Rode o instalar_backup*.sh primeiro."
    command -v openssl &>/dev/null || die "'openssl' não encontrado. Rode o instalar_backup*.sh primeiro."
    perl -MJSON::PP -MMIME::Base64 -MEncode -MDigest::SHA -e 1 &>/dev/null \
        || die "Módulos Perl necessários à navegação segura não estão disponíveis."
    [[ -n "${AWS_ACCESS_KEY_ID}" ]]     || die "AWS_ACCESS_KEY_ID não definido no env."
    [[ -n "${AWS_SECRET_ACCESS_KEY}" ]] || die "AWS_SECRET_ACCESS_KEY não definido no env."
    [[ -n "${RESTIC_PASSWORD}" ]]       || die "RESTIC_PASSWORD não definido no env."
    [[ -n "${S3_BUCKET}" ]]             || die "S3_BUCKET não definido no env."
}

export_restic_env() {
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION RESTIC_PASSWORD
    export RESTIC_REPOSITORY="s3:s3.${AWS_DEFAULT_REGION}.amazonaws.com/${S3_BUCKET}/${RESTIC_S3_PREFIX}"
}

check_repo() {
    info "Abrindo repositório: ${RESTIC_REPOSITORY}"
    if ! restic cat config >/dev/null 2>>"${RESTORE_LOG_FILE}"; then
        die "Não foi possível abrir o repositório restic. Verifique credenciais/rede (log: ${RESTORE_LOG_FILE})."
    fi
}

# ---------------------------------------------------------------------------
# VARIANTES "SAFE" (sem die) — usadas pelo fluxo hub, onde uma falha precisa
# virar "failed <motivo>" auditável no meta.json/job.log, nunca matar o
# processo antes do handler rodar. die() faz exit direto: um `if ! fn` em
# torno da versão "die" nunca vê o erro, porque o processo já morreu dentro
# dela — por isso load_env_file/validate_env/check_repo têm cópias aqui que
# só retornam 1.
# ---------------------------------------------------------------------------

load_env_file_safe() {
    [[ -f "${RESTIC_ENV_FILE}" ]] || { error "Arquivo ${RESTIC_ENV_FILE} não encontrado."; return 1; }
    local perms
    perms="$(stat -c '%a' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || stat -f '%Lp' "${RESTIC_ENV_FILE}" 2>/dev/null \
             || echo '???')"
    if [[ "${perms}" != "???" && "${perms}" != "600" && "${perms}" != "400" ]]; then
        error "Permissões inseguras em ${RESTIC_ENV_FILE} (${perms})."
        return 1
    fi
    # shellcheck source=/dev/null
    source "${RESTIC_ENV_FILE}" || { error "Falha ao carregar ${RESTIC_ENV_FILE}."; return 1; }
    info "Variáveis carregadas de ${RESTIC_ENV_FILE} (perms ${perms})."
}

validate_env_safe() {
    command -v restic &>/dev/null || { error "'restic' não encontrado."; return 1; }
    command -v openssl &>/dev/null || { error "'openssl' não encontrado."; return 1; }
    perl -MJSON::PP -MMIME::Base64 -MEncode -MDigest::SHA -e 1 &>/dev/null \
        || { error "Módulos Perl necessários não estão disponíveis."; return 1; }
    [[ -n "${AWS_ACCESS_KEY_ID}" ]]     || { error "AWS_ACCESS_KEY_ID não definido no env."; return 1; }
    [[ -n "${AWS_SECRET_ACCESS_KEY}" ]] || { error "AWS_SECRET_ACCESS_KEY não definido no env."; return 1; }
    [[ -n "${RESTIC_PASSWORD}" ]]       || { error "RESTIC_PASSWORD não definido no env."; return 1; }
    [[ -n "${S3_BUCKET}" ]]             || { error "S3_BUCKET não definido no env."; return 1; }
    # MIN_FREE_MB entra em aritmética (( )) sob set -u mais adiante — um valor
    # não numérico no env quebraria o script no meio do fluxo hub em vez de
    # falhar aqui, cedo e com mensagem clara.
    [[ "${MIN_FREE_MB}" =~ ^[0-9]+$ ]] || { error "MIN_FREE_MB inválido no env: '${MIN_FREE_MB}'."; return 1; }
    return 0
}

check_repo_safe() {
    info "Abrindo repositório: ${RESTIC_REPOSITORY}"
    restic cat config >/dev/null 2>>"${RESTORE_LOG_FILE}" \
        || { error "Não foi possível abrir o repositório restic."; return 1; }
}

warn_if_backup_running() {
    command -v flock &>/dev/null || return 0
    [[ -e "${LOCK_FILE}" ]] || return 0
    if ! flock -n "${LOCK_FILE}" true 2>/dev/null; then
        warn "Um BACKUP parece estar em execução agora (lock: ${LOCK_FILE})."
        warn "Restaurar durante o backup funciona, mas ambos ficam mais lentos."
        ask_yes_no "Continuar mesmo assim?" "s" || exit 0
    fi
}

ensure_staging() {
    if [[ -z "${STAGING_DIR}" ]]; then
        STAGING_DIR="${RESTORE_STAGING_BASE}-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "${STAGING_DIR}" || die "Não foi possível criar o staging ${STAGING_DIR}."
        chmod 700 "${STAGING_DIR}"
        info "Diretório de staging desta sessão: ${STAGING_DIR}"
    fi
}

# Espaço livre no filesystem do destino; avisa (não bloqueia) se < MIN_FREE_MB.
check_free_space() {
    local target="$1" free_mb
    free_mb="$(df -Pm "${target}" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -n "${free_mb}" ]] && (( free_mb < MIN_FREE_MB )); then
        warn "Pouco espaço livre em ${target}: ${free_mb}MB (< ${MIN_FREE_MB}MB)."
        ask_yes_no "Continuar mesmo assim?" "n" || return 1
    fi
    return 0
}

# Variante fail-closed para o fluxo hub (sem terminal, sem prompt possível):
# df falhando ou saída vazia é tratado como falha, nunca como "sem info,
# segue"; o mínimo exigido é o maior entre MIN_FREE_MB e o tamanho do item
# (se conhecido), para não aceitar espaço que baste pro MIN_FREE_MB mas não
# caiba o item de fato.
check_free_space_fail_closed() {
    local target="$1" item_size_bytes="${2:-0}" free_mb threshold_mb item_mb
    free_mb="$(df -Pm "${target}" 2>/dev/null | awk 'NR==2 {print $4}')"
    [[ "${free_mb}" =~ ^[0-9]+$ ]] || { warn "Não foi possível medir espaço livre em ${target}."; return 1; }
    [[ "${MIN_FREE_MB}" =~ ^[0-9]+$ ]] || { warn "MIN_FREE_MB inválido: '${MIN_FREE_MB}'."; return 1; }
    threshold_mb="${MIN_FREE_MB}"
    if [[ "${item_size_bytes}" =~ ^[0-9]+$ ]] && (( item_size_bytes > 0 )); then
        item_mb=$(((item_size_bytes + 1048575) / 1048576))
        (( item_mb > threshold_mb )) && threshold_mb="${item_mb}"
    fi
    if (( free_mb < threshold_mb )); then
        warn "Pouco espaço livre em ${target}: ${free_mb}MB (< ${threshold_mb}MB necessários)."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# SNAPSHOTS
# ---------------------------------------------------------------------------

menu_snapshots() {
    step "Snapshots disponíveis"
    if ! restic snapshots --compact 2>>"${RESTORE_LOG_FILE}"; then
        error "Falha ao listar snapshots (log: ${RESTORE_LOG_FILE})."
        return 1
    fi
    echo
    local ans
    prompt_read ans "ID do snapshot a usar ('latest' = mais recente)" "${SNAP_ID}" || return 1
    if restic snapshots "${ans}" >/dev/null 2>>"${RESTORE_LOG_FILE}"; then
        SNAP_ID="${ans}"
        info "Snapshot selecionado: ${SNAP_ID}"
    else
        error "Snapshot '${ans}' não encontrado. Mantendo '${SNAP_ID}'."
    fi
}

# ---------------------------------------------------------------------------
# LISTAGEM / NAVEGAÇÃO NO SNAPSHOT
# ---------------------------------------------------------------------------

# Converte o JSON Lines oficial de `restic ls --json` em registros internos
# tipo<TAB>tamanho<TAB>caminho-base64url. O caminho continua codificado até
# chegar ao Bash, impedindo que tabs/newlines de nomes virem novos registros.
restic_ls_records() {
    local snap="$1" path="$2" raw
    raw="$(mktemp)" || return 1
    if ! restic ls --json "${snap}" "${path}" >"${raw}" 2>>"${RESTORE_LOG_FILE}"; then
        rm -f "${raw}"
        return 1
    fi
    perl -MJSON::PP=decode_json -MMIME::Base64=encode_base64 -MEncode=encode_utf8 -e '
        while (my $line = <>) {
            my $entry = eval { decode_json($line) };
            exit 2 if $@ || ref($entry) ne "HASH";
            my $kind = $entry->{message_type} // $entry->{struct_type} // "";
            next if $kind ne "node";
            exit 2 if !defined($entry->{path}) || ref($entry->{path});
            my $node_type = $entry->{type} // "";
            my $type = $node_type eq "dir" ? "d"
                : $node_type eq "file" ? "f"
                : $node_type eq "symlink" ? "l" : "o";
            my $size = $entry->{size} // 0;
            exit 2 if $size !~ /^\d+$/;
            my $encoded = encode_base64(encode_utf8($entry->{path}), "");
            $encoded =~ tr!+/!-_!;
            $encoded =~ s/=+$//;
            print "$type\t$size\t$encoded\n";
        }
    ' "${raw}"
    local rc=$?
    rm -f "${raw}"
    return "${rc}"
}

decode_restic_path() {
    local encoded="$1" padded="${1//-/+}"
    [[ "${encoded}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    # BUG CORRIGIDO: "${padded//_/\/}" produz "\/" literal (barra invertida +
    # barra), não "/" — o \ dentro do padrão de substituição bash não é
    # tratado como escape aqui. Isso quebrava a decodificação de qualquer
    # path cujo base64url contivesse '_' (comum; sem relação com o nome ter
    # caracteres especiais). A forma correta usa uma variável para o valor
    # de substituição, evitando ambiguidade com o delimitador "/" do próprio
    # operador de substituição.
    local slash='/'
    padded="${padded//_/${slash}}"
    case $(( ${#padded} % 4 )) in
        0) ;;
        2) padded+="==" ;;
        3) padded+="=" ;;
        *) return 1 ;;
    esac
    printf '%s' "${padded}" | openssl base64 -A -d 2>/dev/null
}

# O caminho existe no snapshot? (a saída do `restic ls` lista caminhos com /)
path_in_snapshot() {
    local snap="$1" path="$2"
    restic ls "${snap}" "${path}" 2>/dev/null | grep -q '^/'
}

# Lista UM nível de <dir> no snapshot. Preenche G_TYPES[i] (d=dir, f=file,
# l=symlink, o=outro), G_PATHS[i] e G_SIZES[i]. O Restic é executado antes da
# leitura dos resultados para que falhas não sejam confundidas com lista vazia.
snap_ls_dir() {
    local snap="$1" dir="$2" limit="${3:-${RESTORE_LS_LIMIT}}"
    G_PATHS=(); G_TYPES=(); G_SIZES=()
    local records t size encoded p
    records="$(mktemp)" || return 1
    if ! restic_ls_records "${snap}" "${dir}" >"${records}"; then
        rm -f "${records}"
        return 1
    fi
    while IFS=$'\t' read -r t size encoded; do
        p="$(decode_restic_path "${encoded}")" || continue
        [[ -z "${p}" || "${p}" == "${dir}" ]] && continue
        [[ ! "${p}" =~ [[:cntrl:]] ]] || continue
        # Defesa adicional: mesmo que uma versão/mock do Restic devolva
        # descendentes, a API só expõe filhos cujo pai é exatamente <dir>.
        [[ "$(dirname -- "${p}")" == "${dir}" ]] || continue
        G_TYPES+=("${t}")
        G_SIZES+=("${size}")
        G_PATHS+=("${p}")
        (( ${#G_PATHS[@]} >= limit )) && break
    done < "${records}"
    rm -f "${records}"
    return 0
}

# Navegador interativo. Define G_SELECTED (vazio = cancelado).
browse_snapshot() {
    local snap="$1" cur="${2:-/}"
    G_SELECTED=""
    local i name ans idx
    while true; do
        echo
        echo -e "${BOLD}Snapshot ${snap} — ${cur}${NC}"
        snap_ls_dir "${snap}" "${cur}"
        if (( ${#G_PATHS[@]} == 0 )); then
            warn "(diretório vazio ou não listável)"
        else
            for i in "${!G_PATHS[@]}"; do
                name="$(basename "${G_PATHS[$i]}")"
                if [[ "${G_TYPES[$i]}" == "d" ]]; then
                    printf '  [%2d] %s/\n' "$((i + 1))" "${name}"
                else
                    printf '  [%2d] %s\n' "$((i + 1))" "${name}"
                fi
            done
            (( ${#G_PATHS[@]} >= RESTORE_LS_LIMIT )) && \
                warn "Lista truncada em ${RESTORE_LS_LIMIT} itens — use 'm' para digitar o caminho."
        fi
        echo
        echo "  número = entrar no diretório / selecionar arquivo"
        echo "  s = selecionar o diretório atual   .. = subir"
        echo "  m = digitar caminho                q = cancelar"
        prompt_read ans "Opção" || return 0
        case "${ans}" in
            q|Q) return 0 ;;
            s|S) G_SELECTED="${cur}"; return 0 ;;
            ..)  [[ "${cur}" != "/" ]] && cur="$(dirname "${cur}")" ;;
            m|M)
                prompt_read ans "Caminho absoluto dentro do snapshot" || continue
                if path_in_snapshot "${snap}" "${ans}"; then
                    G_SELECTED="${ans}"
                    return 0
                fi
                error "Caminho não encontrado no snapshot: ${ans}"
                ;;
            *)
                if [[ "${ans}" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#G_PATHS[@]} )); then
                    idx=$((ans - 1))
                    if [[ "${G_TYPES[$idx]}" == "d" ]]; then
                        cur="${G_PATHS[$idx]}"
                    else
                        G_SELECTED="${G_PATHS[$idx]}"
                        return 0
                    fi
                else
                    warn "Opção inválida."
                fi
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# RESTAURAÇÃO DE ARQUIVOS/DIRETÓRIOS
# ---------------------------------------------------------------------------

count_path_components() {
    local p="$1"
    [[ "${p}" == "/" ]] && { echo 0; return; }
    p="${p#/}"; p="${p%/}"
    printf '%s' "${p}" | awk -F/ '{print NF}'
}

# Escapa * ? [ ] para o --include do Restic tratar o caminho como literal,
# não como padrão de glob. Sem isso, um item cujo nome real contenha esses
# caracteres pode casar (e restaurar) outros itens do snapshot.
escape_restic_include_pattern() {
    local p="$1"
    p="${p//\\/\\\\}"
    p="${p//\*/\\*}"
    p="${p//\?/\\?}"
    p="${p//\[/\\[}"
    p="${p//\]/\\]}"
    printf '%s' "${p}"
}

# restic restore com saída na tela E no log.
run_restore() {
    local snap="$1" path="$2" target="$3"; shift 3
    log_line "INFO " "restic restore ${snap} --target ${target} --include ${path} $*"
    restic restore "${snap}" --target "${target}" --include "${path}" "$@" \
        2>&1 | tee -a "${RESTORE_LOG_FILE}"
    return "${PIPESTATUS[0]}"
}

# Mesmo restic restore, mas o caminho é tratado como literal (glob escapado).
# Usado no fluxo --hub-restore-item, onde path vem de um token autenticado
# e precisa casar exatamente aquele item, nada mais.
run_restore_exact() {
    local snap="$1" path="$2" target="$3"; shift 3
    local escaped
    escaped="$(escape_restic_include_pattern "${path}")"
    run_restore "${snap}" "${escaped}" "${target}" "$@"
}

# Prévia (dry-run). Se a versão do restic não suportar, apenas avisa.
preview_restore() {
    local snap="$1" path="$2"
    step "Prévia (dry-run) — nada será gravado"
    if ! run_restore "${snap}" "${path}" "/tmp" --dry-run -v; then
        warn "Dry-run indisponível ou falhou (versões antigas do restic não suportam). Seguindo sem prévia."
    fi
}

# Backup preventivo (tar.gz no staging) de um caminho local prestes a ser
# sobrescrito. rc 0 = ok/pulado; rc 1 = falhou e usuário abortou.
preventive_tar() {
    local path="$1"
    [[ -e "${path}" ]] || { info "Local original não existe ainda (${path}) — sem backup preventivo."; return 0; }
    ask_yes_no "Fazer backup preventivo do estado ATUAL de ${path} antes de sobrescrever?" "s" || return 0
    ensure_staging
    local out
    out="${STAGING_DIR}/preventivo-$(basename "${path}")-$(date +%H%M%S).tar.gz"
    info "Gerando backup preventivo: ${out}"
    if tar -czf "${out}" -C "$(dirname "${path}")" "$(basename "${path}")" 2>>"${RESTORE_LOG_FILE}"; then
        info "Backup preventivo OK."
        return 0
    fi
    error "Backup preventivo FALHOU."
    ask_yes_no "Continuar SEM backup preventivo?" "n" && return 0
    return 1
}

# Fluxo completo de restauração de um caminho do snapshot.
restore_path_flow() {
    local snap="$1" path="$2"
    echo
    info "Selecionado: ${path}"
    if [[ "${path}" == *[\*\?\[]* ]]; then
        warn "O caminho contém caracteres curinga (* ? [) — o filtro do restic pode casar mais itens que o esperado."
    fi

    echo
    echo "Destino da restauração:"
    echo "  [1] Staging (recomendado): ${RESTORE_STAGING_BASE}-<data>"
    echo "  [2] Local ORIGINAL (sobrescreve produção!)"
    echo "  [3] Outro diretório"
    echo "  [0] Cancelar"
    local ans
    prompt_read ans "Opção" "1" || return 0
    case "${ans}" in
        1) restore_to_staging "${snap}" "${path}" ;;
        2) restore_to_original "${snap}" "${path}" ;;
        3) restore_to_custom "${snap}" "${path}" ;;
        *) info "Cancelado." ;;
    esac
}

restore_to_staging() {
    local snap="$1" path="$2"
    ensure_staging
    check_free_space "${STAGING_DIR}" || return 0
    if ask_yes_no "Ver prévia (dry-run) antes?" "n"; then
        preview_restore "${snap}" "${path}"
        ask_yes_no "Prosseguir com a restauração para o staging?" "s" || return 0
    fi
    step "Restaurando para o staging"
    if run_restore "${snap}" "${path}" "${STAGING_DIR}"; then
        info "Concluído. Conteúdo em: ${STAGING_DIR}${path}"
        info "Confira os arquivos e mova manualmente para o destino final se estiver tudo certo."
    else
        error "Restauração falhou. Veja ${RESTORE_LOG_FILE}."
    fi
}

restore_to_custom() {
    local snap="$1" path="$2" target
    prompt_read target "Diretório de destino (absoluto; será criado se não existir)" || return 0
    if [[ "${target}" != /* || "${target}" == *..* || "${target}" == "/" ]]; then
        error "Destino inválido: use um caminho absoluto, sem '..', diferente de '/'."
        return 0
    fi
    mkdir -p "${target}" || { error "Não foi possível criar ${target}."; return 0; }
    check_free_space "${target}" || return 0
    step "Restaurando para ${target}"
    if run_restore "${snap}" "${path}" "${target}"; then
        info "Concluído. Conteúdo em: ${target}${path}"
    else
        error "Restauração falhou. Veja ${RESTORE_LOG_FILE}."
    fi
}

restore_to_original() {
    local snap="$1" path="$2"
    local comps
    comps="$(count_path_components "${path}")"
    if (( comps < 2 )); then
        error "Recusado: restaurar '${path}' inteiro no lugar é perigoso demais para este assistente."
        error "Restaure para o staging e mova manualmente, ou use o rr direto (equipe sênior):"
        error "  rr restore ${snap} --target / --include '${path}'"
        return 0
    fi

    echo
    warn "ATENÇÃO: isso vai SOBRESCREVER ${path} no servidor com o conteúdo do snapshot ${snap}."
    warn "Arquivos criados DEPOIS do snapshot que não existem nele NÃO são apagados (sem --delete),"
    warn "mas todo arquivo existente no snapshot será sobrescrito."

    preventive_tar "${path}" || return 0
    check_free_space "$(dirname "${path}")" || return 0

    # Prévia obrigatória antes de tocar em produção.
    preview_restore "${snap}" "${path}"

    confirm_typed "SOBRESCREVER" || return 0

    local verify_flag=()
    ask_yes_no "Verificar os arquivos após restaurar (--verify, mais lento)?" "n" && verify_flag=(--verify)

    step "Restaurando ${path} no local original"
    if run_restore "${snap}" "${path}" "/" "${verify_flag[@]+"${verify_flag[@]}"}"; then
        info "Restauração concluída em ${path}."
        info "Confira permissões/dono e reinicie serviços que usam esses arquivos, se necessário."
    else
        error "Restauração FALHOU. O backup preventivo (se gerado) está no staging."
    fi
}

# ---------------------------------------------------------------------------
# SITES
# ---------------------------------------------------------------------------

# Detecta a "fonte" de sites do snapshot a partir do BACKUP_SOURCE do env,
# com sondagem no snapshot como fallback.
detect_layout() {
    case "${BACKUP_SOURCE}" in
        /home)        echo "runcloud"; return ;;
        /var/www)     echo "varwww";   return ;;
        /etc/dokploy) echo "dokploy";  return ;;
    esac
    if path_in_snapshot "${SNAP_ID}" "/etc/dokploy"; then echo "dokploy"
    elif path_in_snapshot "${SNAP_ID}" "/var/www";  then echo "varwww"
    elif path_in_snapshot "${SNAP_ID}" "/home";     then echo "runcloud"
    else echo "desconhecido"
    fi
}

# Preenche G_PATHS com os sites do snapshot conforme o layout.
list_sites() {
    local layout="$1"
    local sites=() u
    case "${layout}" in
        runcloud)
            # /home/<usuario>/webapps/<app>
            snap_ls_dir "${SNAP_ID}" "/home"
            local users=("${G_PATHS[@]+"${G_PATHS[@]}"}")
            local types=("${G_TYPES[@]+"${G_TYPES[@]}"}")
            local i
            for i in "${!users[@]}"; do
                [[ "${types[$i]}" == "d" ]] || continue
                u="${users[$i]}"
                path_in_snapshot "${SNAP_ID}" "${u}/webapps" || continue
                snap_ls_dir "${SNAP_ID}" "${u}/webapps"
                local j
                for j in "${!G_PATHS[@]}"; do
                    [[ "${G_TYPES[$j]}" == "d" ]] && sites+=("${G_PATHS[$j]}")
                done
            done
            ;;
        varwww)
            snap_ls_dir "${SNAP_ID}" "/var/www"
            local i
            for i in "${!G_PATHS[@]}"; do
                [[ "${G_TYPES[$i]}" == "d" ]] && sites+=("${G_PATHS[$i]}")
            done
            ;;
    esac
    G_PATHS=("${sites[@]+"${sites[@]}"}")
}

menu_restore_site() {
    local layout
    layout="$(detect_layout)"
    step "Restaurar site completo (layout detectado: ${layout})"

    if [[ "${layout}" == "dokploy" ]]; then
        # Dokploy não tem "sites" em disco: o código dos apps vem do Git.
        echo "Em servidores Dokploy o backup protege:"
        echo "  [1] /etc/dokploy (Traefik, certificados, configs do painel)"
        echo "  [2] Um volume Docker (uploads/persistência de um app)"
        echo "  [0] Voltar"
        local ans
        prompt_read ans "Opção" "0" || return 0
        case "${ans}" in
            1) restore_path_flow "${SNAP_ID}" "/etc/dokploy" ;;
            2)
                if ! path_in_snapshot "${SNAP_ID}" "${DOCKER_VOLUMES_DIR}"; then
                    error "Snapshot não contém ${DOCKER_VOLUMES_DIR} (BACKUP_DOCKER_VOLUMES desativado?)."
                    return 0
                fi
                snap_ls_dir "${SNAP_ID}" "${DOCKER_VOLUMES_DIR}"
                local vols=() i
                for i in "${!G_PATHS[@]}"; do
                    [[ "${G_TYPES[$i]}" == "d" ]] && vols+=("${G_PATHS[$i]}")
                done
                (( ${#vols[@]} == 0 )) && { warn "Nenhum volume no snapshot."; return 0; }
                echo
                for i in "${!vols[@]}"; do
                    printf '  [%2d] %s\n' "$((i + 1))" "$(basename "${vols[$i]}")"
                done
                prompt_read ans "Número do volume (0 = voltar)" "0" || return 0
                if [[ "${ans}" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#vols[@]} )); then
                    warn "Restaure o volume com o app PARADO (docker service scale/stop) para não corromper dados."
                    restore_path_flow "${SNAP_ID}" "${vols[$((ans - 1))]}"
                fi
                ;;
        esac
        return 0
    fi

    if [[ "${layout}" == "desconhecido" ]]; then
        warn "Não reconheci o layout de sites deste snapshot. Use a opção 2 (arquivo/diretório) do menu."
        return 0
    fi

    list_sites "${layout}"
    if (( ${#G_PATHS[@]} == 0 )); then
        warn "Nenhum site encontrado no snapshot ${SNAP_ID}."
        return 0
    fi

    local sites=("${G_PATHS[@]}") i ans
    echo
    for i in "${!sites[@]}"; do
        printf '  [%2d] %s\n' "$((i + 1))" "${sites[$i]}"
    done
    echo
    prompt_read ans "Número do site (0 = voltar)" "0" || return 0
    [[ "${ans}" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#sites[@]} )) || return 0

    local site="${sites[$((ans - 1))]}"
    restore_path_flow "${SNAP_ID}" "${site}"

    echo
    if ask_yes_no "Restaurar também um BANCO DE DADOS associado a este site?" "n"; then
        menu_restore_db
    fi
}

# ---------------------------------------------------------------------------
# BANCOS DE DADOS
# ---------------------------------------------------------------------------

# Diretórios candidatos a conter dumps no snapshot (env primeiro, depois os
# defaults das variantes).
dump_dir_candidates() {
    local seen=" " d
    for d in "${DB_DUMP_DIR}" /var/backups/db /home/backups/db; do
        [[ -z "${d}" ]] && continue
        [[ "${seen}" == *" ${d} "* ]] && continue
        seen="${seen}${d} "
        echo "${d}"
    done
}

# Lista os dumps do snapshot em G_PATHS (caminhos completos).
list_dumps() {
    G_PATHS=()
    local d line
    while IFS= read -r d; do
        path_in_snapshot "${SNAP_ID}" "${d}" || continue
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            G_PATHS+=("${line}")
        done < <(restic ls --recursive "${SNAP_ID}" "${d}" 2>>"${RESTORE_LOG_FILE}" \
                    | grep -E '^/.*\.(dump|sql\.gz)$' | sort)
        # Usa o primeiro diretório que contém dumps.
        (( ${#G_PATHS[@]} > 0 )) && { G_DUMP_DIR_IN_SNAP="${d}"; break; }
    done < <(dump_dir_candidates)
}

# Classifica um dump pelo caminho. Ecoa: "<tipo> <extra>"
#   mysql            — .sql.gz na raiz do dir de dumps (variante MySQL)
#   pg-local <porta> — porta-<n>/<db>.dump             (variante PG)
#   pg-docker <svc>  — container-<svc>/<db>.dump       (variante Dokploy)
#   globals-local <porta> / globals-docker <svc>       (roles/permissões)
classify_dump() {
    local path="$1" parent
    parent="$(basename "$(dirname "${path}")")"
    case "${parent}" in
        porta-*)
            if [[ "$(basename "${path}")" == "globals.sql.gz" ]]; then
                echo "globals-local ${parent#porta-}"
            else
                echo "pg-local ${parent#porta-}"
            fi
            ;;
        container-*)
            if [[ "$(basename "${path}")" == "globals.sql.gz" ]]; then
                echo "globals-docker ${parent#container-}"
            else
                echo "pg-docker ${parent#container-}"
            fi
            ;;
        *)
            echo "mysql -"
            ;;
    esac
}

dump_label() {
    local path="$1" kind extra name
    read -r kind extra <<< "$(classify_dump "${path}")"
    name="$(basename "${path}")"
    case "${kind}" in
        mysql)          echo "${name%.sql.gz} (MySQL)" ;;
        pg-local)       echo "${name%.dump} (PostgreSQL porta ${extra})" ;;
        pg-docker)      echo "${name%.dump} (PostgreSQL container ${extra})" ;;
        globals-local)  echo "globals/roles (PostgreSQL porta ${extra})" ;;
        globals-docker) echo "globals/roles (PostgreSQL container ${extra})" ;;
    esac
}

menu_restore_db() {
    step "Restaurar banco de dados (snapshot ${SNAP_ID})"
    G_DUMP_DIR_IN_SNAP=""
    list_dumps
    if (( ${#G_PATHS[@]} == 0 )); then
        warn "Nenhum dump encontrado no snapshot ${SNAP_ID}."
        warn "Diretórios sondados: $(dump_dir_candidates | tr '\n' ' ')"
        return 0
    fi

    local dumps=("${G_PATHS[@]}") i ans
    info "Dumps encontrados em ${G_DUMP_DIR_IN_SNAP}:"
    echo
    for i in "${!dumps[@]}"; do
        printf '  [%2d] %-52s %s\n' "$((i + 1))" "$(dump_label "${dumps[$i]}")" "${dumps[$i]}"
    done
    echo
    prompt_read ans "Número do dump (0 = voltar)" "0" || return 0
    [[ "${ans}" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#dumps[@]} )) || return 0

    local dump_path="${dumps[$((ans - 1))]}"
    local kind extra
    read -r kind extra <<< "$(classify_dump "${dump_path}")"

    # 1) Sempre materializa o dump no staging primeiro.
    ensure_staging
    check_free_space "${STAGING_DIR}" || return 0
    step "Restaurando o arquivo de dump para o staging"
    if ! run_restore "${SNAP_ID}" "${dump_path}" "${STAGING_DIR}"; then
        error "Falha ao restaurar o dump do snapshot."
        return 0
    fi
    local dump_file="${STAGING_DIR}${dump_path}"
    [[ -f "${dump_file}" ]] || { error "Dump não materializado em ${dump_file}."; return 0; }
    info "Dump restaurado: ${dump_file}"

    # 2) Valida integridade do arquivo (sem tocar em banco nenhum).
    verify_dump_file "${dump_file}" "${kind}" "${extra}" || {
        error "O dump parece corrompido — importação bloqueada. Tente outro snapshot."
        return 0
    }

    # 3) Importação (opcional, com confirmação forte).
    echo
    if ! ask_yes_no "Importar este dump no banco AGORA?" "n"; then
        print_manual_import_help "${dump_file}" "${kind}" "${extra}"
        return 0
    fi

    case "${kind}" in
        mysql)          import_mysql "${dump_file}" ;;
        pg-local)       import_pg_local "${dump_file}" "${extra}" ;;
        pg-docker)      import_pg_docker "${dump_file}" "${extra}" ;;
        globals-local)  import_globals_local "${dump_file}" "${extra}" ;;
        globals-docker) import_globals_docker "${dump_file}" "${extra}" ;;
    esac
}

# Confere se o arquivo de dump é legível (gzip -t / pg_restore --list).
verify_dump_file() {
    local file="$1" kind="$2" extra="$3"
    info "Validando integridade do dump..."
    case "${kind}" in
        mysql|globals-*)
            gzip -t "${file}" 2>>"${RESTORE_LOG_FILE}" || return 1
            ;;
        pg-local)
            resolve_pg_bins
            if command -v "${PG_RESTORE_BIN}" &>/dev/null; then
                "${PG_RESTORE_BIN}" --list "${file}" >/dev/null 2>>"${RESTORE_LOG_FILE}" || return 1
            else
                warn "pg_restore indisponível — pulando validação do índice do dump."
            fi
            ;;
        pg-docker)
            local c
            c="$(find_container "${extra}")"
            if [[ -n "${c}" ]]; then
                docker exec -i "${c}" pg_restore --list < "${file}" >/dev/null 2>>"${RESTORE_LOG_FILE}" || return 1
            else
                warn "Container '${extra}' não está rodando — pulando validação do índice do dump."
            fi
            ;;
    esac
    info "Dump íntegro."
    return 0
}

print_manual_import_help() {
    local file="$1" kind="$2" extra="$3"
    echo
    info "O dump ficou em: ${file}"
    info "Para importar depois, manualmente:"
    case "${kind}" in
        mysql)
            echo "  gunzip -c '${file}' | mysql -u root -p NOME_DO_BANCO"
            ;;
        pg-local)
            echo "  sudo -u postgres pg_restore -p ${extra} --clean --if-exists -d NOME_DO_BANCO '${file}'"
            ;;
        pg-docker)
            echo "  docker exec -i \$(docker ps -q -f name=${extra}) \\"
            echo "    pg_restore -U USUARIO --clean --if-exists -d NOME_DO_BANCO < '${file}'"
            ;;
        globals-local)
            echo "  gunzip -c '${file}' | sudo -u postgres psql -p ${extra}"
            ;;
        globals-docker)
            echo "  gunzip -c '${file}' | docker exec -i \$(docker ps -q -f name=${extra}) psql -U USUARIO"
            ;;
    esac
}

valid_db_name() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

# --- MySQL -----------------------------------------------------------------

build_mysql_defaults_file() {
    [[ -n "${MYSQL_DEFAULTS_FILE}" ]] && return 0
    MYSQL_DEFAULTS_FILE="$(mktemp)"
    chmod 600 "${MYSQL_DEFAULTS_FILE}"
    {
        echo "[client]"
        echo "user=${MYSQL_USER}"
        echo "host=${MYSQL_HOST}"
        [[ -n "${MYSQL_PASSWORD}" ]] && echo "password=${MYSQL_PASSWORD}"
    } > "${MYSQL_DEFAULTS_FILE}"
}

mysql_cmd()     { mysql     --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" "$@"; }
mysqldump_cmd() { mysqldump --defaults-extra-file="${MYSQL_DEFAULTS_FILE}" "$@"; }

import_mysql() {
    local file="$1"
    command -v mysql &>/dev/null || { error "'mysql' não encontrado."; return 0; }
    build_mysql_defaults_file
    if ! mysql_cmd --silent -e "SELECT 1;" &>/dev/null; then
        error "Falha ao conectar no MySQL (credenciais do ${RESTIC_ENV_FILE})."
        return 0
    fi

    local def db
    def="$(basename "${file}")"; def="${def%.sql.gz}"
    prompt_read db "Banco de DESTINO da importação" "${def}" || return 0
    valid_db_name "${db}" || { error "Nome de banco inválido: ${db}"; return 0; }

    local exists=""
    exists="$(mysql_cmd --skip-column-names --silent \
        -e "SHOW DATABASES LIKE '${db}';" 2>>"${RESTORE_LOG_FILE}" || true)"

    if [[ -n "${exists}" ]]; then
        warn "O banco '${db}' JÁ EXISTE — a importação vai sobrescrever tabelas/objetos com os do dump."
        if ask_yes_no "Backup preventivo do banco atual '${db}' antes de importar?" "s"; then
            command -v mysqldump &>/dev/null || { error "'mysqldump' não encontrado."; return 0; }
            ensure_staging
            local prev
            prev="${STAGING_DIR}/preventivo-${db}-$(date +%H%M%S).sql.gz"
            info "Dump preventivo: ${prev}"
            if ! mysqldump_cmd --single-transaction --quick --routines --triggers "${db}" \
                    2>>"${RESTORE_LOG_FILE}" | gzip > "${prev}" \
                || (( PIPESTATUS[0] != 0 )); then
                error "Dump preventivo falhou."
                ask_yes_no "Continuar SEM preventivo?" "n" || return 0
            fi
        fi
    else
        info "O banco '${db}' não existe — será criado."
    fi

    confirm_typed "IMPORTAR" || return 0

    if [[ -z "${exists}" ]]; then
        mysql_cmd -e "CREATE DATABASE IF NOT EXISTS \`${db}\`;" 2>>"${RESTORE_LOG_FILE}" \
            || { error "Falha ao criar o banco '${db}'."; return 0; }
    fi

    step "Importando ${file} → banco '${db}'"
    gunzip -c "${file}" | mysql_cmd "${db}" 2>>"${RESTORE_LOG_FILE}"
    local rc=("${PIPESTATUS[@]}")
    if (( rc[0] == 0 && rc[1] == 0 )); then
        info "Importação concluída com sucesso no banco '${db}'."
    else
        error "Importação falhou (gunzip=${rc[0]}, mysql=${rc[1]}). Veja ${RESTORE_LOG_FILE}."
        error "O preventivo (se gerado) está no staging."
    fi
}

# --- PostgreSQL local (variante PG) -----------------------------------------

resolve_pg_bins() {
    [[ "${PG_BINS_RESOLVED}" == "true" ]] && return 0
    PG_BINS_RESOLVED=true
    if [[ -z "${PG_BIN_DIR}" ]]; then
        PG_BIN_DIR="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1 || true)"
    fi
    if [[ -n "${PG_BIN_DIR}" && -x "${PG_BIN_DIR}/pg_restore" ]]; then
        PSQL_BIN="${PG_BIN_DIR}/psql"
        PG_DUMP_BIN="${PG_BIN_DIR}/pg_dump"
        PG_RESTORE_BIN="${PG_BIN_DIR}/pg_restore"
    fi
}

setup_pg_auth() {
    [[ "${PG_AUTH_READY}" == "true" ]] && return 0
    PG_AUTH_READY=true
    if [[ -n "${PG_PASSWORD}" ]]; then
        PGPASS_FILE="$(mktemp)"
        chmod 600 "${PGPASS_FILE}"
        printf '%s:*:*:%s:%s\n' "${PG_HOST}" "${PG_USER}" "${PG_PASSWORD}" > "${PGPASS_FILE}"
        export PGPASSFILE="${PGPASS_FILE}" PGHOST="${PG_HOST}" PGUSER="${PG_USER}"
        PG_USE_SUDO=false
    elif [[ "$(id -u)" -eq 0 ]] && id -u "${PG_SYSTEM_USER}" &>/dev/null; then
        PG_USE_SUDO=true
    else
        PG_USE_SUDO=false
        warn "Sem PG_PASSWORD e sem usuário '${PG_SYSTEM_USER}' — tentando como $(id -un)."
    fi
}

pg_exec() {
    if [[ "${PG_USE_SUDO}" == "true" ]]; then
        sudo -n -u "${PG_SYSTEM_USER}" "$@"
    else
        "$@"
    fi
}

psql_cmd() { local p="$1"; shift; pg_exec "${PSQL_BIN}" -X -p "${p}" "$@"; }

import_pg_local() {
    local file="$1" port="$2"
    resolve_pg_bins
    setup_pg_auth
    command -v "${PG_RESTORE_BIN}" &>/dev/null || { error "'pg_restore' não encontrado."; return 0; }
    if ! psql_cmd "${port}" -Atqc "SELECT 1;" &>/dev/null; then
        error "Falha ao conectar no PostgreSQL na porta ${port}."
        return 0
    fi

    local def db
    def="$(basename "${file}")"; def="${def%.dump}"
    prompt_read db "Banco de DESTINO da importação" "${def}" || return 0
    valid_db_name "${db}" || { error "Nome de banco inválido: ${db}"; return 0; }

    local exists
    exists="$(psql_cmd "${port}" -Atqc \
        "SELECT 1 FROM pg_database WHERE datname='${db}';" 2>>"${RESTORE_LOG_FILE}" || true)"

    if [[ "${exists}" == "1" ]]; then
        warn "O banco '${db}' JÁ EXISTE — o pg_restore --clean vai substituir os objetos pelos do dump."
        if ask_yes_no "Backup preventivo do banco atual '${db}' antes de importar?" "s"; then
            ensure_staging
            local prev
            prev="${STAGING_DIR}/preventivo-${db}-$(date +%H%M%S).dump"
            info "Dump preventivo: ${prev}"
            if ! pg_exec "${PG_DUMP_BIN}" -p "${port}" --format=custom "${db}" \
                    2>>"${RESTORE_LOG_FILE}" > "${prev}"; then
                error "Dump preventivo falhou."
                ask_yes_no "Continuar SEM preventivo?" "n" || return 0
            fi
        fi
    else
        info "O banco '${db}' não existe — será criado."
    fi

    confirm_typed "IMPORTAR" || return 0

    if [[ "${exists}" != "1" ]]; then
        psql_cmd "${port}" -d postgres -qc "CREATE DATABASE \"${db}\";" 2>>"${RESTORE_LOG_FILE}" \
            || { error "Falha ao criar o banco '${db}'."; return 0; }
    fi

    step "Importando ${file} → banco '${db}' (porta ${port})"
    # Via stdin: o arquivo no staging é do root; o pg_restore pode rodar como
    # o usuário postgres (sudo) sem precisar ler o arquivo diretamente.
    if pg_exec "${PG_RESTORE_BIN}" -p "${port}" --clean --if-exists -d "${db}" \
            < "${file}" 2>>"${RESTORE_LOG_FILE}"; then
        info "Importação concluída com sucesso no banco '${db}'."
    else
        warn "pg_restore terminou com avisos/erros (comum com --clean em objetos inexistentes)."
        warn "Revise ${RESTORE_LOG_FILE} e valide a aplicação. Preventivo (se gerado) está no staging."
    fi
}

import_globals_local() {
    local file="$1" port="$2"
    resolve_pg_bins
    setup_pg_auth
    warn "Isto aplica ROLES/PERMISSÕES globais do cluster (porta ${port})."
    warn "Normalmente só é necessário ao reconstruir um servidor novo."
    confirm_typed "IMPORTAR" || return 0
    if gunzip -c "${file}" | pg_exec "${PSQL_BIN}" -X -p "${port}" -d postgres 2>>"${RESTORE_LOG_FILE}" >/dev/null; then
        info "Globals aplicados."
    else
        warn "psql terminou com avisos/erros (roles já existentes geram erro inofensivo). Veja o log."
    fi
}

# --- PostgreSQL em container (variante Dokploy) ------------------------------

find_container() {
    local svc="$1"
    command -v docker &>/dev/null || return 0
    docker ps --filter "name=${svc}" --format '{{.Names}}' 2>/dev/null | head -1
}

container_pg_user() {
    local c="$1" u
    u="$(docker exec "${c}" printenv POSTGRES_USER 2>/dev/null || true)"
    echo "${u:-postgres}"
}

import_pg_docker() {
    local file="$1" svc="$2"
    command -v docker &>/dev/null || { error "'docker' não encontrado."; return 0; }
    local c
    c="$(find_container "${svc}")"
    [[ -n "${c}" ]] || { error "Container '${svc}' não está em execução."; return 0; }
    local user
    user="$(container_pg_user "${c}")"
    info "Container: ${c} (usuário Postgres: ${user})"

    if ! docker exec "${c}" psql -X -U "${user}" -Atqc "SELECT 1;" &>/dev/null; then
        error "Falha ao conectar no Postgres do container ${c}."
        return 0
    fi

    local def db
    def="$(basename "${file}")"; def="${def%.dump}"
    prompt_read db "Banco de DESTINO da importação" "${def}" || return 0
    valid_db_name "${db}" || { error "Nome de banco inválido: ${db}"; return 0; }

    local exists
    exists="$(docker exec "${c}" psql -X -U "${user}" -Atqc \
        "SELECT 1 FROM pg_database WHERE datname='${db}';" 2>>"${RESTORE_LOG_FILE}" || true)"

    if [[ "${exists}" == "1" ]]; then
        warn "O banco '${db}' JÁ EXISTE — o pg_restore --clean vai substituir os objetos pelos do dump."
        if ask_yes_no "Backup preventivo do banco atual '${db}' antes de importar?" "s"; then
            ensure_staging
            local prev
            prev="${STAGING_DIR}/preventivo-${db}-$(date +%H%M%S).dump"
            info "Dump preventivo: ${prev}"
            if ! docker exec "${c}" pg_dump -U "${user}" --format=custom "${db}" \
                    2>>"${RESTORE_LOG_FILE}" > "${prev}"; then
                error "Dump preventivo falhou."
                ask_yes_no "Continuar SEM preventivo?" "n" || return 0
            fi
        fi
    else
        info "O banco '${db}' não existe — será criado."
    fi

    if [[ "${db}" == "dokploy" ]]; then
        warn "Este é o banco do PAINEL Dokploy. Após importar, reinicie o serviço do painel."
    fi

    confirm_typed "IMPORTAR" || return 0

    if [[ "${exists}" != "1" ]]; then
        docker exec "${c}" createdb -U "${user}" "${db}" 2>>"${RESTORE_LOG_FILE}" \
            || { error "Falha ao criar o banco '${db}'."; return 0; }
    fi

    step "Importando ${file} → banco '${db}' (container ${c})"
    if docker exec -i "${c}" pg_restore -U "${user}" --clean --if-exists -d "${db}" \
            < "${file}" 2>>"${RESTORE_LOG_FILE}"; then
        info "Importação concluída com sucesso no banco '${db}'."
    else
        warn "pg_restore terminou com avisos/erros (comum com --clean em objetos inexistentes)."
        warn "Revise ${RESTORE_LOG_FILE} e valide a aplicação. Preventivo (se gerado) está no staging."
    fi
}

import_globals_docker() {
    local file="$1" svc="$2"
    command -v docker &>/dev/null || { error "'docker' não encontrado."; return 0; }
    local c
    c="$(find_container "${svc}")"
    [[ -n "${c}" ]] || { error "Container '${svc}' não está em execução."; return 0; }
    local user
    user="$(container_pg_user "${c}")"
    warn "Isto aplica ROLES/PERMISSÕES globais no Postgres do container ${c}."
    warn "Normalmente só é necessário ao reconstruir um servidor novo."
    confirm_typed "IMPORTAR" || return 0
    if gunzip -c "${file}" | docker exec -i "${c}" psql -X -U "${user}" 2>>"${RESTORE_LOG_FILE}" >/dev/null; then
        info "Globals aplicados."
    else
        warn "psql terminou com avisos/erros (roles já existentes geram erro inofensivo). Veja o log."
    fi
}

# ---------------------------------------------------------------------------
# MENUS
# ---------------------------------------------------------------------------

menu_restore_files() {
    local start="${BACKUP_SOURCE:-/}"
    path_in_snapshot "${SNAP_ID}" "${start}" || start="/"
    browse_snapshot "${SNAP_ID}" "${start}"
    [[ -z "${G_SELECTED}" ]] && { info "Nada selecionado."; return 0; }
    restore_path_flow "${SNAP_ID}" "${G_SELECTED}"
}

menu_preview() {
    browse_snapshot "${SNAP_ID}" "/"
    [[ -n "${G_SELECTED}" ]] && info "Caminho consultado: ${G_SELECTED} (nada foi restaurado)"
}

menu_check() {
    step "Check estrutural rápido do repositório"
    if restic check 2>&1 | tee -a "${RESTORE_LOG_FILE}"; then
        info "Check OK."
    else
        error "Check encontrou problemas — avise o responsável pelo backup."
    fi
}

main_menu() {
    local ans
    while true; do
        echo
        hr
        echo -e "${BOLD}restic-restore — restauração interativa${NC}"
        echo "Repositório : ${RESTIC_REPOSITORY}"
        echo "Snapshot    : ${SNAP_ID}"
        [[ -n "${STAGING_DIR}" ]] && echo "Staging     : ${STAGING_DIR}"
        hr
        echo "  [1] Listar / escolher snapshot"
        echo "  [2] Restaurar arquivo ou diretório"
        echo "  [3] Restaurar site completo"
        echo "  [4] Restaurar banco de dados"
        echo "  [5] Navegar no snapshot (só visualizar)"
        echo "  [6] Check rápido do repositório"
        echo "  [0] Sair"
        prompt_read ans "Opção" || break
        case "${ans}" in
            1) menu_snapshots ;;
            2) menu_restore_files ;;
            3) menu_restore_site ;;
            4) menu_restore_db ;;
            5) menu_preview ;;
            6) menu_check ;;
            0) break ;;
            *) warn "Opção inválida." ;;
        esac
    done
    info "Sessão de restauração encerrada."
}

# ---------------------------------------------------------------------------
# MODO NÃO-INTERATIVO (HUB)
# ---------------------------------------------------------------------------
# Acionado via: restic-restore.sh --non-interactive --snapshot <id> --job <job_id>
# Sem prompt algum; restaura o snapshot INTEIRO para o staging padrão.
# Log em ${HUB_JOB_LOG_DIR}/<job_id>.log; status em ${HUB_JOB_STATUS_DIR}/<job_id>.status.

valid_job_id() {
    [[ "$1" =~ ^[A-Za-z0-9-]{1,64}$ ]]
}

valid_snapshot_id() {
    [[ "$1" =~ ^[0-9a-f]{8,64}$ ]]
}

# ---------------------------------------------------------------------------
# API JSON DE NAVEGAÇÃO / PREFLIGHT (HUB)
# ---------------------------------------------------------------------------

hub_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '%s' "${s}"
}

hub_json_error() {
    local code="$1" message="$2"
    printf '{"version":%d,"ok":false,"error":{"code":"%s","message":"%s"}}\n' \
        "${HUB_API_VERSION}" "$(hub_json_escape "${code}")" "$(hub_json_escape "${message}")"
    return 1
}

# Só aceita caminhos canônicos absolutos. Não normalizamos entrada hostil: um
# token que contenha traversal, barras duplicadas ou controles é recusado.
hub_path_is_safe() {
    local path="$1"
    (( ${#path} <= 4096 )) || return 1
    [[ "${path}" == /* ]] || return 1
    [[ "${path}" == "/" || "${path}" != */ ]] || return 1
    [[ "${path}" != *//* ]] || return 1
    [[ ! "${path}" =~ (^|/)\.{1,2}(/|$) ]] || return 1
    [[ ! "${path}" =~ [[:cntrl:]] ]] || return 1
}

hub_token_key() {
    local key
    [[ -f "${HUB_TOKEN_KEY_FILE}" ]] || return 1
    key="$(cat -- "${HUB_TOKEN_KEY_FILE}")" || return 1
    [[ "${key}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${key}"
}

hub_token_hmac() {
    local snap="$1" payload="$2" digest
    hub_token_key >/dev/null || return 1
    digest="$(printf 'v1\0%s\0%s' "${snap}" "${payload}" \
        | HUB_HMAC_KEY_PATH="${HUB_TOKEN_KEY_FILE}" perl -MDigest::SHA=hmac_sha256_hex -e '
            open my $fh, "<", $ENV{HUB_HMAC_KEY_PATH} or exit 1;
            my $hex = <$fh>; close $fh; chomp $hex;
            $hex =~ /^[0-9a-f]{64}$/ or exit 1;
            binmode STDIN;
            local $/;
            my $data = <STDIN>;
            print hmac_sha256_hex($data, pack("H*", $hex));
        ' 2>/dev/null)" || return 1
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${digest}"
}

hub_base64url_encode() {
    openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '='
}

hub_base64url_decode() {
    local payload="$1" padded="${1//-/+}"
    # Mesma correção de decode_restic_path: "\/" no padrão de substituição
    # bash não vira "/", produz "\/" literal — quebrava tokens cujo payload
    # base64url contivesse '_'.
    local slash='/'
    padded="${padded//_/${slash}}"
    case $(( ${#padded} % 4 )) in
        0) ;;
        2) padded+="==" ;;
        3) padded+="=" ;;
        *) return 1 ;;
    esac
    printf '%s' "${padded}" | openssl base64 -A -d 2>/dev/null
}

hub_make_token() {
    local snap="$1" path="$2" payload mac
    hub_path_is_safe "${path}" || return 1
    payload="$(printf '%s' "${path}" | hub_base64url_encode)" || return 1
    [[ "${payload}" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    (( ${#payload} >= 2 && ${#payload} <= 5462 )) || return 1
    mac="$(hub_token_hmac "${snap}" "${payload}")" || return 1
    printf 'v1.%s.%s' "${payload}" "${mac}"
}

hub_constant_time_hex_equal() {
    local left="$1" right="$2"
    [[ "${left}" =~ ^[0-9a-f]{64}$ && "${right}" =~ ^[0-9a-f]{64}$ ]] || return 1
    perl -e '
        use strict;
        use warnings;

        my ($left, $right) = @ARGV;
        my $difference = 0;
        for my $index (0 .. 63) {
            $difference |= ord(substr($left, $index, 1))
                ^ ord(substr($right, $index, 1));
        }
        exit($difference == 0 ? 0 : 1);
    ' -- "${left}" "${right}" 2>/dev/null
}

# Define G_SELECTED com o caminho autenticado. O MAC é verificado antes de
# decodificar e antes de qualquer chamada ao Restic.
hub_decode_token() {
    local snap="$1" token="$2" payload supplied_mac expected_mac path canonical
    [[ "${token}" =~ ^v1\.([A-Za-z0-9_-]+)\.([0-9a-f]{64})$ ]] || return 1
    payload="${BASH_REMATCH[1]}"
    supplied_mac="${BASH_REMATCH[2]}"
    (( ${#payload} >= 2 && ${#payload} <= 5462 )) || return 1
    expected_mac="$(hub_token_hmac "${snap}" "${payload}")" || return 1
    hub_constant_time_hex_equal "${supplied_mac}" "${expected_mac}" || return 1
    path="$(hub_base64url_decode "${payload}")" || return 1
    [[ -n "${path}" ]] || return 1
    hub_path_is_safe "${path}" || return 1
    canonical="$(printf '%s' "${path}" | hub_base64url_encode)" || return 1
    [[ "${canonical}" == "${payload}" ]] || return 1
    G_SELECTED="${path}"
}

# Carrega apenas o necessário para operações read-only do HUB, sem mensagens
# interativas em stdout. Qualquer detalhe de credencial/repositório fica fora
# da resposta JSON pública.
hub_api_prepare() {
    local perms
    [[ $EUID -eq 0 || "${RESTIC_RESTORE_ALLOW_NONROOT:-0}" == "1" ]] \
        || { hub_json_error "not_authorized" "Operação não autorizada."; return 1; }
    command -v restic &>/dev/null \
        || { hub_json_error "dependency_unavailable" "Serviço de snapshots indisponível."; return 1; }
    command -v openssl &>/dev/null \
        || { hub_json_error "dependency_unavailable" "Serviço de tokens indisponível."; return 1; }
    perl -MJSON::PP -MMIME::Base64 -MEncode -MDigest::SHA -e 1 &>/dev/null \
        || { hub_json_error "dependency_unavailable" "Serviço de tokens indisponível."; return 1; }
    [[ -f "${RESTIC_ENV_FILE}" ]] \
        || { hub_json_error "configuration_unavailable" "Configuração de backup indisponível."; return 1; }
    perms="$(stat -c '%a' "${RESTIC_ENV_FILE}" 2>/dev/null \
        || stat -f '%Lp' "${RESTIC_ENV_FILE}" 2>/dev/null || true)"
    [[ "${perms}" == "600" || "${perms}" == "400" ]] \
        || { hub_json_error "configuration_invalid" "Configuração de backup inválida."; return 1; }

    # shellcheck source=/dev/null
    source "${RESTIC_ENV_FILE}" >/dev/null 2>&1 \
        || { hub_json_error "configuration_invalid" "Configuração de backup inválida."; return 1; }
    [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" \
        && -n "${RESTIC_PASSWORD:-}" && -n "${S3_BUCKET:-}" ]] \
        || { hub_json_error "configuration_invalid" "Configuração de backup inválida."; return 1; }
    [[ "${MIN_FREE_MB}" =~ ^[0-9]+$ && ${#MIN_FREE_MB} -le 9 ]] \
        || { hub_json_error "configuration_invalid" "Configuração de backup inválida."; return 1; }
    hub_token_key >/dev/null \
        || { hub_json_error "configuration_invalid" "Chave de tokens indisponível."; return 1; }
    export_restic_env
    restic cat config >/dev/null 2>>"${RESTORE_LOG_FILE}" \
        || { hub_json_error "repository_unavailable" "Repositório de snapshots indisponível."; return 1; }
}

hub_snapshot_exists() {
    local snap="$1"
    restic snapshots "${snap}" >/dev/null 2>>"${RESTORE_LOG_FILE}"
}

# Consulta exata do item. Define G_ITEM_TYPE e G_ITEM_SIZE; symlinks e tipos
# especiais permanecem distintos e nunca são aceitos como arquivo.
hub_get_item() {
    local snap="$1" wanted="$2" records t size encoded path
    G_ITEM_TYPE=""; G_ITEM_SIZE=""
    records="$(mktemp)" || return 1
    if ! restic_ls_records "${snap}" "${wanted}" >"${records}"; then
        rm -f "${records}"
        return 1
    fi
    while IFS=$'\t' read -r t size encoded; do
        path="$(decode_restic_path "${encoded}")" || continue
        [[ "${path}" == "${wanted}" ]] || continue
        G_ITEM_TYPE="${t}"
        G_ITEM_SIZE="${size}"
        break
    done < "${records}"
    rm -f "${records}"
    [[ -n "${G_ITEM_TYPE}" && "${G_ITEM_SIZE}" =~ ^[0-9]+$ && ${#G_ITEM_SIZE} -le 18 ]]
}

# Restic reporta size=0 no próprio nó de um diretório (não soma filhos). Para
# a checagem de espaço fazer sentido num diretório, somamos o size de todos
# os arquivos descendentes — `restic ls --json <snap> <dir>` já lista a
# árvore inteira recursivamente. Fail-closed: qualquer falha de leitura
# retorna 1 (chamada deve tratar como "não sei o tamanho", não como "0").
# Limite bem acima de qualquer backup real (~9.2 EB, o teto de um inteiro
# assinado de 64 bits usado pelo bash em $(( ))) — existe só para que a
# checagem de overflow abaixo tenha uma margem segura para operar antes de
# `total + size` estourar o range e virar lixo silencioso (bash não detecta
# overflow de aritmética).
readonly HUB_DIR_SIZE_LIMIT=9000000000000000000

hub_dir_total_size() {
    local snap="$1" dir="$2" records t size encoded total=0
    records="$(mktemp)" || return 1
    if ! restic_ls_records "${snap}" "${dir}" >"${records}"; then
        rm -f "${records}"
        return 1
    fi
    while IFS=$'\t' read -r t size encoded; do
        [[ "${t}" == "f" ]] || continue
        [[ "${size}" =~ ^[0-9]+$ && "${#size}" -le 18 ]] || continue
        # Checa ANTES de somar: total > limite - size prova que a soma
        # estouraria o limite, sem nunca deixar `total + size` executar
        # perto do teto do inteiro de 64 bits do bash.
        if (( total > HUB_DIR_SIZE_LIMIT - size )); then
            rm -f "${records}"
            return 1
        fi
        total=$((total + size))
    done < "${records}"
    rm -f "${records}"
    [[ "${total}" =~ ^[0-9]+$ && "${#total}" -le 18 ]] || return 1
    G_ITEM_SIZE="${total}"
}

run_hub_list() {
    local snap="$1" token="${2:-}" dir="/" i path type name item_token
    local items="" count=0 truncated=false

    if [[ -n "${token}" ]]; then
        if ! hub_decode_token "${snap}" "${token}"; then
            hub_json_error "invalid_token" "Token inválido."
            return 1
        fi
        dir="${G_SELECTED}"
    fi
    if ! hub_api_prepare; then return 1; fi
    if ! hub_snapshot_exists "${snap}"; then
        hub_json_error "snapshot_not_found" "Snapshot não encontrado."
        return 1
    fi
    if [[ "${dir}" != "/" ]]; then
        if ! hub_get_item "${snap}" "${dir}"; then
            hub_json_error "item_not_found" "Item não encontrado no snapshot."
            return 1
        fi
        [[ "${G_ITEM_TYPE}" == "d" ]] || {
            hub_json_error "not_a_directory" "O item não é um diretório."
            return 1
        }
    fi
    if ! snap_ls_dir "${snap}" "${dir}" "$((HUB_NAV_LIMIT + 1))"; then
        hub_json_error "snapshot_read_failed" "Falha ao ler o snapshot."
        return 1
    fi
    (( ${#G_PATHS[@]} > HUB_NAV_LIMIT )) && truncated=true

    for i in "${!G_PATHS[@]}"; do
        path="${G_PATHS[$i]}"; type="${G_TYPES[$i]}"
        # Symlinks, devices e outros tipos especiais não recebem token e não
        # podem entrar em nenhum fluxo posterior.
        [[ "${type}" == "d" || "${type}" == "f" ]] || continue
        hub_path_is_safe "${path}" || continue
        name="$(basename -- "${path}")"
        [[ ! "${name}" =~ [[:cntrl:]] ]] || continue
        if (( count >= HUB_NAV_LIMIT )); then
            truncated=true
            break
        fi
        item_token="$(hub_make_token "${snap}" "${path}")" || {
            hub_json_error "token_generation_failed" "Falha ao proteger item do snapshot."
            return 1
        }
        (( count > 0 )) && items+=","
        [[ "${type}" == "d" ]] && type="directory" || type="file"
        items+="{\"name\":\"$(hub_json_escape "${name}")\",\"type\":\"${type}\",\"token\":\"${item_token}\"}"
        ((count++))
    done
    printf '{"version":%d,"ok":true,"action":"list","snapshot":"%s","limit":%d,"truncated":%s,"items":[%s]}\n' \
        "${HUB_API_VERSION}" "${snap}" "${HUB_NAV_LIMIT}" "${truncated}" "${items}"
}

run_hub_preflight() {
    local snap="$1" token="$2" expected="$3" path actual target free_kb
    local available_mb required_mb threshold ready=false
    if ! hub_decode_token "${snap}" "${token}"; then
        hub_json_error "invalid_token" "Token inválido."
        return 1
    fi
    path="${G_SELECTED}"
    if ! hub_api_prepare; then return 1; fi
    if ! hub_snapshot_exists "${snap}"; then
        hub_json_error "snapshot_not_found" "Snapshot não encontrado."
        return 1
    fi
    if ! hub_get_item "${snap}" "${path}"; then
        hub_json_error "item_not_found" "Item não encontrado no snapshot."
        return 1
    fi
    case "${G_ITEM_TYPE}" in
        d) actual="directory" ;;
        f) actual="file" ;;
        l) hub_json_error "unsafe_symlink" "Symlink não pode ser restaurado por esta API."; return 1 ;;
        *) hub_json_error "unsupported_type" "Tipo de item não suportado."; return 1 ;;
    esac
    if [[ "${actual}" != "${expected}" ]]; then
        hub_json_error "type_mismatch" "O tipo do item não corresponde ao esperado."
        return 1
    fi

    # G_ITEM_SIZE de um diretório vem 0 do Restic (o nó não soma filhos) —
    # sem isso, a checagem de espaço abaixo cairia sempre no mínimo genérico
    # (MIN_FREE_MB), aceitando "pronto" mesmo quando o conteúdo real do
    # diretório não caiba no staging. Fail-closed: se não conseguir somar o
    # tamanho real, reporta falha em vez de seguir com um valor errado.
    if [[ "${actual}" == "directory" ]]; then
        if ! hub_dir_total_size "${snap}" "${path}"; then
            hub_json_error "size_check_failed" "Não foi possível calcular o tamanho do diretório."
            return 1
        fi
    fi

    # O preflight é read-only: usa o ancestral existente do staging e não cria
    # diretórios nem lê qualquer conteúdo local de staging.
    target="${RESTORE_STAGING_BASE}"
    while [[ ! -d "${target}" && "${target}" != "/" ]]; do
        target="$(dirname -- "${target}")"
    done
    free_kb="$(LC_ALL=C df -Pk "${target}" 2>/dev/null | awk 'NR == 2 {print $4}')"
    [[ "${free_kb}" =~ ^[0-9]+$ && ${#free_kb} -le 18 ]] || {
        hub_json_error "space_check_failed" "Não foi possível verificar o espaço disponível."
        return 1
    }
    available_mb=$((free_kb / 1024))
    required_mb=$(((G_ITEM_SIZE + 1048575) / 1048576))
    threshold="${MIN_FREE_MB}"
    (( required_mb > threshold )) && threshold="${required_mb}"
    (( available_mb >= threshold )) && ready=true

    printf '{"version":%d,"ok":true,"action":"preflight","snapshot":"%s","ready":%s,"item":{"type":"%s","token":"%s","size_bytes":%s},"space":{"available_mb":%d,"minimum_mb":%d,"required_mb":%d,"sufficient":%s}}\n' \
        "${HUB_API_VERSION}" "${snap}" "${ready}" "${actual}" "${token}" "${G_ITEM_SIZE}" \
        "${available_mb}" "${MIN_FREE_MB}" "${required_mb}" "${ready}"
}

hub_job_log_file()    { echo "${HUB_JOB_LOG_DIR}/${1}.log"; }
hub_job_status_file() { echo "${HUB_JOB_STATUS_DIR}/${1}.status"; }

# write_job_status <job_id> <linha> — grava atomicamente (mv sobre o mesmo fs).
write_job_status() {
    local job_id="$1" line="$2" status_file tmp
    status_file="$(hub_job_status_file "${job_id}")"
    tmp="$(mktemp "${HUB_JOB_STATUS_DIR}/.${job_id}.XXXXXX")"
    printf '%s\n' "${line}" > "${tmp}"
    chgrp hubrestore "${tmp}" 2>/dev/null || true
    chmod 640 "${tmp}"
    mv -f "${tmp}" "${status_file}"
}

# Fluxo completo do modo não-interativo. Nunca propaga erro pro shell do
# chamador: qualquer falha vira "failed <resumo>" no arquivo de status.
run_non_interactive() {
    local snap="$1" job_id="$2"

    mkdir -p "${HUB_JOB_LOG_DIR}" "${HUB_JOB_STATUS_DIR}" \
        || die "Não foi possível criar ${HUB_JOB_LOG_DIR}/${HUB_JOB_STATUS_DIR}."
    # Grupo hubrestore precisa LER (não escrever) — o wrapper hub-restore-shell
    # roda como hubrestore e só faz `cat` nesses arquivos/dirs.
    chgrp hubrestore "${HUB_JOB_LOG_DIR}" "${HUB_JOB_STATUS_DIR}" 2>/dev/null || true
    chmod 750 "${HUB_JOB_LOG_DIR}" "${HUB_JOB_STATUS_DIR}" 2>/dev/null || true

    valid_job_id "${job_id}"  || die "job_id inválido: ${job_id}"
    valid_snapshot_id "${snap}" || die "snapshot inválido: ${snap}"

    RESTORE_LOG_FILE="$(hub_job_log_file "${job_id}")"
    : > "${RESTORE_LOG_FILE}" 2>/dev/null || true
    chgrp hubrestore "${RESTORE_LOG_FILE}" 2>/dev/null || true
    chmod 640 "${RESTORE_LOG_FILE}" 2>/dev/null || true

    write_job_status "${job_id}" "running"
    info "Job ${job_id}: restauração não-interativa do snapshot ${snap} iniciada."

    require_root
    if ! load_env_file 2>>"${RESTORE_LOG_FILE}"; then
        write_job_status "${job_id}" "failed env: ${RESTIC_ENV_FILE} indisponível/inválido"
        exit 1
    fi
    if ! validate_env 2>>"${RESTORE_LOG_FILE}"; then
        write_job_status "${job_id}" "failed variáveis obrigatórias ausentes em ${RESTIC_ENV_FILE}"
        exit 1
    fi
    export_restic_env

    if ! check_repo 2>>"${RESTORE_LOG_FILE}"; then
        write_job_status "${job_id}" "failed não foi possível abrir o repositório restic"
        exit 1
    fi

    if ! restic snapshots "${snap}" >/dev/null 2>>"${RESTORE_LOG_FILE}"; then
        write_job_status "${job_id}" "failed snapshot ${snap} não encontrado"
        exit 1
    fi

    ensure_staging
    if ! check_free_space "${STAGING_DIR}" 2>>"${RESTORE_LOG_FILE}"; then
        write_job_status "${job_id}" "failed espaço livre insuficiente no staging"
        exit 1
    fi

    step "Job ${job_id}: restaurando snapshot ${snap} (completo) → ${STAGING_DIR}"
    if run_restore "${snap}" "/" "${STAGING_DIR}"; then
        info "Job ${job_id}: restauração concluída em ${STAGING_DIR}."
        write_job_status "${job_id}" "success ${STAGING_DIR}"
    else
        error "Job ${job_id}: restauração falhou. Veja ${RESTORE_LOG_FILE}."
        write_job_status "${job_id}" "failed restic restore retornou erro — veja ${RESTORE_LOG_FILE}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# RESTAURAÇÃO SELETIVA (issue #9) — staging isolado por job, expira em 24h
# ---------------------------------------------------------------------------
# Acionado via:
#   restic-restore.sh --hub-restore-item --snapshot <id> --token <tok> --job <job_id>
#   restic-restore.sh --hub-cleanup [--job <job_id>]
#
# Cada job materializa SOMENTE o item apontado pelo token (arquivo ou
# diretório) em ${HUB_ITEM_STAGING_DIR}/<job_id>/, isolado dos demais jobs e
# de produção. Metadados (seleção, estado, destino, expiração) ficam em
# meta.json no mesmo diretório. Só um job pode estar "running" por vez no
# servidor (lock global) — o Restic, uma vez iniciado, não é cancelável.

valid_job_id_selective() { [[ "$1" =~ ${JOB_ID_RE} ]]; }

# job_dir/
#   control/   meta.json, job.log, .ready — nunca no caminho do restic
#   data/      --target real do Restic (só o conteúdo restaurado do item)
# Separado de propósito: o item selecionado pode legitimamente ser um
# arquivo/diretório raiz chamado "meta.json", "job.log" ou ".ready" — sem
# essa separação, restaurar esse item sobrescreveria os próprios controles
# do job no mesmo golpe.
hub_item_job_dir()     { printf '%s/%s' "${HUB_ITEM_STAGING_DIR}" "$1"; }
hub_item_control_dir() { printf '%s/%s/control' "${HUB_ITEM_STAGING_DIR}" "$1"; }
hub_item_data_dir()    { printf '%s/%s/data' "${HUB_ITEM_STAGING_DIR}" "$1"; }
hub_item_meta_file()   { printf '%s/%s/control/meta.json' "${HUB_ITEM_STAGING_DIR}" "$1"; }
hub_item_log_file()    { printf '%s/%s/control/job.log' "${HUB_ITEM_STAGING_DIR}" "$1"; }
hub_item_ready_file()  { printf '%s/%s/control/.ready' "${HUB_ITEM_STAGING_DIR}" "$1"; }

# write_job_meta <job_id> <snapshot> <path> <item_type> <status> <created_at> <expires_at>
# Grava atomicamente (mv sobre o mesmo fs). Campos alinhados ao pedido da
# issue: seleção (snapshot/path/item_type), estado, destino (dir do job) e
# expiração.
write_job_meta() {
    local job_id="$1" snap="$2" path="$3" item_type="$4" status="$5" created="$6" expires="$7"
    local dir data_dir tmp
    dir="$(hub_item_control_dir "${job_id}")"
    data_dir="$(hub_item_data_dir "${job_id}")"
    tmp="$(mktemp "${dir}/.meta.XXXXXX")" || return 1
    if ! printf '{"version":%d,"job_id":"%s","snapshot":"%s","path":"%s","item_type":"%s","status":"%s","created_at":%d,"expires_at":%d,"staging_dir":"%s"}\n' \
        "${HUB_API_VERSION}" "$(hub_json_escape "${job_id}")" "$(hub_json_escape "${snap}")" \
        "$(hub_json_escape "${path}")" "$(hub_json_escape "${item_type}")" "$(hub_json_escape "${status}")" \
        "${created}" "${expires}" "$(hub_json_escape "${data_dir}")" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    chgrp hubrestore "${tmp}" 2>/dev/null || true
    chmod 640 "${tmp}" || { rm -f "${tmp}"; return 1; }
    mv -f "${tmp}" "$(hub_item_meta_file "${job_id}")"
}

# Atualiza só o campo "status" do meta.json existente, preservando o resto.
update_job_meta_status() {
    local job_id="$1" status="$2" meta dir tmp
    meta="$(hub_item_meta_file "${job_id}")"
    [[ -f "${meta}" ]] || return 1
    dir="$(hub_item_control_dir "${job_id}")"
    tmp="$(mktemp "${dir}/.meta.XXXXXX")" || return 1
    if ! perl -MJSON::PP -MEncode=decode_utf8 -e '
        local $/;
        my $data = decode_json(<STDIN>);
        $data->{status} = decode_utf8($ARGV[0]);
        print encode_json($data);
    ' "${status}" < "${meta}" > "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        return 1
    fi
    chgrp hubrestore "${tmp}" 2>/dev/null || true
    chmod 640 "${tmp}"
    mv -f "${tmp}" "${meta}"
}

# Nenhum outro job "running" pode estar em andamento no servidor. O lock é
# mantido pela DURAÇÃO do restic restore (fd aberto no processo atual);
# como o Restic não é cancelável após iniciar, também não liberamos o lock
# antes de terminar. Reusada pelo cleanup (fd diferente) para não remover um
# job cujo dono real ainda está com o lock.
hub_item_acquire_lock() {
    local fd="${1:-9}"
    mkdir -p "$(dirname "${HUB_ITEM_LOCK_FILE}")" 2>/dev/null || true
    eval "exec ${fd}>\"\${HUB_ITEM_LOCK_FILE}\"" || return 1
    flock -n "${fd}"
}

# now_epoch/finalize_job_meta centralizam a transição final: toda saída do
# job (sucesso ou falha) grava status + finished_at antes de sair, para o
# meta.json nunca ficar preso em "running" quando o processo termina.
hub_item_finalize() {
    local job_id="$1" status="$2" exit_code="${3:-1}"
    local finished
    finished="$(date +%s)"
    if ! update_job_meta_status_finished "${job_id}" "${status}" "${finished}"; then
        error "Job ${job_id}: falha ao gravar meta.json final (status pretendido: ${status}) — inconsistência auditável em ${RESTORE_LOG_FILE:-log indisponível}."
        # A gravação final falhou: mesmo que o status pretendido fosse
        # "success" (exit_code=0), o rc do processo não pode mentir que deu
        # tudo certo quando o meta.json não reflete isso — força não-zero.
        exit_code=1
    fi
    exit "${exit_code}"
}

# nonce vem do hub-restore-shell (imprevisível, gerado por tentativa) e é
# gravado no marcador .ready SOMENTE depois de lock+job_dir+meta "running"
# garantidos. O wrapper compara o conteúdo do marcador contra o nonce que
# ele mesmo gerou antes de responder "ok" — um .ready de uma tentativa
# anterior (job_id reciclado após cleanup, por exemplo) tem um nonce
# diferente e não pode ser confundido com a preparação desta tentativa.
run_hub_restore_item() {
    local snap="$1" token="$2" job_id="$3" nonce="$4"
    local now expires job_dir control_dir data_dir item_type path item_size

    # Sinais herdados de uma sessão SSH que caia não devem interromper um
    # Restic já iniciado — o desacoplamento real é feito pelo hub-restore-shell
    # (setsid + redirecionamento), isto é defesa em profundidade caso o
    # processo ainda herde o trap TERM/HUP do shell interativo.
    trap '' TERM HUP

    valid_job_id_selective "${job_id}" || die "job_id inválido: ${job_id}"
    valid_snapshot_id "${snap}"        || die "snapshot inválido: ${snap}"
    [[ "${nonce}" =~ ^[A-Za-z0-9_-]{16,128}$ ]] || die "nonce inválido."

    mkdir -p "${HUB_ITEM_STAGING_DIR}" \
        || die "Não foi possível criar ${HUB_ITEM_STAGING_DIR}."
    chgrp hubrestore "${HUB_ITEM_STAGING_DIR}" 2>/dev/null || true
    chmod 750 "${HUB_ITEM_STAGING_DIR}" 2>/dev/null || true

    # Lock ANTES de qualquer checagem de existência do job_dir: sem isso, dois
    # jobs concorrentes com o MESMO job_id poderiam ambos passar por um
    # `[[ -e ]]` negativo antes de qualquer um criar o diretório (TOCTOU).
    if ! hub_item_acquire_lock 9; then
        die "outro job de restauração seletiva já está em execução neste servidor."
    fi

    job_dir="$(hub_item_job_dir "${job_id}")"
    # mkdir (sem -p) é atômico: EEXIST aqui é a prova definitiva de job_id
    # duplicado, sem a janela de tempo entre "checar" e "criar".
    if ! mkdir "${job_dir}" 2>/dev/null; then
        die "job ${job_id} já existe — job_id deve ser único."
    fi
    chmod 750 "${job_dir}"
    chgrp hubrestore "${job_dir}" 2>/dev/null || true

    # control/ (meta.json, job.log, .ready) e data/ (--target do Restic) são
    # subdiretórios separados: o item selecionado pode legitimamente se
    # chamar "meta.json" ou ".ready" no snapshot, e restaurá-lo não pode
    # sobrescrever os controles do próprio job.
    control_dir="$(hub_item_control_dir "${job_id}")"
    data_dir="$(hub_item_data_dir "${job_id}")"
    mkdir "${control_dir}" "${data_dir}" || die "Job ${job_id}: falha ao criar control/data em ${job_dir}."
    chmod 750 "${control_dir}" "${data_dir}"
    chgrp hubrestore "${control_dir}" "${data_dir}" 2>/dev/null || true

    RESTORE_LOG_FILE="$(hub_item_log_file "${job_id}")"
    : > "${RESTORE_LOG_FILE}" 2>/dev/null || true
    chgrp hubrestore "${RESTORE_LOG_FILE}" 2>/dev/null || true
    chmod 640 "${RESTORE_LOG_FILE}" 2>/dev/null || true

    now="$(date +%s)"
    expires=$((now + HUB_ITEM_TTL_SECONDS))

    require_root
    if ! hub_decode_token "${snap}" "${token}" 2>>"${RESTORE_LOG_FILE}"; then
        write_job_meta "${job_id}" "${snap}" "" "unknown" "running" "${now}" "${expires}" \
            || error "Job ${job_id}: falha ao gravar meta.json inicial."
        hub_item_finalize "${job_id}" "failed invalid_token" 1
    fi
    path="${G_SELECTED}"

    write_job_meta "${job_id}" "${snap}" "${path}" "unknown" "running" "${now}" "${expires}" \
        || die "Job ${job_id}: falha ao gravar meta.json inicial — abortando antes do Restic."
    info "Job ${job_id}: restauração seletiva iniciada — snapshot ${snap}, item ${path}."

    # Handshake com o hub-restore-shell: a partir daqui lock + job_dir +
    # meta.json "running" estão garantidos (todas as rejeições possíveis —
    # job duplicado via EEXIST do mkdir, lock ocupado, token inválido — já
    # aconteceram acima e teriam terminado o processo antes deste ponto). O
    # wrapper compara o conteúdo do marcador contra o nonce que ele mesmo
    # gerou — grava-lo é obrigatório: se a escrita falhar, o wrapper nunca vê
    # o nonce esperado e trata como falha, então uma falha aqui tem que
    # derrubar o job (não seguir tentando o Restic sem handshake confirmado).
    if ! printf '%s' "${nonce}" > "$(hub_item_ready_file "${job_id}")" 2>/dev/null; then
        hub_item_finalize "${job_id}" "failed não foi possível gravar o marcador de handshake" 1
    fi
    chgrp hubrestore "$(hub_item_ready_file "${job_id}")" 2>/dev/null || true
    chmod 640 "$(hub_item_ready_file "${job_id}")" 2>/dev/null || true

    if ! load_env_file_safe 2>>"${RESTORE_LOG_FILE}"; then
        hub_item_finalize "${job_id}" "failed env: ${RESTIC_ENV_FILE} indisponível/inválido" 1
    fi
    if ! validate_env_safe 2>>"${RESTORE_LOG_FILE}"; then
        hub_item_finalize "${job_id}" "failed variáveis obrigatórias ausentes em ${RESTIC_ENV_FILE}" 1
    fi
    export_restic_env

    if ! check_repo_safe 2>>"${RESTORE_LOG_FILE}"; then
        hub_item_finalize "${job_id}" "failed não foi possível abrir o repositório restic" 1
    fi
    if ! restic snapshots "${snap}" >/dev/null 2>>"${RESTORE_LOG_FILE}"; then
        hub_item_finalize "${job_id}" "failed snapshot ${snap} não encontrado" 1
    fi
    if ! hub_get_item "${snap}" "${path}" 2>>"${RESTORE_LOG_FILE}"; then
        hub_item_finalize "${job_id}" "failed item ${path} não encontrado no snapshot" 1
    fi
    case "${G_ITEM_TYPE}" in
        d) item_type="directory" ;;
        f) item_type="file" ;;
        *) hub_item_finalize "${job_id}" "failed tipo de item não suportado" 1 ;;
    esac
    # G_ITEM_SIZE de um diretório vem 0 do Restic (nó não soma filhos); sem
    # recalcular, check_free_space_fail_closed cairia no MIN_FREE_MB genérico
    # e poderia liberar espaço insuficiente para o conteúdo real. Fail-closed:
    # se não conseguir somar, falha aqui em vez de seguir com 0.
    if [[ "${item_type}" == "directory" ]]; then
        if ! hub_dir_total_size "${snap}" "${path}" 2>>"${RESTORE_LOG_FILE}"; then
            hub_item_finalize "${job_id}" "failed não foi possível calcular o tamanho do diretório" 1
        fi
    fi
    item_size="${G_ITEM_SIZE:-0}"
    write_job_meta "${job_id}" "${snap}" "${path}" "${item_type}" "running" "${now}" "${expires}" \
        || hub_item_finalize "${job_id}" "failed erro ao persistir meta.json antes do Restic" 1

    if ! check_free_space_fail_closed "${data_dir}" "${item_size}" 2>>"${RESTORE_LOG_FILE}"; then
        hub_item_finalize "${job_id}" "failed espaço livre insuficiente no staging" 1
    fi

    step "Job ${job_id}: restaurando ${path} (${item_type}) do snapshot ${snap} → ${data_dir}"
    if run_restore_exact "${snap}" "${path}" "${data_dir}"; then
        info "Job ${job_id}: restauração concluída em ${data_dir}."
        hub_item_finalize "${job_id}" "success" 0
    else
        error "Job ${job_id}: restauração falhou. Veja ${RESTORE_LOG_FILE}."
        hub_item_finalize "${job_id}" "failed restic restore retornou erro — veja ${RESTORE_LOG_FILE}" 1
    fi
}

# Igual a update_job_meta_status, mas também grava finished_at — chamada só
# nas transições finais (success/failed), nunca em "running".
update_job_meta_status_finished() {
    local job_id="$1" status="$2" finished="$3" meta dir tmp
    meta="$(hub_item_meta_file "${job_id}")"
    [[ -f "${meta}" ]] || return 1
    dir="$(hub_item_control_dir "${job_id}")"
    tmp="$(mktemp "${dir}/.meta.XXXXXX")" || return 1
    if ! perl -MJSON::PP -MEncode=decode_utf8 -e '
        local $/;
        my $data = decode_json(<STDIN>);
        $data->{status} = decode_utf8($ARGV[0]);
        $data->{finished_at} = $ARGV[1] + 0;
        print encode_json($data);
    ' "${status}" "${finished}" < "${meta}" > "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        return 1
    fi
    chgrp hubrestore "${tmp}" 2>/dev/null || true
    chmod 640 "${tmp}"
    mv -f "${tmp}" "${meta}"
}

# Remove um job expirado ou indicado explicitamente. Nunca aceita caminho
# arbitrário: sempre reconstrói o destino a partir de HUB_ITEM_STAGING_DIR +
# job_id validado, e confirma que o resultado é de fato um filho direto
# daquele diretório antes de apagar. Só remove depois de confirmar (com o
# lock global adquirido) que nenhum restore-item está com o job em "running"
# — evita apagar staging por baixo de uma restauração em andamento.
#
# hub_item_remove_job <job_id> [allow_expired_running]
# allow_expired_running=1 é usado SÓ pela varredura de cron: com o lock em
# mãos (prova de que nenhum restore-item está de fato ativo agora), um
# status "running" cujo expires_at já passou é necessariamente órfão —
# processo morto por crash/SIGKILL/reboot antes de finalizar o job, nunca
# vai liberar o lock nem atualizar o meta.json sozinho. Sem essa exceção,
# esse staging ficaria preso para sempre, quebrando a garantia de expiração
# em 24h. Exclusão ANTECIPADA (chamada explícita por job_id) nunca passa
# allow_expired_running=1 — running running é sempre recusado ali, mesmo
# expirado, para não apagar por engano algo que o operador não pediu.
hub_item_remove_job() {
    local job_id="$1" allow_expired_running="${2:-0}"
    local dir resolved_dir resolved_base meta status expires_at now

    valid_job_id_selective "${job_id}" || return 1
    dir="$(hub_item_job_dir "${job_id}")"
    [[ -d "${dir}" ]] || return 0

    # Lock não bloqueante em fd próprio (10): se outro processo (restore-item
    # do MESMO job, ou outro comando hub-cleanup) já segura o lock global, não
    # arriscamos apagar staging de um job possivelmente em andamento.
    if ! hub_item_acquire_lock 10; then
        warn "Job ${job_id}: lock de restauração seletiva ocupado — limpeza recusada (pode haver job ativo)."
        return 1
    fi

    # Revalida o status DEPOIS de segurar o lock: um restore-item que tenha
    # terminado entre a checagem anterior e agora já teria liberado o lock,
    # então chegar aqui com o lock em mãos garante que "running" é o estado
    # real, não uma leitura obsoleta.
    meta="$(hub_item_meta_file "${job_id}")"
    if [[ -f "${meta}" ]]; then
        status="$(perl -MJSON::PP -e 'local $/; my $d = eval { decode_json(<STDIN>) }; print $d->{status} // "" if ref $d eq "HASH";' < "${meta}" 2>/dev/null)"
        if [[ "${status}" == "running" ]]; then
            expires_at="$(perl -MJSON::PP -e 'local $/; my $d = eval { decode_json(<STDIN>) }; print $d->{expires_at} // "" if ref $d eq "HASH";' < "${meta}" 2>/dev/null)"
            now="$(date +%s)"
            if [[ "${allow_expired_running}" == "1" && "${expires_at}" =~ ^[0-9]+$ && now -ge expires_at ]]; then
                warn "Job ${job_id}: status running mas expirado (órfão — lock livre e expires_at no passado); removendo."
            else
                warn "Job ${job_id}: status running — limpeza recusada."
                exec 10>&-
                return 1
            fi
        fi
    fi

    resolved_base="$(cd "${HUB_ITEM_STAGING_DIR}" 2>/dev/null && pwd -P)" || { exec 10>&-; return 1; }
    resolved_dir="$(cd "${dir}" 2>/dev/null && pwd -P)" || { exec 10>&-; return 1; }
    if [[ "${resolved_dir}" != "${resolved_base}/${job_id}" ]]; then
        exec 10>&-
        return 1
    fi

    rm -rf -- "${resolved_dir}"
    local remove_rc=$?
    exec 10>&-
    return "${remove_rc}"
}

# Limpeza idempotente: sem --job, varre todos os jobs expirados (rodada via
# cron a cada N minutos). Com --job, apaga só aquele (exclusão antecipada).
# Idempotente nos dois casos: job/staging já ausente não é erro. Job "running"
# só é removido pela varredura quando já passou de expires_at (órfão de
# crash/SIGKILL/reboot); a exclusão antecipada por --job nunca remove um job
# "running", mesmo expirado.
run_hub_cleanup() {
    local target_job="${1:-}" job_id meta expires job_dir now removed=0

    [[ -d "${HUB_ITEM_STAGING_DIR}" ]] || { info "Nada a limpar (${HUB_ITEM_STAGING_DIR} não existe)."; return 0; }

    if [[ -n "${target_job}" ]]; then
        valid_job_id_selective "${target_job}" || die "job_id inválido: ${target_job}"
        if hub_item_remove_job "${target_job}"; then
            info "Job ${target_job}: staging removido (exclusão antecipada ou já ausente)."
        else
            die "Falha ao remover staging do job ${target_job} (ausente, lock ocupado ou job em execução)."
        fi
        return 0
    fi

    now="$(date +%s)"
    for job_dir in "${HUB_ITEM_STAGING_DIR}"/*/; do
        [[ -d "${job_dir}" ]] || continue
        job_id="$(basename -- "${job_dir}")"
        valid_job_id_selective "${job_id}" || continue
        meta="$(hub_item_meta_file "${job_id}")"
        expires=""
        if [[ -f "${meta}" ]]; then
            expires="$(perl -MJSON::PP -e 'local $/; my $d = decode_json(<STDIN>); print $d->{expires_at} // "";' < "${meta}" 2>/dev/null)"
        fi
        # meta ausente/corrompido (queda do cliente a meio caminho) também expira
        # — usa mtime do diretório como fallback.
        if [[ ! "${expires}" =~ ^[0-9]+$ ]]; then
            expires=$(( $(stat -c '%Y' "${job_dir}" 2>/dev/null || stat -f '%m' "${job_dir}" 2>/dev/null || echo "${now}") + HUB_ITEM_TTL_SECONDS ))
        fi
        (( now < expires )) && continue
        if hub_item_remove_job "${job_id}" 1; then
            info "Job ${job_id}: expirado, staging removido."
            removed=$((removed + 1))
        else
            warn "Job ${job_id}: falha ao remover staging expirado (ausente, lock ocupado ou em execução)."
        fi
    done
    info "Limpeza concluída: ${removed} job(s) removido(s)."
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

show_help() {
    cat <<'HELP'
restic-restore.sh — restauração interativa dos backups restic (CIPNET)

Uso:
  sudo restic-restore.sh           # abre o menu interativo
  sudo restic-restore.sh --help
  sudo restic-restore.sh --non-interactive --snapshot <id> --job <job_id>
                                    # restaura o snapshot completo p/ staging,
                                    # sem prompt (uso: HUB via hub-restore-shell)
  sudo restic-restore.sh --hub-list --snapshot <id> [--token <token>]
  sudo restic-restore.sh --hub-preflight --snapshot <id> --token <token> \
      --expect-type <file|directory>
                                    # API JSON read-only; uso interno do wrapper
  sudo restic-restore.sh --hub-restore-item --snapshot <id> --token <token> \
      --job <job_id>
                                    # restaura SÓ o item do token p/ staging
                                    # isolado do job, expira em 24h (issue #9)
  sudo restic-restore.sh --hub-cleanup [--job <job_id>]
                                    # remove staging(s) de item expirado(s);
                                    # com --job, exclusão antecipada de um job

O script carrega /etc/restic/env (o mesmo do backup), abre o repositório no
S3 e oferece um menu para restaurar arquivos, sites e bancos de dados de
qualquer snapshot. Por padrão tudo é restaurado em um diretório de staging
(/tmp/restauracao-<data>); sobrescrever produção ou importar banco exige
confirmação digitada (SOBRESCREVER / IMPORTAR) e oferece backup preventivo.

Variáveis opcionais (defina antes de rodar, se precisar):
  RESTIC_ENV_FILE=/outro/env       env alternativo (padrão /etc/restic/env)
  RESTORE_STAGING_BASE=/dir/base   base do staging (padrão /tmp/restauracao)
  RESTORE_LOG_FILE=/arquivo.log    log (padrão /var/log/restic-restore.log)

Modo --non-interactive usa caminhos fixos (não configuráveis, para bater
com o wrapper hub-restore-shell):
  log:    /var/log/hub-restore/<job_id>.log
  status: /var/lib/hub-restore/<job_id>.status

Modo --hub-restore-item usa caminho fixo (mesmo motivo):
  staging: /var/lib/hub-restore/items/<job_id>/ (log e meta.json dentro)
HELP
}

main() {
    local mode="interactive" snap_arg="" job_arg="" token_arg="" expected_type="" nonce_arg=""

    while (( $# > 0 )); do
        case "$1" in
            --help|-h) show_help; exit 0 ;;
            --non-interactive)
                [[ "${mode}" == "interactive" ]] || { echo "Modos incompatíveis" >&2; exit 1; }
                mode="restore"; shift ;;
            --hub-list)
                [[ "${mode}" == "interactive" ]] || { echo "Modos incompatíveis" >&2; exit 1; }
                mode="hub-list"; shift ;;
            --hub-preflight)
                [[ "${mode}" == "interactive" ]] || { echo "Modos incompatíveis" >&2; exit 1; }
                mode="hub-preflight"; shift ;;
            --hub-restore-item)
                [[ "${mode}" == "interactive" ]] || { echo "Modos incompatíveis" >&2; exit 1; }
                mode="hub-restore-item"; shift ;;
            --hub-cleanup)
                [[ "${mode}" == "interactive" ]] || { echo "Modos incompatíveis" >&2; exit 1; }
                mode="hub-cleanup"; shift ;;
            --snapshot)
                [[ $# -ge 2 ]] || { echo "--snapshot exige um valor" >&2; exit 1; }
                snap_arg="$2"; shift 2 ;;
            --job)
                [[ $# -ge 2 ]] || { echo "--job exige um valor" >&2; exit 1; }
                job_arg="$2"; shift 2 ;;
            --token)
                [[ $# -ge 2 ]] || { echo "--token exige um valor" >&2; exit 1; }
                token_arg="$2"; shift 2 ;;
            --expect-type)
                [[ $# -ge 2 ]] || { echo "--expect-type exige um valor" >&2; exit 1; }
                expected_type="$2"; shift 2 ;;
            --nonce)
                [[ $# -ge 2 ]] || { echo "--nonce exige um valor" >&2; exit 1; }
                nonce_arg="$2"; shift 2 ;;
            *) echo "Argumento desconhecido: $1" >&2; exit 1 ;;
        esac
    done

    # Evita avisos de cwd ao rodar comandos como o usuário postgres via sudo.
    cd / || true

    if [[ "${mode}" == "restore" ]]; then
        [[ -n "${snap_arg}" ]] || { echo "--non-interactive exige --snapshot <id>" >&2; exit 1; }
        [[ -n "${job_arg}" ]]  || { echo "--non-interactive exige --job <job_id>" >&2; exit 1; }
        [[ -z "${token_arg}" && -z "${expected_type}" && -z "${nonce_arg}" ]] \
            || { echo "--token/--expect-type/--nonce não pertencem ao modo de restauração" >&2; exit 1; }
        run_non_interactive "${snap_arg}" "${job_arg}"
        return
    fi

    if [[ "${mode}" == "hub-list" ]]; then
        valid_snapshot_id "${snap_arg}" \
            || { hub_json_error "invalid_snapshot" "Identificador de snapshot inválido."; exit 1; }
        [[ -z "${job_arg}" && -z "${expected_type}" && -z "${nonce_arg}" ]] \
            || { hub_json_error "invalid_arguments" "Argumentos inválidos."; exit 1; }
        run_hub_list "${snap_arg}" "${token_arg}"
        return
    fi

    if [[ "${mode}" == "hub-preflight" ]]; then
        valid_snapshot_id "${snap_arg}" \
            || { hub_json_error "invalid_snapshot" "Identificador de snapshot inválido."; exit 1; }
        [[ -z "${job_arg}" && -z "${nonce_arg}" && -n "${token_arg}" \
            && ( "${expected_type}" == "file" || "${expected_type}" == "directory" ) ]] \
            || { hub_json_error "invalid_arguments" "Argumentos inválidos."; exit 1; }
        run_hub_preflight "${snap_arg}" "${token_arg}" "${expected_type}"
        return
    fi

    if [[ "${mode}" == "hub-restore-item" ]]; then
        [[ -n "${snap_arg}" ]]  || { echo "--hub-restore-item exige --snapshot <id>" >&2; exit 1; }
        [[ -n "${token_arg}" ]] || { echo "--hub-restore-item exige --token <token>" >&2; exit 1; }
        [[ -n "${job_arg}" ]]   || { echo "--hub-restore-item exige --job <job_id>" >&2; exit 1; }
        [[ -n "${nonce_arg}" ]] || { echo "--hub-restore-item exige --nonce <valor>" >&2; exit 1; }
        [[ -z "${expected_type}" ]] \
            || { echo "--expect-type não pertence a --hub-restore-item" >&2; exit 1; }
        run_hub_restore_item "${snap_arg}" "${token_arg}" "${job_arg}" "${nonce_arg}"
        return
    fi

    if [[ "${mode}" == "hub-cleanup" ]]; then
        [[ -z "${snap_arg}" && -z "${token_arg}" && -z "${expected_type}" && -z "${nonce_arg}" ]] \
            || { echo "--hub-cleanup só aceita --job" >&2; exit 1; }
        run_hub_cleanup "${job_arg}"
        return
    fi

    # Flags de modos remotos nunca são ignoradas no menu interativo.
    if [[ -n "${snap_arg}" || -n "${job_arg}" || -n "${token_arg}" || -n "${expected_type}" || -n "${nonce_arg}" ]]; then
        echo "Flags remotas exigem um modo explícito" >&2
        exit 1
    fi

    require_root
    load_env_file
    validate_env
    export_restic_env
    check_repo
    warn_if_backup_running
    main_menu
}

main "$@"
