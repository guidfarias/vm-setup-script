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
INCLUDE_LOG="${TMP_DIR}/restore.includes"
MATCHED_LOG="${TMP_DIR}/restore.matched"
SIBLINGS_FILE="${TMP_DIR}/glob.siblings"

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
        MOCK_INCLUDE_LOG="${INCLUDE_LOG}" \
        MOCK_MATCHED_LOG="${MATCHED_LOG}" \
        MOCK_SIBLINGS_FILE="${SIBLINGS_FILE}" \
        "${RESTORE_COPY}" "$@" >"${OUT_FILE}" 2>"${ERR_FILE}"
    RUN_RC=$?
}

# Chamada direta de --hub-restore-item (sem passar pelo wrapper): injeta um
# --nonce fresco automaticamente, já que restic-restore.sh agora exige um.
run_restore_item_direct() {
    local nonce
    nonce="$(openssl rand -hex 16)"
    run_restore "$@" --nonce "${nonce}"
}

# Chama o hub-restore-shell de verdade via SSH_ORIGINAL_COMMAND — cobre o
# handshake completo (nonce gerado pelo wrapper, comparação do marcador,
# timeout/kill do filho) que uma chamada direta a --hub-restore-item não
# exercita.
run_wrapper() {
    local original_command="$1"
    : > "${OUT_FILE}"; : > "${ERR_FILE}"
    env \
        PATH="${MOCK_BIN}:${PATH}" \
        SSH_ORIGINAL_COMMAND="${original_command}" \
        RESTIC_ENV_FILE="${ENV_FILE}" \
        RESTORE_LOG_FILE="${RESTORE_LOG}" \
        RESTIC_RESTORE_ALLOW_NONROOT=1 \
        MOCK_RESTIC_FAIL="${MOCK_RESTIC_FAIL:-}" \
        MOCK_DF_MODE="${MOCK_DF_MODE:-normal}" \
        MOCK_CALL_LOG="${CALL_LOG}" \
        MOCK_DF_LOG="${DF_LOG}" \
        MOCK_SUDO_LOG="${SUDO_LOG}" \
        MOCK_LOGGER_LOG="${LOGGER_LOG}" \
        MOCK_INCLUDE_LOG="${INCLUDE_LOG}" \
        MOCK_MATCHED_LOG="${MATCHED_LOG}" \
        MOCK_SIBLINGS_FILE="${SIBLINGS_FILE}" \
        "${SHELL_COPY}" >"${OUT_FILE}" 2>"${ERR_FILE}"
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
TEST_RESTORE_BIN="${RESTORE_COPY}" TEST_ITEM_DIR="${ITEM_STAGING_DIR}" \
    perl -0pi -e '
        my $restore = qq{readonly RESTORE_BIN="$ENV{TEST_RESTORE_BIN}"};
        my $items = qq{readonly HUB_ITEM_STAGING_DIR="$ENV{TEST_ITEM_DIR}"};
        s{\Qreadonly RESTORE_BIN="/usr/local/bin/restic-restore.sh"\E}{$restore};
        s{\Qreadonly HUB_ITEM_STAGING_DIR="/var/lib/hub-restore/items"\E}{$items};
        # Timeout de handshake reduzido só na cópia de teste (1s em vez de
        # 8s) para o cenário de timeout não gastar tempo real em CI.
        s{\Qreadonly HANDSHAKE_TIMEOUT_S=8\E}{readonly HANDSHAKE_TIMEOUT_S=1};
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
            '/nome[esquisito]*.txt')
                echo '{"struct_type":"node","path":"/nome[esquisito]*.txt","type":"file","size":7}'
                ;;
            '/a?txt')
                # Item real cujo nome contém um metacaractere de glob do
                # restic ('?' casa 1 char qualquer). Existe também /abtxt no
                # snapshot (ver GLOB_SIBLINGS abaixo) — sem escape, o padrão
                # cru '/a?txt' casaria os dois.
                echo '{"struct_type":"node","path":"/a?txt","type":"file","size":3}'
                ;;
            *) exit 1 ;;
        esac
        ;;
    restore)
        [[ "$#" -ge 5 && "$3" == "--target" ]] || exit 95
        # Grava o --include literal recebido, para o teste de glob confirmar
        # que o caminho foi escapado antes de chegar ao Restic (senão um
        # padrão como '*' casaria outros itens do snapshot).
        include=""
        for ((i = 1; i <= $#; i++)); do
            if [[ "${!i}" == "--include" ]]; then
                j=$((i + 1))
                include="${!j}"
                printf '%s\n' "${include}" >> "${MOCK_INCLUDE_LOG:-/dev/null}"
            fi
        done
        # Simula a expansão do padrão --include contra a lista completa do
        # snapshot (GLOB_SIBLINGS): cada arquivo do "snapshot" cujo nome
        # cru CASA o padrão recebido conta como "materializado". Se o
        # caminho foi escapado corretamente, só o item exato casa; se não
        # foi, o irmão com metacaractere também casaria.
        if [[ -n "${include}" && -n "${MOCK_MATCHED_LOG:-}" && -f "${MOCK_SIBLINGS_FILE:-/dev/null}" ]]; then
            : > "${MOCK_MATCHED_LOG}"
            while IFS= read -r candidate; do
                [[ -n "${candidate}" ]] || continue
                # shellcheck disable=SC2053 # comparação de glob intencional
                if [[ "${candidate}" == ${include} ]]; then
                    printf '%s\n' "${candidate}" >> "${MOCK_MATCHED_LOG}"
                fi
            done < "${MOCK_SIBLINGS_FILE}"
        fi
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

# sudo mockado: o wrapper roda "sudo -n RESTORE_BIN ...". Sem privilégio
# real disponível no ambiente de teste, só remove o "-n" e executa o resto —
# RESTIC_RESTORE_ALLOW_NONROOT=1 já faz o restic-restore.sh aceitar rodar
# sem ser root.
cat > "${MOCK_BIN}/sudo" <<'MOCK'
#!/bin/bash
printf 'sudo argc=%d <%s>\n' "$#" "$*" >> "${MOCK_SUDO_LOG:-/dev/null}"
[[ "$1" == "-n" ]] && shift
exec "$@"
MOCK

chmod +x "${MOCK_BIN}/restic" "${MOCK_BIN}/df" "${MOCK_BIN}/logger" "${MOCK_BIN}/sudo"

# flock real é exigido (produção é sempre Linux/RunCloud). Se o sistema local
# de teste não tiver util-linux (ex.: macOS), pula só os cenários que
# precisam de execução real do modo --hub-restore-item — os demais (cleanup,
# validação de job_id) não dependem de flock e continuam rodando.
HAVE_FLOCK=1
command -v flock >/dev/null 2>&1 || HAVE_FLOCK=0
: > "${CALL_LOG}"; : > "${DF_LOG}"; : > "${LOGGER_LOG}"; : > "${INCLUDE_LOG}"

TOKEN_FILE="$(token_for_path "${SNAPSHOT}" "/arquivo.txt")"
TOKEN_DIR="$(token_for_path "${SNAPSHOT}" "/diretorio")"
TOKEN_MISSING="$(token_for_path "${SNAPSHOT}" "/nao-existe")"
TOKEN_GLOB="$(token_for_path "${SNAPSHOT}" '/nome[esquisito]*.txt')"
TOKEN_A_QMARK="$(token_for_path "${SNAPSHOT}" '/a?txt')"

if (( HAVE_FLOCK )); then
    # 1. Arquivo: materializa só o item, meta.json completo, staging isolado.
    run_restore_item_direct --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --job job-file-1
    assert_eq "0" "${RUN_RC}" "restauração de arquivo"
    [[ -f "${ITEM_STAGING_DIR}/job-file-1/control/meta.json" ]] || fail "meta.json ausente (arquivo)"
    assert_eq "success" "$(json_field "${ITEM_STAGING_DIR}/job-file-1/control/meta.json" status)" "status final (arquivo)"
    assert_eq "file" "$(json_field "${ITEM_STAGING_DIR}/job-file-1/control/meta.json" item_type)" "item_type (arquivo)"
    assert_eq "/arquivo.txt" "$(json_field "${ITEM_STAGING_DIR}/job-file-1/control/meta.json" path)" "path persistido (arquivo)"
    [[ "$(json_field "${ITEM_STAGING_DIR}/job-file-1/control/meta.json" expires_at)" -gt "$(json_field "${ITEM_STAGING_DIR}/job-file-1/control/meta.json" created_at)" ]] \
        || fail "expires_at deve ser posterior a created_at"
    pass "restauração seletiva de arquivo materializa só o item em staging isolado"

    # 2. Diretório: mesmo fluxo, item_type=directory.
    run_restore_item_direct --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_DIR}" --job job-dir-1
    assert_eq "0" "${RUN_RC}" "restauração de diretório"
    assert_eq "directory" "$(json_field "${ITEM_STAGING_DIR}/job-dir-1/control/meta.json" item_type)" "item_type (diretório)"
    [[ -d "${ITEM_STAGING_DIR}/job-dir-1" ]] || fail "staging do job-dir-1 ausente"
    [[ -d "${ITEM_STAGING_DIR}/job-file-1" ]] || fail "staging do job-file-1 deveria continuar existindo (isolado do job-dir-1)"
    pass "restauração seletiva de diretório usa staging isolado do job"

    # 3. Item ausente no snapshot: falha auditável, sem restic restore.
    : > "${CALL_LOG}"
    run_restore_item_direct --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_MISSING}" --job job-missing-1
    assert_eq "1" "${RUN_RC}" "item ausente deve falhar"
    assert_contains "${ITEM_STAGING_DIR}/job-missing-1/control/meta.json" '"status":"failed item' "meta de item ausente"
    grep -q '^restic argc=[0-9]* <restore>' "${CALL_LOG}" && fail "não deveria chamar restic restore para item ausente"
    pass "item ausente no snapshot recusa e registra falha auditável, sem tentar restic restore"

    # 4. Pouco espaço: falha auditável antes do restic restore.
    : > "${CALL_LOG}"
    MOCK_DF_MODE=low run_restore_item_direct --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --job job-lowspace-1
    assert_eq "1" "${RUN_RC}" "pouco espaço deve falhar"
    assert_contains "${ITEM_STAGING_DIR}/job-lowspace-1/control/meta.json" 'espaço livre insuficiente' "meta de pouco espaço"
    grep -q '^restic argc=[0-9]* <restore>' "${CALL_LOG}" && fail "não deveria chamar restic restore com pouco espaço"
    pass "pouco espaço recusa a restauração antes de tocar o restic"

    # 5. Job duplicado: mesmo job_id não pode ser reaproveitado.
    run_restore_item_direct --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --job job-file-1
    [[ "${RUN_RC}" -ne 0 ]] || fail "job_id repetido deveria ser recusado"
    assert_contains "${ERR_FILE}" "já existe" "mensagem de job duplicado"
    pass "segundo job com o mesmo job_id é recusado"

    # 6. Falha do Restic: status failed auditável, staging preservado para inspeção.
    MOCK_RESTIC_FAIL=restore run_restore_item_direct --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --job job-resticfail-1
    assert_eq "1" "${RUN_RC}" "falha do restic deve propagar rc != 0"
    assert_contains "${ITEM_STAGING_DIR}/job-resticfail-1/control/meta.json" '"status":"failed restic restore' "meta de falha do restic"
    [[ -d "${ITEM_STAGING_DIR}/job-resticfail-1" ]] || fail "staging da falha deve ser preservado para auditoria"
    pass "falha do Restic termina em failed auditável, staging preservado"

    # 11. Nome com metacaracteres de glob do Restic (* ? [ ]): o --include
    # recebido pelo restic precisa ser o caminho ESCAPADO (literal), senão um
    # '*' ou '[...]' no nome real casaria outros itens do snapshot.
    : > "${INCLUDE_LOG}"
    run_restore_item_direct --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_GLOB}" --job job-glob-1
    assert_eq "0" "${RUN_RC}" "restauração de item com metacaracteres de glob no nome"
    assert_eq "file" "$(json_field "${ITEM_STAGING_DIR}/job-glob-1/control/meta.json" item_type)" "item_type (glob)"
    assert_eq '/nome[esquisito]*.txt' "$(json_field "${ITEM_STAGING_DIR}/job-glob-1/control/meta.json" path)" "path persistido sem escape (glob)"
    assert_contains "${INCLUDE_LOG}" '/nome\[esquisito\]\*.txt' "--include recebido pelo restic deve estar escapado"
    grep -qF '/nome[esquisito]*.txt' "${INCLUDE_LOG}" && fail "--include não pode chegar ao restic sem escape (viraria glob real)"
    pass "item com * ? [ ] no nome é passado ao restic como padrão literal (escapado), só o item exato é materializado"

    # 12. Colisão de glob de verdade: /a?txt existe no snapshot, e /abtxt é um
    # IRMÃO que o padrão CRU '/a?txt' (sem escape) também casaria (? = 1
    # caractere qualquer). Simula a expansão do --include recebido contra os
    # dois nomes reais do "snapshot" e prova que só o item pedido casa.
    printf '/a?txt\n/abtxt\n' > "${SIBLINGS_FILE}"
    : > "${MATCHED_LOG}"
    run_restore_item_direct --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_A_QMARK}" --job job-glob-collision-1
    assert_eq "0" "${RUN_RC}" "restauração de /a?txt (colisão de glob)"
    [[ -s "${MATCHED_LOG}" ]] || fail "MATCHED_LOG vazio — mock de expansão de glob não rodou"
    assert_eq "1" "$(wc -l < "${MATCHED_LOG}" | tr -d ' ')" "exatamente 1 item deve casar o --include"
    assert_contains "${MATCHED_LOG}" '/a?txt' "o item exato deve casar"
    grep -qxF '/abtxt' "${MATCHED_LOG}" && fail "/abtxt (irmão) não pode casar — prova que o --include NÃO foi escapado corretamente"
    pass "irmão que casaria o padrão cru (/abtxt vs /a?txt) não é materializado — só o item exato"
