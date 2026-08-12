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

# 17. TERM durante o download não pode injetar texto no meio do stream.
#
# Tentativa anterior desta suíte matava (`kill -TERM`) um `staging-download`
# real bloqueado escrevendo num FIFO com leitor lento. Verificado à mão
# neste ambiente (múltiplas variações, inclusive com /bin/kill externo em
# vez do builtin): quando o comando em primeiro plano é `cat`/`tar` externo
# bloqueado em write() de um pipe cheio, o processo às vezes morre por
# SIGPIPE/KILL sem o bash pai chegar a rodar o trap — não é uma falha do
# código sob teste, é uma característica de timing entre sinal, bash e
# comando externo bloqueado em I/O que este ambiente não garante de forma
# confiável (processo pode morrer via bytes já enfileirados no pipe antes do
# handler despachar). Um teste que dependa disso é ele mesmo não-confiável:
# a rodada anterior "passava" tanto com o código corrigido quanto com
# restaurar_backup.sh totalmente revertido a 37abe6c, porque na prática o
# TERM raramente chegava a acionar QUALQUER trap em nenhum dos dois casos.
#
# Este cenário substitui aquela abordagem por uma determinística: extrai o
# trecho REAL do arquivo (trap + cleanup() + funções de log de que o trap
# depende, cortando antes de qualquer coisa que chame main) e o executa num
# subprocesso que AUTOSSINALIZA (`kill -TERM $$`) depois de simular o estado
# "no meio do download" (HUB_STDOUT_IS_BINARY=true). Autossinalização é
# processada de forma síncrona e 100% confiável pelo bash (verificado): o
# handler roda sempre, eliminando a variável de timing entre processos que
# tornava o cenário anterior inconclusivo. O que é exercitado é o MESMO
# trecho de código de produção, sem reescrever a lógica do trap no teste —
# só o gancho que dispara o sinal é diferente de um `cat`/`tar` real
# bloqueado.
extract_trap_snippet() {
    local restore_file="$1" out_file="$2"
    local end_line
    end_line="$(grep -n '^die() { error "\$\*"; exit 1; }$' "${restore_file}" | head -1 | cut -d: -f1)"
    [[ -n "${end_line}" ]] || return 1
    head -n "${end_line}" "${restore_file}" > "${out_file}"
}

# run_trap_snippet <restore_file> <binary:true|false> → stdout/stderr/rc do
# subprocesso capturados em OUT_FILE/ERR_FILE/RUN_RC, igual às outras
# run_* deste arquivo.
run_trap_snippet() {
    local restore_file="$1" binary="$2" snippet runner
    snippet="${TMP_DIR}/trap_snippet.sh"
    runner="${TMP_DIR}/trap_runner.sh"
    extract_trap_snippet "${restore_file}" "${snippet}" \
        || fail "não foi possível extrair o trecho do trap de ${restore_file} (die() não encontrado — arquivo mudou de forma incompatível com este teste)"
    {
        cat "${snippet}"
        echo
        printf 'RESTORE_LOG_FILE=%q\n' "${TMP_DIR}/trap_snippet.log"
        : > "${TMP_DIR}/trap_snippet.log"
        [[ "${binary}" == "true" ]] && echo 'HUB_STDOUT_IS_BINARY=true'
        echo '# Simula bytes já emitidos no stdout ANTES do sinal chegar —'
        echo '# é exatamente esse conteúdo que não pode ganhar uma cauda de'
        echo '# texto se o trap disparar logo em seguida.'
        echo 'printf "BYTES_JA_EMITIDOS"'
        echo 'kill -TERM $$'
        echo 'echo "NAO_DEVERIA_CHEGAR_AQUI: trap não interrompeu a execução"'
    } > "${runner}"
    : > "${OUT_FILE}"; : > "${ERR_FILE}"
    bash "${runner}" >"${OUT_FILE}" 2>"${ERR_FILE}"
    RUN_RC=$?
}

run_trap_snippet "${ROOT_DIR}/restaurar_backup.sh" true
assert_eq "130" "${RUN_RC}" "trap de TERM deve terminar com rc 130 (modo binário)"
assert_eq "BYTES_JA_EMITIDOS" "$(cat "${OUT_FILE}")" \
    "com HUB_STDOUT_IS_BINARY=true, TERM não pode acrescentar nada além dos bytes já emitidos"
