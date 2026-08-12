#!/bin/bash
# Testes comportamentais e de segurança da restauração seletiva (issue #9):
# staging isolado por job, expirável em 24h, job único por servidor, limpeza
# idempotente. Usa somente cópias temporárias e mocks; nunca acessa
# Restic/S3 reais.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hub-selective-restore.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

MOCK_BIN="${TMP_DIR}/bin"
RESTORE_COPY="${TMP_DIR}/restic-restore.sh"
SHELL_COPY="${TMP_DIR}/hub-restore-shell"
ENV_FILE="${TMP_DIR}/restic.env"
TOKEN_KEY_FILE="${TMP_DIR}/hub-token.key"
RESTORE_LOG="${TMP_DIR}/restore.log"
CALL_LOG="${TMP_DIR}/restic.calls"
SUDO_LOG="${TMP_DIR}/sudo.calls"
DF_LOG="${TMP_DIR}/df.calls"
LOGGER_LOG="${TMP_DIR}/logger.calls"
ITEM_STAGING_DIR="${TMP_DIR}/items"
LOCK_FILE="${TMP_DIR}/job.lock"
OUT_FILE="${TMP_DIR}/stdout"
ERR_FILE="${TMP_DIR}/stderr"

SNAPSHOT="01234567"
TOKEN_KEY_HEX="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

PASS_COUNT=0

fail() {
    echo "not ok - $*" >&2
    if [[ -s "${OUT_FILE}" ]]; then echo "stdout:" >&2; sed -n '1,20p' "${OUT_FILE}" >&2; fi
    if [[ -s "${ERR_FILE}" ]]; then echo "stderr:" >&2; sed -n '1,20p' "${ERR_FILE}" >&2; fi
    exit 1
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "ok ${PASS_COUNT} - $*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "comando obrigatório ausente no ambiente de teste: $1"
}

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    [[ "${actual}" == "${expected}" ]] || fail "${label}: esperado '${expected}', recebido '${actual}'"
}

assert_contains() {
    local file="$1" text="$2" label="$3"
    grep -F -- "${text}" "${file}" >/dev/null 2>&1 || fail "${label}: texto ausente: ${text}"
}

json_field() {
    local file="$1" key="$2"
    "${PYTHON_BIN}" - "${file}" "${key}" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
print(data[sys.argv[2]])
PY
}

token_for_path() {
    local snapshot="$1" path="$2"
    "${PYTHON_BIN}" - "${snapshot}" "${path}" "${TOKEN_KEY_HEX}" <<'PY'
import base64, hashlib, hmac, sys
snapshot = sys.argv[1].encode("ascii")
path = sys.argv[2].encode("utf-8")
key = bytes.fromhex(sys.argv[3])
payload = base64.urlsafe_b64encode(path).rstrip(b"=")
mac = hmac.new(key, b"v1\0" + snapshot + b"\0" + payload, hashlib.sha256).hexdigest()
print("v1." + payload.decode("ascii") + "." + mac)
PY
}

run_restore() {
    : > "${OUT_FILE}"; : > "${ERR_FILE}"
    env \
        PATH="${MOCK_BIN}:${PATH}" \
        RESTIC_ENV_FILE="${ENV_FILE}" \
        RESTORE_LOG_FILE="${RESTORE_LOG}" \
        RESTIC_RESTORE_ALLOW_NONROOT=1 \
        MOCK_RESTIC_FAIL="${MOCK_RESTIC_FAIL:-}" \
        MOCK_DF_MODE="${MOCK_DF_MODE:-normal}" \
        MOCK_CALL_LOG="${CALL_LOG}" \
        MOCK_DF_LOG="${DF_LOG}" \
        MOCK_SUDO_LOG="${SUDO_LOG}" \
        MOCK_LOGGER_LOG="${LOGGER_LOG}" \
        "${RESTORE_COPY}" "$@" >"${OUT_FILE}" 2>"${ERR_FILE}"
    RUN_RC=$?
}

require_command bash
require_command openssl
require_command perl
if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python)"
else
    fail "python3/python é necessário somente para validar JSON nos testes"
fi