else
    echo "# aviso: 'flock' ausente neste sistema — pulando cenários 1-6, 9, 11 e 12 (execução real de --hub-restore-item)." >&2
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

# 12. Corrida cleanup vs restore: job com status "running" e lock global
# ocupado (simula um restore-item de fato em andamento) não pode ser
# removido — nem por exclusão antecipada, nem pela varredura de expirados.
if command -v flock >/dev/null 2>&1; then
    mkdir -p "${ITEM_STAGING_DIR}/job-running-1/control" "${ITEM_STAGING_DIR}/job-running-1/data"
    cat > "${ITEM_STAGING_DIR}/job-running-1/control/meta.json" <<JSON
{"version":1,"job_id":"job-running-1","snapshot":"${SNAPSHOT}","path":"/arquivo.txt","item_type":"file","status":"running","created_at":1,"expires_at":1}
JSON
    # Segura o MESMO lock global que run_hub_restore_item usa, num processo em
    # background, para simular um job realmente em execução. HOLD_SENTINEL só
    # é criado DEPOIS do flock ter sucesso — barreira determinística, sem
    # depender de polling que competiria pelo próprio lock e distorceria o
    # timing. `flock 8 -c 'sleep N'` (em vez de `flock 8; sleep N` em
    # comandos separados) garante que o processo que segura o lock e o que
    # dorme são o MESMO PID — sem isso, alguns bashes bifurcam `sleep` como
    # filho separado, e matar só o PID capturado deixa esse filho órfão
    # segurando o fd do lock (visto na prática: o wait/kill do PID pai
    # retornava, mas lsof ainda mostrava um `sleep` distinto com o fd aberto).
    HOLD_SENTINEL="${TMP_DIR}/holder.locked"
    rm -f "${HOLD_SENTINEL}"
    flock 8 -c ": > '${HOLD_SENTINEL}'; sleep 2" 8>"${LOCK_FILE}" &
    HOLDER_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [[ -f "${HOLD_SENTINEL}" ]] && break
        sleep 0.1
    done
    [[ -f "${HOLD_SENTINEL}" ]] || fail "holder não conseguiu segurar o lock a tempo (setup do teste)"

    run_restore --hub-cleanup --job job-running-1
    [[ "${RUN_RC}" -ne 0 ]] || fail "cleanup não deveria remover job com lock ocupado (running)"
    [[ -d "${ITEM_STAGING_DIR}/job-running-1" ]] || fail "staging do job running foi removido durante corrida com cleanup"

    # Espera o holder terminar sozinho (sleep 2, curto e determinístico) em
    # vez de tentar matá-lo — evita toda a categoria de problema de processos
    # filhos órfãos ainda segurando o fd do lock.
    wait "${HOLDER_PID}" 2>/dev/null || true
    LOCK_FREE=0
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if flock -n "${LOCK_FILE}" -c true 2>/dev/null; then
            LOCK_FREE=1
            break
        fi
        sleep 0.2
    done
    (( LOCK_FREE )) || fail "lock não foi liberado a tempo após o holder terminar (setup do teste)"

    # Expirado (created_at antigo) mas ainda "running" com lock livre agora:
    # a limpeza revalida o status DEPOIS de adquirir o lock e ainda recusa,
    # porque o meta.json continua dizendo running.
    run_restore --hub-cleanup --job job-running-1
    [[ "${RUN_RC}" -ne 0 ]] || fail "cleanup não deveria remover job com status running, mesmo com lock livre"
    [[ -d "${ITEM_STAGING_DIR}/job-running-1" ]] || fail "staging do job running não deveria ser removido enquanto status=running"
    pass "limpeza durante job ativo (lock ocupado ou status running) é recusada"
