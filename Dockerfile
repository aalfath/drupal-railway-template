# Drupal on Railway: the official drupal image (Apache, PHP 8.5), pinned by digest,
# with Drush baked in and a small start script.
FROM drupal:11.4.12-apache-trixie@sha256:2dbcced819fa070bc49280bbf263c9d55703b14fad97f2a8c633c3e92a7535ba

ENV DRUSH_VERSION=13.8.1

# Drush is added at build time, so a boot needs no package download.
RUN set -eux; \
    cd /opt/drupal; \
    COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1 \
      composer require --no-progress --update-no-dev -W "drush/drush:${DRUSH_VERSION}"; \
    COMPOSER_ALLOW_SUPERUSER=1 composer clear-cache; \
    vendor/bin/drush --version

COPY railway-start.sh /usr/local/bin/railway-start.sh
RUN chmod 755 /usr/local/bin/railway-start.sh

CMD ["/usr/local/bin/railway-start.sh"]
