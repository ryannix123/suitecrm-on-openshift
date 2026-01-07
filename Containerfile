# ═══════════════════════════════════════════════════════════════════════════════
# SuiteCRM Container for OpenShift
# Base: CentOS Stream 9 + Remi PHP 8.3 + nginx + PHP-FPM
# Runs as non-root, OpenShift restricted SCC compatible
# ═══════════════════════════════════════════════════════════════════════════════

FROM quay.io/centos/centos:stream9

LABEL maintainer="Ryan <ryan@redhat.com>" \
      description="SuiteCRM 7.15 for OpenShift with nginx + PHP-FPM" \
      version="7.15.0" \
      io.k8s.description="SuiteCRM - Open Source CRM" \
      io.k8s.display-name="SuiteCRM 7.15" \
      io.openshift.expose-services="8080:http" \
      io.openshift.tags="crm,suitecrm,php,nginx"

ARG SUITECRM_VERSION=7.15.0

# ─────────────────────────────────────────────────────────────────────────────
# Environment Variables
# ─────────────────────────────────────────────────────────────────────────────
ENV SUITECRM_VERSION=${SUITECRM_VERSION} \
    PHP_MEMORY_LIMIT=512M \
    PHP_UPLOAD_MAX_FILESIZE=100M \
    PHP_POST_MAX_SIZE=100M \
    PHP_MAX_EXECUTION_TIME=300 \
    PHP_MAX_INPUT_TIME=300

# ─────────────────────────────────────────────────────────────────────────────
# Install packages from EPEL and Remi repos
# ─────────────────────────────────────────────────────────────────────────────
RUN dnf -y install epel-release && \
    dnf -y install https://rpms.remirepo.net/enterprise/remi-release-9.rpm && \
    dnf -y module reset php && \
    dnf -y module enable php:remi-8.3 && \
    dnf -y install --allowerasing \
        nginx \
        supervisor \
        curl \
        unzip \
        bzip2 \
        procps-ng \
        php-fpm \
        php-cli \
        php-gd \
        php-mbstring \
        php-xml \
        php-zip \
        php-curl \
        php-intl \
        php-bcmath \
        php-opcache \
        php-mysqlnd \
        php-pdo \
        php-imap \
        php-ldap \
        php-soap \
        php-pecl-apcu \
        php-pecl-redis5 \
        php-sodium \
        && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# ─────────────────────────────────────────────────────────────────────────────
# Download and install SuiteCRM
# ─────────────────────────────────────────────────────────────────────────────
WORKDIR /tmp

