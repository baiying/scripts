#!/bin/bash
set -e

### ===== 基本配置 =====
WWW_USER="www"
WWW_HOME="/home/$WWW_USER"

DEPLOY_ROOT="/opt/deploy"
COMMON_DIR="$DEPLOY_ROOT/common"
PROJECT_DIR="$DEPLOY_ROOT/projects"

WEB_ROOT="/var/www/aigc.pub"
LOG_ROOT="/var/log/deploy"

SSH_DIR="$WWW_HOME/.ssh"
DEPLOY_KEY="$SSH_DIR/aigc_deploy_key"
SSH_CONFIG="$SSH_DIR/config"
SYSTEMD_DIR="/etc/systemd/system"

MAX_BACKUP=3

### ===== 项目配置 =====
PROJECTS=(
  "api.aigc.pub git@github-gnuapi:baiying/api.aigc.pub.git python"
  "workflow.aigc.pub git@github-gnuapi:baiying/workflow.aigc.pub.git python"
  "www.aigc.pub git@github-gnuapi:baiying/www.aigc.pub.git nextjs"
)

echo "🚀 Bootstrap deploy environment..."

### ===== 0. 检查用户 =====
id "$WWW_USER" &>/dev/null || {
  echo "❌ User $WWW_USER does not exist"
  exit 1
}

### ===== 1. 目录创建 =====
mkdir -p "$DEPLOY_ROOT" "$COMMON_DIR" "$PROJECT_DIR" "$WEB_ROOT" "$LOG_ROOT"

chown -R "$WWW_USER:$WWW_USER" "$DEPLOY_ROOT" "$WEB_ROOT" "$LOG_ROOT"
chmod 755 "$DEPLOY_ROOT" "$WEB_ROOT"
chmod 750 "$LOG_ROOT"

### ===== 2. SSH 目录 & gnuapi key =====
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown -R "$WWW_USER:$WWW_USER" "$SSH_DIR"

if [ ! -f "$DEPLOY_KEY" ]; then
  echo "🔑 Generating gnuapi SSH key..."
  sudo -u "$WWW_USER" ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -C "gnuapi@deploy"
else
  echo "🔑 SSH key already exists"
fi

chmod 600 "$DEPLOY_KEY"
chmod 644 "$DEPLOY_KEY.pub"

### ===== 3. SSH config =====
echo "🛠️ Writing SSH config..."

cat > "$SSH_CONFIG" <<EOF
Host github-gnuapi
  HostName github.com
  User git
  IdentityFile $DEPLOY_KEY
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF

chmod 600 "$SSH_CONFIG"
chown "$WWW_USER:$WWW_USER" "$SSH_CONFIG"

### ===== 4. 公共部署库 =====
cat > "$COMMON_DIR/deploy-lib.sh" <<'EOF'
#!/bin/bash

LOCK_FILE="/opt/deploy/common/deploy.lock"
LOG_DIR="/var/log/deploy"
MAX_BACKUP=3

mkdir -p "$LOG_DIR"

log() {
  echo "[$(date '+%F %T')] $1"
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || {
    log "❌ Another deployment is running"
    exit 1
  }
}

cleanup_old_backup() {
  ls -dt "$APP_DIR".bak.* 2>/dev/null | tail -n +$((MAX_BACKUP+1)) | xargs -r rm -rf
}

rollback() {
  log "⚠️ Rollback triggered"
  LAST=$(ls -dt "$APP_DIR".bak.* 2>/dev/null | head -n 1)
  if [ -d "$LAST" ]; then
    sudo rm -rf "$APP_DIR"
    sudo mv "$LAST" "$APP_DIR"
    log "✅ Rollback completed"
  else
    log "❌ No backup found"
  fi
}
EOF

chmod 750 "$COMMON_DIR/deploy-lib.sh"
chown "$WWW_USER:$WWW_USER" "$COMMON_DIR/deploy-lib.sh"

