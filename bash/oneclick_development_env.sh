#!/bin/bash
# 测试开发环境一键安装脚本

set -e
set -o pipefail

########################################
# 安装开关配置
########################################
INSTALL_NODEJS=true
INSTALL_PYTHON=true
INSTALL_REDIS=true
INSTALL_POSTGRESQL=true
INSTALL_NGINX=true
INSTALL_SECURITY=true  # 防火墙和SELinux配置

########################################
# 全局配置
########################################
WWW_USER="www"
WWW_GROUP="www"
WEB_ROOT="/var/www"
LOG_ROOT="/var/log/www"

########################################
# Node.js 配置
########################################
NODE_VERSION="22.11.0"
NODE_GLOBAL_DIR="/home/$WWW_USER/.node_modules"

########################################
# Python 配置
########################################
PY_VERSION="3.12.7"
PYENV_ROOT="/usr/local/pyenv"

########################################
# Redis 配置
########################################
REDIS_PASSWORD="xxxxxx"
REDIS_DATA_DIR="/var/lib/redis"
REDIS_PORT="6379"
REDIS_BIND="0.0.0.0"
REDIS_MAXMEMORY="512mb"  # 2C4G配置下从256mb调整为512mb

########################################
# PostgreSQL 配置
########################################
POSTGRES_PASSWORD="xxxxxx"
POSTGRES_VERSION="17"
POSTGRES_MAX_CONNECTIONS="150"

########################################
# Nginx 配置
########################################
NGINX_LOG_DIR="/var/log/nginx"
NGINX_CONF_DIR="/etc/nginx"

########################################
# 通用函数
########################################

# 安全执行（忽略非 0）
safe_run() {
  set +e
  "$@"
  set -e
}

# 检查 root 权限
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请以 root 运行此脚本"
    exit 1
  fi
}

# 创建 www 用户
create_www_user() {
  echo "👤 创建 www 用户..."
  
  if ! id -u "$WWW_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$WWW_USER"
    echo "  - www 用户创建完成"
  else
    echo "  - www 用户已存在"
  fi
  
  # 提前创建Node全局模块目录（避免安装时权限问题）
  mkdir -p $NODE_GLOBAL_DIR
  chown -R $WWW_USER:$WWW_GROUP $NODE_GLOBAL_DIR
}

# 创建目录结构
setup_directories() {
  echo "📂 创建目录结构..."
  
  # 检查并创建各个目录
  for dir in "$WEB_ROOT" "$LOG_ROOT" "$REDIS_DATA_DIR" "$NGINX_LOG_DIR" "$NGINX_CONF_DIR"; do
    if [ -d "$dir" ]; then
      echo "  - $dir 已存在，跳过创建"
    else
      echo "  - 创建目录: $dir"
      mkdir -p "$dir"
    fi
  done
  
  # 统一设置目录所有者为www（无论是否新建）
  chown -R $WWW_USER:$WWW_GROUP $WEB_ROOT $LOG_ROOT $REDIS_DATA_DIR $NGINX_LOG_DIR $NGINX_CONF_DIR
  
  chmod -R 755 $WEB_ROOT
  chmod -R 775 $LOG_ROOT
  chmod -R 750 $REDIS_DATA_DIR  # Redis数据目录限制权限
  chmod -R 750 $NGINX_CONF_DIR  # Nginx配置目录限制权限
}

# 安装系统依赖
install_system_deps() {
  echo "📦 安装系统依赖..."
  
  dnf install -y epel-release
  dnf install -y wget curl git unzip gcc make openssl-devel \
    bzip2-devel libffi-devel sqlite-devel acl sudo tar xz \
    readline-devel ncurses-devel xz-devel libuuid-devel tk-devel
  
  # gdbm-devel在AlmaLinux 9中可能不存在，尝试安装gdbm
  dnf install -y gdbm 2>/dev/null || echo "  - gdbm 包未找到，跳过"
}

