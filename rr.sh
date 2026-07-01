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
