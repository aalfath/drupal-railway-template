#!/bin/bash
# Drupal on Railway: start script, baked into the image by the Dockerfile.
# Source: https://github.com/aalfath/drupal-railway-template
set -euo pipefail
log() { echo "[railway-drupal] $*"; }

DATA="${DRUPAL_DATA_DIR:-${RAILWAY_VOLUME_MOUNT_PATH:-/data}}"
APP=/opt/drupal
WEB="$APP/web"
SITE="$WEB/sites/default"
export PORT="${PORT:-80}"
export DRUPAL_SITE_NAME="${DRUPAL_SITE_NAME:-Drupal}"
export DRUPAL_ADMIN_USER="${DRUPAL_ADMIN_USER:-admin}"
export DRUPAL_ADMIN_EMAIL="${DRUPAL_ADMIN_EMAIL:-admin@example.com}"
export DRUPAL_DATA_DIR="$DATA"
export COMPOSER_HOME="$DATA/.composer" COMPOSER_NO_INTERACTION=1 COMPOSER_ALLOW_SUPERUSER=1

: "${DATABASE_URL:?DATABASE_URL is not set (expected \${{Postgres.DATABASE_URL}})}"
: "${DRUPAL_HASH_SALT:?DRUPAL_HASH_SALT is not set}"
: "${DRUPAL_ADMIN_PASSWORD:?DRUPAL_ADMIN_PASSWORD is not set}"

# 1. Persistent folders on the volume.
rm -rf "$DATA/lost+found"
mkdir -p "$DATA/files" "$DATA/private" "$DATA/config/sync" "$DATA/translations" "$COMPOSER_HOME" \
         "$DATA/modules" "$DATA/themes"
rm -rf "$SITE/files" "$WEB/modules/custom" "$WEB/themes/custom"
ln -sfn "$DATA/files" "$SITE/files"
ln -sfn "$DATA/modules" "$WEB/modules/custom"
ln -sfn "$DATA/themes" "$WEB/themes/custom"
chown www-data:www-data "$DATA" "$DATA/files" "$DATA/private" "$DATA/config" "$DATA/config/sync" "$DATA/translations"
find "$DATA/files" "$DATA/private" "$DATA/config" "$DATA/translations" ! -user www-data -exec chown www-data:www-data {} + 2>/dev/null || true

# 2. Drush is part of the image. Extra Composer packages (DRUPAL_COMPOSER_PACKAGES) are added
#    on top at boot. After the first success, composer.json/lock are kept on the volume and later
#    boots run an offline `composer install` from them. A new image (new lock) starts over.
EXTRA="${DRUPAL_COMPOSER_PACKAGES:-}"
if [ -n "$EXTRA" ]; then
  KEY=$(printf '%s|%s' "$(md5sum < "$APP/composer.lock" | cut -c1-12)" "$EXTRA" | md5sum | cut -c1-12)
  LOCKDIR="$COMPOSER_HOME/lock-$KEY"
  cd "$APP"
  if [ -f "$LOCKDIR/composer.lock" ]; then
    log "restoring $EXTRA from the cached lock file"
    cp "$LOCKDIR/composer.json" "$LOCKDIR/composer.lock" "$APP/"
    composer install --no-progress --no-dev > /tmp/composer.log 2>&1 || { cat /tmp/composer.log; exit 1; }
  else
    log "composer require $EXTRA"
    composer require --no-progress --update-no-dev -W $EXTRA \
      > /tmp/composer.log 2>&1 || { cat /tmp/composer.log; exit 1; }
    rm -rf "$COMPOSER_HOME"/lock-*; mkdir -p "$LOCKDIR"
    cp "$APP/composer.json" "$APP/composer.lock" "$LOCKDIR/"
  fi
fi
DRUSH="$APP/vendor/bin/drush"