########################################
# Node.js 安装模块
########################################
install_nodejs() {
  if [ "$INSTALL_NODEJS" != "true" ]; then
    echo "⏭️  跳过 Node.js 安装"
    return
  fi

  echo "📦 安装 Node.js v${NODE_VERSION}..."

  # 下载并解压Node（root权限执行）
  wget -q https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz -O /tmp/node.tar.xz
  tar -xf /tmp/node.tar.xz -C /usr/local
  NODE_INSTALL_DIR="/usr/local/node-v${NODE_VERSION}-linux-x64"

  # 修改Node安装目录权限，让www用户可读写
  chown -R $WWW_USER:$WWW_GROUP $NODE_INSTALL_DIR

  # 创建软链接（root权限执行，确保全局可访问）
  ln -sf $NODE_INSTALL_DIR/bin/node /usr/bin/node
  ln -sf $NODE_INSTALL_DIR/bin/npm /usr/bin/npm

  # 为www用户配置npm全局路径（避免权限冲突）
  su - $WWW_USER -c "npm config set prefix '$NODE_GLOBAL_DIR' && npm config set cache '$NODE_GLOBAL_DIR/.cache'"

  # 以www用户安装全局工具
  su - $WWW_USER -c "npm install -g pnpm pm2 npm@latest"

  # 为全局工具创建软链接（确保系统可访问）
  ln -sf $NODE_GLOBAL_DIR/bin/npm /usr/bin/npm || true
  ln -sf $NODE_GLOBAL_DIR/bin/pnpm /usr/bin/pnpm || true
  ln -sf $NODE_GLOBAL_DIR/bin/pm2 /usr/bin/pm2 || true

  echo "✅ Node 安装完成（版本：$(node -v)，npm：$(npm -v)，pnpm：$(pnpm -v)）"
}

# 配置 PM2 开机自启
setup_pm2() {
  if [ "$INSTALL_NODEJS" != "true" ]; then
    return
  fi

  echo "⚙️  配置 PM2 开机自启..."

  # 确保PM2以www用户注册服务
  su - $WWW_USER -c "pm2 startup systemd -u $WWW_USER --hp /home/$WWW_USER >/tmp/pm2_start_cmd.txt 2>&1" || true

  PM2_CMD=$(safe_run cat /tmp/pm2_start_cmd.txt | grep sudo | sed 's/sudo //')
  safe_run eval "$PM2_CMD"

  safe_run systemctl enable pm2-$WWW_USER

  echo "✅ PM2 配置完成（版本：$(pm2 -v)）"
}

########################################
# Python 安装模块
########################################
install_python() {
  if [ "$INSTALL_PYTHON" != "true" ]; then
    echo "⏭️  跳过 Python 安装"
    return
  fi

  echo "🐍 安装 pyenv..."

  # 克隆pyenv仓库（使用root权限）
  if [ ! -d "$PYENV_ROOT" ]; then
    git clone https://github.com/pyenv/pyenv.git $PYENV_ROOT
    git clone https://github.com/pyenv/pyenv-virtualenv.git $PYENV_ROOT/plugins/pyenv-virtualenv
  fi

  # 配置全局环境变量
  cat >/etc/profile.d/pyenv.sh <<EOF
export PYENV_ROOT="$PYENV_ROOT"
export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init -)"
eval "\$(pyenv virtualenv-init -)"
EOF

  # 为www用户单独配置
  cat >>/home/$WWW_USER/.bashrc <<EOF
