#!/bin/bash
#################################################################
# Script de configuração de VM - Versão Atualizada             #
# Desenvolvido por: Guilherme Farias      #
# Atualizado em: Outubro de 2025                               #
#################################################################

set -euo pipefail  # Parar em erros, variáveis não definidas e erros em pipes

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Funções auxiliares
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    sleep 1
}

log_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
    sleep 1
}

log_error() {
    echo -e "${RED}[ERRO]${NC} $1"
    sleep 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script precisa ser executado como root!"
        exit 1
    fi
}

# Verificar se é root
check_root

###Início da configuração###
log_info "=== Iniciando configuração da nova máquina virtual ==="
sleep 2

###Atualização inicial do sistema###
log_info "Atualizando lista de pacotes..."
apt update -y || { log_error "Falha ao atualizar pacotes"; exit 1; }

log_info "Atualizando pacotes instalados (isso pode demorar)..."
DEBIAN_FRONTEND=noninteractive apt upgrade -y || { log_error "Falha ao fazer upgrade"; exit 1; }

###Configurações de data e hora###
log_info "Configurando timezone para America/Sao_Paulo..."
timedatectl set-timezone America/Sao_Paulo
timezone=$(timedatectl status | grep "Time zone" | awk '{print $3}')
log_info "Timezone configurado: $timezone"

log_info "Configurando formato de hora 24h..."
localectl set-locale LC_TIME=en_GB.UTF-8
log_info "Formato de hora configurado com sucesso"

###Instalação de pacotes essenciais###
log_info "Instalando pacotes essenciais..."
apt-get install -y \
    traceroute \
    mlocate \
    wget \
    curl \
    neovim \
    net-tools \
    htop \
    tmux \
    git \
    unzip \
    gnupg \
    ca-certificates \
    software-properties-common || {
    log_error "Falha na instalação de pacotes essenciais"
    exit 1
}
log_info "Pacotes essenciais instalados com sucesso"

###Configurações do Neovim###
log_info "Configurando Neovim como editor padrão..."

# Criar diretório de configuração do Neovim
mkdir -p /root/.config/nvim

# Configuração do Neovim com tema escuro minimalista (inspirado em oxocarbon)
cat > /root/.config/nvim/init.vim << 'EOF'
" Configuração básica do Neovim
set number              " Mostrar números das linhas
set relativenumber      " Números relativos
set mouse=a             " Habilitar mouse
set clipboard=unnamedplus " Clipboard do sistema
set expandtab           " Usar espaços ao invés de tabs
set tabstop=4           " Tamanho do tab
set shiftwidth=4        " Tamanho da indentação
set autoindent          " Auto-indentação
set smartindent         " Indentação inteligente
set cursorline          " Destacar linha atual
set termguicolors       " Cores true color
set background=dark     " Fundo escuro
syntax enable           " Syntax highlighting
set encoding=utf-8      " Encoding UTF-8
set scrolloff=8         " Manter linhas visíveis ao rolar
set signcolumn=yes      " Coluna de sinais sempre visível
set updatetime=300      " Tempo de atualização mais rápido
set timeoutlen=500      " Timeout para mapeamentos

" Tema minimalista escuro personalizado (inspirado em oxocarbon)
colorscheme habamax     " Base moderna e limpa
hi Normal guibg=#161616 guifg=#f2f4f8
hi CursorLine guibg=#262626
hi LineNr guifg=#525252 guibg=#161616
hi CursorLineNr guifg=#78a9ff guibg=#262626 gui=bold
hi Comment guifg=#6f6f6f gui=italic
hi Statement guifg=#ee5396 gui=bold
hi Type guifg=#3ddbd9
hi String guifg=#33b1ff
hi Function guifg=#be95ff
hi Constant guifg=#ff7eb6
hi PreProc guifg=#42be65
hi Special guifg=#ff6f00
hi Identifier guifg=#82cfff
hi Visual guibg=#393939
hi Search guibg=#42be65 guifg=#161616
hi IncSearch guibg=#ee5396 guifg=#161616
hi StatusLine guibg=#262626 guifg=#f2f4f8
hi StatusLineNC guibg=#1c1c1c guifg=#6f6f6f
hi VertSplit guibg=#161616 guifg=#393939
hi Pmenu guibg=#262626 guifg=#f2f4f8
hi PmenuSel guibg=#393939 guifg=#78a9ff