# PHP limits (override with PHP_MEMORY_LIMIT / PHP_UPLOAD_MAX).
cat > /usr/local/etc/php/conf.d/zz-railway.ini <<INI
memory_limit=${PHP_MEMORY_LIMIT:-512M}
upload_max_filesize=${PHP_UPLOAD_MAX:-64M}
post_max_size=${PHP_UPLOAD_MAX:-64M}
max_execution_time=120
expose_php=Off
INI

# 3. settings.php, written on every boot from the environment.
cp "$SITE/default.settings.php" "$SITE/settings.php"
cat >> "$SITE/settings.php" <<'PHP'

// ---- Railway settings (written by the start script on every boot) ----
$railway_db = parse_url(getenv('DATABASE_URL'));
$databases['default']['default'] = [
  'driver' => in_array($railway_db['scheme'], ['mysql', 'mariadb']) ? 'mysql' : 'pgsql',
  'database' => ltrim($railway_db['path'] ?? '', '/'),
  'username' => urldecode($railway_db['user'] ?? ''),
  'password' => urldecode($railway_db['pass'] ?? ''),
  'host' => $railway_db['host'],
  'port' => $railway_db['port'] ?? (in_array($railway_db['scheme'], ['mysql', 'mariadb']) ? 3306 : 5432),
  'prefix' => '',
  'namespace' => in_array($railway_db['scheme'], ['mysql', 'mariadb']) ? 'Drupal\\mysql\\Driver\\Database\\mysql' : 'Drupal\\pgsql\\Driver\\Database\\pgsql',
  'autoload' => in_array($railway_db['scheme'], ['mysql', 'mariadb']) ? 'core/modules/mysql/src/Driver/Database/mysql/' : 'core/modules/pgsql/src/Driver/Database/pgsql/',
];
$settings['hash_salt'] = getenv('DRUPAL_HASH_SALT');
$railway_data = getenv('DRUPAL_DATA_DIR') ?: '/data';
$settings['config_sync_directory'] = $railway_data . '/config/sync';
$settings['file_private_path'] = $railway_data . '/private';
$settings['file_temp_path'] = '/tmp';
$config['locale.settings']['translation']['path'] = $railway_data . '/translations';
// Railway's edge proxy terminates TLS and forwards X-Forwarded-* headers.
$settings['reverse_proxy'] = TRUE;
$settings['reverse_proxy_addresses'] = [$_SERVER['REMOTE_ADDR'] ?? '127.0.0.1'];
$settings['reverse_proxy_trusted_headers'] = \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_FOR
  | \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_HOST
  | \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PORT
  | \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PROTO;
// Only answer for the Railway domain, Railway's health checker and any extra hosts.
$settings['trusted_host_patterns'] = ['^localhost$', '^127\.0\.0\.1$', '^healthcheck\.railway\.app$'];
foreach (preg_split('/[\s,]+/', getenv('RAILWAY_PUBLIC_DOMAIN') . ',' . getenv('DRUPAL_TRUSTED_HOSTS'), -1, PREG_SPLIT_NO_EMPTY) as $railway_host) {
  $settings['trusted_host_patterns'][] = '^' . preg_quote($railway_host) . '$';
}
$settings['skip_permissions_hardening'] = TRUE;
// Drupal 12 default; set explicitly so the status report has no warning.
$settings['enable_html5_validation'] = FALSE;
if (file_exists($app_root . '/' . $site_path . '/settings.local.php')) {
  include $app_root . '/' . $site_path . '/settings.local.php';
}
if (file_exists($railway_data . '/settings.custom.php')) {
  include $railway_data . '/settings.custom.php';
}
PHP
chown root:www-data "$SITE/settings.php"; chmod 440 "$SITE/settings.php"

# 4. Wait for the database.
log "waiting for the database"
for i in $(seq 1 60); do
  php -r '$u=parse_url(getenv("DATABASE_URL"));$m=in_array($u["scheme"],["mysql","mariadb"]);
    $dsn=($m?"mysql":"pgsql").":host=".$u["host"].";port=".($u["port"]??($m?3306:5432)).";dbname=".ltrim($u["path"],"/");
    new PDO($dsn,urldecode($u["user"]),urldecode($u["pass"]??""));' 2>/dev/null && break
  [ "$i" = 60 ] && { log "database not reachable"; exit 1; }
  sleep 2
