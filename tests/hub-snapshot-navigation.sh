#!/bin/bash
# Testes comportamentais e de segurança da navegação/preflight de snapshots.
# Usa somente cópias temporárias e mocks; nunca acessa Restic/S3 ou staging real.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hub-snapshot-navigation.XXXXXX")"
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
STATUS_DIR="${TMP_DIR}/status"
JOB_LOG_DIR="${TMP_DIR}/jobs"
STAGING_PATH="${TMP_DIR}/staging-must-not-exist"
OUT_FILE="${TMP_DIR}/stdout"
ERR_FILE="${TMP_DIR}/stderr"

SNAPSHOT="01234567"
OTHER_SNAPSHOT="89abcdef"
MISSING_SNAPSHOT="deadbeef"
TOKEN_KEY_HEX="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

PASS_COUNT=0

fail() {
    echo "not ok - $*" >&2
    if [[ -s "${OUT_FILE}" ]]; then
        echo "stdout:" >&2
        sed -n '1,20p' "${OUT_FILE}" >&2
    fi
    if [[ -s "${ERR_FILE}" ]]; then
        echo "stderr:" >&2
        sed -n '1,20p' "${ERR_FILE}" >&2
    fi
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
    [[ "${actual}" == "${expected}" ]] \
        || fail "${label}: esperado '${expected}', recebido '${actual}'"
}

assert_contains() {
    local file="$1" text="$2" label="$3"
    grep -F -- "${text}" "${file}" >/dev/null 2>&1 || fail "${label}: texto ausente: ${text}"
}

assert_not_contains() {
    local file="$1" text="$2" label="$3"
    if grep -F -- "${text}" "${file}" >/dev/null 2>&1; then
        fail "${label}: texto inesperado: ${text}"
    fi
}

assert_empty() {
    [[ ! -s "$1" ]] || fail "$2: arquivo deveria estar vazio"
}

line_count() {
    if [[ -f "$1" ]]; then
        wc -l < "$1" | tr -d ' '
    else
        printf '0'
    fi
}

json_assert() {
    local file="$1" expression="$2" label="$3"
    "${PYTHON_BIN}" - "${file}" "${expression}" <<'PY' || fail "${label}"
import json
import sys

path, expression = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
safe = {"data": data, "set": set, "sorted": sorted, "all": all, "len": len, "next": next}
safe["__builtins__"] = {}
if not eval(expression, safe, {}):
    raise SystemExit(f"expressão falsa: {expression}; JSON={data!r}")
PY
}

json_get() {
    local file="$1" expression="$2"
    "${PYTHON_BIN}" - "${file}" "${expression}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
safe = {"data": data, "next": next}
safe["__builtins__"] = {}
value = eval(sys.argv[2], safe, {})
print(value)
PY
}

token_for_hex_path() {
    local snapshot="$1" path_hex="$2"
    "${PYTHON_BIN}" - "${snapshot}" "${path_hex}" "${TOKEN_KEY_HEX}" <<'PY'
import base64
import hashlib
import hmac
import sys

snapshot = sys.argv[1].encode("ascii")
path = bytes.fromhex(sys.argv[2])
key = bytes.fromhex(sys.argv[3])
payload = base64.urlsafe_b64encode(path).rstrip(b"=")
mac = hmac.new(key, b"v1\0" + snapshot + b"\0" + payload, hashlib.sha256).hexdigest()
print("v1." + payload.decode("ascii") + "." + mac)
PY
}

