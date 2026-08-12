#!/usr/bin/env bash
# Teste de integração do contrato de monitoramento Restic.
# Todos os executáveis externos são mocks locais; nenhuma chamada sai da máquina.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_SCRIPT="${ROOT_DIR}/configura_backup.sh"
JQ_BIN="$(command -v jq)"
TEST_TMP="$(mktemp -d)"
MOCK_BIN="${TEST_TMP}/bin"
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

cleanup() {
    rm -rf "${TEST_TMP}"
}
trap cleanup EXIT

fail() {
    echo "FALHOU: $*" >&2
    exit 1
}

assert_jq() {
    local file="$1" filter="$2"
    "${JQ_BIN}" -e "${filter}" "${file}" >/dev/null \
        || fail "assertion jq falhou (${filter}) em ${file}"
}

mkdir -p "${MOCK_BIN}"

create_mocks() {
    cat > "${MOCK_BIN}/restic" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_RESTIC_LOG}"

case "${1:-}" in
    cat|init|forget|check)
        exit 0
        ;;
    backup)
        [[ "${MOCK_RESTIC_MODE}" == "backup-failure" ]] && exit 1
        exit 0
        ;;
    stats)
        printf 'Total Size: 42 MiB\n'
        exit 0
        ;;
    snapshots)
        if [[ "${2:-}" == "latest" ]]; then
            printf '[{"short_id":"latest01","time":"2026-08-12T00:00:00Z","paths":["/home"]}]\n'
            exit 0
        fi
        case "${MOCK_RESTIC_MODE}" in
            snapshots-error)
                exit 1
                ;;
            snapshots-empty)
                printf '[]\n'
                ;;
            snapshots-invalid)
                printf '[{"short_id":"bad","time":"2026-08-12T00:00:00Z","paths":["/home"]}] conteudo-invalido\n'
                ;;
            *)
                cat "${MOCK_SNAPSHOTS_FILE}"
                ;;
        esac
        exit 0
        ;;
esac

exit 0
MOCK

    cat > "${MOCK_BIN}/mysql" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    *"SHOW DATABASES;"*)
        if [[ "${MOCK_PARTIAL}" == "true" ]]; then
            printf 'app_ok\nbad"db\tname\n'
        else
            printf 'app_ok\n'
        fi
        ;;
esac
MOCK

    cat > "${MOCK_BIN}/mysqldump" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
database="${!#}"
if [[ "${MOCK_PARTIAL}" == "true" && "${database}" == $'bad"db\tname' ]]; then
    exit 1
fi
printf -- '-- dump de %s\n' "${database}"
MOCK

    cat > "${MOCK_BIN}/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_AWS_LOG}"
cat > "${MOCK_AWS_CAPTURE}"
MOCK

    chmod +x "${MOCK_BIN}/restic" "${MOCK_BIN}/mysql" \
        "${MOCK_BIN}/mysqldump" "${MOCK_BIN}/aws"
}

run_case() {
    local name="$1" restic_mode="$2" partial="$3"
    local case_dir="${TEST_TMP}/${name}"
    mkdir -p "${case_dir}/source" "${case_dir}/db"

    cat > "${case_dir}/snapshots.json" <<'JSON'
[
  {
    "short_id": "abc123",
    "time": "2026-08-12T12:34:56Z",
    "paths": ["/home/site com espaco", "/home/aspas \"duplas\"", "/home/barra\\invertida", "/home/tab\tlinha\nfinal", "/home/unicode\u00e7"],
    "hostname": "interno",
    "tags": ["private"],
    "tree": "secret"
  }
]
JSON

    set +e
    PATH="${MOCK_BIN}:${SYSTEM_PATH}" \
    RESTIC_ENV_FILE="${case_dir}/env-inexistente" \
    STATUS_LOCAL_FILE="${case_dir}/status.json" \
    LOG_FILE="${case_dir}/backup.log" \
    LOCK_FILE="${case_dir}/backup.lock" \
    BACKUP_SOURCE="${case_dir}/source" \
    DB_DUMP_DIR="${case_dir}/db" \
    MIN_FREE_MB=0 \
    ENABLE_WEEKLY_ARCHIVES=false \
    AWS_ACCESS_KEY_ID=mock-key \
    AWS_SECRET_ACCESS_KEY=mock-secret \
    RESTIC_PASSWORD=mock-password \
    S3_BUCKET=mock-bucket \
    MOCK_RESTIC_MODE="${restic_mode}" \
    MOCK_PARTIAL="${partial}" \
    MOCK_SNAPSHOTS_FILE="${case_dir}/snapshots.json" \
    MOCK_RESTIC_LOG="${case_dir}/restic.log" \
    MOCK_AWS_LOG="${case_dir}/aws.log" \
    MOCK_AWS_CAPTURE="${case_dir}/aws.json" \
    bash "${BACKUP_SCRIPT}" > "${case_dir}/stdout.log" 2>&1
    CASE_EXIT_CODE=$?
    set -e

    CASE_DIR="${case_dir}"
    [[ -f "${CASE_DIR}/status.json" ]] || fail "${name}: status local não foi criado"
    "${JQ_BIN}" empty "${CASE_DIR}/status.json" || fail "${name}: status local inválido"
    [[ -s "${CASE_DIR}/restic.log" ]] || fail "${name}: mock restic não foi chamado"
    [[ -s "${CASE_DIR}/aws.log" ]] || fail "${name}: mock aws não foi chamado"
}