export PYENV_ROOT="$PYENV_ROOT"
export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init -)"
eval "\$(pyenv virtualenv-init -)"
EOF

  source /etc/profile.d/pyenv.sh

  echo "🐍 安装 Python ${PY_VERSION}..."

  # 使用root权限安装Python（避免权限问题）
  pyenv install $PY_VERSION
  pyenv global $PY_VERSION
  
  # 安装完成后，将pyenv目录权限授予www用户
  chown -R $WWW_USER:$WWW_GROUP $PYENV_ROOT

  # 创建系统软链接
  ln -sf $PYENV_ROOT/shims/python3 /usr/bin/python3 || true
  ln -sf $PYENV_ROOT/shims/pip3 /usr/bin/pip3 || true
  ln -sf $PYENV_ROOT/shims/python /usr/bin/python || true
  ln -sf $PYENV_ROOT/shims/pip /usr/bin/pip || true

  # 以www用户安装Python包
  su - $WWW_USER -c "source /etc/profile.d/pyenv.sh && pip install --upgrade pip"
  su - $WWW_USER -c "source /etc/profile.d/pyenv.sh && pip install uvicorn fastapi"
  
  # 确保shims目录对www用户可写（用于rehash）
  chmod -R 775 $PYENV_ROOT/shims

  echo "✅ Python ${PY_VERSION} 安装完成（版本：$(python3 --version)）"
}

########################################
# Redis 安装模块
########################################
install_redis() {
  if [ "$INSTALL_REDIS" != "true" ]; then
    echo "⏭️  跳过 Redis 安装"
    return
  fi

  echo "🟥 安装 Redis 7.2..."

  dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
  dnf module reset -y redis
  dnf module install -y redis:remi-7.2
  dnf install -y redis

  # 确保Redis配置目录存在并设置权限
  mkdir -p /etc/redis
  chown -R $WWW_USER:$WWW_GROUP /etc/redis
  chmod 755 /etc/redis

  # 配置Redis
  cat > /etc/redis/redis.conf <<EOF
bind $REDIS_BIND
protected-mode yes
port $REDIS_PORT
requirepass $REDIS_PASSWORD
dir $REDIS_DATA_DIR

maxmemory $REDIS_MAXMEMORY
maxmemory-policy allkeys-lru
supervised systemd
EOF

  # 确保配置文件权限正确
  chown $WWW_USER:$WWW_GROUP /etc/redis/redis.conf
  chmod 640 /etc/redis/redis.conf

  # 创建自定义服务文件，指定www用户运行
  cat > /etc/systemd/system/redis.service <<EOF
[Unit]
Description=Redis persistent key-value database
After=network.target

[Service]
User=$WWW_USER
Group=$WWW_GROUP
ExecStart=/usr/bin/redis-server /etc/redis/redis.conf --supervised systemd
ExecStop=/usr/libexec/redis-shutdown
LimitNOFILE=10032
TimeoutStopSec=5
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  # 确保Redis数据目录权限正确（清理可能的旧文件）
  mkdir -p $REDIS_DATA_DIR
  chown -R $WWW_USER:$WWW_GROUP $REDIS_DATA_DIR
  chmod 750 $REDIS_DATA_DIR
  
  # 停止可能存在的旧Redis进程
  systemctl stop redis 2>/dev/null || true
  pkill -u $WWW_USER redis-server 2>/dev/null || true
  sleep 2

  systemctl daemon-reload
  systemctl enable redis --now

  # 等待Redis启动
  sleep 3

  # 验证Redis启动状态
  if ! systemctl is-active --quiet redis; then
    echo "❌ Redis 启动失败，查看详细日志："
    journalctl -u redis -n 30 --no-pager
    echo ""
    echo "💡 手动排查命令："
    echo "   journalctl -u redis -n 50"
    echo "   ss -tuln | grep 6379"
    exit 1
  fi

  echo "✅ Redis 安装完成（版本：$(redis-server --version)）"
}