run_restore() {
    : > "${OUT_FILE}"
    : > "${ERR_FILE}"
    env \
        PATH="${MOCK_BIN}:${PATH}" \
        RESTIC_ENV_FILE="${ENV_FILE}" \
        RESTORE_LOG_FILE="${RESTORE_LOG}" \
        RESTORE_STAGING_BASE="${STAGING_PATH}" \
        RESTIC_RESTORE_ALLOW_NONROOT=1 \
        MOCK_RESTIC_FAIL="${MOCK_RESTIC_FAIL:-}" \
        MOCK_ITEM_REMOVED="${MOCK_ITEM_REMOVED:-0}" \
        MOCK_MANY_COUNT="${MOCK_MANY_COUNT:-0}" \
        MOCK_DF_MODE="${MOCK_DF_MODE:-normal}" \
        MOCK_CALL_LOG="${CALL_LOG}" \
        MOCK_DF_LOG="${DF_LOG}" \
        MOCK_SUDO_LOG="${SUDO_LOG}" \
        MOCK_LOGGER_LOG="${LOGGER_LOG}" \
        "${RESTORE_COPY}" "$@" >"${OUT_FILE}" 2>"${ERR_FILE}"
    RUN_RC=$?
}

run_wrapper() {
    local original_command="$1"
    : > "${OUT_FILE}"
    : > "${ERR_FILE}"
    env \
        PATH="${MOCK_BIN}:${PATH}" \
        SSH_ORIGINAL_COMMAND="${original_command}" \
        RESTIC_ENV_FILE="${ENV_FILE}" \
        RESTORE_LOG_FILE="${RESTORE_LOG}" \
        RESTORE_STAGING_BASE="${STAGING_PATH}" \
        RESTIC_RESTORE_ALLOW_NONROOT=1 \
        MOCK_RESTIC_FAIL="${MOCK_RESTIC_FAIL:-}" \
        MOCK_ITEM_REMOVED="${MOCK_ITEM_REMOVED:-0}" \
        MOCK_MANY_COUNT="${MOCK_MANY_COUNT:-0}" \
        MOCK_DF_MODE="${MOCK_DF_MODE:-normal}" \
        MOCK_CALL_LOG="${CALL_LOG}" \
        MOCK_DF_LOG="${DF_LOG}" \
        MOCK_SUDO_LOG="${SUDO_LOG}" \
        MOCK_LOGGER_LOG="${LOGGER_LOG}" \
        "${SHELL_COPY}" >"${OUT_FILE}" 2>"${ERR_FILE}"
    RUN_RC=$?
}

