# Como usar — `setup-vps.sh`

Um único script que configura uma VPS nova (do zero) e já deixa o backup
automático rodando para o Amazon S3. Não precisa baixar mais nada além dele.

## 1. Baixar o script no servidor

```bash
curl -fsSL https://raw.githubusercontent.com/guidfarias/vm-setup-script/master/setup-vps.sh -o setup-vps.sh
```

## 2. Rodar (como root)

```bash
sudo bash setup-vps.sh
```

Isso faz os dois passos, em ordem:

1. **Configuração inicial** — atualiza o sistema, ajusta timezone e locale,
   instala pacotes úteis (neovim, htop, bat, ripgrep...), configura o bash e
   instala a chave SSH padrão.
2. **Backup** — instala o `restic`, o AWS CLI, o script de backup e o
   comando `rr`, agenda o cron (seg-sex às 02:30) e cria o arquivo de
   configuração `/etc/restic/env`.

Na primeira execução, o script **para automaticamente** depois de criar o
`/etc/restic/env`, porque ele ainda não tem credenciais reais.

## 3. Preencher as credenciais

```bash
sudo nano /etc/restic/env
```

Preencha os campos marcados com `SUA_...` / `SENHA_...`: as chaves da AWS, o
nome do bucket S3, uma senha forte para o restic e a senha do MySQL/MariaDB.

> ⚠️ Use **aspas simples** `' '` nas senhas (não aspas duplas) — evita que um
> `$` na senha seja interpretado como variável. O template já vem assim.

## 4. Rodar de novo para concluir

```bash
sudo bash setup-vps.sh backup
```

Agora, com as credenciais preenchidas, o script aplica a regra de expiração
no S3 e pergunta se quer rodar o primeiro backup.

## Pronto — o que ficou rodando

| Item | Onde |
|---|---|
| Backup automático | cron, seg-sex às 02:30 |
| Log do backup | `/var/log/restic-backup.log` |
| Configuração | `/etc/restic/env` |
| Comando rápido do restic | `rr snapshots`, `rr stats`, `rr check` |

## Comandos do dia a dia

```bash
rr snapshots                                    # lista os backups salvos
/usr/local/bin/restic-backup.sh --dry-run       # simula, não envia nada
/usr/local/bin/restic-backup.sh --test-restore  # testa se o backup é restaurável
```

## Só uma parte do script

```bash
sudo bash setup-vps.sh setup     # só a configuração inicial (sem backup)
sudo bash setup-vps.sh backup    # só o backup (servidor já configurado)
```

## Se algo der errado

- **Erro de sintaxe ao baixar:** rode `bash -n setup-vps.sh` antes de
  executar — se voltar sem erro, o arquivo baixou corretamente.
- **Backup falhou:** veja `/var/log/restic-backup.log` e `/var/log/restic-cron.log`.
- **Precisa restaurar algo:** use o assistente interativo `restic-restore.sh`
  (instalação e detalhes na Seção 6 de `DOCUMENTACAO.md`).

Para detalhes técnicos completos (variáveis, arquitetura, restauração passo a
passo, instalação manual), veja `DOCUMENTACAO.md`. Este arquivo é só o
essencial para colocar um servidor novo no ar.