########################################
# PostgreSQL 安装模块
# PostgreSQL is for local dev/testing only, not for load testing
########################################
install_postgresql() {
  if [ "$INSTALL_POSTGRESQL" != "true" ]; then
    echo "⏭️  跳过 PostgreSQL 安装"
    return
  fi

  echo "🟦 安装 PostgreSQL ${POSTGRES_VERSION}..."

  safe_run dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-$(rpm -E %rhel)-x86_64/pgdg-redhat-repo-latest.noarch.rpm
  safe_run dnf -qy module disable postgresql
  safe_run dnf install -y postgresql${POSTGRES_VERSION} postgresql${POSTGRES_VERSION}-server
  safe_run /usr/pgsql-${POSTGRES_VERSION}/bin/postgresql-${POSTGRES_VERSION}-setup initdb

  PG_CONF="/var/lib/pgsql/${POSTGRES_VERSION}/data/postgresql.conf"
  PG_HBA="/var/lib/pgsql/${POSTGRES_VERSION}/data/pg_hba.conf"

  # 依据当前服务器配置优化PostgreSQL配置
  # ===== Memory tuning for 2C4G dev server =====
  shared_buffers = 256MB
  work_mem = 4MB
  maintenance_work_mem = 64MB
  effective_cache_size = 1GB
  # ===== Connection control =====
  max_connections = 50
  # ===== Autovacuum control =====
  autovacuum_max_workers = 2
  autovacuum_work_mem = 64MB

  # 配置PostgreSQL网络访问
  sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" $PG_CONF
  sed -i "s/#max_connections = 100/max_connections = $POSTGRES_MAX_CONNECTIONS/" $PG_CONF
  echo "host all all 0.0.0.0/0 md5" >> $PG_HBA

  safe_run systemctl enable postgresql-${POSTGRES_VERSION} --now
  
  # 验证PostgreSQL启动状态
  if ! systemctl is-active --quiet postgresql-${POSTGRES_VERSION}; then
    echo "❌ PostgreSQL 启动失败，请检查日志: journalctl -u postgresql-${POSTGRES_VERSION} -n 50"
    exit 1
  fi
  
  safe_run su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '${POSTGRES_PASSWORD}';\""

  echo "✅ PostgreSQL ${POSTGRES_VERSION} 安装完成（保持默认postgres用户运行）"
}

########################################
# Nginx 安装模块
########################################
install_nginx() {
  if [ "$INSTALL_NGINX" != "true" ]; then
    echo "⏭️  跳过 Nginx 安装"
    return
  fi

  echo "🌐 安装 Nginx..."

  dnf install -y nginx

  # 修改nginx配置文件用户和PID路径
  sed -i "s/^user .*/user $WWW_USER;/" /etc/nginx/nginx.conf
  sed -i "s|^pid .*|pid /run/nginx/nginx.pid;|" /etc/nginx/nginx.conf || \
    echo "pid /run/nginx/nginx.pid;" >> /etc/nginx/nginx.conf

  # 创建Nginx运行目录
  mkdir -p /run/nginx
  chown $WWW_USER:$WWW_GROUP /run/nginx

  # 创建Nginx临时目录（关键修复）
  mkdir -p /var/lib/nginx/tmp/client_body_temp
  mkdir -p /var/lib/nginx/tmp/proxy_temp
  mkdir -p /var/lib/nginx/tmp/fastcgi_temp
  mkdir -p /var/lib/nginx/tmp/uwsgi_temp
  mkdir -p /var/lib/nginx/tmp/scgi_temp
  chown -R $WWW_USER:$WWW_GROUP /var/lib/nginx
  
  # 确保缓存和日志目录权限正确
  mkdir -p /var/cache/nginx
  chown -R $WWW_USER:$WWW_GROUP /var/cache/nginx
  chown -R $WWW_USER:$WWW_GROUP /var/log/nginx

  # 授予Nginx绑定特权端口的能力（允许www用户绑定80/443端口）
  setcap 'cap_net_bind_service=+ep' /usr/sbin/nginx

  # 创建自定义服务文件，指定www用户运行
  cat > /etc/systemd/system/nginx.service <<EOF
[Unit]
Description=The nginx HTTP and reverse proxy server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
User=$WWW_USER
Group=$WWW_GROUP
PIDFile=/run/nginx/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -c /etc/nginx/nginx.conf
ExecStart=/usr/sbin/nginx -c /etc/nginx/nginx.conf
ExecReload=/bin/kill -s HUP \$MAINPID
KillSignal=SIGQUIT
TimeoutStopSec=5
KillMode=process
PrivateTmp=true
RuntimeDirectory=nginx
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable nginx --now

  # 验证Nginx启动状态
  if ! systemctl is-active --quiet nginx; then
    echo "❌ Nginx 启动失败，请检查日志: journalctl -u nginx -n 50"
    exit 1
  fi

  echo "✅ Nginx 安装完成（版本：$(nginx -v 2>&1)）"
}

