# Drupal on Railway

Start script behind the [Drupal Railway template](https://railway.com/deploy/drupal-11) (Agaz Self-Host). It runs the **official `drupal` image** with no custom build:

| Service  | Image (pinned) | Volume |
|----------|----------------|--------|
| Drupal   | `drupal:11.4.12-apache-trixie@sha256:2dbcced819fa070bc49280bbf263c9d55703b14fad97f2a8c633c3e92a7535ba` (PHP 8.5, Apache) | `/data` |
| Postgres | `ghcr.io/railwayapp-templates/postgres-ssl:18.6@sha256:4fc833b43d2aaf6ecc9b18615f5533602b723a32d0e2efe2dae8ca0f7217c863` | `/var/lib/postgresql/data` |

The Railway start command is `start.sh`, gzipped and base64-encoded inline (`./make-start-command.sh` prints it).

## What `start.sh` does on every boot

1. Links `sites/default/files`, `web/modules/custom` and `web/themes/custom` to the `/data` volume, and keeps private files (`/data/private`), config sync (`/data/config/sync`) and translations there too.
2. Adds Drush 13.8.1, plus any packages in `DRUPAL_COMPOSER_PACKAGES`, with Composer. After the first success, `composer.json` and `composer.lock` are cached on the volume, so later boots run an offline `composer install`.
3. Writes `settings.php` from the environment:
   - the database from `DATABASE_URL` (Postgres or MySQL);
   - the hash salt from `DRUPAL_HASH_SALT`;
   - trusted host patterns for `RAILWAY_PUBLIC_DOMAIN`, Railway's health checker and `DRUPAL_TRUSTED_HOSTS`;
   - reverse-proxy settings for Railway's edge.
   
   The file is read-only for the web server. Put your own overrides in `/data/settings.custom.php`.
4. Waits for the database and enables `pg_trgm`, which Drupal 11 needs on PostgreSQL.
5. **First boot** (no `key_value` table yet): installs the site before Apache starts, so the web installer is never reachable:
   - `drush site:install standard` with the admin password from `DRUPAL_ADMIN_PASSWORD`;
   - sets sign-up to administrators only;
   - applies core's `page_content_type` and `article_tags` recipes, because Drupal 11.4 dropped Article and Basic page from the Standard profile.

   **Later boots:** `drush updatedb` and `drush cache:rebuild`.
6. Starts Apache (prefork MPM only) on `$PORT`.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` | `postgresql://` or `mysql://` |
| `DRUPAL_HASH_SALT` | `${{secret(64)}}` | keep it stable |
| `DRUPAL_ADMIN_PASSWORD` | `${{secret(24)}}` | password of the first admin (user `admin`) |
| `DRUPAL_ADMIN_EMAIL` | (required) | admin and site e-mail |
| `DRUPAL_ADMIN_USER` | `admin` | optional |
| `DRUPAL_SITE_NAME` | `Drupal` | optional, first install only |
| `DRUPAL_INSTALL_RECIPES` | `page_content_type article_tags` | optional, first install only; `none` for the bare Standard profile |
| `DRUPAL_COMPOSER_PACKAGES` | empty | optional, e.g. `drupal/admin_toolbar drupal/pathauto` |
| `DRUPAL_TRUSTED_HOSTS` | empty | optional, extra host names (custom domains) |
| `PHP_MEMORY_LIMIT` / `PHP_UPLOAD_MAX` | `512M` / `64M` | optional |

## Test

`e2e.sh BASE_URL admin PASSWORD` runs these checks:
- the front page loads;
- the installer says the site is already installed;
- anonymous sign-up returns 403;
- the admin can log in;
- an Article with an image can be created, and anonymous visitors can see the article and its image.
