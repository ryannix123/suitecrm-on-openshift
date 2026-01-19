#!/bin/bash
set -e

echo "============================================"
echo "SuiteCRM 8 Container Starting..."
echo "Version: ${SUITECRM_VERSION:-8.9.1}"
echo "============================================"

# Environment defaults
export DB_HOST="${DB_HOST:-mariadb}"
export DB_PORT="${DB_PORT:-3306}"
export DB_NAME="${DB_NAME:-suitecrm}"
export DB_USER="${DB_USER:-suitecrm}"
export DB_PASSWORD="${DB_PASSWORD:-suitecrm}"
export SITE_URL="${SITE_URL:-http://localhost:8080}"
export ADMIN_USER="${ADMIN_USER:-admin}"
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

SUITECRM_ROOT="/var/www/html"
LEGACY_DIR="${SUITECRM_ROOT}/public/legacy"
CONFIG_FILE="${LEGACY_DIR}/config.php"
CONFIG_OVERRIDE="${LEGACY_DIR}/config_override.php"

# Persistent config location (mounted from PVC)
PERSIST_DIR="/mnt/suitecrm-config"
PERSIST_CONFIG="${PERSIST_DIR}/config.php"
PERSIST_OVERRIDE="${PERSIST_DIR}/config_override.php"

# Create session directory
mkdir -p /tmp/sessions 2>/dev/null || true

# Fix permissions for writable directories
chmod -R g+rwX ${SUITECRM_ROOT}/cache 2>/dev/null || true
chmod -R g+rwX ${LEGACY_DIR}/cache 2>/dev/null || true
chmod -R g+rwX ${LEGACY_DIR}/custom 2>/dev/null || true
chmod -R g+rwX ${LEGACY_DIR}/upload 2>/dev/null || true
chmod -R g+rwX ${LEGACY_DIR}/modules 2>/dev/null || true
chmod -R g+rwX ${SUITECRM_ROOT}/logs 2>/dev/null || true

# Copy vCard fix to persistent custom directory if not present
VCARD_SRC="${LEGACY_DIR}/include/MVC/View/tpls/Importvcard.tpl"
VCARD_DST="${LEGACY_DIR}/custom/include/MVC/View/tpls/Importvcard.tpl"
if [ ! -f "${VCARD_DST}" ] && [ -f "${VCARD_SRC}" ]; then
    echo "==> Installing vCard upload fix (100MB limit)..."
    mkdir -p "$(dirname ${VCARD_DST})"
    sed 's/value="30000"/value="104857600"/' "${VCARD_SRC}" > "${VCARD_DST}"
    chmod 644 "${VCARD_DST}"
fi

# Wait for database
echo "==> Waiting for database..."
for i in $(seq 1 60); do
    if php -r "\$c=@new mysqli('${DB_HOST}','${DB_USER}','${DB_PASSWORD}','${DB_NAME}',${DB_PORT});if(\$c->connect_error){exit(1);}\$c->close();exit(0);" 2>/dev/null; then
        echo "==> Database ready!"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "==> ERROR: Database not available after 60 attempts"
        exit 1
    fi
    echo "    Attempt $i/60..."
    sleep 2
done

# Create .env.local for Symfony
cat > "${SUITECRM_ROOT}/.env.local" <<ENVEOF
DATABASE_URL=mysql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}
ENVEOF
chmod 644 "${SUITECRM_ROOT}/.env.local" 2>/dev/null || true

# Check if persistent config exists (from previous installation)
INSTALLED=false
if [ -d "${PERSIST_DIR}" ] && [ -f "${PERSIST_CONFIG}" ]; then
    if grep -q "db_host_name" "${PERSIST_CONFIG}" 2>/dev/null; then
        echo "==> Found persistent config, restoring..."
        cp "${PERSIST_CONFIG}" "${CONFIG_FILE}"
        chmod 644 "${CONFIG_FILE}"
        
        if [ -f "${PERSIST_OVERRIDE}" ]; then
            cp "${PERSIST_OVERRIDE}" "${CONFIG_OVERRIDE}"
            chmod 644 "${CONFIG_OVERRIDE}"
        fi
        
        INSTALLED=true
        echo "==> SuiteCRM configuration restored from persistent storage"
    fi
