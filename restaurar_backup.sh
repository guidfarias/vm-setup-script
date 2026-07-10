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
G_PATHS=(); G_TYPES=()
G_SELECTED=""

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

# O caminho existe no snapshot? (a saída do `restic ls` lista caminhos com /)
path_in_snapshot() {
    local snap="$1" path="$2"
    restic ls "${snap}" "${path}" 2>/dev/null | grep -q '^/'
}

# Lista UM nível de <dir> no snapshot. Preenche G_TYPES[i] (d=dir, f=outro)
# e G_PATHS[i] (caminho absoluto). Limita a RESTORE_LS_LIMIT itens.
snap_ls_dir() {
    local snap="$1" dir="$2"
    G_PATHS=(); G_TYPES=()
    local t p line
    while IFS=$'\t' read -r t p; do
        [[ -z "${p}" || "${p}" == "${dir}" ]] && continue
        G_TYPES+=("${t}")
        G_PATHS+=("${p}")
        (( ${#G_PATHS[@]} >= RESTORE_LS_LIMIT )) && break
    done < <(restic ls --long "${snap}" "${dir}" 2>>"${RESTORE_LOG_FILE}" \
        | awk '
            /^[a-z?-][rwxsStT?-]{9}[[:space:]]/ {
                mode = substr($0, 1, 1)
                line = $0
                for (i = 0; i < 6; i++) sub(/^[^[:space:]]+[[:space:]]+/, "", line)
                type = (mode == "d") ? "d" : "f"
                print type "\t" line
            }')
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

# restic restore com saída na tela E no log.
run_restore() {
    local snap="$1" path="$2" target="$3"; shift 3
    log_line "INFO " "restic restore ${snap} --target ${target} --include ${path} $*"
    restic restore "${snap}" --target "${target}" --include "${path}" "$@" \
        2>&1 | tee -a "${RESTORE_LOG_FILE}"
    return "${PIPESTATUS[0]}"
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
# MAIN
# ---------------------------------------------------------------------------

show_help() {
    cat <<'HELP'
restic-restore.sh — restauração interativa dos backups restic (CIPNET)

Uso:
  sudo restic-restore.sh           # abre o menu interativo
  sudo restic-restore.sh --help

O script carrega /etc/restic/env (o mesmo do backup), abre o repositório no
S3 e oferece um menu para restaurar arquivos, sites e bancos de dados de
qualquer snapshot. Por padrão tudo é restaurado em um diretório de staging
(/tmp/restauracao-<data>); sobrescrever produção ou importar banco exige
confirmação digitada (SOBRESCREVER / IMPORTAR) e oferece backup preventivo.

Variáveis opcionais (defina antes de rodar, se precisar):
  RESTIC_ENV_FILE=/outro/env       env alternativo (padrão /etc/restic/env)
  RESTORE_STAGING_BASE=/dir/base   base do staging (padrão /tmp/restauracao)
  RESTORE_LOG_FILE=/arquivo.log    log (padrão /var/log/restic-restore.log)
HELP
}

main() {
    for arg in "$@"; do
        case "${arg}" in
            --help|-h) show_help; exit 0 ;;
            *) echo "Argumento desconhecido: ${arg}" >&2; exit 1 ;;
        esac
    done

    # Evita avisos de cwd ao rodar comandos como o usuário postgres via sudo.
    cd / || true

    require_root
    load_env_file
    validate_env
    export_restic_env
    check_repo
    warn_if_backup_running
    main_menu
}

main "$@"