########################################
# 安全加固模块
########################################
setup_security() {
  if [ "$INSTALL_SECURITY" != "true" ]; then
    echo "⏭️  跳过安全配置"
    return
  fi

  echo "🔒 配置 SELinux..."
  
  # 临时禁用SELinux（测试环境）
  setenforce 0 2>/dev/null || true
  sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true

  echo "🔥 配置防火墙..."
  
  systemctl enable firewalld --now 2>/dev/null || true
  firewall-cmd --permanent --add-service=http 2>/dev/null || true
  firewall-cmd --permanent --add-service=https 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true

  echo "🔐 配置权限..."

  # 目录权限补充
  safe_run setfacl -R -m u:root:rwx $WEB_ROOT
  safe_run setfacl -R -m u:$WWW_USER:rwx $WEB_ROOT

  # 允许www用户管理服务（不扩展其他权限）
  if ! grep -q "^$WWW_USER ALL=(ALL) NOPASSWD:" /etc/sudoers; then
    echo "$WWW_USER ALL=(ALL) NOPASSWD: /usr/bin/pm2, /usr/bin/systemctl reload nginx, /usr/bin/systemctl restart nginx, /usr/bin/systemctl restart redis" >> /etc/sudoers
  fi

  echo "✅ 安全配置完成"
}

########################################
# 主流程
########################################
main() {
  check_root
  
  echo ""
  echo "========================================="
  echo "  测试开发环境一键安装脚本"
  echo "========================================="
  echo ""
  
  create_www_user
  setup_directories
  install_system_deps
  
  install_nodejs
  setup_pm2
  
  install_python
  install_redis
  install_postgresql
  install_nginx
  
  setup_security
  
  # 打印安装摘要
  echo ""
  echo "========================================="
  echo "🎉 开发环境安装完成！"
  echo "========================================="
  echo ""
  echo "📋 服务信息："
  [ "$INSTALL_REDIS" = "true" ] && echo "  Redis 密码：${REDIS_PASSWORD}"
  [ "$INSTALL_POSTGRESQL" = "true" ] && echo "  PostgreSQL 密码：${POSTGRES_PASSWORD}"
  echo ""
  echo "📦 软件版本："
  [ "$INSTALL_PYTHON" = "true" ] && echo "  Python: $(python3 --version 2>&1 || echo '未安装')"
  [ "$INSTALL_NODEJS" = "true" ] && echo "  Node.js: $(node -v 2>&1 || echo '未安装')"
  [ "$INSTALL_NODEJS" = "true" ] && echo "  npm: $(npm -v 2>&1 || echo '未安装')"
  [ "$INSTALL_NODEJS" = "true" ] && echo "  pnpm: $(pnpm -v 2>&1 || echo '未安装')"
  [ "$INSTALL_NODEJS" = "true" ] && echo "  PM2: $(pm2 -v 2>&1 || echo '未安装')"
  echo ""
  echo "📂 目录信息："
  echo "  Web 根目录：$WEB_ROOT"
  echo "  日志目录：$LOG_ROOT"
  echo ""
  echo "👤 服务运行用户：$WWW_USER（Nginx/Redis/PM2）"
  echo ""
  echo "🔍 验证服务状态："
  echo "  systemctl status nginx redis $([ "$INSTALL_POSTGRESQL" = "true" ] && echo "postgresql-${POSTGRES_VERSION}") pm2-$WWW_USER"
  echo "  ss -tuln | grep -E ':(80|443|6379|5432)'"
  echo ""
}

# 执行主流程
main