done
# Drupal 11 needs pg_trgm on PostgreSQL.
php -r '$u=parse_url(getenv("DATABASE_URL")); if (!in_array($u["scheme"],["mysql","mariadb"])) {
  $p=new PDO("pgsql:host=".$u["host"].";port=".($u["port"]??5432).";dbname=".ltrim($u["path"],"/"),urldecode($u["user"]),urldecode($u["pass"]??""));
  $p->exec("CREATE EXTENSION IF NOT EXISTS pg_trgm"); }'

# 5. Install on first boot (before Apache starts, so the web installer is never public),
#    otherwise apply pending database updates.
cd "$APP"
TABLES=$(php -r '$u=parse_url(getenv("DATABASE_URL"));$m=in_array($u["scheme"],["mysql","mariadb"]);
  $p=new PDO(($m?"mysql":"pgsql").":host=".$u["host"].";port=".($u["port"]??($m?3306:5432)).";dbname=".ltrim($u["path"],"/"),urldecode($u["user"]),urldecode($u["pass"]??""));
  echo $p->query($m?"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name=\"key_value\"":"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=current_schema() AND table_name=\x27key_value\x27")->fetchColumn();')
if [ "$TABLES" != "0" ]; then
  log "existing site found: running database updates"
  "$DRUSH" updatedb -y
  "$DRUSH" cache:rebuild
else
  log "no site in the database: installing Drupal (standard profile)"
  chmod 640 "$SITE/settings.php"; chown www-data:www-data "$SITE/settings.php"
  "$DRUSH" site:install "${DRUPAL_INSTALL_PROFILE:-standard}" -y \
    --site-name="$DRUPAL_SITE_NAME" --site-mail="$DRUPAL_ADMIN_EMAIL" \
    --account-name="$DRUPAL_ADMIN_USER" --account-mail="$DRUPAL_ADMIN_EMAIL" \
    --account-pass="$DRUPAL_ADMIN_PASSWORD" --locale="${DRUPAL_LOCALE:-en}"
  # Close public sign-up: only administrators create accounts.
  "$DRUSH" config:set user.settings register admin_only -y
  # Drupal 11.4 dropped Article and Basic page from the Standard profile; core still ships
  # them as recipes. Apply them unless DRUPAL_INSTALL_RECIPES is set to "none".
  RECIPES="${DRUPAL_INSTALL_RECIPES:-page_content_type article_tags}"
  if [ "$RECIPES" != "none" ]; then
    for r in $RECIPES; do
      case "$r" in */*) path="$r" ;; *) path="$WEB/core/recipes/$r" ;; esac
      log "applying recipe $r"; "$DRUSH" recipe "$path" -y
    done
    "$DRUSH" cache:rebuild
  fi
  log "installed. Log in at https://${RAILWAY_PUBLIC_DOMAIN:-localhost}/user/login as $DRUPAL_ADMIN_USER"
fi
chown root:www-data "$SITE/settings.php"; chmod 440 "$SITE/settings.php"
chown root:root "$SITE"; chmod 755 "$SITE"   # web server can't rewrite its own config
chown -R www-data:www-data "$DATA/files" "$DATA/private" "$DATA/config" "$DATA/translations" 2>/dev/null || true

# 6. Apache on $PORT, prefork MPM only.
rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*
ln -sf ../mods-available/mpm_prefork.load /etc/apache2/mods-enabled/mpm_prefork.load
ln -sf ../mods-available/mpm_prefork.conf /etc/apache2/mods-enabled/mpm_prefork.conf
sed -ri "s/^Listen [0-9]+$/Listen ${PORT}/" /etc/apache2/ports.conf
sed -ri "s/<VirtualHost \*:[0-9]+>/<VirtualHost *:${PORT}>/" /etc/apache2/sites-enabled/*.conf
log "starting Apache on port $PORT"
exec docker-php-entrypoint apache2-foreground
