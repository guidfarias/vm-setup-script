#!/bin/bash
# Testes comportamentais e de segurança da navegação/download do staging de
# um job de restauração seletiva JÁ CONCLUÍDO (issue #10). Usa somente
# cópias temporárias e um staging real (arquivos/diretórios de verdade em
# disco); nunca acessa Restic/S3.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hub-staging-access.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

MOCK_BIN="${TMP_DIR}/bin"
RESTORE_COPY="${TMP_DIR}/restic-restore.sh"
SHELL_COPY="${TMP_DIR}/hub-restore-shell"
ENV_FILE="${TMP_DIR}/restic.env"
TOKEN_KEY_FILE="${TMP_DIR}/hub-token.key"
RESTORE_LOG="${TMP_DIR}/restore.log"
SUDO_LOG="${TMP_DIR}/sudo.calls"
LOGGER_LOG="${TMP_DIR}/logger.calls"
ITEM_STAGING_DIR="${TMP_DIR}/items"
LOCK_FILE="${TMP_DIR}/job.lock"
OUT_FILE="${TMP_DIR}/stdout"
ERR_FILE="${TMP_DIR}/stderr"

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

assert_not_contains() {
    local file="$1" text="$2" label="$3"
    if grep -F -- "${text}" "${file}" >/dev/null 2>&1; then
        fail "${label}: texto inesperado: ${text}"
    fi
}

assert_empty() {
    [[ ! -s "$1" ]] || fail "$2: arquivo deveria estar vazio"
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

# Mesmo protocolo HMAC do wrapper (prefixo "v1s", chave local, assinado sobre
# job_id + payload base64url do caminho relativo).
token_for_rel_path() {
    local job_id="$1" rel_path="$2"
    "${PYTHON_BIN}" - "${job_id}" "${rel_path}" "${TOKEN_KEY_HEX}" <<'PY'
import base64
import hashlib
import hmac
import sys

job_id = sys.argv[1].encode("ascii")
path = sys.argv[2].encode("utf-8")
key = bytes.fromhex(sys.argv[3])
payload = base64.urlsafe_b64encode(path).rstrip(b"=")
mac = hmac.new(key, b"v1s\0" + job_id + b"\0" + payload, hashlib.sha256).hexdigest()
print("v1s." + payload.decode("ascii") + "." + mac)
PY
}

run_restore() {
    : > "${OUT_FILE}"; : > "${ERR_FILE}"
    env \
        PATH="${MOCK_BIN}:${PATH}" \
        RESTIC_ENV_FILE="${ENV_FILE}" \
        RESTORE_LOG_FILE="${RESTORE_LOG}" \
        RESTIC_RESTORE_ALLOW_NONROOT=1 \
        MOCK_SUDO_LOG="${SUDO_LOG}" \
        MOCK_LOGGER_LOG="${LOGGER_LOG}" \
        "${RESTORE_COPY}" "$@" >"${OUT_FILE}" 2>"${ERR_FILE}"
    RUN_RC=$?
}

run_wrapper() {
    local original_command="$1"
    : > "${OUT_FILE}"; : > "${ERR_FILE}"
    env \
        PATH="${MOCK_BIN}:${PATH}" \
        SSH_ORIGINAL_COMMAND="${original_command}" \
        RESTIC_ENV_FILE="${ENV_FILE}" \
        RESTORE_LOG_FILE="${RESTORE_LOG}" \
        RESTIC_RESTORE_ALLOW_NONROOT=1 \
        MOCK_SUDO_LOG="${SUDO_LOG}" \
        MOCK_LOGGER_LOG="${LOGGER_LOG}" \
        "${SHELL_COPY}" >"${OUT_FILE}" 2>"${ERR_FILE}"
    RUN_RC=$?
}

assert_error_json() {
    local expected_code="$1" label="$2"
    [[ "${RUN_RC}" -ne 0 ]] || fail "${label}: deveria retornar rc não-zero"
    json_assert "${OUT_FILE}" \
        "set(data.keys()) == {'version','ok','error'} and data['version'] == 1 and data['ok'] is False and set(data['error'].keys()) == {'code','message'} and data['error']['code'] == '${expected_code}'" \
        "${label}: resposta de erro JSON inválida"
}

require_command bash
require_command openssl
require_command perl
require_command tar
if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python)"
else
    fail "python3/python é necessário somente para validar JSON nos testes"
fi

mkdir -p "${MOCK_BIN}" "${ITEM_STAGING_DIR}"
cp "${ROOT_DIR}/restaurar_backup.sh" "${RESTORE_COPY}"
cp "${ROOT_DIR}/hub-restore-shell" "${SHELL_COPY}"