assert_error_json() {
    local expected_code="$1" label="$2"
    [[ "${RUN_RC}" -ne 0 ]] || fail "${label}: deveria retornar rc não-zero"
    assert_empty "${ERR_FILE}" "${label}"
    json_assert "${OUT_FILE}" \
        "set(data.keys()) == {'version','ok','error'} and data['version'] == 1 and data['ok'] is False and set(data['error'].keys()) == {'code','message'} and data['error']['code'] == '${expected_code}'" \
        "${label}: resposta de erro JSON inválida"
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

mkdir -p "${MOCK_BIN}" "${STATUS_DIR}" "${JOB_LOG_DIR}"
cp "${ROOT_DIR}/restaurar_backup.sh" "${RESTORE_COPY}"
cp "${ROOT_DIR}/hub-restore-shell" "${SHELL_COPY}"

# Ajusta apenas as constantes absolutas nas cópias descartáveis.
TEST_KEY_FILE="${TOKEN_KEY_FILE}" perl -0pi -e '
    my $replacement = qq{readonly HUB_TOKEN_KEY_FILE="$ENV{TEST_KEY_FILE}"};
    s{\Qreadonly HUB_TOKEN_KEY_FILE="/etc/restic/hub-token.key"\E}{$replacement};
' "${RESTORE_COPY}"
TEST_RESTORE_BIN="${RESTORE_COPY}" TEST_STATUS_DIR="${STATUS_DIR}" TEST_JOB_LOG_DIR="${JOB_LOG_DIR}" \
    perl -0pi -e '
        my $restore = qq{readonly RESTORE_BIN="$ENV{TEST_RESTORE_BIN}"};
        my $status = qq{readonly HUB_JOB_STATUS_DIR="$ENV{TEST_STATUS_DIR}"};
        my $logs = qq{readonly HUB_JOB_LOG_DIR="$ENV{TEST_JOB_LOG_DIR}"};
        s{\Qreadonly RESTORE_BIN="/usr/local/bin/restic-restore.sh"\E}{$restore};
        s{\Qreadonly HUB_JOB_STATUS_DIR="/var/lib/hub-restore"\E}{$status};
        s{\Qreadonly HUB_JOB_LOG_DIR="/var/log/hub-restore"\E}{$logs};
    ' "${SHELL_COPY}"

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
printf 'running\n' > "${STATUS_DIR}/existing-job.status"
printf 'fixture log\n' > "${JOB_LOG_DIR}/existing-job.log"
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
        case "$2" in
            01234567|89abcdef) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    ls)
        [[ "$#" -eq 4 && "$2" == "--json" ]] || exit 93
        [[ "$3" == "01234567" || "$3" == "89abcdef" ]] || exit 1
        path="$4"
        printf '{"struct_type":"snapshot","id":"%s","hostname":"must-not-leak","paths":["/secret/root"]}\n' "$3"
        if [[ "${MOCK_MANY_COUNT:-0}" -gt 0 && "${path}" == "/" ]]; then
            i=1
            while (( i <= MOCK_MANY_COUNT )); do
                printf '{"struct_type":"node","path":"/item-%03d","type":"file","size":1,"uid":99}\n' "${i}"
                i=$((i + 1))
            done
            exit 0
        fi
        if [[ "${MOCK_ITEM_REMOVED:-0}" == "1" && "${path}" == '/arquivo especial $;[].txt' ]]; then
            exit 0
        fi
        case "${path}" in
            /)
                cat <<'JSON'
{"struct_type":"node","path":"/","type":"dir","size":0}
{"struct_type":"node","path":"/home","type":"dir","size":0}
{"struct_type":"node","path":"/empty","type":"dir","size":0}
{"struct_type":"node","path":"/arquivo especial $;[].txt","type":"file","size":12}
{"struct_type":"node","path":"/aspas \"e\" unicode ç.txt","type":"file","size":20}
{"struct_type":"node","path":"/link-internal","type":"symlink","size":0}
{"struct_type":"node","path":"/link-external","type":"symlink","size":0}
{"struct_type":"node","path":"/device","type":"dev","size":0}
{"struct_type":"node","path":"/linha\ninjetada","type":"file","size":1}
{"struct_type":"node","path":"/home/descendente-oculto","type":"file","size":3}
JSON
                ;;
            /home)
                cat <<'JSON'
{"struct_type":"node","path":"/home","type":"dir","size":0}
{"struct_type":"node","path":"/home/subdir","type":"dir","size":0}
{"struct_type":"node","path":"/home/com espaço;$(printf INJECTED).txt","type":"file","size":33}
{"struct_type":"node","path":"/home/subdir/neto-oculto","type":"file","size":4}
JSON
                ;;
            /empty)
                echo '{"struct_type":"node","path":"/empty","type":"dir","size":0}'
                ;;
            /home/subdir)
                echo '{"struct_type":"node","path":"/home/subdir","type":"dir","size":0}'
                ;;
            '/arquivo especial $;[].txt')
                echo '{"struct_type":"node","path":"/arquivo especial $;[].txt","type":"file","size":12}'
                ;;
            '/aspas "e" unicode ç.txt')
                echo '{"struct_type":"node","path":"/aspas \"e\" unicode ç.txt","type":"file","size":20}'
                ;;
            '/home/com espaço;$(printf INJECTED).txt')
                echo '{"struct_type":"node","path":"/home/com espaço;$(printf INJECTED).txt","type":"file","size":33}'
                ;;
            /link-internal|/link-external)
                printf '{"struct_type":"node","path":"%s","type":"symlink","size":0}\n' "${path}"
                ;;
            /device)
                echo '{"struct_type":"node","path":"/device","type":"dev","size":0}'
                ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 94 ;;