mkdir -p "${MOCK_BIN}"
cp "${ROOT_DIR}/restaurar_backup.sh" "${RESTORE_COPY}"
cp "${ROOT_DIR}/hub-restore-shell" "${SHELL_COPY}"

# Ajusta só as constantes absolutas na cópia descartável — mesmo padrão de
# tests/hub-snapshot-navigation.sh.
TEST_KEY_FILE="${TOKEN_KEY_FILE}" TEST_ITEM_DIR="${ITEM_STAGING_DIR}" TEST_LOCK_FILE="${LOCK_FILE}" \
    perl -0pi -e '
        my $key = qq{readonly HUB_TOKEN_KEY_FILE="$ENV{TEST_KEY_FILE}"};
        my $items = qq{readonly HUB_ITEM_STAGING_DIR="$ENV{TEST_ITEM_DIR}"};
        my $lock = qq{readonly HUB_ITEM_LOCK_FILE="$ENV{TEST_LOCK_FILE}"};
        s{\Qreadonly HUB_TOKEN_KEY_FILE="/etc/restic/hub-token.key"\E}{$key};
        s{\Qreadonly HUB_ITEM_STAGING_DIR="/var/lib/hub-restore/items"\E}{$items};
        s{\Qreadonly HUB_ITEM_LOCK_FILE="/var/lib/hub-restore/.job.lock"\E}{$lock};
    ' "${RESTORE_COPY}"

cat > "${ENV_FILE}" <<'ENV'
AWS_ACCESS_KEY_ID='fixture-access'
AWS_SECRET_ACCESS_KEY='fixture-secret'
AWS_DEFAULT_REGION='us-east-1'
S3_BUCKET='fixture-bucket'
RESTIC_S3_PREFIX='Restic/fixture'
RESTIC_PASSWORD='fixture-restic-password'
MIN_FREE_MB='2048'
ENV
printf '%s\n' "${TOKEN_KEY_HEX}" > "${TOKEN_KEY_FILE}"
chmod 600 "${ENV_FILE}" "${TOKEN_KEY_FILE}"
chmod +x "${RESTORE_COPY}" "${SHELL_COPY}"

cat > "${MOCK_BIN}/restic" <<'MOCK'
#!/bin/bash
set -uo pipefail
{
    printf 'restic argc=%d' "$#"
    for arg in "$@"; do printf ' <%q>' "${arg}"; done
    printf '\n'
} >> "${MOCK_CALL_LOG}"

[[ "${MOCK_RESTIC_FAIL:-}" == "$1" ]] && exit 17

case "$1" in
    cat)
        [[ "$#" -eq 2 && "$2" == "config" ]] || exit 91
        exit 0
        ;;
    snapshots)
        [[ "$#" -eq 2 ]] || exit 92
        [[ "$2" == "01234567" ]] && exit 0
        exit 1
        ;;
    ls)
        [[ "$#" -eq 4 && "$2" == "--json" ]] || exit 93
        path="$4"
        case "${path}" in
            /arquivo.txt)
                echo '{"struct_type":"node","path":"/arquivo.txt","type":"file","size":42}'
                ;;
            /diretorio)
                echo '{"struct_type":"node","path":"/diretorio","type":"dir","size":0}'
                ;;
            *) exit 1 ;;
        esac
        ;;
    restore)
        [[ "$#" -ge 5 && "$3" == "--target" ]] || exit 95
        exit 0
        ;;
    *) exit 94 ;;
esac
MOCK

cat > "${MOCK_BIN}/df" <<'MOCK'
#!/bin/bash
set -uo pipefail
printf 'df argc=%d <%s>\n' "$#" "$*" >> "${MOCK_DF_LOG}"
case "${MOCK_DF_MODE:-normal}" in
    low) available=1024 ;;
    normal) available=5242880 ;;
    *) exit 20 ;;
esac
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '/dev/mock 10485760 1 %s 1%% /tmp\n' "${available}"
MOCK

cat > "${MOCK_BIN}/logger" <<'MOCK'
#!/bin/bash
printf 'logger argc=%d <%s>\n' "$#" "$*" >> "${MOCK_LOGGER_LOG}"
MOCK