# Ajusta só as constantes absolutas nas cópias descartáveis — mesmo padrão
# dos demais testes hub-*.
TEST_KEY_FILE="${TOKEN_KEY_FILE}" TEST_ITEM_DIR="${ITEM_STAGING_DIR}" TEST_LOCK_FILE="${LOCK_FILE}" \
    perl -0pi -e '
        my $key = qq{readonly HUB_TOKEN_KEY_FILE="$ENV{TEST_KEY_FILE}"};
        my $items = qq{readonly HUB_ITEM_STAGING_DIR="$ENV{TEST_ITEM_DIR}"};
        my $lock = qq{readonly HUB_ITEM_LOCK_FILE="$ENV{TEST_LOCK_FILE}"};
        s{\Qreadonly HUB_TOKEN_KEY_FILE="/etc/restic/hub-token.key"\E}{$key};
        s{\Qreadonly HUB_ITEM_STAGING_DIR="/var/lib/hub-restore/items"\E}{$items};
        s{\Qreadonly HUB_ITEM_LOCK_FILE="/var/lib/hub-restore/.job.lock"\E}{$lock};
    ' "${RESTORE_COPY}"
TEST_RESTORE_BIN="${RESTORE_COPY}" TEST_ITEM_DIR="${ITEM_STAGING_DIR}" \
    perl -0pi -e '
        my $restore = qq{readonly RESTORE_BIN="$ENV{TEST_RESTORE_BIN}"};
        my $items = qq{readonly HUB_ITEM_STAGING_DIR="$ENV{TEST_ITEM_DIR}"};
        s{\Qreadonly RESTORE_BIN="/usr/local/bin/restic-restore.sh"\E}{$restore};
        s{\Qreadonly HUB_ITEM_STAGING_DIR="/var/lib/hub-restore/items"\E}{$items};
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
chmod 600 "${ENV_FILE}" "${TOKEN_KEY_FILE}"
chmod +x "${RESTORE_COPY}" "${SHELL_COPY}"

cat > "${MOCK_BIN}/logger" <<'MOCK'
#!/bin/bash
printf 'logger argc=%d <%s>\n' "$#" "$*" >> "${MOCK_LOGGER_LOG}"
MOCK

cat > "${MOCK_BIN}/sudo" <<'MOCK'
#!/bin/bash
{
    printf 'sudo argc=%d' "$#"
    for arg in "$@"; do printf ' <%q>' "${arg}"; done
    printf '\n'
} >> "${MOCK_SUDO_LOG:-/dev/null}"
[[ "$1" == "-n" ]] && shift
exec "$@"
MOCK

chmod +x "${MOCK_BIN}/logger" "${MOCK_BIN}/sudo"
: > "${LOGGER_LOG}"; : > "${SUDO_LOG}"

now="$(date +%s)"
future=$((now + 3600))
past=$((now - 3600))

# write_meta <job_id> <status> <expires_at> — meta.json mínimo válido; os
# testes de staging não olham snapshot/path/item_type, só status/expires_at.
write_meta() {
    local job_id="$1" status="$2" expires="$3"
    local dir="${ITEM_STAGING_DIR}/${job_id}"
    mkdir -p "${dir}/control" "${dir}/data"
    cat > "${dir}/control/meta.json" <<JSON
{"version":1,"job_id":"${job_id}","snapshot":"01234567","path":"/x","item_type":"directory","status":"${status}","created_at":${now},"expires_at":${expires},"staging_dir":"${dir}/data"}
JSON
}

# --- Job "pronto" com conteúdo variado ---------------------------------

READY_JOB="job-ready-1"
write_meta "${READY_JOB}" "success" "${future}"
READY_DATA="${ITEM_STAGING_DIR}/${READY_JOB}/data"
mkdir -p "${READY_DATA}/subdir"
printf 'conteudo pequeno' > "${READY_DATA}/pequeno.txt"
printf 'nome especial' > "${READY_DATA}/arquivo com espaço \$;[].txt"
printf 'aninhado' > "${READY_DATA}/subdir/aninhado.txt"
# Arquivo "grande simulado": alguns MB, o bastante para provar streaming sem
# comparar por igualdade ingênua de string gigante.
head -c 5000000 /dev/urandom > "${READY_DATA}/grande.bin" 2>/dev/null \
    || dd if=/dev/zero of="${READY_DATA}/grande.bin" bs=1024 count=4883 2>/dev/null