esac
MOCK

cat > "${MOCK_BIN}/df" <<'MOCK'
#!/bin/bash
set -uo pipefail
printf 'df argc=%d <%s>\n' "$#" "$*" >> "${MOCK_DF_LOG}"
case "${MOCK_DF_MODE:-normal}" in
    fail) exit 19 ;;
    low) available=1048576 ;;
    normal) available=5242880 ;;
    *) exit 20 ;;
esac
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '/dev/mock 10485760 1 %s 1%% /tmp\n' "${available}"
MOCK

cat > "${MOCK_BIN}/sudo" <<'MOCK'
#!/bin/bash
set -uo pipefail
{
    printf 'sudo argc=%d' "$#"
    for arg in "$@"; do printf ' <%q>' "${arg}"; done
    printf '\n'
} >> "${MOCK_SUDO_LOG}"
[[ "$1" == "-n" ]] || exit 80
shift
if [[ " $* " == *' --non-interactive '* ]]; then
    exit 0
fi
exec "$@"
MOCK

cat > "${MOCK_BIN}/logger" <<'MOCK'
#!/bin/bash
printf 'logger argc=%d <%s>\n' "$#" "$*" >> "${MOCK_LOGGER_LOG}"
MOCK

chmod +x "${MOCK_BIN}/restic" "${MOCK_BIN}/df" "${MOCK_BIN}/sudo" "${MOCK_BIN}/logger"
: > "${CALL_LOG}"
: > "${SUDO_LOG}"
: > "${DF_LOG}"
: > "${LOGGER_LOG}"

# 1. Raiz: schema exato, somente filhos diretos, tipos seguros e tokens opacos.
run_restore --hub-list --snapshot "${SNAPSHOT}"
assert_eq "0" "${RUN_RC}" "listagem da raiz"
assert_empty "${ERR_FILE}" "listagem da raiz"
json_assert "${OUT_FILE}" \
    "set(data.keys()) == {'version','ok','action','snapshot','limit','truncated','items'} and data['version'] == 1 and data['ok'] is True and data['action'] == 'list' and data['snapshot'] == '${SNAPSHOT}' and data['limit'] == 100 and data['truncated'] is False" \
    "schema da listagem da raiz"
json_assert "${OUT_FILE}" \
    "sorted((item['name'], item['type']) for item in data['items']) == [('arquivo especial $;[].txt','file'), ('aspas \"e\" unicode ç.txt','file'), ('empty','directory'), ('home','directory')] and all(set(item.keys()) == {'name','type','token'} for item in data['items'])" \
    "filhos diretos e tipos da raiz"
assert_not_contains "${OUT_FILE}" "descendente-oculto" "descendente não pode vazar"
assert_not_contains "${OUT_FILE}" "link-internal" "symlink não pode ser emitido"
assert_not_contains "${OUT_FILE}" "must-not-leak" "metadados do Restic não podem vazar"
TOKEN_HOME="$(json_get "${OUT_FILE}" "next(item['token'] for item in data['items'] if item['name'] == 'home')")"
TOKEN_EMPTY="$(json_get "${OUT_FILE}" "next(item['token'] for item in data['items'] if item['name'] == 'empty')")"
TOKEN_FILE="$(json_get "${OUT_FILE}" "next(item['token'] for item in data['items'] if item['name'] == 'arquivo especial $;[].txt')")"
TOKEN_UNICODE="$(json_get "${OUT_FILE}" "next(item['token'] for item in data['items'] if item['name'] == 'aspas \"e\" unicode ç.txt')")"
[[ "${TOKEN_HOME}" =~ ^v1\.[A-Za-z0-9_-]+\.[0-9a-f]{64}$ ]] || fail "formato do token opaco"
[[ "${TOKEN_HOME}" != *home* && "${TOKEN_HOME}" != *fixture-secret* ]] || fail "token vazou caminho bruto ou segredo"
pass "raiz retorna schema v1, filhos diretos, tipos e tokens opacos"

