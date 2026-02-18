#!/bin/bash
set -euo pipefail

source "$(dirname "$0")/config.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_step()    { echo -e "${BLUE}[STEP]${NC} $1"; }

check_root() {
    [ "$EUID" -eq 0 ] || log_error "Lance ce script en root (sudo)"
}

# ─────────────────────────────────────────
# Vérification des prérequis
# ─────────────────────────────────────────
check_prerequisites() {
    log_step "Vérification des prérequis..."
    [ -d "$KOEL_DIR/.git" ] || log_error "Koel ne semble pas installé dans $KOEL_DIR"
    mountpoint -q "$MOUNT_POINT" || log_warning "Le partage SMB ne semble pas monté"
    nginx -t 2>/dev/null || log_error "La config Nginx est invalide"
    log_info "Prérequis OK"
}

# ─────────────────────────────────────────
# Sauvegarde
# ─────────────────────────────────────────
backup() {
    log_step "Sauvegarde..."

    BACKUP_DIR="/var/backups/koel/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    cp "$KOEL_DIR/.env" "$BACKUP_DIR/.env"
    log_info ".env sauvegardé"

    mysqldump -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" > "$BACKUP_DIR/db.sql"
    log_info "Base de données sauvegardée"

    # On garde les 5 dernières sauvegardes
    ls -dt /var/backups/koel/*/ | tail -n +6 | xargs rm -rf 2>/dev/null || true

    log_info "Sauvegarde dans $BACKUP_DIR"
    echo "$BACKUP_DIR" > /tmp/koel_last_backup
}

# ─────────────────────────────────────────
# Maintenance
# ─────────────────────────────────────────
maintenance_on() {
    log_step "Activation du mode maintenance..."
    cd "$KOEL_DIR"
    sudo -u www-data php artisan down
    log_info "Mode maintenance activé"
}

maintenance_off() {
    cd "$KOEL_DIR"
    sudo -u www-data php artisan up
    log_info "Mode maintenance désactivé"
}

# ─────────────────────────────────────────
# Mise à jour du code
# ─────────────────────────────────────────
update_code() {
    log_step "Mise à jour du code depuis la branche $KOEL_BRANCH..."
    cd "$KOEL_DIR"

    CURRENT_COMMIT=$(git rev-parse --short HEAD)
    git pull origin "$KOEL_BRANCH"
    NEW_COMMIT=$(git rev-parse --short HEAD)

    if [ "$CURRENT_COMMIT" = "$NEW_COMMIT" ]; then
        log_warning "Aucun changement détecté sur la branche $KOEL_BRANCH"
    else
        log_info "Déployé : $CURRENT_COMMIT → $NEW_COMMIT"
    fi
}

# ─────────────────────────────────────────
# Mise à jour des dépendances
# ─────────────────────────────────────────
update_dependencies() {
    log_step "Mise à jour des dépendances PHP..."
    cd "$KOEL_DIR"
    sudo -u www-data composer install --no-dev --no-interaction --optimize-autoloader
    log_info "Dépendances PHP OK"

    log_step "Mise à jour des dépendances JS et recompilation..."
    npm install && npm run build
    log_info "Assets compilés OK"
}

# ─────────────────────────────────────────
# Migrations
# ─────────────────────────────────────────
update_database() {
    log_step "Migrations base de données..."
    cd "$KOEL_DIR"
    sudo -u www-data php artisan migrate --force
    log_info "Migrations OK"
}

# ─────────────────────────────────────────
# Caches
# ─────────────────────────────────────────
clear_caches() {
    log_step "Nettoyage et recompilation des caches..."
    cd "$KOEL_DIR"
    sudo -u www-data php artisan cache:clear
    sudo -u www-data php artisan config:clear
    sudo -u www-data php artisan view:clear
    sudo -u www-data php artisan route:clear
    sudo -u www-data php artisan config:cache
    sudo -u www-data php artisan route:cache
    log_info "Caches OK"
}

# ─────────────────────────────────────────
# Permissions
# ─────────────────────────────────────────
fix_permissions() {
    log_step "Correction des permissions..."
    chown -R www-data:www-data "$KOEL_DIR/storage"
    chown -R www-data:www-data "$KOEL_DIR/bootstrap/cache"
    log_info "Permissions OK"
}

# ─────────────────────────────────────────
# Rollback
# ─────────────────────────────────────────
rollback() {
    log_error "Erreur détectée — tentative de rollback..."

    BACKUP_DIR=$(cat /tmp/koel_last_backup 2>/dev/null || echo "")
    [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ] && log_error "Pas de sauvegarde disponible"

    log_info "Restauration depuis $BACKUP_DIR..."
    cp "$BACKUP_DIR/.env" "$KOEL_DIR/.env"
    mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" < "$BACKUP_DIR/db.sql"

    cd "$KOEL_DIR"
    git checkout "$(git rev-parse HEAD~1)"

    maintenance_off
    systemctl restart nginx php8.2-fpm

    log_info "Rollback effectué — vérifie que tout fonctionne sur https://${VM_IP}"
    exit 1
}

# ─────────────────────────────────────────
# Redémarrage des services
# ─────────────────────────────────────────
restart_services() {
    log_step "Redémarrage des services..."
    systemctl restart php8.2-fpm
    systemctl reload nginx
    log_info "Services redémarrés"
}

# ─────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────
main() {
    check_root
    log_info "=== Mise à jour Koel ==="

    trap rollback ERR

    check_prerequisites
    backup
    maintenance_on
    update_code
    update_dependencies
    update_database
    clear_caches
    fix_permissions
    restart_services
    maintenance_off

    log_info "=== Mise à jour terminée ==="
    log_info "Koel accessible sur https://${VM_IP}"
}

main "$@"