GRANDE_SHA="$(shasum -a 256 "${READY_DATA}/grande.bin" 2>/dev/null | awk '{print $1}')"
[[ -n "${GRANDE_SHA}" ]] || GRANDE_SHA="$(sha256sum "${READY_DATA}/grande.bin" | awk '{print $1}')"
# Symlink externo: aponta para fora do staging (via TMP_DIR, fora de data/).
OUTSIDE_FILE="${TMP_DIR}/fora-do-staging.txt"
printf 'nao pode vazar' > "${OUTSIDE_FILE}"
ln -s "${OUTSIDE_FILE}" "${READY_DATA}/link-externo"
ln -s "${READY_DATA}/pequeno.txt" "${READY_DATA}/link-interno"
# Symlink em componente INTERMEDIÁRIO do caminho (não no nó final): um
# diretório dentro do staging que é, na verdade, um link para fora dele.
# hub_staging_resolve precisa recusar mesmo quando só o meio do caminho
# escapa, não só quando o próprio nó pedido é um link.
OUTSIDE_DIR="${TMP_DIR}/fora-do-staging-dir"
mkdir -p "${OUTSIDE_DIR}"
printf 'vazou via componente intermediario' > "${OUTSIDE_DIR}/segredo.txt"
ln -s "${OUTSIDE_DIR}" "${READY_DATA}/elo-intermediario"

# --- Jobs em outros estados ---------------------------------------------

write_meta "job-running-1" "running" "${future}"
mkdir -p "${ITEM_STAGING_DIR}/job-running-1/data"
printf 'em andamento' > "${ITEM_STAGING_DIR}/job-running-1/data/x.txt"

write_meta "job-failed-1" "failed algum motivo" "${future}"
mkdir -p "${ITEM_STAGING_DIR}/job-failed-1/data"
printf 'falhou' > "${ITEM_STAGING_DIR}/job-failed-1/data/x.txt"

write_meta "job-expired-1" "success" "${past}"
mkdir -p "${ITEM_STAGING_DIR}/job-expired-1/data"
printf 'expirou' > "${ITEM_STAGING_DIR}/job-expired-1/data/x.txt"

# 1. Listagem da raiz do staging: schema, tipos, tokens opacos, sem symlink.
run_restore --hub-staging-list --job "${READY_JOB}"
assert_eq "0" "${RUN_RC}" "listagem da raiz do staging"
json_assert "${OUT_FILE}" \
    "set(data.keys()) == {'version','ok','action','job_id','limit','truncated','items'} and data['ok'] is True and data['action'] == 'staging-list' and data['job_id'] == '${READY_JOB}'" \
    "schema da listagem do staging"
json_assert "${OUT_FILE}" \
    "sorted((i['name'], i['type']) for i in data['items']) == [('arquivo com espaço \$;[].txt','file'), ('grande.bin','file'), ('pequeno.txt','file'), ('subdir','directory')] and all(set(i.keys()) == {'name','type','token'} for i in data['items'])" \
    "filhos diretos do staging, sem symlinks"
assert_not_contains "${OUT_FILE}" "link-externo" "symlink externo não pode ser listado"
assert_not_contains "${OUT_FILE}" "link-interno" "symlink interno não pode ser listado"
TOKEN_PEQUENO="$(json_get "${OUT_FILE}" "next(i['token'] for i in data['items'] if i['name'] == 'pequeno.txt')")"
TOKEN_GRANDE="$(json_get "${OUT_FILE}" "next(i['token'] for i in data['items'] if i['name'] == 'grande.bin')")"
TOKEN_SUBDIR="$(json_get "${OUT_FILE}" "next(i['token'] for i in data['items'] if i['name'] == 'subdir')")"
TOKEN_ESPECIAL="$(json_get "${OUT_FILE}" "next(i['token'] for i in data['items'] if i['type'] == 'file' and 'espaço' in i['name'])")"
[[ "${TOKEN_PEQUENO}" =~ ^v1s\.[A-Za-z0-9_-]+\.[0-9a-f]{64}$ ]] || fail "formato do token de staging"
pass "listagem da raiz do staging retorna schema v1, filhos diretos, tipos e tokens opacos, sem symlinks"

# 2. Navegação em subdiretório e arquivo não navegável.
run_restore --hub-staging-list --job "${READY_JOB}" --token "${TOKEN_SUBDIR}"
assert_eq "0" "${RUN_RC}" "listagem de subdir"
json_assert "${OUT_FILE}" \
    "[(i['name'], i['type']) for i in data['items']] == [('aninhado.txt','file')]" \
    "filho de subdir"
run_restore --hub-staging-list --job "${READY_JOB}" --token "${TOKEN_PEQUENO}"
assert_error_json "not_a_directory" "arquivo não navegável no staging"
pass "navegação em subdiretório funciona e arquivo é recusado como diretório"

