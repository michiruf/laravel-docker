#!/usr/bin/env sh
# Supervisor wrapper for artisan programs that may not exist in every application.
#
# Usage: laravel-optional.sh <composer-package|-> <artisan args...>
#
# - Waits until the application is provisioned (artisan + vendor exist), so
#   supervisor programs stay RUNNING instead of crash-looping before the first
#   deploy finished.
# - If a composer package is given (e.g. 'laravel/horizon') and it is not
#   installed, idles and re-checks periodically, so a later deploy that adds
#   the package starts the program without a container restart. Pass '-' to
#   skip the package check.
# - Once runnable, exec's into artisan so supervisor signals reach the process
#   directly (keeps e.g. horizon's graceful drain via stopwaitsecs intact).
set -e
. /opt/docker/etc/laravel-env.sh

package=$1
shift

# Exit promptly when supervisor stops us while we are waiting/idling
trap 'exit 0' TERM INT

# Wait for the application to be provisioned
while [ ! -f "$APPLICATION_PATH/artisan" ] || [ ! -d "$APPLICATION_PATH/vendor" ]; do
    sleep 5 &
    wait $!
done

# Idle while the optional package is not installed
if [ "$package" != '-' ] && [ ! -d "$APPLICATION_PATH/vendor/$package" ]; then
    p "package '$package' is not installed, idling (re-checking periodically)" 'yellow'
    while [ ! -d "$APPLICATION_PATH/vendor/$package" ]; do
        sleep 60 &
        wait $!
    done
fi

cd "$APPLICATION_PATH"
exec php artisan "$@" --ansi