else
    echo "# aviso: 'flock' ausente — pulando cenário 12 (corrida cleanup vs restore)." >&2
fi

# 13. Falha de env (RESTIC_ENV_FILE ausente): meta.json termina em failed,
# nunca fica preso em running — cobre load_env_file_safe/validate_env_safe
# (variantes que retornam erro em vez de matar o processo com die).
if (( HAVE_FLOCK )); then
    # A env real é passada via RESTIC_ENV_FILE; para simular falha, chamamos
    # diretamente com RESTIC_ENV_FILE apontando para um arquivo inexistente.
    : > "${OUT_FILE}"; : > "${ERR_FILE}"
    env \
        PATH="${MOCK_BIN}:${PATH}" \
        RESTIC_ENV_FILE="${TMP_DIR}/env-que-nao-existe" \
        RESTORE_LOG_FILE="${RESTORE_LOG}" \
        RESTIC_RESTORE_ALLOW_NONROOT=1 \
        MOCK_CALL_LOG="${CALL_LOG}" \
        MOCK_DF_LOG="${DF_LOG}" \
        MOCK_SUDO_LOG="${SUDO_LOG}" \
        MOCK_LOGGER_LOG="${LOGGER_LOG}" \
        MOCK_INCLUDE_LOG="${INCLUDE_LOG}" \
        "${RESTORE_COPY}" --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_FILE}" --job job-envfail-2 \
        --nonce "$(openssl rand -hex 16)" \
        >"${OUT_FILE}" 2>"${ERR_FILE}"
    RUN_RC=$?
    assert_eq "1" "${RUN_RC}" "falha de env deve retornar rc != 0"
    [[ -f "${ITEM_STAGING_DIR}/job-envfail-2/control/meta.json" ]] || fail "meta.json ausente após falha de env"
    assert_contains "${ITEM_STAGING_DIR}/job-envfail-2/control/meta.json" '"status":"failed env' "meta de falha de env"
    grep -qF '"status":"running"' "${ITEM_STAGING_DIR}/job-envfail-2/control/meta.json" \
        && ! grep -qF '"status":"failed' "${ITEM_STAGING_DIR}/job-envfail-2/control/meta.json" \
        && fail "job de falha de env não pode ficar preso em running"
    pass "falha simulada de env deixa meta.json em failed, nunca preso em running"