fi

if [ "$INSTALLED" = false ]; then
    echo "============================================"
    echo "Running SuiteCRM CLI Installer..."
    echo "============================================"
    
    cd "${SUITECRM_ROOT}"
    
    echo "==> Running: php bin/console suitecrm:app:install"
    echo "    Site URL: ${SITE_URL}"
    echo "    DB Host: ${DB_HOST}"
    echo "    DB Name: ${DB_NAME}"
    echo "    Admin User: ${ADMIN_USER}"
    
    # Run the CLI installer
    php bin/console suitecrm:app:install \
        -u "${ADMIN_USER}" \
        -p "${ADMIN_PASSWORD}" \
        -U "${DB_USER}" \
        -P "${DB_PASSWORD}" \
        -H "${DB_HOST}" \
        -N "${DB_NAME}" \
        -S "${SITE_URL}" \
        --no-interaction
    
    INSTALL_EXIT_CODE=$?
    
    if [ $INSTALL_EXIT_CODE -eq 0 ]; then
        echo "==> CLI installer completed successfully!"
        
        # Add trusted referer
        SITE_HOST=$(echo "${SITE_URL}" | sed -e 's|https://||' -e 's|http://||' -e 's|/.*||')
        
        if [ -f "${CONFIG_OVERRIDE}" ]; then
            if ! grep -q "${SITE_HOST}" "${CONFIG_OVERRIDE}" 2>/dev/null; then
                echo "\$sugar_config['http_referer']['list'][] = '${SITE_HOST}';" >> "${CONFIG_OVERRIDE}"
            fi
        else
            cat > "${CONFIG_OVERRIDE}" <<OVERRIDEEOF
<?php
\$sugar_config['http_referer']['list'][] = '${SITE_HOST}';
OVERRIDEEOF
        fi
        chmod 644 "${CONFIG_OVERRIDE}" 2>/dev/null || true
        
        # Persist config files to PVC
        if [ -d "${PERSIST_DIR}" ]; then
            echo "==> Persisting configuration to storage..."
            cp "${CONFIG_FILE}" "${PERSIST_CONFIG}"
            cp "${CONFIG_OVERRIDE}" "${PERSIST_OVERRIDE}"
            chmod 644 "${PERSIST_CONFIG}" "${PERSIST_OVERRIDE}" 2>/dev/null || true
            echo "==> Configuration persisted successfully"
        fi
        
        echo "============================================"
        echo "Auto-installation complete!"
        echo "Admin user: ${ADMIN_USER}"
        echo "Site URL: ${SITE_URL}"
        echo "============================================"
    else
        echo "==> ERROR: CLI installer failed with exit code ${INSTALL_EXIT_CODE}"
        echo "==> Check logs for details. You may need to complete installation manually."
    fi
else
    # Existing installation - ensure trusted referer is set
    SITE_HOST=$(echo "${SITE_URL}" | sed -e 's|https://||' -e 's|http://||' -e 's|/.*||')
    
    if [ ! -f "${CONFIG_OVERRIDE}" ]; then
        echo '<?php' > "${CONFIG_OVERRIDE}"
    fi
    
    if ! grep -q "${SITE_HOST}" "${CONFIG_OVERRIDE}" 2>/dev/null; then
        echo "\$sugar_config['http_referer']['list'][] = '${SITE_HOST}';" >> "${CONFIG_OVERRIDE}"
        echo "==> Added trusted referer: ${SITE_HOST}"
        
        # Update persistent copy
        if [ -d "${PERSIST_DIR}" ]; then
            cp "${CONFIG_OVERRIDE}" "${PERSIST_OVERRIDE}" 2>/dev/null || true
        fi
    fi
fi

echo "============================================"
echo "Starting nginx + PHP-FPM..."
echo "Site URL: ${SITE_URL}"
echo "============================================"

exec "$@"
