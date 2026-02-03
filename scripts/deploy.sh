#!/bin/bash
set -e

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                    OpenClaw (Moltbot) 一键部署脚本                          ║
# ║                    在 Cloudflare Workers 上运行 AI 助手                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# 使用方法:
#   curl -fsSL https://raw.githubusercontent.com/cloudflare/moltworker/main/scripts/deploy.sh | bash
#
# 或者本地运行:
#   chmod +x scripts/deploy.sh && ./scripts/deploy.sh
#
# 前置要求:
#   - GitHub 账号
#   - Cloudflare 账号 (Workers Paid 计划, $5/月)
#   - Anthropic API Key 或 AI Gateway 配置

# =============================================================================
# 颜色和打印函数
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC}  $1"; }
success() { echo -e "${GREEN}✓${NC}  $1"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $1"; }
error()   { echo -e "${RED}✗${NC}  $1"; exit 1; }
prompt()  { echo -e "${GREEN}?${NC}  $1"; }
step()    { echo -e "\n${CYAN}${BOLD}[$1/$TOTAL_STEPS]${NC} ${BOLD}$2${NC}\n"; }

# =============================================================================
# 全局变量
# =============================================================================

UPSTREAM_REPO="cloudflare/moltworker"
WORK_DIR="/tmp/moltworker-deploy-$$"
TOTAL_STEPS=8
GITHUB_USER=""
USER_REPO=""
WORKER_NAME="moltbot-sandbox"
WORKER_URL=""
GATEWAY_TOKEN=""

# 配置存储
CF_ACCOUNT_ID=""
CF_API_TOKEN=""
ANTHROPIC_API_KEY=""
AI_GATEWAY_BASE_URL=""
AI_GATEWAY_API_KEY=""
CF_ACCESS_TEAM_DOMAIN=""
CF_ACCESS_AUD=""

# 可选配置
TELEGRAM_BOT_TOKEN=""
DISCORD_BOT_TOKEN=""
R2_ACCESS_KEY_ID=""
R2_SECRET_ACCESS_KEY=""

# =============================================================================
# 欢迎界面
# =============================================================================

show_banner() {
    clear
    echo ""
    echo -e "${CYAN}"
    cat << 'EOF'
   ___                    ____ _
  / _ \ _ __   ___ _ __  / ___| | __ ___      __
 | | | | '_ \ / _ \ '_ \| |   | |/ _` \ \ /\ / /
 | |_| | |_) |  __/ | | | |___| | (_| |\ V  V /
  \___/| .__/ \___|_| |_|\____|_|\__,_| \_/\_/
       |_|
EOF
    echo -e "${NC}"
    echo -e "${BOLD}  在 Cloudflare Workers 上运行你的个人 AI 助手${NC}"
    echo ""
    echo "  GitHub: https://github.com/cloudflare/moltworker"
    echo ""
    echo -e "  ${YELLOW}前置要求:${NC}"
    echo "    • GitHub 账号"
    echo "    • Cloudflare 账号 (Workers Paid 计划, \$5/月)"
    echo "    • Anthropic API Key 或 AI Gateway"
    echo ""
    echo "─────────────────────────────────────────────────────────────"
    echo ""
    prompt "准备好了吗？按 Enter 开始，Ctrl+C 退出"
    read -r
}

# =============================================================================
# 第1步: 环境检查
# =============================================================================

check_os() {
    case "$(uname -s)" in
        Darwin*) OS="macos" ;;
        Linux*)  OS="linux" ;;
        *)       error "不支持的操作系统，仅支持 macOS 和 Linux" ;;
    esac
}

install_gh_cli() {
    if [[ "$OS" == "macos" ]]; then
        if command -v brew &> /dev/null; then
            brew install gh
        else
            error "请先安装 Homebrew: https://brew.sh/"
        fi
    else
        # Linux
        (type -p wget >/dev/null || (sudo apt update && sudo apt-get install wget -y)) \
        && sudo mkdir -p -m 755 /etc/apt/keyrings \
        && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
        && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
        && sudo apt update \
        && sudo apt install gh -y
    fi
}

check_requirements() {
    step 1 "环境检查"

    check_os
    success "操作系统: $OS"

    # 检查 gh CLI
    if ! command -v gh &> /dev/null; then
        warn "未安装 GitHub CLI (gh)"
        prompt "是否自动安装？(y/n): "
        read -r install_gh
        if [[ "$install_gh" == "y" || "$install_gh" == "Y" ]]; then
            info "安装 GitHub CLI..."
            install_gh_cli
        else
            echo ""
            echo "  请手动安装 GitHub CLI:"
            echo "    macOS:  brew install gh"
            echo "    Linux:  https://cli.github.com/packages"
            echo ""
            error "需要 GitHub CLI 才能继续"
        fi
    fi
    success "GitHub CLI 已安装"

    # 检查 gh 登录状态
    if ! gh auth status &> /dev/null 2>&1; then
        warn "GitHub CLI 未登录"
        info "正在打开浏览器进行 GitHub 登录..."
        gh auth login --web --git-protocol https
    fi
    GITHUB_USER=$(gh api user --jq '.login')
    USER_REPO="$GITHUB_USER/moltworker"
    success "GitHub 已登录: $GITHUB_USER"

    # 检查 Node.js
    if ! command -v node &> /dev/null; then
        echo ""
        echo "  请先安装 Node.js:"
        echo "    https://nodejs.org/"
        echo "    或使用 nvm: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash"
        echo ""
        error "需要 Node.js 才能继续"
    fi
    success "Node.js 已安装: $(node --version)"

    # 检查/安装 wrangler (本地不需要，但用于设置 secrets)
    if ! command -v wrangler &> /dev/null; then
        info "安装 Wrangler CLI..."
        npm install -g wrangler
    fi
    success "Wrangler CLI 已安装"
}

# =============================================================================
# 第2步: Fork & Clone 仓库
# =============================================================================

setup_repo() {
    step 2 "设置 GitHub 仓库"

    # 检查是否已经 fork 过
    if gh repo view "$USER_REPO" &> /dev/null 2>&1; then
        success "仓库已存在: $USER_REPO"
        prompt "是否使用现有仓库？(y=使用现有 / n=删除重建): "
        read -r use_existing
        if [[ "$use_existing" != "y" && "$use_existing" != "Y" ]]; then
            warn "删除现有仓库..."
            gh repo delete "$USER_REPO" --yes
            sleep 2
            info "重新 Fork 仓库..."
            gh repo fork "$UPSTREAM_REPO" --clone=false
        fi
    else
        info "Fork 仓库到你的账号..."
        gh repo fork "$UPSTREAM_REPO" --clone=false
    fi

    # 同步上游
    info "同步上游最新代码..."
    gh repo sync "$USER_REPO" --source "$UPSTREAM_REPO" 2>/dev/null || true
    success "仓库准备完成: https://github.com/$USER_REPO"

    # Clone 到本地
    info "Clone 仓库到本地临时目录..."
    rm -rf "$WORK_DIR"
    gh repo clone "$USER_REPO" "$WORK_DIR" -- --depth=1
    cd "$WORK_DIR"
    success "已 Clone 到: $WORK_DIR"
}

# =============================================================================
# 第3步: 确保 GitHub Actions workflow 存在
# =============================================================================

ensure_workflows() {
    step 3 "配置 GitHub Actions"

    WORKFLOW_FILE=".github/workflows/deploy.yml"

    if [[ -f "$WORKFLOW_FILE" ]]; then
        success "部署 workflow 已存在"
    else
        info "创建部署 workflow..."
        mkdir -p .github/workflows

        cat > "$WORKFLOW_FILE" << 'WORKFLOW_EOF'
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: Type check
        run: npm run typecheck

      - name: Run tests
        run: npm test

      - name: Deploy to Cloudflare Workers
        run: npx wrangler deploy
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
WORKFLOW_EOF

        git add "$WORKFLOW_FILE"
        git commit -m "ci: add deploy workflow" || true
        git push origin main
        success "部署 workflow 已创建"
    fi

    # 检查同步 workflow
    SYNC_WORKFLOW=".github/workflows/sync-upstream.yml"
    if [[ ! -f "$SYNC_WORKFLOW" ]]; then
        info "创建上游同步 workflow..."

        cat > "$SYNC_WORKFLOW" << 'SYNC_EOF'
name: Sync Upstream

on:
  schedule:
    - cron: "0 8 * * *"
  workflow_dispatch:

jobs:
  sync:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Add upstream remote
        run: git remote add upstream https://github.com/cloudflare/moltworker.git || true

      - name: Fetch upstream
        run: git fetch upstream main

      - name: Check for new commits
        id: check
        run: |
          BEHIND=$(git rev-list --count HEAD..upstream/main)
          echo "behind=$BEHIND" >> "$GITHUB_OUTPUT"

      - name: Merge upstream
        if: steps.check.outputs.behind != '0'
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git merge upstream/main --no-edit

      - name: Push changes
        if: steps.check.outputs.behind != '0'
        run: git push origin main
SYNC_EOF

        git add "$SYNC_WORKFLOW"
        git commit -m "ci: add upstream sync workflow" || true
        git push origin main
        success "上游同步 workflow 已创建 (每日 UTC 08:00 自动同步)"
    else
        success "上游同步 workflow 已存在"
    fi
}

# =============================================================================
# 第4步: 收集 Cloudflare 配置
# =============================================================================

collect_cloudflare_config() {
    step 4 "配置 Cloudflare"

    echo "  我们需要你的 Cloudflare 账号信息。"
    echo ""

    # Account ID
    echo -e "  ${BOLD}1. Cloudflare Account ID${NC}"
    echo "     打开: https://dash.cloudflare.com/"
    echo "     点击右侧栏中任意域名 → 右下角 'Account ID'"
    echo "     或在 URL 中查看: dash.cloudflare.com/xxxxxxxx"
    echo ""
    prompt "请输入 Account ID: "
    read -r CF_ACCOUNT_ID

    if [[ -z "$CF_ACCOUNT_ID" ]]; then
        error "Account ID 不能为空"
    fi
    success "Account ID 已记录"

    # API Token
    echo ""
    echo -e "  ${BOLD}2. Cloudflare API Token${NC}"
    echo "     打开: https://dash.cloudflare.com/profile/api-tokens"
    echo "     点击 'Create Token'"
    echo "     使用 'Edit Cloudflare Workers' 模板"
    echo "     添加以下额外权限:"
    echo "       • Account → Cloudflare Container Registry → Edit"
    echo "       • Account → Workers R2 Storage → Edit (可选，用于持久化)"
    echo ""
    prompt "请输入 API Token: "
    read -r CF_API_TOKEN

    if [[ -z "$CF_API_TOKEN" ]]; then
        error "API Token 不能为空"
    fi
    success "API Token 已记录"
}

# =============================================================================
# 第5步: 收集 AI 配置
# =============================================================================

collect_ai_config() {
    step 5 "配置 AI 服务"

    echo "  选择 AI 服务提供方式:"
    echo ""
    echo "    [1] Anthropic API Key (直接连接 Anthropic)"
    echo "    [2] AI Gateway (通过自定义网关代理)"
    echo ""
    prompt "请选择 (1/2): "
    read -r ai_choice

    if [[ "$ai_choice" == "2" ]]; then
        echo ""
        prompt "请输入 AI Gateway Base URL (例如 https://your-gateway.com/): "
        read -r AI_GATEWAY_BASE_URL

        prompt "请输入 AI Gateway API Key: "
        read -r AI_GATEWAY_API_KEY

        if [[ -z "$AI_GATEWAY_BASE_URL" || -z "$AI_GATEWAY_API_KEY" ]]; then
            error "AI Gateway 配置不完整"
        fi
        success "AI Gateway 已配置"
    else
        echo ""
        echo "  获取 Anthropic API Key: https://console.anthropic.com/"
        echo ""
        prompt "请输入 Anthropic API Key: "
        read -r ANTHROPIC_API_KEY

        if [[ -z "$ANTHROPIC_API_KEY" ]]; then
            error "API Key 不能为空"
        fi
        success "Anthropic API Key 已记录"
    fi

    # 生成 Gateway Token
    echo ""
    info "生成 Gateway Token..."
    GATEWAY_TOKEN=$(openssl rand -hex 32)
    success "Gateway Token 已生成 (部署完成后会显示)"
}

# =============================================================================
# 第6步: 设置 GitHub Secrets 并触发部署
# =============================================================================

setup_github_secrets() {
    step 6 "设置 GitHub Secrets 并部署"

    info "设置 CLOUDFLARE_ACCOUNT_ID..."
    echo "$CF_ACCOUNT_ID" | gh secret set CLOUDFLARE_ACCOUNT_ID --repo "$USER_REPO"
    success "CLOUDFLARE_ACCOUNT_ID 已设置"

    info "设置 CLOUDFLARE_API_TOKEN..."
    echo "$CF_API_TOKEN" | gh secret set CLOUDFLARE_API_TOKEN --repo "$USER_REPO"
    success "CLOUDFLARE_API_TOKEN 已设置"

    # 触发部署
    info "触发 GitHub Actions 部署..."
    gh workflow run deploy.yml --repo "$USER_REPO" 2>/dev/null || {
        # 如果 workflow dispatch 失败，尝试推送空提交触发
        git commit --allow-empty -m "chore: trigger deploy"
        git push origin main
    }

    echo ""
    info "等待部署完成 (可能需要 3-5 分钟)..."
    echo ""

    # 等待 workflow 开始
    sleep 10

    # 获取最新的 workflow run
    RUN_ID=$(gh run list --repo "$USER_REPO" --workflow=deploy.yml --limit=1 --json databaseId --jq '.[0].databaseId')

    if [[ -n "$RUN_ID" ]]; then
        # 显示进度
        gh run watch "$RUN_ID" --repo "$USER_REPO" --exit-status || {
            error "部署失败！请检查 GitHub Actions 日志: https://github.com/$USER_REPO/actions"
        }
        success "GitHub Actions 部署完成"
    else
        warn "无法获取部署状态，请手动检查: https://github.com/$USER_REPO/actions"
    fi
}

# =============================================================================
# 第7步: 设置 Worker Secrets
# =============================================================================

setup_worker_secrets() {
    step 7 "配置 Worker Secrets"

    # 登录 wrangler
    if ! wrangler whoami &> /dev/null 2>&1; then
        info "登录 Wrangler..."
        wrangler login
    fi
    success "Wrangler 已登录"

    # 设置必需的 secrets
    info "设置 MOLTBOT_GATEWAY_TOKEN..."
    echo "$GATEWAY_TOKEN" | wrangler secret put MOLTBOT_GATEWAY_TOKEN --name "$WORKER_NAME"

    if [[ -n "$AI_GATEWAY_API_KEY" ]]; then
        info "设置 AI_GATEWAY_API_KEY..."
        echo "$AI_GATEWAY_API_KEY" | wrangler secret put AI_GATEWAY_API_KEY --name "$WORKER_NAME"

        info "设置 AI_GATEWAY_BASE_URL..."
        echo "$AI_GATEWAY_BASE_URL" | wrangler secret put AI_GATEWAY_BASE_URL --name "$WORKER_NAME"
    else
        info "设置 ANTHROPIC_API_KEY..."
        echo "$ANTHROPIC_API_KEY" | wrangler secret put ANTHROPIC_API_KEY --name "$WORKER_NAME"
    fi

    success "Worker Secrets 已配置"

    # Worker URL
    WORKER_URL="https://${WORKER_NAME}.${GITHUB_USER}.workers.dev"
}

# =============================================================================
# 第8步: 选择启动模式和可选配置
# =============================================================================

configure_mode_and_options() {
    step 8 "启动模式和可选配置"

    echo "  选择启动模式:"
    echo ""
    echo "    [A] 快速体验 (推荐新手)"
    echo "        跳过 Cloudflare Access 配置，直接可用"
    echo "        安全性较低，适合个人测试"
    echo ""
    echo "    [B] 完整安全配置"
    echo "        配置 Cloudflare Access 保护管理界面"
    echo "        需要额外的手动步骤"
    echo ""
    prompt "请选择 (A/B): "
    read -r mode_choice

    if [[ "$mode_choice" == "B" || "$mode_choice" == "b" ]]; then
        configure_cloudflare_access
    else
        info "设置 DEV_MODE=true (快速体验模式)..."
        echo "true" | wrangler secret put DEV_MODE --name "$WORKER_NAME"
        success "快速体验模式已启用"
        warn "注意: 此模式跳过了认证，仅建议用于个人测试"
    fi

    # 可选配置
    echo ""
    echo "─────────────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${BOLD}可选配置${NC} (可以跳过，之后再配置)"
    echo ""

    # Telegram
    prompt "是否配置 Telegram Bot？(y/n): "
    read -r config_telegram
    if [[ "$config_telegram" == "y" || "$config_telegram" == "Y" ]]; then
        configure_telegram
    fi

    # Discord
    prompt "是否配置 Discord Bot？(y/n): "
    read -r config_discord
    if [[ "$config_discord" == "y" || "$config_discord" == "Y" ]]; then
        configure_discord
    fi

    # R2 Storage
    prompt "是否配置 R2 持久化存储？(推荐，防止数据丢失) (y/n): "
    read -r config_r2
    if [[ "$config_r2" == "y" || "$config_r2" == "Y" ]]; then
        configure_r2
    fi
}

configure_cloudflare_access() {
    echo ""
    echo -e "  ${BOLD}配置 Cloudflare Access${NC}"
    echo ""
    echo "  请按以下步骤操作:"
    echo ""
    echo "  1. 打开 Workers 设置页面:"
    echo "     https://dash.cloudflare.com/${CF_ACCOUNT_ID}/workers-and-pages"
    echo ""
    echo "  2. 点击 '$WORKER_NAME' → Settings → Domains & Routes"
    echo ""
    echo "  3. 在 workers.dev 行，点击 '...' → Enable Cloudflare Access"
    echo ""
    echo "  4. 配置允许访问的邮箱"
    echo ""
    echo "  5. 复制 'Application Audience (AUD)' 值"
    echo ""

    prompt "请输入 CF_ACCESS_AUD (Application Audience): "
    read -r CF_ACCESS_AUD

    echo ""
    echo "  6. 打开 Zero Trust 设置查看 Team Domain:"
    echo "     https://one.dash.cloudflare.com/"
    echo "     Settings → Custom Pages → Team domain"
    echo "     (格式: xxxxx.cloudflareaccess.com)"
    echo ""

    prompt "请输入 Team Domain (不含 .cloudflareaccess.com): "
    read -r team_name
    CF_ACCESS_TEAM_DOMAIN="${team_name}.cloudflareaccess.com"

    if [[ -n "$CF_ACCESS_AUD" && -n "$CF_ACCESS_TEAM_DOMAIN" ]]; then
        info "设置 CF_ACCESS_AUD..."
        echo "$CF_ACCESS_AUD" | wrangler secret put CF_ACCESS_AUD --name "$WORKER_NAME"

        info "设置 CF_ACCESS_TEAM_DOMAIN..."
        echo "$CF_ACCESS_TEAM_DOMAIN" | wrangler secret put CF_ACCESS_TEAM_DOMAIN --name "$WORKER_NAME"

        info "禁用 DEV_MODE..."
        echo "false" | wrangler secret put DEV_MODE --name "$WORKER_NAME"

        success "Cloudflare Access 已配置"
    else
        warn "Cloudflare Access 配置不完整，使用快速体验模式"
        echo "true" | wrangler secret put DEV_MODE --name "$WORKER_NAME"
    fi
}

configure_telegram() {
    echo ""
    echo -e "  ${BOLD}配置 Telegram Bot${NC}"
    echo ""
    echo "  1. 在 Telegram 中找 @BotFather"
    echo "  2. 发送 /newbot 创建机器人"
    echo "  3. 复制 Bot Token"
    echo ""

    prompt "请输入 Telegram Bot Token: "
    read -r TELEGRAM_BOT_TOKEN

    if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
        echo "$TELEGRAM_BOT_TOKEN" | wrangler secret put TELEGRAM_BOT_TOKEN --name "$WORKER_NAME"

        # 设置 DM 策略为 open (方便使用)
        echo "open" | wrangler secret put TELEGRAM_DM_POLICY --name "$WORKER_NAME"

        success "Telegram Bot 已配置"
    fi
}

configure_discord() {
    echo ""
    echo -e "  ${BOLD}配置 Discord Bot${NC}"
    echo ""
    echo "  1. 打开 https://discord.com/developers/applications"
    echo "  2. 创建新应用 → Bot → Copy Token"
    echo ""

    prompt "请输入 Discord Bot Token: "
    read -r DISCORD_BOT_TOKEN

    if [[ -n "$DISCORD_BOT_TOKEN" ]]; then
        echo "$DISCORD_BOT_TOKEN" | wrangler secret put DISCORD_BOT_TOKEN --name "$WORKER_NAME"
        echo "open" | wrangler secret put DISCORD_DM_POLICY --name "$WORKER_NAME"
        success "Discord Bot 已配置"
    fi
}

configure_r2() {
    echo ""
    echo -e "  ${BOLD}配置 R2 持久化存储${NC}"
    echo ""
    echo "  1. 打开 R2 API Tokens 页面:"
    echo "     https://dash.cloudflare.com/${CF_ACCOUNT_ID}/r2/api-tokens"
    echo ""
    echo "  2. 创建 API Token (Object Read & Write, All buckets)"
    echo ""

    prompt "请输入 R2 Access Key ID: "
    read -r R2_ACCESS_KEY_ID

    prompt "请输入 R2 Secret Access Key: "
    read -r R2_SECRET_ACCESS_KEY

    if [[ -n "$R2_ACCESS_KEY_ID" && -n "$R2_SECRET_ACCESS_KEY" ]]; then
        echo "$R2_ACCESS_KEY_ID" | wrangler secret put R2_ACCESS_KEY_ID --name "$WORKER_NAME"
        echo "$R2_SECRET_ACCESS_KEY" | wrangler secret put R2_SECRET_ACCESS_KEY --name "$WORKER_NAME"
        echo "$CF_ACCOUNT_ID" | wrangler secret put CF_ACCOUNT_ID --name "$WORKER_NAME"
        success "R2 存储已配置"
    fi
}

# =============================================================================
# 完成
# =============================================================================

show_completion() {
    # 触发重新部署以应用所有配置
    info "触发重新部署以应用配置..."
    gh workflow run deploy.yml --repo "$USER_REPO" 2>/dev/null || true

    echo ""
    echo ""
    echo -e "${GREEN}"
    cat << 'EOF'
  ╔═══════════════════════════════════════════════════════════════╗
  ║                                                               ║
  ║                    🎉 部署完成！                               ║
  ║                                                               ║
  ╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"

    WORKER_URL="https://${WORKER_NAME}.${GITHUB_USER}.workers.dev"

    echo ""
    echo -e "  ${BOLD}Worker URL:${NC}"
    echo -e "    ${CYAN}${WORKER_URL}${NC}"
    echo ""
    echo -e "  ${BOLD}Gateway Token (请妥善保存):${NC}"
    echo -e "    ${YELLOW}${GATEWAY_TOKEN}${NC}"
    echo ""
    echo -e "  ${BOLD}访问控制面板:${NC}"
    echo -e "    ${CYAN}${WORKER_URL}/?token=${GATEWAY_TOKEN}${NC}"
    echo ""
    echo -e "  ${BOLD}管理后台:${NC}"
    echo -e "    ${CYAN}${WORKER_URL}/_admin/?token=${GATEWAY_TOKEN}${NC}"
    echo ""
    echo "─────────────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${BOLD}下一步:${NC}"
    echo "    1. 首次访问可能需要 1-2 分钟等待容器启动"
    echo "    2. 在控制面板中开始与 AI 对话"
    echo "    3. 如配置了 Telegram，直接给 Bot 发消息即可"
    echo ""
    echo -e "  ${BOLD}GitHub 仓库:${NC}"
    echo -e "    https://github.com/${USER_REPO}"
    echo ""
    echo -e "  ${BOLD}遇到问题?${NC}"
    echo "    查看文档: https://github.com/cloudflare/moltworker#readme"
    echo ""

    # 清理临时目录
    cd ~
    rm -rf "$WORK_DIR"
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    show_banner
    check_requirements
    setup_repo
    ensure_workflows
    collect_cloudflare_config
    collect_ai_config
    setup_github_secrets
    setup_worker_secrets
    configure_mode_and_options
    show_completion
}

# 运行
main "$@"