RUN curl -fSL "https://suitecrm.com/files/147/SuiteCRM-7.15/${SUITECRM_VERSION}/SuiteCRM-${SUITECRM_VERSION}.zip" \
        -o suitecrm.zip || \
    curl -fSL "https://github.com/salesagility/SuiteCRM/releases/download/v${SUITECRM_VERSION}/SuiteCRM-${SUITECRM_VERSION}.zip" \
        -o suitecrm.zip && \
    unzip -q suitecrm.zip && \
    rm -rf /var/www/html && \
    mkdir -p /var/www/html && \
    mv SuiteCRM-${SUITECRM_VERSION}/* /var/www/html/ && \
    rm -rf suitecrm.zip SuiteCRM-${SUITECRM_VERSION}

# ─────────────────────────────────────────────────────────────────────────────
# Configure nginx for non-root operation
# ─────────────────────────────────────────────────────────────────────────────
RUN mkdir -p /var/lib/nginx/tmp/client_body \
             /var/lib/nginx/tmp/proxy \
             /var/lib/nginx/tmp/fastcgi \
             /var/lib/nginx/tmp/uwsgi \
             /var/lib/nginx/tmp/scgi \
             /var/log/nginx \
             /run/nginx

# nginx main config
RUN cat > /etc/nginx/nginx.conf <<'NGINXCONF'
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript 
               application/xml application/xml+rss text/javascript;
    client_body_temp_path /var/lib/nginx/tmp/client_body;
    proxy_temp_path /var/lib/nginx/tmp/proxy;
    fastcgi_temp_path /var/lib/nginx/tmp/fastcgi;
    uwsgi_temp_path /var/lib/nginx/tmp/uwsgi;
    scgi_temp_path /var/lib/nginx/tmp/scgi;
    client_max_body_size 100M;
    client_body_buffer_size 128k;
    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;
    fastcgi_read_timeout 300;
    include /etc/nginx/conf.d/*.conf;
}
NGINXCONF

# nginx server block
RUN cat > /etc/nginx/conf.d/default.conf <<'SERVERCONF'
server {
    listen 8080 default_server;
    listen [::]:8080 default_server;
    server_name _;
    root /var/www/html;
    index index.php index.html;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    location ~ /\. { deny all; }
    location ~* \.(sql|log|ini|sh|yml|yaml|lock|md|txt)$ { deny all; }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
        try_files $uri =404;
    }

    location ^~ /Api/ {
        try_files $uri $uri/ /Api/index.php?$args;
        location ~ \.php$ {
            fastcgi_split_path_info ^(.+\.php)(/.+)$;
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_param PATH_INFO $fastcgi_path_info;
            include fastcgi_params;
            fastcgi_read_timeout 300;
        }
    }

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        include fastcgi_params;
        fastcgi_read_timeout 300;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 256 16k;
        fastcgi_busy_buffers_size 256k;
    }
}
SERVERCONF

# ─────────────────────────────────────────────────────────────────────────────
# Configure PHP-FPM
# ─────────────────────────────────────────────────────────────────────────────
RUN mkdir -p /run/php-fpm /var/log/php-fpm

RUN cat > /etc/php-fpm.d/www.conf <<'PHPFPM'
[www]
listen = 127.0.0.1:9000
listen.allowed_clients = 127.0.0.1
user = nobody
group = nobody
pm = dynamic
pm.max_children = 50
pm.start_servers = 5
pm.min_spare_servers = 5
pm.max_spare_servers = 35
pm.max_requests = 500
pm.status_path = /fpm-status
ping.path = /fpm-ping
ping.response = pong
access.log = /var/log/php-fpm/access.log
slowlog = /var/log/php-fpm/slow.log
request_slowlog_timeout = 10s
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/php-fpm/error.log
catch_workers_output = yes
decorate_workers_output = no
php_admin_flag[expose_php] = off
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 100M
php_admin_value[post_max_size] = 100M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_time] = 300
php_admin_value[session.save_handler] = files
php_admin_value[session.save_path] = /tmp/sessions
php_admin_value[date.timezone] = UTC
clear_env = no
PHPFPM

# PHP settings
RUN cat > /etc/php.d/99-suitecrm.ini <<'PHPINI'
memory_limit = 512M
max_execution_time = 300
max_input_time = 300
upload_max_filesize = 100M
post_max_size = 100M
max_file_uploads = 20
display_errors = Off
log_errors = On
error_log = /var/log/php-fpm/php_errors.log
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
session.save_handler = files
session.save_path = "/tmp/sessions"
session.gc_maxlifetime = 3600
session.cookie_httponly = On
session.cookie_secure = On
date.timezone = UTC
expose_php = Off
allow_url_fopen = On
allow_url_include = Off
realpath_cache_size = 4096K
realpath_cache_ttl = 600
opcache.enable = 1
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 60
opcache.fast_shutdown = 1
apc.enabled = 1
apc.shm_size = 64M
apc.ttl = 7200
imap.enable_insecure_rsh = 0
mysqli.reconnect = On
mysqli.allow_persistent = On
PHPINI

# ─────────────────────────────────────────────────────────────────────────────
# Configure Supervisor
# ─────────────────────────────────────────────────────────────────────────────
RUN mkdir -p /var/log/supervisor

RUN cat > /etc/supervisord.conf <<'SUPERVISOR'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/run/supervisord.pid
childlogdir=/var/log/supervisor
logfile_maxbytes=50MB
logfile_backups=10
loglevel=info

[program:php-fpm]
command=/usr/sbin/php-fpm -F
autostart=true
autorestart=true
priority=10
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=/usr/sbin/nginx -g 'daemon off;'
autostart=true
autorestart=true
priority=20
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
SUPERVISOR

# ─────────────────────────────────────────────────────────────────────────────
# Entrypoint Script
# ─────────────────────────────────────────────────────────────────────────────
RUN cat > /entrypoint.sh <<'ENTRYPOINT'
#!/bin/bash
set -e

echo "============================================"
echo "SuiteCRM Container Starting..."
echo "Version: ${SUITECRM_VERSION:-7.15.0}"
echo "Running as UID: $(id -u), GID: $(id -g)"
echo "============================================"

# Environment defaults
export DB_HOST="${DB_HOST:-mariadb}"
export DB_PORT="${DB_PORT:-3306}"
export DB_NAME="${DB_NAME:-suitecrm}"
export DB_USER="${DB_USER:-suitecrm}"
export DB_PASSWORD="${DB_PASSWORD:-suitecrm}"
export SITE_URL="${SITE_URL:-http://localhost:8080}"
export REDIS_HOST="${REDIS_HOST:-redis}"
export REDIS_PORT="${REDIS_PORT:-6379}"

DOCUMENT_ROOT="/var/www/html"
CONFIG_OVERRIDE="${DOCUMENT_ROOT}/config_override.php"

# Fix permissions
chmod -R g+rwX ${DOCUMENT_ROOT}/cache ${DOCUMENT_ROOT}/custom ${DOCUMENT_ROOT}/upload ${DOCUMENT_ROOT}/modules 2>/dev/null || true
mkdir -p /tmp/sessions && chmod 1777 /tmp/sessions

# Configure Redis sessions if available
if php -r "\$r=new Redis(); try{\$r->connect('${REDIS_HOST}',${REDIS_PORT},2);\$r->ping();exit(0);}catch(Exception \$e){exit(1);}" 2>/dev/null; then
    echo "==> Redis available - configuring sessions..."
    sed -i "s|php_admin_value\[session.save_handler\].*|php_admin_value[session.save_handler] = redis|" /etc/php-fpm.d/www.conf
    sed -i "s|php_admin_value\[session.save_path\].*|php_admin_value[session.save_path] = \"tcp://${REDIS_HOST}:${REDIS_PORT}\"|" /etc/php-fpm.d/www.conf
fi

# Wait for database
echo "==> Waiting for database..."
for i in $(seq 1 60); do
    if php -r "\$c=@new mysqli('${DB_HOST}','${DB_USER}','${DB_PASSWORD}','',${DB_PORT});if(\$c->connect_error){exit(1);}\$c->close();exit(0);" 2>/dev/null; then
        echo "==> Database ready!"
        break
    fi
    echo "    Attempt $i/60..."
    sleep 2
done

# Create config override
cat > "${CONFIG_OVERRIDE}" <<EOF
<?php
\$sugar_config['dbconfig']['db_host_name'] = '${DB_HOST}';
\$sugar_config['dbconfig']['db_port'] = '${DB_PORT}';
\$sugar_config['dbconfig']['db_name'] = '${DB_NAME}';
\$sugar_config['dbconfig']['db_user_name'] = '${DB_USER}';
\$sugar_config['dbconfig']['db_password'] = '${DB_PASSWORD}';
\$sugar_config['site_url'] = '${SITE_URL}';
\$sugar_config['host_name'] = parse_url('${SITE_URL}', PHP_URL_HOST);
\$sugar_config['session_dir'] = '/tmp/sessions';
\$sugar_config['cache_dir'] = 'cache/';
\$sugar_config['upload_dir'] = 'upload/';
\$sugar_config['logger']['level'] = 'error';
EOF

chmod 644 "${CONFIG_OVERRIDE}" 2>/dev/null || true

echo "============================================"
echo "Starting nginx + PHP-FPM via supervisor..."
echo "Site URL: ${SITE_URL}"
echo "============================================"

exec "$@"
ENTRYPOINT

RUN chmod +x /entrypoint.sh

# ─────────────────────────────────────────────────────────────────────────────
# Set permissions for OpenShift (arbitrary UID with GID 0)
# ─────────────────────────────────────────────────────────────────────────────
RUN chgrp -R 0 /var/www/html && chmod -R g=u /var/www/html && \
    chgrp -R 0 /var/lib/nginx && chmod -R g=u /var/lib/nginx && \
    chgrp -R 0 /var/log/nginx && chmod -R g=u /var/log/nginx && \
    chgrp -R 0 /run/nginx && chmod -R g=u /run/nginx && \
    chgrp -R 0 /var/log/php-fpm && chmod -R g=u /var/log/php-fpm && \
    chgrp -R 0 /run/php-fpm && chmod -R g=u /run/php-fpm && \
    chgrp -R 0 /var/log/supervisor && chmod -R g=u /var/log/supervisor && \
    chgrp 0 /entrypoint.sh && chmod g=u /entrypoint.sh && \
    mkdir -p /var/www/html/cache /var/www/html/custom /var/www/html/upload && \
    chmod -R g+rwX /var/www/html/cache /var/www/html/custom /var/www/html/upload && \
    mkdir -p /tmp/sessions && chmod 1777 /tmp/sessions

# ─────────────────────────────────────────────────────────────────────────────
# Final setup
# ─────────────────────────────────────────────────────────────────────────────
EXPOSE 8080
WORKDIR /var/www/html

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -sf http://localhost:8080/health || exit 1

USER 1001

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
