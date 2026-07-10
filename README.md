#################################################################
# Script desenvolvido por Guilherme Farias
#################################################################

Script para utilização global para novos servidores e de produção.

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