# 2. Navegação por diretório, arquivo não navegável e diretório vazio.
run_restore --hub-list --snapshot "${SNAPSHOT}" --token "${TOKEN_HOME}"
assert_eq "0" "${RUN_RC}" "listagem de /home"
json_assert "${OUT_FILE}" \
    "sorted((item['name'], item['type']) for item in data['items']) == [('com espaço;\$(printf INJECTED).txt','file'), ('subdir','directory')]" \
    "filhos diretos de /home"
assert_not_contains "${OUT_FILE}" "neto-oculto" "neto não pode vazar"
TOKEN_SPECIAL="$(json_get "${OUT_FILE}" "next(item['token'] for item in data['items'] if item['type'] == 'file')")"
# O fragmento deve permanecer literal na resposta.
# shellcheck disable=SC2016
assert_contains "${OUT_FILE}" '$(printf INJECTED)' "nome especial deve permanecer dado literal"
run_restore --hub-list --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}"
assert_error_json "not_a_directory" "arquivo não navegável"
run_restore --hub-list --snapshot "${SNAPSHOT}" --token "${TOKEN_EMPTY}"
assert_eq "0" "${RUN_RC}" "diretório vazio"
json_assert "${OUT_FILE}" "data['items'] == [] and data['truncated'] is False" "diretório vazio deve retornar items=[]"
pass "navegação aceita diretórios, recusa arquivo e representa diretório vazio"

# 3. Preflight positivo para arquivo/diretório e nomes especiais.
run_restore --hub-preflight --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --expect-type file
assert_eq "0" "${RUN_RC}" "preflight de arquivo"
assert_empty "${ERR_FILE}" "preflight de arquivo"
json_assert "${OUT_FILE}" \
    "set(data.keys()) == {'version','ok','action','snapshot','ready','item','space'} and data['ready'] is True and data['item'] == {'type':'file','token':'${TOKEN_FILE}','size_bytes':12} and set(data['space'].keys()) == {'available_mb','minimum_mb','required_mb','sufficient'} and data['space']['sufficient'] is True" \
    "schema e métricas do preflight de arquivo"
run_restore --hub-preflight --snapshot "${SNAPSHOT}" --token "${TOKEN_HOME}" --expect-type directory
assert_eq "0" "${RUN_RC}" "preflight de diretório"
json_assert "${OUT_FILE}" "data['item']['type'] == 'directory' and data['item']['size_bytes'] == 0 and data['ready'] is True" \
    "preflight de diretório"
run_restore --hub-preflight --snapshot "${SNAPSHOT}" --token "${TOKEN_UNICODE}" --expect-type file
assert_eq "0" "${RUN_RC}" "preflight de nome com aspas/unicode"
run_restore --hub-preflight --snapshot "${SNAPSHOT}" --token "${TOKEN_SPECIAL}" --expect-type file
assert_eq "0" "${RUN_RC}" "preflight de nome com espaço, cifrão e ponto e vírgula"
assert_contains "${CALL_LOG}" "restic argc=4 <ls> <--json> <${SNAPSHOT}>" "Restic deve receber exatamente quatro argumentos"
pass "preflight valida arquivo, diretório, espaço e transporte de nomes especiais"