chmod +x "${MOCK_BIN}/restic" "${MOCK_BIN}/df" "${MOCK_BIN}/logger"

# flock real é exigido (produção é sempre Linux/RunCloud). Se o sistema local
# de teste não tiver util-linux (ex.: macOS), pula só os cenários que
# precisam de execução real do modo --hub-restore-item — os demais (cleanup,
# validação de job_id) não dependem de flock e continuam rodando.
HAVE_FLOCK=1
command -v flock >/dev/null 2>&1 || HAVE_FLOCK=0
: > "${CALL_LOG}"; : > "${DF_LOG}"; : > "${LOGGER_LOG}"

TOKEN_FILE="$(token_for_path "${SNAPSHOT}" "/arquivo.txt")"
TOKEN_DIR="$(token_for_path "${SNAPSHOT}" "/diretorio")"
TOKEN_MISSING="$(token_for_path "${SNAPSHOT}" "/nao-existe")"

if (( HAVE_FLOCK )); then
    # 1. Arquivo: materializa só o item, meta.json completo, staging isolado.
    run_restore --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --job job-file-1
    assert_eq "0" "${RUN_RC}" "restauração de arquivo"
    [[ -f "${ITEM_STAGING_DIR}/job-file-1/meta.json" ]] || fail "meta.json ausente (arquivo)"
    assert_eq "success" "$(json_field "${ITEM_STAGING_DIR}/job-file-1/meta.json" status)" "status final (arquivo)"
    assert_eq "file" "$(json_field "${ITEM_STAGING_DIR}/job-file-1/meta.json" item_type)" "item_type (arquivo)"
    assert_eq "/arquivo.txt" "$(json_field "${ITEM_STAGING_DIR}/job-file-1/meta.json" path)" "path persistido (arquivo)"
    [[ "$(json_field "${ITEM_STAGING_DIR}/job-file-1/meta.json" expires_at)" -gt "$(json_field "${ITEM_STAGING_DIR}/job-file-1/meta.json" created_at)" ]] \
        || fail "expires_at deve ser posterior a created_at"
    pass "restauração seletiva de arquivo materializa só o item em staging isolado"

    # 2. Diretório: mesmo fluxo, item_type=directory.
    run_restore --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_DIR}" --job job-dir-1
    assert_eq "0" "${RUN_RC}" "restauração de diretório"
    assert_eq "directory" "$(json_field "${ITEM_STAGING_DIR}/job-dir-1/meta.json" item_type)" "item_type (diretório)"
    [[ -d "${ITEM_STAGING_DIR}/job-dir-1" ]] || fail "staging do job-dir-1 ausente"
    [[ -d "${ITEM_STAGING_DIR}/job-file-1" ]] || fail "staging do job-file-1 deveria continuar existindo (isolado do job-dir-1)"
    pass "restauração seletiva de diretório usa staging isolado do job"

    # 3. Item ausente no snapshot: falha auditável, sem restic restore.
    : > "${CALL_LOG}"
    run_restore --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_MISSING}" --job job-missing-1
    assert_eq "1" "${RUN_RC}" "item ausente deve falhar"
    assert_contains "${ITEM_STAGING_DIR}/job-missing-1/meta.json" '"status":"failed item' "meta de item ausente"
    grep -q '^restic argc=[0-9]* <restore>' "${CALL_LOG}" && fail "não deveria chamar restic restore para item ausente"
    pass "item ausente no snapshot recusa e registra falha auditável, sem tentar restic restore"

    # 4. Pouco espaço: falha auditável antes do restic restore.
    : > "${CALL_LOG}"
    MOCK_DF_MODE=low run_restore --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --job job-lowspace-1
    assert_eq "1" "${RUN_RC}" "pouco espaço deve falhar"
    assert_contains "${ITEM_STAGING_DIR}/job-lowspace-1/meta.json" 'espaço livre insuficiente' "meta de pouco espaço"
    grep -q '^restic argc=[0-9]* <restore>' "${CALL_LOG}" && fail "não deveria chamar restic restore com pouco espaço"
    pass "pouco espaço recusa a restauração antes de tocar o restic"

    # 5. Job duplicado: mesmo job_id não pode ser reaproveitado.
    run_restore --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --job job-file-1
    [[ "${RUN_RC}" -ne 0 ]] || fail "job_id repetido deveria ser recusado"
    assert_contains "${ERR_FILE}" "já existe" "mensagem de job duplicado"
    pass "segundo job com o mesmo job_id é recusado"

    # 6. Falha do Restic: status failed auditável, staging preservado para inspeção.
    MOCK_RESTIC_FAIL=restore run_restore --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --job job-resticfail-1
    assert_eq "1" "${RUN_RC}" "falha do restic deve propagar rc != 0"
    assert_contains "${ITEM_STAGING_DIR}/job-resticfail-1/meta.json" '"status":"failed restic restore' "meta de falha do restic"
    [[ -d "${ITEM_STAGING_DIR}/job-resticfail-1" ]] || fail "staging da falha deve ser preservado para auditoria"
    pass "falha do Restic termina em failed auditável, staging preservado"