fi

# 14. Queda do cliente durante a restauração: run_hub_restore_item não deve
# depender de stdin/sessão viva para terminar — roda até o fim mesmo com
# stdin fechado desde o início (equivalente a uma sessão SSH que caiu antes
# do job iniciar de verdade) e ainda assim persiste um resultado auditável.
if (( HAVE_FLOCK )); then
    : > "${OUT_FILE}"; : > "${ERR_FILE}"
    env \
        PATH="${MOCK_BIN}:${PATH}" \
        RESTIC_ENV_FILE="${ENV_FILE}" \
        RESTORE_LOG_FILE="${RESTORE_LOG}" \
        RESTIC_RESTORE_ALLOW_NONROOT=1 \
        MOCK_CALL_LOG="${CALL_LOG}" \
        MOCK_DF_LOG="${DF_LOG}" \
        MOCK_SUDO_LOG="${SUDO_LOG}" \
        MOCK_LOGGER_LOG="${LOGGER_LOG}" \
        MOCK_INCLUDE_LOG="${INCLUDE_LOG}" \
        "${RESTORE_COPY}" --hub-restore-item --snapshot "${SNAPSHOT}" --token "${TOKEN_DIR}" --job job-clientdrop-1 \
        --nonce "$(openssl rand -hex 16)" \
        </dev/null >"${OUT_FILE}" 2>"${ERR_FILE}"
    RUN_RC=$?
    assert_eq "0" "${RUN_RC}" "job com stdin fechado (sessão caída) deve terminar normalmente"
    assert_eq "success" "$(json_field "${ITEM_STAGING_DIR}/job-clientdrop-1/control/meta.json" status)" "status final (sessão caída)"
    [[ "$(json_field "${ITEM_STAGING_DIR}/job-clientdrop-1/control/meta.json" finished_at)" -gt 0 ]] \
        || fail "finished_at ausente/zero após conclusão"
    pass "job não depende de stdin/sessão viva — sobrevive à queda do cliente e termina auditável"