# 4. Tipo divergente, item removido, pouco espaço e falha de df.
run_restore --hub-preflight --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --expect-type directory
assert_error_json "type_mismatch" "arquivo esperado como diretório"
run_restore --hub-preflight --snapshot "${SNAPSHOT}" --token "${TOKEN_HOME}" --expect-type file
assert_error_json "type_mismatch" "diretório esperado como arquivo"
MOCK_ITEM_REMOVED=1 run_restore --hub-preflight --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --expect-type file
assert_error_json "item_not_found" "item removido entre listagem e preflight"
MOCK_DF_MODE=low run_restore --hub-preflight --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --expect-type file
assert_eq "0" "${RUN_RC}" "preflight com pouco espaço"
json_assert "${OUT_FILE}" "data['ready'] is False and data['space']['sufficient'] is False and data['space']['available_mb'] < data['space']['minimum_mb']" \
    "decisão de pouco espaço"
MOCK_DF_MODE=fail run_restore --hub-preflight --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --expect-type file
assert_error_json "space_check_failed" "falha de df"
pass "preflight recusa tipo/item inválido e reporta decisão/falha de espaço"

# 5. Limite explícito: exatamente no limite e limite+1.
MOCK_MANY_COUNT=100 run_restore --hub-list --snapshot "${SNAPSHOT}"
assert_eq "0" "${RUN_RC}" "lista exatamente no limite"
json_assert "${OUT_FILE}" "data['limit'] == 100 and len(data['items']) == 100 and data['truncated'] is False" \
    "lista exatamente no limite"
MOCK_MANY_COUNT=101 run_restore --hub-list --snapshot "${SNAPSHOT}"
assert_eq "0" "${RUN_RC}" "lista truncada"
json_assert "${OUT_FILE}" "data['limit'] == 100 and len(data['items']) == 100 and data['truncated'] is True" \
    "limite+1 deve truncar"
pass "limite explícito impede resposta ilimitada"

# 6. Snapshot inexistente e falhas do Restic geram um único JSON limitado.
run_restore --hub-list --snapshot "${MISSING_SNAPSHOT}"
assert_error_json "snapshot_not_found" "snapshot inexistente"
MOCK_RESTIC_FAIL="cat"
run_restore --hub-list --snapshot "${SNAPSHOT}"
MOCK_RESTIC_FAIL=""
assert_error_json "repository_unavailable" "falha ao abrir repositório"
MOCK_RESTIC_FAIL="ls"
run_restore --hub-list --snapshot "${SNAPSHOT}"
MOCK_RESTIC_FAIL=""
assert_error_json "snapshot_read_failed" "falha de restic ls"
pass "snapshot inexistente e falhas do Restic não produzem sucesso parcial"

# 7. Tokens adulterados/traversal/controles são recusados antes do Restic.
before_calls="$(line_count "${CALL_LOG}")"
run_restore --hub-list --snapshot "${SNAPSHOT}" --token "token-malformado"
assert_error_json "invalid_token" "token malformado"
assert_eq "${before_calls}" "$(line_count "${CALL_LOG}")" "token malformado deve falhar antes do Restic"
ALTERED_TOKEN="${TOKEN_HOME%?}0"
[[ "${ALTERED_TOKEN}" != "${TOKEN_HOME}" ]] || ALTERED_TOKEN="${TOKEN_HOME%?}1"
run_restore --hub-list --snapshot "${SNAPSHOT}" --token "${ALTERED_TOKEN}"
assert_error_json "invalid_token" "MAC adulterado"
assert_eq "${before_calls}" "$(line_count "${CALL_LOG}")" "MAC adulterado deve falhar antes do Restic"
INVALID_MAC_TOKEN="${TOKEN_HOME%.*}.0000000000000000000000000000000000000000000000000000000000000000"
run_restore --hub-list --snapshot "${SNAPSHOT}" --token "${INVALID_MAC_TOKEN}"
assert_error_json "invalid_token" "MAC inválido com formato válido"
assert_eq "${before_calls}" "$(line_count "${CALL_LOG}")" "MAC inválido deve falhar antes do Restic"
run_restore --hub-list --snapshot "${OTHER_SNAPSHOT}" --token "${TOKEN_HOME}"
assert_error_json "invalid_token" "token de outro snapshot"
assert_eq "${before_calls}" "$(line_count "${CALL_LOG}")" "token cross-snapshot deve falhar antes do Restic"

