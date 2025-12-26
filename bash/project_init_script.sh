#!/bin/bash
set -e

### ===== 项目环境初始化脚本 =====

### ===== 基本配置 =====
WWW_USER="www"
WWW_HOME="/home/$WWW_USER"

# 部署根目录（保留用于存放公共库或锁文件）
DEPLOY_ROOT="/opt/deploy"
COMMON_DIR="$DEPLOY_ROOT/common"

# Web 根目录
WEB_ROOT="/var/www/aigc.pub"
LOG_ROOT="/var/log/deploy"

# 环境变量存放目录
ENV_DIR="$WEB_ROOT/env"

echo "🚀 Bootstrap deploy environment..."

### ===== 0. 检查用户 =====
id "$WWW_USER" &>/dev/null || {
  echo "❌ User $WWW_USER does not exist"
  exit 1
}

### ===== 1. 目录创建 =====
# 创建基础目录
mkdir -p "$DEPLOY_ROOT" "$COMMON_DIR" "$WEB_ROOT" "$LOG_ROOT" "$ENV_DIR"

# 设置权限
chown -R "$WWW_USER:$WWW_USER" "$DEPLOY_ROOT" "$WEB_ROOT" "$LOG_ROOT" "$ENV_DIR"
chmod 755 "$DEPLOY_ROOT" "$WEB_ROOT"
chmod 750 "$LOG_ROOT"
chmod 700 "$ENV_DIR" # 环境变量包含敏感信息，权限设严一点

### ===== 2. 公共部署库 (可选，如果你的新脚本不再依赖它，可以移除) =====
# 目前看来新的 deploy.sh 是独立的，不依赖这个库，但保留它作为锁机制的存放地也无妨
cat > "$COMMON_DIR/deploy-lib.sh" <<'EOF'
#!/bin/bash
# 这是一个占位文件，目前的部署方案主要依赖项目内的 scripts/deploy.sh
# 但如果未来需要服务器端的全局锁或公共函数，可以在这里添加
EOF

chmod 750 "$COMMON_DIR/deploy-lib.sh"
chown "$WWW_USER:$WWW_USER" "$COMMON_DIR/deploy-lib.sh"

### ===== 3. 提示信息 =====
echo ""
echo "✅ Deploy environment initialized"
echo ""
echo "📌 现在的部署方案 (Push Mode) 不需要服务器主动拉取代码，因此不需要配置 GitHub SSH Key。"
echo ""
echo "📌 请确保 'www' 用户拥有以下 sudo 权限 (visudo):"
echo ""
echo "www ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart aigc-api"
echo "www ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart aigc-workflow"
echo "www ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable aigc-api"
echo "www ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable aigc-workflow"
echo "www ALL=(ALL) NOPASSWD: /usr/bin/cp /var/www/aigc.pub/*/scripts/*.service /etc/systemd/system/*"
echo "www ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload"
echo ""
echo "📌 环境变量文件位置:"
echo "请将 api.aigc.pub 的 .env 内容写入: $ENV_DIR/api.aigc.pub.env"
echo ""

echo "========================================================================"
echo "📌 后续手动操作指南 (首次部署必读)"
echo "========================================================================"
echo ""
echo "1. [api.aigc.pub] & [workflow.aigc.pub] 服务初始化:"
echo "   由于部署脚本可能没有权限直接写入 /etc/systemd/system，首次部署或服务文件变更时，"
echo "   请在服务器上以 root 身份执行以下命令 (假设代码已同步到服务器):"
echo ""
echo "   # 安装 api 服务"
echo "   cp /var/www/aigc.pub/api.aigc.pub/scripts/aigc-api.service /etc/systemd/system/"
echo "   systemctl daemon-reload"
echo "   systemctl enable aigc-api"
echo "   systemctl start aigc-api"
echo ""
echo "   # 安装 workflow 服务"
echo "   cp /var/www/aigc.pub/workflow.aigc.pub/scripts/aigc-workflow.service /etc/systemd/system/"
echo "   systemctl daemon-reload"
echo "   systemctl enable aigc-workflow"
echo "   systemctl start aigc-workflow"
echo ""
echo "2. [www.aigc.pub] PM2 初始化:"
echo "   确保 'www' 用户已安装 PM2:"
echo "   sudo -u www npm install -g pm2"
echo "   sudo -u www pm2 install pm2-logrotate"
echo ""
echo "3. 权限配置 (visudo):"
echo "   为了让部署脚本能自动重启服务，请将以下内容添加到 /etc/sudoers:"
echo ""
echo "   www ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart aigc-api"
echo "   www ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart aigc-workflow"
echo "   www ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable aigc-api"
echo "   www ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable aigc-workflow"
echo "   www ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload"
echo "   www ALL=(ALL) NOPASSWD: /usr/bin/cp /var/www/aigc.pub/*/scripts/*.service /etc/systemd/system/*"
echo ""
echo "========================================================================"
