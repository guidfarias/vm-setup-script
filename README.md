#################################################################
# Script desenvolvido por Guilherme Farias
#################################################################

Script para utilização global para novos servidores e de produção.

## Servidor novo (RunCloud / MySQL) — script único

Configuração inicial da VPS + backup para S3, em um único arquivo, sem
depender de baixar mais nada durante a execução:

```bash
curl -fsSL https://raw.githubusercontent.com/guidfarias/vm-setup-script/master/setup-vps.sh -o setup-vps.sh
sudo bash setup-vps.sh
```

Passo a passo comentado: `USO.md`.

## Scripts de backup (restic + tar.gz → S3)

| Servidor | Instalador | Script de backup |
|---|---|---|
| RunCloud / MySQL (`/home`) | `instalar_backup.sh` | `configura_backup.sh` |
| `/var/www` + PostgreSQL | `instalar_backup_pg.sh` | `configura_backup_pg.sh` |
| Dokploy (Docker Swarm) | `instalar_backup_dokploy.sh` | `configura_backup_dokploy.sh` |

Cada instalador também instala o wrapper `rr` (restic com o env carregado) e o
`restic-restore.sh` (restauração interativa). Documentação completa: `DOCUMENTACAO.md`.

## Recuperação rápida

```bash
sudo restic-restore.sh   # menu interativo: arquivos, sites e bancos
rr snapshots             # listar snapshots direto no restic
```

O assistente restaura por padrão em staging (`/tmp/restauracao-<data>`) e só
sobrescreve produção/importa banco com confirmação digitada e backup preventivo.
Ver seção 6 da `DOCUMENTACAO.md`.

## Instalar o restic-restore.sh em servidores já configurados

Servidores que rodaram o `instalar_backup*.sh` **antes** da existência do
assistente não precisam reinstalar nem reconfigurar nada do backup — basta
instalar o script novo. Use este procedimento **depois** que o
`restaurar_backup.sh` estiver publicado no branch `master` deste repositório:

```bash
tmp="$(mktemp)"
curl -fsSL https://raw.githubusercontent.com/guidfarias/vm-setup-script/master/restaurar_backup.sh -o "$tmp"
bash -n "$tmp"
sudo install -o root -g root -m 0755 "$tmp" /usr/local/bin/restic-restore.sh
rm -f "$tmp"
```

Valide e use:

```bash
sudo restic-restore.sh --help
sudo restic-restore.sh
```

O script reutiliza o `/etc/restic/env` já existente no servidor e **não altera**
o cron nem a configuração atual do backup.
