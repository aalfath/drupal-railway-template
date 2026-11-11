#!/bin/sh
# Prints the Railway start command used by the template: start.sh, gzipped and base64-encoded
# inline, so the service runs the official drupal image with no extra download at boot.
printf "/bin/sh -c 'echo %s | base64 -d | gunzip > /tmp/railway-start.sh && exec bash /tmp/railway-start.sh'\n" \
  "$(gzip -9c "$(dirname "$0")/start.sh" | base64 -w0)"
