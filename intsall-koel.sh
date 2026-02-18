#!/bin/bash
set -euo pipefail

source "$(dirname "$0")/config.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    [ "$EUID" -eq 0 ] || log_error "Lance ce script en root (sudo)"
}

# ─────────────────────────────────────────
# ÉTAPE 1 — Mise à jour système
# ─────────────────────────────────────────
step_system() {
    log_info "Mise à jour du système..."
    apt update && apt upgrade -y
    apt install -y git curl wget unzip nginx mysql-server \
        cifs-utils libnss3-tools
    log_info "Système OK"
}

# ─────────────────────────────────────────
# ÉTAPE 2 — PHP 8.2
# ─────────────────────────────────────────
step_php() {
    if php -v 2>/dev/null | grep -q "8.2"; then
        log_warning "PHP 8.2 déjà installé, on passe"
        return
    fi

    log_info "Installation PHP 8.2..."
    apt install -y php8.2 php8.2-fpm php8.2-cli php8.2-mbstring \
        php8.2-xml php8.2-curl php8.2-zip php8.2-mysql \
        php8.2-bcmath php8.2-intl
    log_info "PHP OK"
}

# ─────────────────────────────────────────
# ÉTAPE 3 — Composer
# ─────────────────────────────────────────
step_composer() {
    if command -v composer &>/dev/null; then
        log_warning "Composer déjà installé, on passe"
        return
    fi

    log_info "Installation Composer..."
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer
    log_info "Composer OK"
}

# ─────────────────────────────────────────
# ÉTAPE 4 — Node.js
# ─────────────────────────────────────────
step_nodejs() {
    if command -v node &>/dev/null; then
        log_warning "Node.js déjà installé, on passe"
        return
    fi

    log_info "Installation Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
    log_info "Node.js OK"
}

# ─────────────────────────────────────────
# ÉTAPE 5 — MySQL
# ─────────────────────────────────────────
step_mysql() {
    if mysql -u "$DB_USER" -p"$DB_PASSWORD" -e "USE $DB_NAME" 2>/dev/null; then
        log_warning "Base de données déjà configurée, on passe"
        return
    fi

    log_info "Configuration MySQL..."
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
    log_info "MySQL OK"
}

# ─────────────────────────────────────────
# ÉTAPE 6 — mkcert + certificat SSL
# ─────────────────────────────────────────
step_ssl() {
    if [ -f "/etc/ssl/koel/${VM_IP}.pem" ]; then
        log_warning "Certificat SSL déjà généré, on passe"
        return
    fi

    log_info "Installation mkcert et génération du certificat..."

    curl -Lo /usr/local/bin/mkcert \
        https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v1.4.4-linux-amd64
    chmod +x /usr/local/bin/mkcert

    mkdir -p /etc/ssl/koel
    CAROOT=/etc/ssl/koel mkcert -install
    cd /etc/ssl/koel
    CAROOT=/etc/ssl/koel mkcert "$VM_IP"

    log_info "SSL OK"
    log_info "CA à installer sur tes appareils : /etc/ssl/koel/rootCA.pem"
}

# ─────────────────────────────────────────
# ÉTAPE 7 — Montage SMB Freebox
# ─────────────────────────────────────────
step_smb() {
    if mountpoint -q "$MOUNT_POINT"; then
        log_warning "Partage SMB déjà monté, on passe"
        return
    fi

    log_info "Configuration du montage SMB..."
    mkdir -p "$MOUNT_POINT"

    cat > /etc/koel-smb-credentials <<EOF
username=${FREEBOX_USER}
password=${FREEBOX_PASSWORD}
EOF
    chmod 600 /etc/koel-smb-credentials

    if ! grep -q "$MOUNT_POINT" /etc/fstab; then
        echo "//${FREEBOX_IP}/${FREEBOX_SHARE} ${MOUNT_POINT} cifs credentials=/etc/koel-smb-credentials,uid=www-data,gid=www-data,_netdev 0 0" >> /etc/fstab
    fi

    mount "$MOUNT_POINT" || log_error "Impossible de monter le partage SMB"
    log_info "SMB OK"
}

# ─────────────────────────────────────────
# ÉTAPE 8 — Koel
# ─────────────────────────────────────────
step_koel() {
    if [ -d "$KOEL_DIR/.git" ]; then
        log_warning "Koel déjà installé, on passe"
        return
    fi

    log_info "Clonage de Koel depuis la branche $KOEL_BRANCH..."
    git clone --branch "$KOEL_BRANCH" "$KOEL_REPO" "$KOEL_DIR"
    cd "$KOEL_DIR"

    log_info "Installation des dépendances PHP..."
    sudo -u www-data composer install --no-dev --no-interaction

    log_info "Installation des dépendances JS et compilation..."
    npm install && npm run build

    if [ ! -f "$KOEL_DIR/.env" ]; then
        cp "$KOEL_DIR/.env.example" "$KOEL_DIR/.env"
        sed -i "s|APP_URL=.*|APP_URL=https://${VM_IP}|" "$KOEL_DIR/.env"
        sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" "$KOEL_DIR/.env"
        sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" "$KOEL_DIR/.env"
        sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" "$KOEL_DIR/.env"
        sed -i "s|MEDIA_PATH=.*|MEDIA_PATH=${MOUNT_POINT}|" "$KOEL_DIR/.env"
    fi

    php artisan key:generate --force
    php artisan migrate --force

    chown -R www-data:www-data "$KOEL_DIR/storage"
    chown -R www-data:www-data "$KOEL_DIR/bootstrap/cache"

    log_info "Koel OK"
}

# ─────────────────────────────────────────
# ÉTAPE 9 — Nginx
# ─────────────────────────────────────────
step_nginx() {
    log_info "Configuration Nginx..."
    cat > /etc/nginx/sites-available/koel <<EOF
server {
    listen 443 ssl;
    server_name ${VM_IP};
    root ${KOEL_DIR}/public;
    index index.php;

    ssl_certificate /etc/ssl/koel/${VM_IP}.pem;
    ssl_certificate_key /etc/ssl/koel/${VM_IP}-key.pem;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location /media {
        internal;
        alias ${MOUNT_POINT};
    }
}

server {
    listen 80;
    server_name ${VM_IP};
    return 301 https://\$host\$request_uri;
}
EOF

    ln -sf /etc/nginx/sites-available/koel /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    nginx -t || log_error "Config Nginx invalide"
    systemctl restart nginx php8.2-fpm
    log_info "Nginx OK"
}

# ─────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────
main() {
    check_root
    log_info "=== Installation Koel ==="

    step_system
    step_php
    step_composer
    step_nodejs
    step_mysql
    step_ssl
    step_smb
    step_koel
    step_nginx

    log_info "=== Installation terminée ==="
    log_info "Koel accessible sur https://${VM_IP}"
    log_info "Lance la synchronisation : php artisan koel:sync"
}

main "$@"