create_mocks

# Sucesso: versão explícita, redução pública, escapes, auditoria e upload mockado.
run_case success success false
[[ "${CASE_EXIT_CODE}" -eq 0 ]] || fail "success: saída esperada 0, recebeu ${CASE_EXIT_CODE}"
assert_jq "${CASE_DIR}/status.json" '
  .schema_version == 1 and .status == "success" and
  (.snapshots | length) == 1 and
  (.snapshots[0] | keys == ["paths", "short_id", "time"]) and
  .snapshots[0].paths == ["/home/site com espaco", "/home/aspas \"duplas\"", "/home/barra\\invertida", "/home/tab\tlinha\nfinal", "/home/unicodeç"] and
  (.errors | length) == 0
'
cmp -s "${CASE_DIR}/status.json" "${CASE_DIR}/aws.json" \
    || fail "success: JSON enviado ao aws mock diverge do arquivo local"
grep -F -- '--content-type application/json' "${CASE_DIR}/aws.log" >/dev/null \
    || fail "success: upload não declarou application/json"
grep -F -- 's3://mock-bucket/Monitoramento/' "${CASE_DIR}/aws.log" >/dev/null \
    || fail "success: destino de monitoramento não foi usado"

# Parcial: erro com aspas e tab continua como JSON válido e snapshots permanecem públicos.
run_case partial success true
[[ "${CASE_EXIT_CODE}" -eq 0 ]] || fail "partial: saída esperada 0, recebeu ${CASE_EXIT_CODE}"
assert_jq "${CASE_DIR}/status.json" '
  .schema_version == 1 and .status == "partial" and
  .databases.ok == 1 and .databases.failed == 1 and
  (.errors | any(contains("bad\"db\tname"))) and
  (.snapshots[0] | keys == ["paths", "short_id", "time"])
'

# Falha precoce: o trap ainda persiste um relatório JSON versionado e de erro.
run_case early-error backup-failure false
[[ "${CASE_EXIT_CODE}" -ne 0 ]] || fail "early-error: saída deveria falhar"
assert_jq "${CASE_DIR}/status.json" '
  .schema_version == 1 and .status == "error" and
  (.errors | length) > 0 and
  (has("snapshots") | not)
'

# Lista vazia deve ser distinta de falha de coleta: snapshots é [] e o estado permanece sucesso.
run_case empty snapshots-empty false
[[ "${CASE_EXIT_CODE}" -eq 0 ]] || fail "empty: saída esperada 0, recebeu ${CASE_EXIT_CODE}"
assert_jq "${CASE_DIR}/status.json" '.status == "success" and .snapshots == [] and (.errors | length) == 0'

# Falha do comando de coleta não invalida o restante; snapshots é omitido e o relatório vira parcial.
run_case snapshots-error snapshots-error false
[[ "${CASE_EXIT_CODE}" -eq 0 ]] || fail "snapshots-error: saída esperada 0, recebeu ${CASE_EXIT_CODE}"
assert_jq "${CASE_DIR}/status.json" '
  .schema_version == 1 and .status == "partial" and
  (has("snapshots") | not) and
  (.errors | any(contains("Falha ao listar snapshots restic para o status")))
'

# JSON Restic inválido também não é repassado nem invalida o envelope público.
run_case snapshots-invalid snapshots-invalid false
[[ "${CASE_EXIT_CODE}" -eq 0 ]] || fail "snapshots-invalid: saída esperada 0, recebeu ${CASE_EXIT_CODE}"
assert_jq "${CASE_DIR}/status.json" '
  .schema_version == 1 and .status == "partial" and
  (has("snapshots") | not) and
  (.errors | any(contains("Falha ao processar snapshots restic para o status")))
'

echo "OK: monitoramento Restic coberto sem rede ou binários reais"
