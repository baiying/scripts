#!/bin/bash
# 测试开发环境一键安装脚本

set -e
set -o pipefail

########################################
# 配置
########################################

REDIS_PASSWORD="By^108508@2025"
POSTGRES_PASSWORD="By^108508@2025"

NODE_VERSION="22.11.0"
PY_VERSION="3.12.7"

WWW_USER="www"
WWW_GROUP="www"
WEB_ROOT="/var/www"
LOG_ROOT="/var/log/www"


########################################
# 函数：安全执行（忽略非 0）
########################################
safe_run() {
  set +e
  "$@"
  set -e
}


########################################
# 1. 必须以 root 运行
########################################
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请以 root 运行此脚本"
  exit 1
fi


########################################
# 2. 创建 www 用户
########################################
echo "👤 创建 www 用户..."

if ! id -u "$WWW_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$WWW_USER"
  echo "  - www 用户创建完成"
else
  echo "  - www 用户已存在"
fi


########################################
# 3. 创建目录结构
########################################
echo "📂 创建目录结构..."

mkdir -p $WEB_ROOT
mkdir -p $LOG_ROOT

chown -R $WWW_USER:$WWW_GROUP $WEB_ROOT
chown -R $WWW_USER:$WWW_GROUP $LOG_ROOT

chmod -R 755 $WEB_ROOT
chmod -R 775 $LOG_ROOT


########################################
# 4. 更新系统 + 安装依赖
########################################
echo "📦 安装系统依赖..."

dnf install -y epel-release
dnf install -y wget curl git unzip gcc make openssl-devel \
  bzip2-devel libffi-devel sqlite-devel acl sudo tar xz


########################################
# 5. 安装 Node.js + pnpm + pm2
########################################
echo "📦 安装 Node.js v${NODE_VERSION}..."

wget -q https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz -O /tmp/node.tar.xz
tar -xf /tmp/node.tar.xz -C /usr/local
ln -sf /usr/local/node-v${NODE_VERSION}-linux-x64/bin/node /usr/bin/node
ln -sf /usr/local/node-v${NODE_VERSION}-linux-x64/bin/npm /usr/bin/npm

npm install -g pnpm pm2 || true

ln -sf /usr/local/node-v${NODE_VERSION}-linux-x64/bin/pnpm /usr/bin/pnpm || true
ln -sf /usr/local/node-v${NODE_VERSION}-linux-x64/bin/pm2 /usr/bin/pm2 || true

echo "Node 安装完成"


########################################
# 6. PM2 开机自启（fork 模式）
########################################
echo "⚙️ 配置 PM2..."

safe_run su - $WWW_USER -c "pm2 startup systemd -u $WWW_USER --hp /home/$WWW_USER >/tmp/pm2_start_cmd.txt 2>&1"

PM2_CMD=$(safe_run cat /tmp/pm2_start_cmd.txt | grep sudo | sed 's/sudo //')
safe_run eval "$PM2_CMD"

safe_run systemctl enable pm2-$WWW_USER

echo "PM2 配置完成"


########################################
# 7. 安装 pyenv（全局）
########################################
echo "🐍 安装 pyenv..."

safe_run git clone https://github.com/pyenv/pyenv.git /usr/local/pyenv
safe_run git clone https://github.com/pyenv/pyenv-virtualenv.git /usr/local/pyenv/plugins/pyenv-virtualenv

cat >/etc/profile.d/pyenv.sh <<EOF
export PYENV_ROOT="/usr/local/pyenv"
export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init -)"
EOF

source /etc/profile.d/pyenv.sh


########################################
# 8. 安装 Python 3.12.7 via pyenv
########################################
echo "🐍 安装 Python ${PY_VERSION}..."

safe_run pyenv install $PY_VERSION
safe_run pyenv global $PY_VERSION

ln -sf /usr/local/pyenv/shims/python3 /usr/bin/python3 || true
ln -sf /usr/local/pyenv/shims/pip3 /usr/bin/pip3 || true
ln -sf /usr/local/pyenv/shims/python /usr/bin/python || true
ln -sf /usr/local/pyenv/shims/pip /usr/bin/pip || true

pip install --upgrade pip || true
pip install uvicorn fastapi || true

echo "Python ${PY_VERSION} 安装完成"


########################################
# 9. 安装 Redis（系统包）
########################################
echo "🟥 安装 Redis 7.4..."

# 安装 Remi 仓库
dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm

# 启用 remi-redis72 源
dnf module reset -y redis
dnf module install -y redis:remi-7.2

# 安装 Redis 7.2
dnf install -y redis

# 写入 redis.conf
cat > /etc/redis/redis.conf <<EOF
bind 0.0.0.0
protected-mode yes
port 6379
requirepass ${REDIS_PASSWORD}

maxmemory 256mb
maxmemory-policy allkeys-lru
supervised systemd
EOF

systemctl enable redis --now
echo "Redis 版本：$(redis-server --version)"


########################################
# 10. 安装 PostgreSQL 17
########################################
echo "🟦 安装 PostgreSQL 17..."

safe_run dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %rhel)-x86_64/pgdg-redhat-repo-latest.noarch.rpm

safe_run dnf -qy module disable postgresql
safe_run dnf install -y postgresql17 postgresql17-server

safe_run /usr/pgsql-17/bin/postgresql-17-setup initdb

PG_CONF="/var/lib/pgsql/17/data/postgresql.conf"
PG_HBA="/var/lib/pgsql/17/data/pg_hba.conf"

sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" $PG_CONF
sed -i "s/#max_connections = 100/max_connections = 150/" $PG_CONF

echo "host all all 0.0.0.0/0 md5" >> $PG_HBA

safe_run systemctl enable postgresql-17 --now

safe_run su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '${POSTGRES_PASSWORD}';\""

echo "PostgreSQL 安装完成"


########################################
# 11. 安装 Nginx（系统包）
########################################
echo "🌐 安装 Nginx..."

dnf install -y nginx

safe_run systemctl enable nginx --now

echo "Nginx 安装完成"


########################################
# 12. GitHub Actions 权限
########################################
echo "🔐 配置 GitHub Actions 权限..."

safe_run setfacl -R -m u:root:rwx $WEB_ROOT
safe_run setfacl -R -m u:$WWW_USER:rwx $WEB_ROOT

echo "$WWW_USER ALL=(ALL) NOPASSWD: /usr/bin/pm2, /usr/bin/systemctl reload nginx" >> /etc/sudoers

echo "GitHub Actions 权限设置完成"


########################################
# DONE
########################################
echo ""
echo "🎉 开发环境安装完成！"
echo "Redis 密码：${REDIS_PASSWORD}"
echo "PostgreSQL 密码：${POSTGRES_PASSWORD}"
echo ""
echo "Python: $(python3 --version)"
echo "Node.js: $(node -v)"
echo ""
echo "Web 根目录：$WEB_ROOT"
echo "日志目录：$LOG_ROOT"
echo ""
echo "系统已准备好运行 Node 和 Python 项目。"