# 3. Stat de arquivo pequeno, grande e diretório — tamanho correto.
run_restore --hub-staging-stat --job "${READY_JOB}" --token "${TOKEN_PEQUENO}"
assert_eq "0" "${RUN_RC}" "stat de arquivo pequeno"
json_assert "${OUT_FILE}" \
    "data['item'] == {'type':'file','token':'${TOKEN_PEQUENO}','size_bytes':16}" \
    "tamanho do arquivo pequeno"
run_restore --hub-staging-stat --job "${READY_JOB}" --token "${TOKEN_GRANDE}"
assert_eq "0" "${RUN_RC}" "stat de arquivo grande"
json_assert "${OUT_FILE}" "data['item']['type'] == 'file' and data['item']['size_bytes'] >= 4000000" \
    "tamanho do arquivo grande"
run_restore --hub-staging-stat --job "${READY_JOB}" --token "${TOKEN_SUBDIR}"
assert_eq "0" "${RUN_RC}" "stat de diretório"
json_assert "${OUT_FILE}" "data['item']['type'] == 'directory' and data['item']['size_bytes'] > 0" \
    "tamanho do diretório"
pass "stat reporta tipo e tamanho corretos para arquivo pequeno, grande e diretório"

# 4. Download de arquivo pequeno: stdout é EXATAMENTE o conteúdo, nada mais.
run_restore --hub-staging-download --job "${READY_JOB}" --token "${TOKEN_PEQUENO}"
assert_eq "0" "${RUN_RC}" "download de arquivo pequeno"
assert_eq "conteudo pequeno" "$(cat "${OUT_FILE}")" "conteúdo binário do arquivo pequeno"
assert_empty "${ERR_FILE}" "download de arquivo pequeno não deve gravar nada em stderr"
pass "download de arquivo pequeno transmite exatamente o conteúdo, sem contaminação em stdout/stderr"

# 5. Download de arquivo grande: hash bate, prova que o streaming não trunca
# nem corrompe (não carregado inteiro em variável de shell).
: > "${OUT_FILE}"; : > "${ERR_FILE}"
env \
    PATH="${MOCK_BIN}:${PATH}" \
    RESTIC_ENV_FILE="${ENV_FILE}" \
    RESTORE_LOG_FILE="${RESTORE_LOG}" \
    RESTIC_RESTORE_ALLOW_NONROOT=1 \
    "${RESTORE_COPY}" --hub-staging-download --job "${READY_JOB}" --token "${TOKEN_GRANDE}" \
    >"${OUT_FILE}" 2>"${ERR_FILE}"
RUN_RC=$?
assert_eq "0" "${RUN_RC}" "download de arquivo grande"
OUT_SHA="$(shasum -a 256 "${OUT_FILE}" 2>/dev/null | awk '{print $1}')"
[[ -n "${OUT_SHA}" ]] || OUT_SHA="$(sha256sum "${OUT_FILE}" | awk '{print $1}')"
assert_eq "${GRANDE_SHA}" "${OUT_SHA}" "hash do arquivo grande baixado deve bater com o original"
pass "download de arquivo grande simulado preserva integridade byte a byte (streaming)"

# 6. Download de diretório: artefato tar válido, extrai para o conteúdo certo.
run_restore --hub-staging-download --job "${READY_JOB}" --token "${TOKEN_SUBDIR}"
assert_eq "0" "${RUN_RC}" "download de diretório"
assert_empty "${ERR_FILE}" "download de diretório não deve gravar nada em stderr"
EXTRACT_DIR="${TMP_DIR}/extraido"
mkdir -p "${EXTRACT_DIR}"
tar -xf "${OUT_FILE}" -C "${EXTRACT_DIR}" || fail "artefato do diretório não é um tar válido"
[[ -f "${EXTRACT_DIR}/subdir/aninhado.txt" ]] || fail "tar extraído não contém o arquivo esperado"
assert_eq "aninhado" "$(cat "${EXTRACT_DIR}/subdir/aninhado.txt")" "conteúdo do arquivo dentro do tar"
pass "download de diretório empacota como tar de streaming, extraível e com o conteúdo esperado"

# 7. Nome especial (espaço, cifrão, ponto e vírgula, colchetes) sobrevive
# intacto no download.
run_restore --hub-staging-download --job "${READY_JOB}" --token "${TOKEN_ESPECIAL}"
assert_eq "0" "${RUN_RC}" "download de arquivo com nome especial"
assert_eq "nome especial" "$(cat "${OUT_FILE}")" "conteúdo do arquivo com nome especial"
pass "arquivo com nome especial (espaço, cifrão, colchetes) é transmitido corretamente"