fi

# ---------------------------------------------------------------------------
# Integração via hub-restore-shell (item 3, ciclo 3): cobre o handshake
# COMPLETO — nonce gerado pelo wrapper, comparação do marcador, timeout/kill
# do filho — que uma chamada direta a --hub-restore-item não exercita.
# ---------------------------------------------------------------------------

if (( HAVE_FLOCK )); then
    # 16. Marcador fresco exigido: um .ready de uma tentativa ANTERIOR (nonce
    # diferente) não pode fazer o wrapper aceitar a tentativa atual. Cria um
    # job_dir com control/.ready contendo um nonce arbitrário, sem meta.json
    # "running" real por trás — se o wrapper só checasse existência (bug do
    # ciclo 2), aceitaria na hora; com a checagem de conteúdo, ele precisa
    # esperar o job de verdade preparar (que vai gravar outro nonce) e só aí
    # aceitar.
    mkdir -p "${ITEM_STAGING_DIR}/job-staleready-1/control" "${ITEM_STAGING_DIR}/job-staleready-1/data"
    printf 'nonce-de-uma-tentativa-anterior-que-nao-eh-esta' > "${ITEM_STAGING_DIR}/job-staleready-1/control/.ready"
    # job_dir já existe → mkdir (sem -p) do run_hub_restore_item real vai
    # falhar com EEXIST (job duplicado) — o que É o comportamento correto:
    # mesmo com um .ready "válido" (existe) mas de conteúdo errado, o
    # wrapper não pode aceitar. Confirma que a rejeição chega ao cliente,
    # não um "ok" baseado no marcador obsoleto.
    run_wrapper "restore-item ${SNAPSHOT} ${TOKEN_FILE} job-staleready-1"
    [[ "${RUN_RC}" -ne 0 ]] || fail "marcador .ready de tentativa anterior não pode gerar 'ok' para um job_id reciclado sem preparação real"
    assert_contains "${ERR_FILE}" "recusado" "rejeição de marcador obsoleto deve chegar ao cliente"
    pass "marcador .ready de tentativa anterior (nonce diferente) não gera ok — job_id reciclado é sempre recusado até preparar de verdade"

    # 17. Rejeição imediata de job duplicado via wrapper: job_id já usado com
    # sucesso (job-dir-1, do bloco de chamada direta acima — não removido por
    # nenhum teste anterior) deve ser recusado pelo wrapper com erro
    # imediato, sem "ok" otimista.
    run_wrapper "restore-item ${SNAPSHOT} ${TOKEN_DIR} job-dir-1"
    [[ "${RUN_RC}" -ne 0 ]] || fail "wrapper não deveria responder ok para job_id já existente"
    assert_contains "${ERR_FILE}" "recusado" "rejeição imediata de job duplicado via wrapper"
    grep -qF '"ok":true' "${OUT_FILE}" && fail "wrapper não pode responder ok:true para job duplicado"
    pass "wrapper rejeita job_id duplicado imediatamente via handshake, sem ok otimista"

    # 18. Timeout de handshake mata o filho: RESTORE_BIN mockado para nunca
    # gravar o marcador (dorme além do HANDSHAKE_TIMEOUT_S=1 reduzido nesta
    # cópia de teste). O wrapper deve rejeitar E o processo/grupo não pode
    # sobreviver à rejeição — testado verificando que o "job trava" (arquivo
    # sentinela feito pelo mock DEPOIS do sleep) nunca aparece, provando que
    # o processo foi morto antes de completar o sleep.
    SLOW_SENTINEL="${TMP_DIR}/slow-restore-completed"
    rm -f "${SLOW_SENTINEL}"
    SLOW_RESTORE_BIN="${TMP_DIR}/restic-restore-slow.sh"
    cat > "${SLOW_RESTORE_BIN}" <<SLOWMOCK