" Melhorar visualização
set list                " Mostrar caracteres invisíveis
set listchars=tab:→\ ,trail:·,nbsp:␣

" Pesquisa
set ignorecase          " Ignorar case na busca
set smartcase           " Case sensitive se usar maiúsculas
set incsearch           " Busca incremental
set hlsearch            " Highlight de busca

" Backup e swap
set nobackup
set nowritebackup
set noswapfile

" Atalhos úteis
nnoremap <C-s> :w<CR>   " Ctrl+S para salvar
inoremap <C-s> <Esc>:w<CR>a
EOF

# Definir Neovim como editor padrão
update-alternatives --set editor /usr/bin/nvim 2>/dev/null || \
update-alternatives --install /usr/bin/editor editor /usr/bin/nvim 100

# Criar alias para facilitar
if ! grep -q "alias vim='nvim'" /root/.bashrc; then
    echo "alias vim='nvim'" >> /root/.bashrc
    echo "alias vi='nvim'" >> /root/.bashrc
    echo "export EDITOR='nvim'" >> /root/.bashrc
    echo "export VISUAL='nvim'" >> /root/.bashrc
fi

log_info "Neovim configurado com tema escuro minimalista"

###Melhorias no bash###
log_info "Aplicando melhorias no bash prompt..."
if ! grep -q "PS1 customizado" /root/.bashrc; then
    cat >> /root/.bashrc << 'EOF'

# PS1 customizado
export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# Aliases úteis
alias ll='ls -lah --color=auto'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias df='df -h'
alias free='free -h'
alias ..='cd ..'
alias ...='cd ../..'

# History melhorado
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S "
export HISTCONTROL=ignoredups:erasedups
EOF
    log_info "Melhorias no bash aplicadas"
fi

###Instalação do Zabbix###
log_info "Instalando e configurando Zabbix Agent..."

# Instalar Zabbix Agent 2 (versão mais recente)
apt-get install -y zabbix-agent2 || {
    log_warning "Falha ao instalar zabbix-agent2, tentando zabbix-agent..."
    apt-get install -y zabbix-agent
}

# Configurar Zabbix
ZABBIX_CONF="/etc/zabbix/zabbix_agent2.conf"
if [ ! -f "$ZABBIX_CONF" ]; then
    ZABBIX_CONF="/etc/zabbix/zabbix_agentd.conf"
fi

log_info "Configurando Zabbix Agent..."
sed -i 's/^Server=.*/Server=200.187.67.220/' "$ZABBIX_CONF"
sed -i 's/^ServerActive=.*/ServerActive=200.187.67.220/' "$ZABBIX_CONF"
sed -i "s/^Hostname=.*/Hostname=$(hostname)/" "$ZABBIX_CONF"

# Configurar firewall se existir
if command -v firewall-cmd &> /dev/null; then
    log_info "Configurando firewall para Zabbix..."
    firewall-cmd --add-port=10050/tcp --permanent
    firewall-cmd --reload
    
    if firewall-cmd --list-all | grep -q 10050; then
        log_info "Regra de firewall criada com sucesso"
    else
        log_warning "Regra de firewall pode não ter sido criada corretamente"
    fi
elif command -v ufw &> /dev/null; then
    log_info "Configurando UFW para Zabbix..."
    ufw allow 10050/tcp
    log_info "Regra UFW criada"
else
    log_warning "Nenhum firewall detectado (firewalld/ufw)"
fi

# Reiniciar serviço Zabbix
systemctl restart zabbix-agent2 2>/dev/null || systemctl restart zabbix-agent
systemctl enable zabbix-agent2 2>/dev/null || systemctl enable zabbix-agent
log_info "Zabbix Agent configurado e iniciado"

###Configuração de Autenticação SSH###
log_info "=== Configurando autenticação SSH com chaves ==="