# 8. Symlink externo e interno são recusados em list/stat/download, mesmo
# tentando referenciá-los via token forjado com o mesmo esquema.
TOKEN_LINK_EXT="$(token_for_rel_path "${READY_JOB}" "/link-externo")"
run_restore --hub-staging-stat --job "${READY_JOB}" --token "${TOKEN_LINK_EXT}"
assert_error_json "item_not_found" "symlink externo recusado no stat"
run_restore --hub-staging-download --job "${READY_JOB}" --token "${TOKEN_LINK_EXT}"
[[ "${RUN_RC}" -ne 0 ]] || fail "download de symlink externo deveria falhar"
assert_empty "${OUT_FILE}" "symlink externo não pode vazar conteúdo em stdout"
assert_not_contains "${OUT_FILE}" "nao pode vazar" "conteúdo do arquivo fora do staging não pode aparecer no stdout"
TOKEN_LINK_INT="$(token_for_rel_path "${READY_JOB}" "/link-interno")"
run_restore --hub-staging-stat --job "${READY_JOB}" --token "${TOKEN_LINK_INT}"
assert_error_json "item_not_found" "symlink interno recusado no stat"
pass "symlink externo e interno nunca são lidos, mesmo com token forjado no mesmo esquema"

# 8b. Symlink em componente INTERMEDIÁRIO do caminho (não no nó final): o
# alvo pedido (.../elo-intermediario/segredo.txt) tem um arquivo real no
# fim, mas o diretório pai é um link para fora do staging. A validação por
# pathname (cd + pwd -P) segue esse link ao resolver — precisa recusar antes
# de qualquer leitura, e o conteúdo nunca pode aparecer em stdout.
TOKEN_ELO_INTERMEDIARIO="$(token_for_rel_path "${READY_JOB}" "/elo-intermediario/segredo.txt")"
run_restore --hub-staging-stat --job "${READY_JOB}" --token "${TOKEN_ELO_INTERMEDIARIO}"
assert_error_json "item_not_found" "symlink em componente intermediário recusado no stat"
run_restore --hub-staging-download --job "${READY_JOB}" --token "${TOKEN_ELO_INTERMEDIARIO}"
[[ "${RUN_RC}" -ne 0 ]] || fail "download via symlink intermediário deveria falhar"
assert_empty "${OUT_FILE}" "symlink intermediário não pode vazar conteúdo em stdout"
assert_not_contains "${OUT_FILE}" "vazou via componente intermediario" "conteúdo atrás do link intermediário não pode aparecer no stdout"
pass "symlink em componente intermediário do caminho (não só o nó final) é recusado, sem vazar conteúdo"

# 9. Traversal (../) e caminho absoluto fora do staging são recusados antes
# de qualquer leitura — o token nem decodifica.
run_restore --hub-staging-stat --job "${READY_JOB}" --token "$(token_for_rel_path "${READY_JOB}" "/../fora-do-staging.txt")"
assert_error_json "invalid_token" "traversal .. recusado"
run_restore --hub-staging-stat --job "${READY_JOB}" --token "$(token_for_rel_path "${READY_JOB}" "/etc/passwd")"
assert_error_json "item_not_found" "caminho absoluto fora do staging recusado"
pass "traversal e caminho fora do staging são recusados sem tocar o item real"

# 10. Job ativo, falho, expirado e inexistente: mesmo erro genérico, sem
# diferenciar o motivo (evita oráculo de estado interno).
run_restore --hub-staging-list --job "job-running-1"
assert_error_json "job_not_ready" "job running recusado"
run_restore --hub-staging-list --job "job-failed-1"
assert_error_json "job_not_ready" "job failed recusado"
run_restore --hub-staging-list --job "job-expired-1"
assert_error_json "job_not_ready" "job expirado recusado"
run_restore --hub-staging-list --job "job-inexistente-1"
assert_error_json "job_not_ready" "job inexistente recusado"
pass "job ativo, falho, expirado e inexistente retornam o mesmo erro job_not_ready"

# 11. Download recusado nos mesmos casos, sem vazar conteúdo em stdout.
run_restore --hub-staging-download --job "job-running-1" --token "$(token_for_rel_path "job-running-1" "/x.txt")"
[[ "${RUN_RC}" -ne 0 ]] || fail "download de job running deveria ser recusado"
assert_empty "${OUT_FILE}" "download de job running não pode vazar conteúdo em stdout"
run_restore --hub-staging-download --job "job-expired-1" --token "$(token_for_rel_path "job-expired-1" "/x.txt")"
[[ "${RUN_RC}" -ne 0 ]] || fail "download de job expirado deveria ser recusado"
assert_empty "${OUT_FILE}" "download de job expirado não pode vazar conteúdo em stdout"
pass "download recusa job ativo/expirado sem vazar bytes em stdout"