#!/bin/bash
sleep 5
: > "${SLOW_SENTINEL}"
SLOWMOCK
    chmod +x "${SLOW_RESTORE_BIN}"
    SLOW_SHELL_COPY="${TMP_DIR}/hub-restore-shell-slow"
    cp "${SHELL_COPY}" "${SLOW_SHELL_COPY}"
    TEST_SLOW_BIN="${SLOW_RESTORE_BIN}" perl -0pi -e '
        my $restore = qq{readonly RESTORE_BIN="$ENV{TEST_SLOW_BIN}"};
        s{\Qreadonly RESTORE_BIN="'"${RESTORE_COPY}"'"\E}{$restore};
    ' "${SLOW_SHELL_COPY}"
    START_TS=$(date +%s)
    env \
        PATH="${MOCK_BIN}:${PATH}" \
        SSH_ORIGINAL_COMMAND="restore-item ${SNAPSHOT} ${TOKEN_FILE} job-timeout-1" \
        RESTIC_ENV_FILE="${ENV_FILE}" \
        RESTORE_LOG_FILE="${RESTORE_LOG}" \
        RESTIC_RESTORE_ALLOW_NONROOT=1 \
        MOCK_CALL_LOG="${CALL_LOG}" MOCK_DF_LOG="${DF_LOG}" MOCK_SUDO_LOG="${SUDO_LOG}" \
        MOCK_LOGGER_LOG="${LOGGER_LOG}" \
        "${SLOW_SHELL_COPY}" >"${OUT_FILE}" 2>"${ERR_FILE}"
    RUN_RC=$?
    ELAPSED=$(( $(date +%s) - START_TS ))
    [[ "${RUN_RC}" -ne 0 ]] || fail "handshake sem marcador deveria terminar em rejeição (timeout)"
    assert_contains "${ERR_FILE}" "recusado" "timeout de handshake deve rejeitar explicitamente"
    (( ELAPSED < 5 )) || fail "wrapper esperou o sleep 5 inteiro — não matou o filho no timeout (levou ${ELAPSED}s)"
    sleep 1
    [[ ! -f "${SLOW_SENTINEL}" ]] || fail "processo lento completou o sleep 5 após o timeout — não foi morto (processo órfão)"
    pass "timeout de handshake mata o processo/grupo do filho antes de rejeitar, sem deixá-lo órfão"

    # 19. Fallback seletivo de status/log via wrapper: um job seletivo
    # concluído (job-dir-1) deve responder a `status`/`log` mesmo não tendo
    # NENHUM registro no protocolo legado (HUB_JOB_STATUS_DIR/HUB_JOB_LOG_DIR).
    run_wrapper "status job-dir-1"
    assert_eq "0" "${RUN_RC}" "status via wrapper para job seletivo"
    assert_contains "${OUT_FILE}" '"status":"success"' "fallback de status deve ler o meta.json seletivo"
    run_wrapper "log job-dir-1"
    assert_eq "0" "${RUN_RC}" "log via wrapper para job seletivo"
    pass "status/log via wrapper têm fallback para o job seletivo quando o protocolo legado não tem o job"

    # 20. Remoção automática de running órfão expirado via wrapper/cleanup:
    # job com status running e expires_at no passado (sem lock ativo — o
    # dono morreu) deve ser removido por `cleanup` de varredura (chamada
    # direta a --hub-cleanup, que é o que o cron roda; o wrapper só expõe
    # exclusão antecipada por job_id, que corretamente NUNCA remove running).
    mkdir -p "${ITEM_STAGING_DIR}/job-orphanrunning-1/control" "${ITEM_STAGING_DIR}/job-orphanrunning-1/data"
    cat > "${ITEM_STAGING_DIR}/job-orphanrunning-1/control/meta.json" <<JSON
{"version":1,"job_id":"job-orphanrunning-1","snapshot":"${SNAPSHOT}","path":"/arquivo.txt","item_type":"file","status":"running","created_at":1,"expires_at":1}
JSON
    run_restore --hub-cleanup
    assert_eq "0" "${RUN_RC}" "varredura de cleanup com running órfão expirado"
    [[ ! -d "${ITEM_STAGING_DIR}/job-orphanrunning-1" ]] \
        || fail "job running órfão e expirado (sem lock ativo) deveria ter sido removido pela varredura"
    pass "varredura de cleanup remove automaticamente job running órfão já expirado"
else
    echo "# aviso: 'flock' ausente neste sistema — pulando cenários 16-20 (integração via wrapper)." >&2
fi

echo "${PASS_COUNT} verificações OK."