else
    echo "# aviso: 'flock' ausente neste sistema — pulando cenários 1-6 e 9 (execução real de --hub-restore-item)." >&2
fi

# 7. Queda do cliente a meio caminho: job sem meta.json (SSH caiu antes do
# primeiro write) ainda expira e é limpo pela varredura (usa mtime do dir).
mkdir -p "${ITEM_STAGING_DIR}/job-orphan-1"
touch -t 202001010000 "${ITEM_STAGING_DIR}/job-orphan-1"
run_restore --hub-cleanup
assert_eq "0" "${RUN_RC}" "cleanup geral"
[[ ! -d "${ITEM_STAGING_DIR}/job-orphan-1" ]] || fail "job órfão (sem meta.json) deveria expirar via mtime"
pass "job órfão por queda do cliente ainda expira e é limpo (fallback por mtime)"

# 8. Limpeza idempotente: rodar de novo sem alvo não falha, mesmo sem nada a apagar.
run_restore --hub-cleanup
assert_eq "0" "${RUN_RC}" "segunda rodada de cleanup"
run_restore --hub-cleanup
assert_eq "0" "${RUN_RC}" "terceira rodada de cleanup (idempotente)"
pass "--hub-cleanup é idempotente quando não há nada a expirar"

# 9. Exclusão antecipada por job_id: só apaga o job pedido, preserva os demais.
if (( HAVE_FLOCK )); then
    [[ -d "${ITEM_STAGING_DIR}/job-file-1" ]] || fail "pré-condição: job-file-1 deveria existir antes da exclusão antecipada"
    run_restore --hub-cleanup --job job-file-1
    assert_eq "0" "${RUN_RC}" "exclusão antecipada"
    [[ ! -d "${ITEM_STAGING_DIR}/job-file-1" ]] || fail "exclusão antecipada não removeu o staging do job"
    [[ -d "${ITEM_STAGING_DIR}/job-dir-1" ]] || fail "exclusão antecipada não deveria afetar outros jobs"
    run_restore --hub-cleanup --job job-file-1
    assert_eq "0" "${RUN_RC}" "exclusão antecipada repetida (idempotente)"
    pass "exclusão antecipada remove só o job pedido e é idempotente ao repetir"
else
    # Sem flock: valida exclusão antecipada idempotente sobre um job inexistente.
    run_restore --hub-cleanup --job job-inexistente-1
    assert_eq "0" "${RUN_RC}" "exclusão antecipada de job inexistente (idempotente)"
    pass "exclusão antecipada de job inexistente não falha (idempotente)"
fi

# 10. Limpeza recusa job_id fora do formato (sem aceitar caminho arbitrário).
run_restore --hub-cleanup --job "../../etc"
[[ "${RUN_RC}" -ne 0 ]] || fail "job_id com traversal deveria ser recusado"
[[ -d "${ROOT_DIR}" ]] || fail "sanity: ROOT_DIR deveria continuar intacto"
pass "--hub-cleanup recusa job_id fora do formato, sem aceitar caminho arbitrário"

echo "${PASS_COUNT} verificações OK."