# 12. Token de outro job (cross-job) é recusado — o job_id faz parte do MAC.
CROSS_TOKEN="$(token_for_rel_path "job-failed-1" "/pequeno.txt")"
run_restore --hub-staging-stat --job "${READY_JOB}" --token "${CROSS_TOKEN}"
assert_error_json "invalid_token" "token assinado para outro job_id é recusado"
pass "token de outro job_id não pode ser reaproveitado (job_id faz parte do MAC)"

# 13. Token de navegação de snapshot (prefixo v1.) não pode ser aceito como
# token de staging, e vice-versa — domínios de token nunca se misturam.
FAKE_SNAPSHOT_TOKEN="v1.$(printf '/pequeno.txt' | openssl base64 -A | tr '+/' '-_' | tr -d '=').$(printf '0%.0s' {1..64})"
run_restore --hub-staging-stat --job "${READY_JOB}" --token "${FAKE_SNAPSHOT_TOKEN}"
assert_error_json "invalid_token" "token com prefixo de outro domínio (v1.) recusado como token de staging"
pass "token do domínio de navegação de snapshot não é aceito como token de staging"

# 14. Exclusão antecipada via cleanup remove o staging do job pronto; repetir
# é idempotente. Depois da exclusão, list/stat/download voltam a falhar.
run_restore --hub-cleanup --job "${READY_JOB}"
assert_eq "0" "${RUN_RC}" "exclusão antecipada do job pronto"
[[ ! -d "${ITEM_STAGING_DIR}/${READY_JOB}" ]] || fail "cleanup não removeu o staging do job"
run_restore --hub-cleanup --job "${READY_JOB}"
assert_eq "0" "${RUN_RC}" "exclusão antecipada repetida (idempotente)"
run_restore --hub-staging-list --job "${READY_JOB}"
assert_error_json "job_not_ready" "job removido não expõe mais conteúdo"
pass "exclusão antecipada remove o staging, é idempotente e bloqueia acesso subsequente"

# --- Forced command (wrapper) --------------------------------------------

# Recria o job pronto (removido no cenário 14) para os testes de wrapper.
write_meta "${READY_JOB}" "success" "${future}"
mkdir -p "${READY_DATA}"
printf 'conteudo pequeno' > "${READY_DATA}/pequeno.txt"
TOKEN_PEQUENO="$(token_for_rel_path "${READY_JOB}" "/pequeno.txt")"

# 15. Forced command aceita staging-list/staging-stat/staging-download.
run_wrapper "staging-list ${READY_JOB}"
assert_eq "0" "${RUN_RC}" "wrapper staging-list raiz"
json_assert "${OUT_FILE}" "data['ok'] is True and data['action'] == 'staging-list'" "wrapper staging-list raiz"
run_wrapper "staging-stat ${READY_JOB} ${TOKEN_PEQUENO}"
assert_eq "0" "${RUN_RC}" "wrapper staging-stat"
json_assert "${OUT_FILE}" "data['ok'] is True and data['action'] == 'staging-stat'" "wrapper staging-stat"
run_wrapper "staging-download ${READY_JOB} ${TOKEN_PEQUENO}"
assert_eq "0" "${RUN_RC}" "wrapper staging-download"
assert_eq "conteudo pequeno" "$(cat "${OUT_FILE}")" "wrapper staging-download entrega o conteúdo"
assert_contains "${SUDO_LOG}" "<--hub-staging-download>" "allowlist deve encaminhar --hub-staging-download"
pass "forced command aceita staging-list, staging-stat e staging-download com sucesso"

# 16. Forced command recusa formato de token errado e argc incorreto antes
# de alcançar sudo/restic — mesma allowlist rígida dos demais comandos.
before_sudo="$(wc -l < "${SUDO_LOG}" | tr -d ' ')"
reject_commands=(
    "staging-list"
    "staging-list ${READY_JOB} token-malformado"
    "staging-list ${READY_JOB} extra extra"
    "staging-stat ${READY_JOB}"
    "staging-stat ${READY_JOB} token-malformado"
    "staging-stat ${READY_JOB} ${TOKEN_PEQUENO} extra"
    "staging-download ${READY_JOB}"
    "staging-download ${READY_JOB} token-malformado"
    "staging-download invalid_job! ${TOKEN_PEQUENO}"
    "staging-stat ${READY_JOB} v1.$(printf 'x' | openssl base64 -A | tr '+/' '-_' | tr -d '=').$(printf '0%.0s' {1..64})"
)
for rejected in "${reject_commands[@]}"; do
    run_wrapper "${rejected}"
    [[ "${RUN_RC}" -ne 0 ]] || fail "wrapper aceitou comando proibido: ${rejected}"
    assert_contains "${ERR_FILE}" "hub-restore-shell: comando recusado." "rejeição genérica do wrapper: ${rejected}"