assert_not_contains "${OUT_FILE}" "Interrompido" "TERM durante o download não pode injetar aviso no stdout binário"
assert_not_contains "${OUT_FILE}" "AVISO" "TERM durante o download não pode injetar tag de log no stdout binário"
assert_not_contains "${OUT_FILE}" "NAO_DEVERIA_CHEGAR_AQUI" "trap deve interromper a execução (exit), não deixar o script continuar"

# Controle negativo: com a flag "false" (fora do modo de download), o MESMO
# trap real deve continuar avisando em texto — prova que o teste acima
# discrimina de verdade o estado da flag, não é uma checagem que sempre dá
# "sem texto" independente do código.
run_trap_snippet "${ROOT_DIR}/restaurar_backup.sh" false
assert_eq "130" "${RUN_RC}" "trap de TERM deve terminar com rc 130 (modo texto)"
assert_contains "${OUT_FILE}" "Interrompido pelo usuário" "fora do modo de download, o trap deve avisar normalmente em stdout (controle negativo)"
pass "trap de TERM respeita HUB_STDOUT_IS_BINARY: silencioso durante download, textual fora dele (controle negativo incluído)"

# 18. Corrida cleanup vs leitura: um `staging-download` REAL (não um holder
# `flock -s` sintético — achado da rodada anterior: um holder sintético só
# prova que "flock -s existe e funciona no SO", não que
# run_hub_staging_download de fato CHAMA hub_item_acquire_lock_shared antes
# de ler) precisa bloquear um `cleanup` concorrente (lock exclusivo) até
# terminar — prova que o código de produção realmente adquire e mantém o
# lock durante toda a leitura, não só que o mecanismo do SO funciona
# isoladamente.
if (( HAVE_FLOCK )); then
    RACE_JOB="job-race-1"
    write_meta "${RACE_JOB}" "success" "${future}"
    RACE_DATA="${ITEM_STAGING_DIR}/${RACE_JOB}/data"
    mkdir -p "${RACE_DATA}"
    # 300MB: verificado à parte (script de diagnóstico isolado) que um
    # arquivo pequeno (5MB) faz o `cat` real de dentro de
    # run_hub_staging_download terminar de escrever no FIFO rápido demais
    # (buffer do pipe absorve tudo antes do cleanup rodar) — precisa de
    # volume suficiente para garantir uma janela de bloqueio real e
    # mensurável, independente da velocidade de I/O local.
    head -c 300000000 /dev/urandom > "${RACE_DATA}/grande.bin" 2>/dev/null \
        || dd if=/dev/zero of="${RACE_DATA}/grande.bin" bs=1048576 count=300 2>/dev/null
    TOKEN_RACE_GRANDE="$(token_for_rel_path "${RACE_JOB}" "/grande.bin")"

    # FIFO com leitor que ABRE o descritor de leitura IMEDIATAMENTE (antes do
    # download começar), mas só CONSOME depois de um delay. Diferença crucial
    # em relação a uma tentativa anterior desta suíte: `> FIFO` num
    # redirecionamento bloqueia a própria ABERTURA até existir um leitor —
    # atrasar o leitor (com um `sleep` antes de sequer abrir o FIFO) atrasava
    # o INÍCIO do processo de download inteiro, não criava uma janela de
    # bloqueio no MEIO do cat como a intenção do cenário exige (verificado
    # com um script de diagnóstico isolado: nesse caso o download morria
    # "cedo" só porque na prática ele nunca tinha começado a rodar de
    # verdade). Aqui o leitor abre o fd logo de cara (o `env ... > FIFO`
    # desbloqueia e o script começa a executar imediatamente), e só a
    # LEITURA em si é adiada — isso enche o buffer do pipe e bloqueia o
    # `cat <&11` real em write(), confirmado com o mesmo script de
    # diagnóstico usando flock -n externo contra o lock do processo real.
    READER_DELAY_S=3
    RACE_FIFO="${TMP_DIR}/race.fifo"
    rm -f "${RACE_FIFO}"
    mkfifo "${RACE_FIFO}"
    RACE_OUT="${TMP_DIR}/race.out"
    : > "${RACE_OUT}"
    (
        exec 30<"${RACE_FIFO}"
        sleep "${READER_DELAY_S}"
        cat <&30 > "${RACE_OUT}"
    ) &
    RACE_READER_PID=$!
    env \
        PATH="${MOCK_BIN}:${PATH}" \
        RESTIC_ENV_FILE="${ENV_FILE}" \
        RESTORE_LOG_FILE="${RESTORE_LOG}" \
        RESTIC_RESTORE_ALLOW_NONROOT=1 \
        "${RESTORE_COPY}" --hub-staging-download --job "${RACE_JOB}" --token "${TOKEN_RACE_GRANDE}" \
        >"${RACE_FIFO}" 2>"${TMP_DIR}/race.err" &
    RACE_DOWNLOAD_PID=$!
    # Confirma que o processo de download está de fato vivo e ainda rodando
    # (bloqueado em write(), buffer do pipe cheio, leitor ainda dormindo) no
    # meio da janela de READER_DELAY_S — não apenas que ele iniciou.
    sleep "$(awk "BEGIN { print ${READER_DELAY_S} / 2 }")"
    kill -0 "${RACE_DOWNLOAD_PID}" 2>/dev/null \
        || fail "staging-download real terminou cedo demais — não ficou bloqueado no FIFO sem leitura ativa (setup do teste de corrida)"

    run_restore --hub-cleanup --job "${RACE_JOB}"
    [[ "${RUN_RC}" -ne 0 ]] || fail "cleanup não deveria remover staging com um staging-download real em andamento"
    [[ -d "${ITEM_STAGING_DIR}/${RACE_JOB}" ]] || fail "staging foi removido durante corrida com download real ativo"
    # Confirma que o download ainda estava vivo DEPOIS da tentativa de
    # cleanup também — se o cleanup tivesse (por hipótese de bug) matado ou
    # corrompido o staging por baixo dele, o cat que já tinha o fd aberto
    # teria morrido ou travado de forma anormal.
    kill -0 "${RACE_DOWNLOAD_PID}" 2>/dev/null \
        || fail "staging-download real morreu inesperadamente durante/após a tentativa de cleanup concorrente"

    # Deixa o leitor (que acorda sozinho após READER_DELAY_S) drenar o FIFO
    # e o download real terminar sozinho — não mata nada (cenário de sinal
    # já é coberto isoladamente no 17; aqui o que importa é a janela de
    # sobreposição com o cleanup).
    wait "${RACE_DOWNLOAD_PID}" 2>/dev/null || true
    wait "${RACE_READER_PID}" 2>/dev/null || true
    rm -f "${RACE_FIFO}"
    RACE_SHA_ORIGINAL="$(shasum -a 256 "${RACE_DATA}/grande.bin" 2>/dev/null | awk '{print $1}')"
    [[ -n "${RACE_SHA_ORIGINAL}" ]] || RACE_SHA_ORIGINAL="$(sha256sum "${RACE_DATA}/grande.bin" | awk '{print $1}')"
    RACE_SHA_RECEIVED="$(shasum -a 256 "${RACE_OUT}" 2>/dev/null | awk '{print $1}')"
    [[ -n "${RACE_SHA_RECEIVED}" ]] || RACE_SHA_RECEIVED="$(sha256sum "${RACE_OUT}" | awk '{print $1}')"
    assert_eq "${RACE_SHA_ORIGINAL}" "${RACE_SHA_RECEIVED}" \
        "conteúdo transmitido durante a corrida com cleanup deve permanecer íntegro (sem truncar/corromper)"

    run_restore --hub-cleanup --job "${RACE_JOB}"
    assert_eq "0" "${RUN_RC}" "cleanup após o download real terminar (lock liberado) deve suceder"
    [[ ! -d "${ITEM_STAGING_DIR}/${RACE_JOB}" ]] || fail "cleanup não removeu o staging depois do download real terminar"
    pass "cleanup concorrente com um staging-download REAL em andamento é recusado; após terminar, cleanup sucede"
else
    echo "# aviso: 'flock' ausente neste sistema — pulando cenário de corrida cleanup-vs-leitura." >&2
fi

bash -n "${ROOT_DIR}/restaurar_backup.sh" || fail "bash -n restaurar_backup.sh"
bash -n "${ROOT_DIR}/hub-restore-shell" || fail "bash -n hub-restore-shell"
bash -n "$0" || fail "bash -n do novo teste"
pass "sintaxe dos scripts afetados e do teste"

echo "1..${PASS_COUNT}"
