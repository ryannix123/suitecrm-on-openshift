# ═══════════════════════════════════════════════════════════════════════════════
# SuiteCRM 8 Container for OpenShift
# Base: CentOS Stream 10 + Remi PHP 8.4 + nginx + PHP-FPM
# Runs as non-root, OpenShift restricted SCC compatible
# ═══════════════════════════════════════════════════════════════════════════════

FROM quay.io/centos/centos:stream10

LABEL maintainer="Ryan Nix <ryan.nix@gmail.com>" \
      description="SuiteCRM 8.10 for OpenShift with nginx + PHP-FPM" \
      version="8.10.1" \
      io.k8s.description="SuiteCRM - Open Source CRM" \
      io.k8s.display-name="SuiteCRM 8.10" \
      io.openshift.expose-services="8080:http" \
      io.openshift.tags="crm,suitecrm,php,nginx,symfony"

ARG SUITECRM_VERSION=8.10.1

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
# Install packages from EPEL and Remi repos (PHP 8.4)
# ─────────────────────────────────────────────────────────────────────────────
RUN dnf -y install \
        https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm \
        https://rpms.remirepo.net/enterprise/remi-release-10.rpm && \
    dnf -y module reset php && \
    dnf -y module enable php:remi-8.4 && \
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
        php-pecl-redis6 \
        php-sodium \
        && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# ─────────────────────────────────────────────────────────────────────────────
# Download and install SuiteCRM 8
# ─────────────────────────────────────────────────────────────────────────────
WORKDIR /tmp

RUN curl -fSL -o suitecrm.zip \
        "https://github.com/SuiteCRM/SuiteCRM-Core/releases/download/v${SUITECRM_VERSION}/SuiteCRM-${SUITECRM_VERSION}.zip" && \
    mkdir -p /tmp/suitecrm-extract && \
    unzip -q suitecrm.zip -d /tmp/suitecrm-extract && \
    rm -rf /var/www/html && \
    mkdir -p /var/www/html && \
    cd /tmp/suitecrm-extract && \
    SRCDIR=$(find . -maxdepth 1 -type d ! -name '.' | head -1) && \
    if [ -n "$SRCDIR" ] && [ -d "$SRCDIR/public" ]; then \
        cp -a "$SRCDIR"/. /var/www/html/; \
    else \
        cp -a . /var/www/html/; \
    fi && \
    rm -rf /tmp/suitecrm.zip /tmp/suitecrm-extract

# ─────────────────────────────────────────────────────────────────────────────
# Custom vCard upload fix (increase limit from 30KB to 100MB)
# ─────────────────────────────────────────────────────────────────────────────
RUN if [ -f /var/www/html/public/legacy/include/MVC/View/tpls/Importvcard.tpl ]; then \
        mkdir -p /var/www/html/public/legacy/custom/include/MVC/View/tpls && \
        sed 's/value="30000"/value="104857600"/' \
            /var/www/html/public/legacy/include/MVC/View/tpls/Importvcard.tpl \
            > /var/www/html/public/legacy/custom/include/MVC/View/tpls/Importvcard.tpl; \
    fi

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

COPY nginx.conf /etc/nginx/nginx.conf
RUN chmod 644 /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf
RUN chmod 644 /etc/nginx/conf.d/default.conf

# ─────────────────────────────────────────────────────────────────────────────
# Configure PHP-FPM
# ─────────────────────────────────────────────────────────────────────────────
RUN mkdir -p /run/php-fpm /var/log/php-fpm

COPY www.conf /etc/php-fpm.d/www.conf
RUN chmod 644 /etc/php-fpm.d/www.conf
COPY 99-suitecrm.ini /etc/php.d/99-suitecrm.ini
RUN chmod 644 /etc/php.d/99-suitecrm.ini

# ─────────────────────────────────────────────────────────────────────────────
# Configure Supervisor
# ─────────────────────────────────────────────────────────────────────────────
RUN mkdir -p /var/log/supervisor

COPY supervisord.conf /etc/supervisord.conf
RUN chmod 644 /etc/supervisord.conf

# ─────────────────────────────────────────────────────────────────────────────
# Entrypoint Script with Auto-Installation
# ─────────────────────────────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ─────────────────────────────────────────────────────────────────────────────
# Set permissions for OpenShift
# ─────────────────────────────────────────────────────────────────────────────
RUN chgrp -R 0 /var/www/html && chmod -R g=u /var/www/html && \
    chgrp -R 0 /var/lib/nginx && chmod -R g=u /var/lib/nginx && \
    chgrp -R 0 /var/log/nginx && chmod -R g=u /var/log/nginx && \
    chgrp -R 0 /run/nginx && chmod -R g=u /run/nginx && \
    chgrp -R 0 /var/log/php-fpm && chmod -R g=u /var/log/php-fpm && \
    chgrp -R 0 /run/php-fpm && chmod -R g=u /run/php-fpm && \
    chgrp -R 0 /etc/php-fpm.d && chmod -R g=u /etc/php-fpm.d && \
    chgrp -R 0 /var/log/supervisor && chmod -R g=u /var/log/supervisor && \
    chgrp 0 /entrypoint.sh && chmod g=u /entrypoint.sh && \
    touch /var/www/html/public/legacy/config_override.php && \
    echo '<?php' > /var/www/html/public/legacy/config_override.php && \
    chmod 666 /var/www/html/public/legacy/config_override.php && \
    mkdir -p /var/www/html/cache \
             /var/www/html/public/legacy/cache \
             /var/www/html/public/legacy/custom \
             /var/www/html/public/legacy/upload \
             /var/www/html/logs && \
    chmod -R g+rwX /var/www/html/cache \
                   /var/www/html/public/legacy/cache \
                   /var/www/html/public/legacy/custom \
                   /var/www/html/public/legacy/upload \
                   /var/www/html/logs && \
    mkdir -p /tmp/sessions && chmod 1777 /tmp/sessions

EXPOSE 8080
WORKDIR /var/www/html

USER 1001

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