done
after_sudo="$(wc -l < "${SUDO_LOG}" | tr -d ' ')"
assert_eq "${before_sudo}" "${after_sudo}" "comandos de staging proibidos não podem alcançar sudo"
pass "forced command recusa staging-list/stat/download malformados antes de alcançar sudo"

# --- Sinal durante o stream e corrida cleanup-vs-leitura -----------------

HAVE_FLOCK=1
command -v flock >/dev/null 2>&1 || HAVE_FLOCK=0

# Job dedicado a este cenário (não reaproveita READY_JOB, que a esta altura
# já foi apagado/recriado por cenários anteriores e teria só pequeno.txt).
TERM_JOB="job-term-1"
write_meta "${TERM_JOB}" "success" "${future}"
TERM_DATA="${ITEM_STAGING_DIR}/${TERM_JOB}/data"
mkdir -p "${TERM_DATA}"
head -c 5000000 /dev/urandom > "${TERM_DATA}/grande.bin" 2>/dev/null \
    || dd if=/dev/zero of="${TERM_DATA}/grande.bin" bs=1024 count=4883 2>/dev/null
TOKEN_TERM_GRANDE="$(token_for_rel_path "${TERM_JOB}" "/grande.bin")"

# 17. TERM durante o download não pode injetar texto no meio do stream: a
# flag HUB_STDOUT_IS_BINARY faz o trap de sinal (topo de restaurar_backup.sh)
# escrever só em stderr/log quando ativa. Para garantir determinismo (não
# depender da velocidade do disco terminar antes do kill), o stdout do
# processo é escrito num FIFO cujo leitor consome DEVAGAR (1 byte por vez,
# com sleep) — isso aplica backpressure real no pipe e mantém o `cat`/`tar`
# de dentro de run_hub_staging_download genuinamente bloqueado no meio da
# escrita até o sinal chegar, sem alterar o código de produção.
FIFO_PATH="${TMP_DIR}/download.fifo"
rm -f "${FIFO_PATH}"
mkfifo "${FIFO_PATH}"
: > "${OUT_FILE}"; : > "${ERR_FILE}"
(
    # dd (não `read` do bash) para não corromper bytes binários — bash
    # `read` é orientado a linha/delimitador e não é seguro para dados
    # arbitrários (NUL, sequências que colidem com o delimitador). Blocos de
    # 4KB com uma pausa entre cada leitura aplicam a mesma backpressure sem
    # arriscar a integridade do conteúdo. O loop para quando um bloco lido
    # tem 0 bytes (EOF do FIFO) — o rc de `dd` sozinho não distingue isso.
    CHUNK="${TMP_DIR}/download.chunk"
    while true; do
        dd if="${FIFO_PATH}" bs=4096 count=1 of="${CHUNK}" 2>/dev/null
        [[ -s "${CHUNK}" ]] || break
        cat "${CHUNK}" >> "${OUT_FILE}"
        sleep 0.02
    done
) &
READER_PID=$!
env \
    PATH="${MOCK_BIN}:${PATH}" \
    RESTIC_ENV_FILE="${ENV_FILE}" \
    RESTORE_LOG_FILE="${RESTORE_LOG}" \
    RESTIC_RESTORE_ALLOW_NONROOT=1 \
    "${RESTORE_COPY}" --hub-staging-download --job "${TERM_JOB}" --token "${TOKEN_TERM_GRANDE}" \
    >"${FIFO_PATH}" 2>"${ERR_FILE}" &
DOWNLOAD_PID=$!
# Espera o arquivo de saída começar a crescer (prova que o leitor devagar já
# está drenando o FIFO e o cat/tar de dentro do download está bloqueado na
# escrita) antes de mandar o sinal.
GREW=0
for _ in $(seq 1 100); do
    if [[ -s "${OUT_FILE}" ]]; then
        GREW=1
        break
    fi
    sleep 0.05
