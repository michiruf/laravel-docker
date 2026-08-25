#!/usr/bin/env sh
# shellcheck shell=sh
set -e
. /opt/docker/etc/laravel-env.sh
# Guarded artisan wrapper: refuses to run before the application is provisioned.

fail() {
    p "cannot execute artisan command \"$cmd\" yet: $1" 'red'
    exit 1
}

cmd="$*"
[ -d "$APPLICATION_PATH" ]         || fail "deployment not yet complete (there is no $APPLICATION_PATH directory)"
[ -f "$APPLICATION_PATH/artisan" ] || fail "deployment not yet complete (there is no artisan file in $APPLICATION_PATH)"
[ -d "$APPLICATION_PATH/vendor" ]  || fail "composer did not install dependencies yet (there is no vendor directory in $APPLICATION_PATH)"

# Some commands require to be in the artisan directory already, so we first need to switch directories
cd "$APPLICATION_PATH"
php artisan "$@" --ansi