###Backup da configuração SSH atual###
log_info "Fazendo backup da configuração SSH..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)

###PASSO 1: Garantir que root está habilitado temporariamente###
log_info "Habilitando acesso root temporariamente para download da chave..."
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Reiniciar SSH para aplicar
systemctl restart sshd
log_info "SSH configurado para permitir acesso root temporariamente"

###Criação das Chaves SSH###
log_info "Gerando par de chaves SSH ED25519 (mais seguro e rápido)..."
SSH_KEY_NAME="$(hostname)"
SSH_KEY_PATH="/root/.ssh/${SSH_KEY_NAME}"

if [ ! -f "${SSH_KEY_PATH}" ]; then
    mkdir -p /root/.ssh
    ssh-keygen -t ed25519 -a 100 -f "${SSH_KEY_PATH}" -C "SSH Key - $(hostname) - $(date +%Y-%m-%d)" -N ""
    log_info "Chaves SSH criadas: ${SSH_KEY_PATH}"
else
    log_warning "Chave SSH já existe em ${SSH_KEY_PATH}"
fi

###Criação do usuário de autenticação SSH###
log_info "Configurando usuário 'supcip' para acesso via SSH..."
if ! id "supcip" &>/dev/null; then
    useradd -m -s /bin/bash supcip
    log_info "Usuário 'supcip' criado"
else
    log_warning "Usuário 'supcip' já existe"
fi

# Configurar diretório SSH
mkdir -p /home/supcip/.ssh
touch /home/supcip/.ssh/authorized_keys
chmod 700 /home/supcip/.ssh
chmod 600 /home/supcip/.ssh/authorized_keys

# Adicionar chave pública
cat "${SSH_KEY_PATH}.pub" >> /home/supcip/.ssh/authorized_keys
chown -R supcip:supcip /home/supcip/.ssh
log_info "Chave pública adicionada ao authorized_keys"

# Configurar sudo sem senha para supcip
if [ ! -f /etc/sudoers.d/supcip ]; then
    echo "supcip ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/supcip
    chmod 440 /etc/sudoers.d/supcip
    log_info "Permissões sudo configuradas para 'supcip'"
fi

# Aplicar alias e configurações do bash para supcip
cp /root/.bashrc /home/supcip/.bashrc
mkdir -p /home/supcip/.config
cp -r /root/.config/nvim /home/supcip/.config/
chown -R supcip:supcip /home/supcip/.bashrc /home/supcip/.config
log_info "Configurações do bash e nvim copiadas para supcip"

###PASSO 2: Instruções para download da chave privada###
echo
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}DOWNLOAD DA CHAVE SSH${NC}"
echo -e "${CYAN}========================================${NC}"
log_warning "IMPORTANTE: Você DEVE baixar a chave privada AGORA!"
echo
echo -e "${YELLOW}Localização da chave:${NC} ${SSH_KEY_PATH}"
echo
echo -e "${GREEN}Método - SCP:${NC}"
echo -e "No seu computador, execute:"
echo -e "${CYAN}scp root@$(hostname -I | awk '{print $1}'):${SSH_KEY_PATH} ~/Downloads/${SSH_KEY_NAME}.key${NC}"
echo -e "${RED}ATENÇÃO: Após baixar, ajuste as permissões:${NC}"
echo -e "${CYAN}chmod 600 ~/Downloads/${SSH_KEY_NAME}.key${NC}"
echo -e "${CYAN}========================================${NC}"
echo

read -p "Pressione ENTER após baixar a chave privada para continuar..."
log_info "Continuando configuração..."

