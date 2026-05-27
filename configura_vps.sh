#!/bin/bash
#################################################################
# Script de configuração de VM - Versão Com SSH Keys          #
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
}

log_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

append_once() {
    local line="$1"
    local file="$2"

    grep -qxF "$line" "$file" || echo "$line" >> "$file"
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

log_info "Gerando locale en_GB.UTF-8..."
apt-get install -y locales || { log_error "Falha ao instalar pacote locales"; exit 1; }
locale-gen en_GB.UTF-8 || { log_error "Falha ao gerar locale en_GB.UTF-8"; exit 1; }

log_info "Configurando formato de hora 24h..."
localectl set-locale LC_TIME=en_GB.UTF-8
log_info "Formato de hora configurado com sucesso"

###Instalação de pacotes essenciais###
log_info "Instalando pacotes essenciais..."
apt-get install -y \
    traceroute \
    plocate \
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
    software-properties-common \
    ncdu \
    iotop \
    nmap \
    bat \
    ripgrep || {
    log_error "Falha na instalação de pacotes essenciais"
    exit 1
}
log_info "Pacotes essenciais instalados com sucesso"

###Instalação do duf (df mais visual)###
log_info "Instalando duf..."
DUF_VERSION="0.8.1"
DUF_ARCH="linux_amd64"
wget -q "https://github.com/muesli/duf/releases/download/v${DUF_VERSION}/duf_${DUF_VERSION}_${DUF_ARCH}.deb" -O /tmp/duf.deb && \
    dpkg -i /tmp/duf.deb && \
    rm -f /tmp/duf.deb && \
    log_info "duf instalado com sucesso" || \
    log_warning "Falha ao instalar duf (não crítico, continuando...)"

###Configurações do Neovim###
log_info "Configurando Neovim como editor padrão..."

# Criar diretório de configuração do Neovim
mkdir -p /root/.config/nvim

# Configuração do Neovim com tema escuro minimalista (inspirado em oxocarbon)
cat > /root/.config/nvim/init.vim << 'EOF'
" Configuração básica do Neovim
set number              " Mostrar números das linhas
set norelativenumber    " Números absolutos facilitam copiar/colar
set mouse=              " Desabilitar mouse para seleção normal via SSH
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
" Caracteres invisíveis ficam disponíveis via :set list quando necessário
set nolist
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

touch /root/.bashrc

# Remover aliases antigos que atrapalham copiar/colar e comandos esperados
sed -i "/^alias cat='batcat --paging=never'$/d" /root/.bashrc
sed -i "/^alias vim='nvim'$/d" /root/.bashrc
sed -i "/^alias vi='nvim'$/d" /root/.bashrc

# Configurar editor padrão sem sobrescrever comandos esperados como vim/vi
append_once "alias nv='nvim'" /root/.bashrc
append_once "export EDITOR='nvim'" /root/.bashrc
append_once "export VISUAL='nvim'" /root/.bashrc

log_info "Neovim configurado com visual colorido e uso amigável via SSH"

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
alias bat='batcat'
alias ccat='batcat --paging=never'
alias rg='rg --smart-case'

# History melhorado
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S "
export HISTCONTROL=ignoredups:erasedups
EOF
    log_info "Melhorias no bash aplicadas"
fi

# Garantir aliases úteis mesmo em servidores onde o script já foi executado antes
append_once "alias bat='batcat'" /root/.bashrc
append_once "alias ccat='batcat --paging=never'" /root/.bashrc
append_once "alias rg='rg --smart-case'" /root/.bashrc

###Copiar configurações para /etc/skel (novos usuários herdam)###
log_info "Copiando configurações para /etc/skel/ (template de novos usuários)..."

# Copiar config do Neovim
mkdir -p /etc/skel/.config/nvim
cp /root/.config/nvim/init.vim /etc/skel/.config/nvim/init.vim

# Copiar .bashrc customizado
cp /root/.bashrc /etc/skel/.bashrc

log_info "Configurações copiadas para /etc/skel/ com sucesso"

###Fim da configuração###
echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}CONFIGURAÇÃO CONCLUÍDA!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Hostname: ${CYAN}$(hostname)${NC}"
echo -e "IP: ${CYAN}$(hostname -I | awk '{print $1}')${NC}"
echo -e "Timezone: ${CYAN}$timezone${NC}"
echo -e "Editor: ${CYAN}Neovim (nvim) - Visual colorido e amigável via SSH${NC}"
echo -e "${GREEN}========================================${NC}"
echo
###SSH KEY GUILHERME FARIAS###
log_info "Instalando chave SSH do Guilherme Farias..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
curl -fs https://sshid.io/guilhermefarias >> /root/.ssh/authorized_keys
sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
log_info "Chave SSH instalada com permissões corretas"
###Reiniciar o servidor###
log_warning "É recomendado reiniciar o servidor para aplicar todas as configurações"
echo -n "Deseja reiniciar agora? [Sim/Nao]: "
read -r REBOOT_CONFIRM || true

if [ "$REBOOT_CONFIRM" = "Sim" ]; then
    log_info "Reiniciando servidor..."
    reboot
else
    log_warning "Lembre-se de reiniciar o servidor manualmente!"
    log_info "Para reiniciar: sudo reboot"
fi
