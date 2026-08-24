#!/usr/bin/env sh
# Build helper for baked consumer images, executed at image build time after
# the application source was copied to /app-src.
# shellcheck shell=sh
set -e
. /opt/docker/etc/print.sh

p '> installing composer dependencies for baked application' 'cyan'
cd /app-src
composer install --no-progress --optimize-autoloader --ansi
chown -R "$APPLICATION_UID":"$APPLICATION_GID" /app-src