done
[[ "${GREW}" == "1" ]] || fail "leitor devagar do FIFO não recebeu nenhum byte a tempo (setup do teste de TERM)"
kill -TERM "${DOWNLOAD_PID}" 2>/dev/null || true
# Watchdog: se o TERM não derrubar o processo rapidamente (não deveria
# acontecer — write() bloqueado é interrompido pelo sinal — mas evita travar
# o teste indefinidamente se algo no ambiente se comportar diferente), força
# com KILL depois de uma folga curta.
( sleep 5; kill -KILL "${DOWNLOAD_PID}" 2>/dev/null || true ) &
WATCHDOG_PID=$!
wait "${DOWNLOAD_PID}" 2>/dev/null
kill "${WATCHDOG_PID}" 2>/dev/null || true
wait "${WATCHDOG_PID}" 2>/dev/null || true
# Não há um jeito portátil e rápido de sinalizar EOF ao leitor devagar sem
# arriscar travar o teste (o writer já morreu; reabrir o FIFO para fechar em
# seguida nem sempre acorda um `read` bloqueado a tempo em todo shell). Como
# o que importa já foi capturado em OUT_FILE no momento do kill, o leitor é
# encerrado diretamente — ele é um subshell descartável deste cenário, sem
# nenhum estado que precise de finalização graciosa.
kill -KILL "${READER_PID}" 2>/dev/null || true
wait "${READER_PID}" 2>/dev/null || true
rm -f "${FIFO_PATH}"
assert_not_contains "${OUT_FILE}" "Interrompido pelo usuário" "TERM durante o stream não pode injetar aviso no stdout binário"
assert_not_contains "${OUT_FILE}" "AVISO" "TERM durante o stream não pode injetar tag de log no stdout binário"
head -c "$(wc -c < "${OUT_FILE}" | tr -d ' ')" "${TERM_DATA}/grande.bin" > "${TMP_DIR}/expected-prefix"
cmp -s "${OUT_FILE}" "${TMP_DIR}/expected-prefix" \
    || fail "bytes recebidos antes do TERM não são um prefixo exato do arquivo original (stream contaminado)"
pass "sinal TERM recebido durante o streaming de download não contamina o stdout binário"

# 18. Corrida cleanup vs leitura: um leitor (staging-download) segurando o
# lock COMPARTILHADO deve bloquear um cleanup concorrente (lock exclusivo)
# até o leitor soltar — prova que a exclusão mútua kernel-level (flock) está
# de fato em vigor, não só documentada. Mesmo padrão de sincronização
# determinística de tests/hub-selective-restore.sh (cenário 12): um processo
# em background segura o lock e sinaliza via arquivo sentinela, sem polling
# que competiria pelo próprio lock.
if (( HAVE_FLOCK )); then
    HOLD_SENTINEL="${TMP_DIR}/staging-holder.locked"
    RELEASE_SENTINEL="${TMP_DIR}/staging-holder.release"
    rm -f "${HOLD_SENTINEL}" "${RELEASE_SENTINEL}"
    (
        exec 9>"${LOCK_FILE}"
        flock -s 9
        : > "${HOLD_SENTINEL}"
        while [[ ! -f "${RELEASE_SENTINEL}" ]]; do sleep 0.05; done
    ) &
    HOLDER_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [[ -f "${HOLD_SENTINEL}" ]] && break
        sleep 0.1
    done
    [[ -f "${HOLD_SENTINEL}" ]] || fail "holder do lock compartilhado não conseguiu segurar o lock a tempo (setup do teste)"

    run_restore --hub-cleanup --job "${READY_JOB}"
    [[ "${RUN_RC}" -ne 0 ]] || fail "cleanup não deveria remover staging com uma leitura (lock compartilhado) em andamento"
    [[ -d "${ITEM_STAGING_DIR}/${READY_JOB}" ]] || fail "staging foi removido durante corrida com leitura ativa"

    : > "${RELEASE_SENTINEL}"
    wait "${HOLDER_PID}" 2>/dev/null || true

    run_restore --hub-cleanup --job "${READY_JOB}"
    assert_eq "0" "${RUN_RC}" "cleanup após o leitor soltar o lock deve suceder"
    [[ ! -d "${ITEM_STAGING_DIR}/${READY_JOB}" ]] || fail "cleanup não removeu o staging depois do lock liberado"
    pass "cleanup concorrente com uma leitura ativa (lock compartilhado) é recusado; após liberar, cleanup sucede"

    # Recria o job pronto de novo — os cenários acima consumiram-no.
    write_meta "${READY_JOB}" "success" "${future}"
    mkdir -p "${READY_DATA}"
    printf 'conteudo pequeno' > "${READY_DATA}/pequeno.txt"
else
    echo "# aviso: 'flock' ausente neste sistema — pulando cenário de corrida cleanup-vs-leitura." >&2
fi

bash -n "${ROOT_DIR}/restaurar_backup.sh" || fail "bash -n restaurar_backup.sh"
bash -n "${ROOT_DIR}/hub-restore-shell" || fail "bash -n hub-restore-shell"
bash -n "$0" || fail "bash -n do novo teste"
pass "sintaxe dos scripts afetados e do teste"

echo "1..${PASS_COUNT}"
