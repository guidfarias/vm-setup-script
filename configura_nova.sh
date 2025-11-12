#!/bin/bash
#################################################################
# Script de configuração de VM - Versão Sem SSH Keys          #
# Desenvolvido por: Guilherme Farias                           #
# Atualizado em: Novembro de 2025                              #
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

###Fim da configuração###
echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}CONFIGURAÇÃO CONCLUÍDA!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Hostname: ${CYAN}$(hostname)${NC}"
echo -e "IP: ${CYAN}$(hostname -I | awk '{print $1}')${NC}"
echo -e "Timezone: ${CYAN}$timezone${NC}"
echo -e "Editor: ${CYAN}Neovim (nvim) - Tema escuro minimalista${NC}"
echo -e "Zabbix Server: ${CYAN}200.187.67.220${NC}"
echo -e "${GREEN}========================================${NC}"
echo

###Reiniciar o servidor###
log_warning "É recomendado reiniciar o servidor para aplicar todas as configurações"
echo -n "Deseja reiniciar agora? [Sim/Nao]: "
read REBOOT_CONFIRM

if [ "$REBOOT_CONFIRM" = "Sim" ]; then
    log_info "Reiniciando servidor em 10 segundos..."
    sleep 10
    reboot
else
    log_warning "Lembre-se de reiniciar o servidor manualmente!"
    log_info "Para reiniciar: sudo reboot"
fi