for hostile_hex in \
    2f2e2e2f657463 \
    72656c6174697665 \
    2f2f657463 \
    2f6c696e650a627265616b
do
    HOSTILE_TOKEN="$(token_for_hex_path "${SNAPSHOT}" "${hostile_hex}")"
    run_restore --hub-list --snapshot "${SNAPSHOT}" --token "${HOSTILE_TOKEN}"
    assert_error_json "invalid_token" "token assinado com caminho hostil ${hostile_hex}"
    assert_eq "${before_calls}" "$(line_count "${CALL_LOG}")" "caminho hostil deve falhar antes do Restic"
done
NUL_TOKEN="$(token_for_hex_path "${SNAPSHOT}" "2f6261640070617468")"
run_restore --hub-list --snapshot "${SNAPSHOT}" --token "${NUL_TOKEN}"
[[ "${RUN_RC}" -ne 0 ]] || fail "token com NUL deveria retornar rc não-zero"
json_assert "${OUT_FILE}" "data['ok'] is False and data['error']['code'] == 'invalid_token'" \
    "token com NUL deve retornar erro JSON"
assert_eq "${before_calls}" "$(line_count "${CALL_LOG}")" "NUL deve falhar antes do Restic"
pass "token adulterado, cross-snapshot, traversal, relativo, //, newline e NUL são recusados"

# 8. Symlink/tipos especiais não são emitidos e são recusados mesmo com token válido.
TOKEN_LINK="$(token_for_hex_path "${SNAPSHOT}" "$(printf '/link-internal' | od -An -tx1 | tr -d ' \n')")"
run_restore --hub-preflight --snapshot "${SNAPSHOT}" --token "${TOKEN_LINK}" --expect-type file
assert_error_json "unsafe_symlink" "symlink interno"
TOKEN_EXTERNAL="$(token_for_hex_path "${SNAPSHOT}" "$(printf '/link-external' | od -An -tx1 | tr -d ' \n')")"
run_restore --hub-preflight --snapshot "${SNAPSHOT}" --token "${TOKEN_EXTERNAL}" --expect-type file
assert_error_json "unsafe_symlink" "symlink externo"
TOKEN_DEVICE="$(token_for_hex_path "${SNAPSHOT}" "$(printf '/device' | od -An -tx1 | tr -d ' \n')")"
run_restore --hub-preflight --snapshot "${SNAPSHOT}" --token "${TOKEN_DEVICE}" --expect-type file
assert_error_json "unsupported_type" "tipo especial"
pass "symlinks e tipos especiais nunca são reclassificados como arquivo"

# 9. Forced command: positivos novos/legados e rejeições antes de sudo/restic.
run_wrapper "list ${SNAPSHOT}"
assert_eq "0" "${RUN_RC}" "wrapper list raiz"
json_assert "${OUT_FILE}" "data['ok'] is True and data['action'] == 'list'" "wrapper list raiz"
run_wrapper "list ${SNAPSHOT} ${TOKEN_HOME}"
assert_eq "0" "${RUN_RC}" "wrapper list diretório"
run_wrapper "preflight ${SNAPSHOT} ${TOKEN_FILE} file"
assert_eq "0" "${RUN_RC}" "wrapper preflight"
run_wrapper "restore ${SNAPSHOT} valid-job"
assert_eq "0" "${RUN_RC}" "wrapper restore legado"
run_wrapper "status existing-job"
assert_eq "0" "${RUN_RC}" "wrapper status legado"
assert_eq "running" "$(tr -d '\n' < "${OUT_FILE}")" "conteúdo de status legado"
run_wrapper "log existing-job"
assert_eq "0" "${RUN_RC}" "wrapper log legado"
assert_eq "fixture log" "$(tr -d '\n' < "${OUT_FILE}")" "conteúdo de log legado"

