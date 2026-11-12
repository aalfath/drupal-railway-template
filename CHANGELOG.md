# Changelog

Breaking changes are listed first in each entry.

## 11.4.12-1 (2026-11-12)

First release of the template built from this repository.

- Drupal 11.4.12 on the official `drupal:11.4.12-apache-trixie` image (PHP 8.5), pinned by digest `sha256:2dbcced819fa070bc49280bbf263c9d55703b14fad97f2a8c633c3e92a7535ba`.
- Drush 13.8.1, added at build time.
- PostgreSQL 18 (Railway's `postgres-ssl:18.6`).
- First boot installs the Standard profile with Drush before Apache starts, closes public sign-up, and adds Article and Basic page by recipe.