###PASSO 3: TESTE OBRIGATÓRIO DE CONEXÃO###
echo
echo -e "${RED}========================================${NC}"
echo -e "${RED}TESTE DE CONEXÃO OBRIGATÓRIO${NC}"
echo -e "${RED}========================================${NC}"
log_warning "Antes de bloquear o root, você DEVE testar a conexão SSH!"
echo
echo -e "${YELLOW}Em OUTRO TERMINAL, execute:${NC}"
echo -e "${CYAN}ssh -i ~/Downloads/${SSH_KEY_NAME}.key supcip@$(hostname -I | awk '{print $1}')${NC}"
echo
echo -e "${YELLOW}Após conectar com sucesso:${NC}"
echo -e "1. Teste o comando: ${CYAN}sudo -l${NC}"
echo -e "2. Verifique se consegue executar comandos com sudo"
echo -e "3. ${RED}NÃO FECHE ESTA SESSÃO até confirmar que tudo funciona!${NC}"
echo
echo -e "${RED}========================================${NC}"
echo

# Loop de confirmação obrigatório
CONEXAO_OK="false"
while [ "$CONEXAO_OK" != "Sim" ]; do
    echo -n "Você testou e confirmou que consegue conectar via SSH com o usuário supcip? [Sim/Nao]: "
    read CONEXAO_OK
    
    if [ "$CONEXAO_OK" != "Sim" ]; then
        log_error "Você PRECISA testar a conexão antes de continuar!"
        log_warning "Execute em outro terminal: ssh -i ~/Downloads/${SSH_KEY_NAME}.key supcip@$(hostname -I | awk '{print $1}')"
        echo
    fi
done

log_info "Teste de conexão confirmado! Prosseguindo com hardening..."

###PASSO 4: Aplicar hardening SSH (desabilitar root)###
log_info "Aplicando configurações de segurança SSH..."

cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'EOF'
# Configurações de segurança SSH
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 10
Protocol 2
EOF

log_info "Arquivo de configuração SSH criado"

###Validação da configuração SSH###
log_info "Validando configuração SSH..."
if sshd -t 2>/dev/null; then
    log_info "Configuração SSH válida"
else
    log_error "Configuração SSH inválida! Revertendo backup..."
    rm /etc/ssh/sshd_config.d/99-hardening.conf
    exit 1
fi

###Configurações finais de segurança###
log_info "Aplicando configurações finais de segurança..."

# Desabilitar login com senha vazia
sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config

# Reiniciar SSH para aplicar hardening
log_warning "Reiniciando SSH com configurações de segurança..."
systemctl restart sshd
log_info "SSH configurado com hardening completo"

###Fim da configuração###
echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}CONFIGURAÇÃO CONCLUÍDA!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Hostname: ${CYAN}$(hostname)${NC}"
echo -e "IP: ${CYAN}$(hostname -I | awk '{print $1}')${NC}"
echo -e "Timezone: ${CYAN}$timezone${NC}"
echo -e "Usuário SSH: ${CYAN}supcip${NC}"
echo -e "Editor: ${CYAN}Neovim (nvim) - Tema escuro minimalista${NC}"
echo -e "Zabbix Server: ${CYAN}200.187.67.220${NC}"
echo -e "Chave SSH: ${CYAN}${SSH_KEY_PATH}${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo -e "${YELLOW}Próximos passos:${NC}"
echo -e "1. ${RED}MANTENHA a conexão de teste aberta!${NC}"
echo -e "2. ${CYAN}Reinicie o servidor para aplicar todas as configurações${NC}"
echo -e "3. ${CYAN}Após reboot, conecte usando: ssh -i ${SSH_KEY_NAME}.key supcip@$(hostname -I | awk '{print $1}')${NC}"
echo

###Reiniciar o servidor###
log_warning "É necessário reiniciar o servidor para aplicar todas as configurações"
echo -n "Deseja reiniciar agora? [Sim/Nao]: "
read REBOOT_CONFIRM

if [ "$REBOOT_CONFIRM" = "Sim" ]; then
    log_info "Reiniciando servidor em 10 segundos..."
    log_warning "MANTENHA sua conexão de teste aberta!"
    sleep 10
    reboot
else
    log_warning "Lembre-se de reiniciar o servidor manualmente!"
    log_info "Para reiniciar: sudo reboot"
    echo
    log_info "Comando para conectar após reboot:"
    echo -e "${CYAN}ssh -i ~/Downloads/${SSH_KEY_NAME}.key supcip@$(hostname -I | awk '{print $1}')${NC}"
fi