reject_commands=(
    ""
    "unknown ${SNAPSHOT}"
    "sh -c id"
    "list"
    "list invalid-snapshot"
    "list ${SNAPSHOT} token-malformado"
    "list ${SNAPSHOT} extra extra"
    "preflight ${SNAPSHOT} ${TOKEN_FILE}"
    "preflight ${SNAPSHOT} ${TOKEN_FILE} other"
    "preflight ${SNAPSHOT} ${TOKEN_FILE} file extra"
    "list ${SNAPSHOT};id"
    "list ${SNAPSHOT} | id"
    "list \$(id)"
    "list ${SNAPSHOT} > /tmp/out"
    $'list 01234567\nstatus existing-job'
    $'list 01234567\rstatus existing-job'
)
for rejected in "${reject_commands[@]}"; do
    before_sudo="$(line_count "${SUDO_LOG}")"
    before_restic="$(line_count "${CALL_LOG}")"
    run_wrapper "${rejected}"
    [[ "${RUN_RC}" -ne 0 ]] || fail "wrapper aceitou comando proibido: ${rejected}"
    assert_contains "${ERR_FILE}" "hub-restore-shell: comando recusado." "rejeição genérica do wrapper"
    assert_eq "${before_sudo}" "$(line_count "${SUDO_LOG}")" "comando proibido não pode alcançar sudo"
    assert_eq "${before_restic}" "$(line_count "${CALL_LOG}")" "comando proibido não pode alcançar Restic"
done
assert_not_contains "${CALL_LOG}" "<restore>" "navegação/preflight não pode executar restic restore"
assert_contains "${SUDO_LOG}" "<--hub-list>" "allowlist deve encaminhar apenas --hub-list"
assert_contains "${SUDO_LOG}" "<--hub-preflight>" "allowlist deve encaminhar apenas --hub-preflight"
assert_contains "${SUDO_LOG}" "<--non-interactive>" "restore legado deve continuar encaminhado"
pass "forced command mantém protocolo legado e recusa shell/comandos fora da allowlist"

# 10. Instalação preserva forced command e todas as restrições SSH.
# Buscamos o texto literal do template shell.
# shellcheck disable=SC2016
assert_contains "${ROOT_DIR}/instalar_backup.sh" \
    'command=\"${HUB_SHELL_DEST}\",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding' \
    "authorized_keys deve preservar todas as restrições"
assert_contains "${ROOT_DIR}/instalar_backup.sh" 'openssl rand -hex 32' \
    "instalador deve gerar chave HMAC forte"
# Buscamos o identificador literal no instalador.
# shellcheck disable=SC2016
assert_contains "${ROOT_DIR}/instalar_backup.sh" 'chmod 600 "${HUB_TOKEN_KEY_FILE}"' \
    "chave HMAC deve ter modo 600"
assert_contains "${ROOT_DIR}/hub-restore-shell" 'readonly RESTORE_BIN="/usr/local/bin/restic-restore.sh"' \
    "wrapper de produção deve manter binário absoluto"
pass "instalador preserva forced command, restrições de forwarding e chave local"

# Garantias fora de escopo: nenhum staging/produção e nenhuma restauração.
[[ ! -e "${STAGING_PATH}" ]] || fail "teste detectou criação indevida de staging"
assert_not_contains "${CALL_LOG}" "<restore>" "nenhum cenário pode chamar restic restore"

bash -n "${ROOT_DIR}/restaurar_backup.sh" || fail "bash -n restaurar_backup.sh"
bash -n "${ROOT_DIR}/hub-restore-shell" || fail "bash -n hub-restore-shell"
bash -n "${ROOT_DIR}/instalar_backup.sh" || fail "bash -n instalar_backup.sh"
bash -n "$0" || fail "bash -n do novo teste"
pass "sintaxe dos scripts afetados e do teste"

echo "1..${PASS_COUNT}"