### ===== systemd services（python）=====
for p in "${PROJECTS[@]}"; do
  read NAME REPO TYPE <<< "$p"
  [ "$TYPE" != "python" ] && continue

  SERVICE_FILE="$SYSTEMD_DIR/$NAME.service"
  [ -f "$SERVICE_FILE" ] && continue

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=$NAME service
After=network.target

[Service]
User=www
WorkingDirectory=$WEB_ROOT/$NAME
Environment=PYENV_ROOT=/usr/local/pyenv
Environment=PATH=/usr/local/pyenv/shims:/home/www/.local/bin:/usr/bin
ExecStart=$WEB_ROOT/$NAME/run.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$NAME"
done

### ===== 5. deploy.sh =====

for p in "${PROJECTS[@]}"; do
  read NAME REPO TYPE <<< "$p"
  APP_DEPLOY_DIR="$PROJECT_DIR/$NAME"

  mkdir -p "$APP_DEPLOY_DIR"
  chown -R "$WWW_USER:$WWW_USER" "$APP_DEPLOY_DIR"

  if [ "$TYPE" = "python" ]; then
    cat > "$APP_DEPLOY_DIR/deploy.sh" <<EOF
#!/bin/bash
set -e
source $COMMON_DIR/deploy-lib.sh

APP="$NAME"
APP_DIR="$WEB_ROOT/$NAME"
TMP_DIR="$WEB_ROOT/.$NAME.tmp"
REPO="$REPO"
LOG_FILE="$LOG_ROOT/$NAME.log"

[ -z "\$APP" ] && {
  echo "❌ APP is empty, abort"
  exit 1
}

exec >> "\$LOG_FILE" 2>&1

acquire_lock
log "🚀 Deploy start: \$APP"
trap rollback ERR

cleanup_tmp() {
  rm -rf "\$TMP_DIR"
}
trap cleanup_tmp EXIT

ssh -T github-gnuapi 2>&1 | grep -q "successfully authenticated" || {
  log "❌ GitHub SSH authentication failed"
  exit 1
}

git clone "\$REPO" "\$TMP_DIR"

cd "\$TMP_DIR"
export PATH="/usr/local/pyenv/shims:/home/www/.local/bin:\$PATH"
uv sync --frozen

[ -d "\$APP_DIR" ] && mv "\$APP_DIR" "\${APP_DIR}.bak.\$(date +%s)"
mv "\$TMP_DIR" "\$APP_DIR"

sudo systemctl restart "\$APP"
sudo systemctl is-active --quiet "\$APP" || {
  log "❌ Service \$APP failed to start"
  exit 1
}

cleanup_old_backup
log "✅ Deploy success: \$APP"
EOF
  else
    cat > "$APP_DEPLOY_DIR/deploy.sh" <<EOF
#!/bin/bash
set -e
source $COMMON_DIR/deploy-lib.sh

APP="$NAME"
LOG_FILE="$LOG_ROOT/$NAME.log"

exec >> "\$LOG_FILE" 2>&1

acquire_lock
log "♻️ Reload Next.js app: \$APP"
export PM2_HOME="/home/www/.pm2"
pm2 reload "\$APP" || {
  log "❌ PM2 reload failed"
  exit 1
}

EOF
  fi

  chmod 750 "$APP_DEPLOY_DIR/deploy.sh"
  chown "$WWW_USER:$WWW_USER" "$APP_DEPLOY_DIR/deploy.sh"
done

echo ""
echo "✅ Deploy environment initialized"
echo ""
echo "📌 Add this SSH public key to GitHub user: gnuapi (Authentication Key)"
echo ""
cat "$DEPLOY_KEY.pub"
echo ""
echo "📌 Replace www account sudoers config with this: "
echo ""
echo "www ALL=(root) NOPASSWD: /usr/bin/pm2, /usr/bin/systemctl reload nginx, /usr/bin/systemctl restart nginx, /usr/bin/systemctl restart redis, /usr/bin/systemctl restart *, /usr/bin/systemctl is-active *"
echo ""
echo ""