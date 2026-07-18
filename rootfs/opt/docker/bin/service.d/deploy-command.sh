#!/usr/bin/env sh
# Provisioning command dispatcher: executes a single deploy command token.
# See the README for the full command DSL reference.
set -e
. /opt/docker/etc/print.sh

# Trim surrounding whitespace (pure parameter expansion; unlike xargs this
# does not mangle quotes or backslashes)
command=$*
command=${command#"${command%%[![:space:]]*}"}
command=${command%"${command##*[![:space:]]}"}

# Switch what to do with the command
case $command in
    -*)
        p "skipping command since it starts with '-'" 'yellow'
        ;;
    git:update)
        current_branch=$(git symbolic-ref --short HEAD)
        git reset --hard "origin/$current_branch"
        ;;
    env:update)
        /opt/docker/bin/service.d/laravel-env.sh
        ;;
    permissions:fix)
        chown -R "$APPLICATION_UID":"$APPLICATION_GID" .
        ;;
    composer:*)
        eval "composer ${command#composer:} --ansi"
        ;;
    'artisan?:'*)
        # Optional artisan command: tolerate absence/failure (e.g. horizon:terminate
        # on an application that does not ship horizon)
        args=${command#"artisan?:"}
        eval "/opt/docker/bin/service.d/laravel-artisan.sh $args" \
            || p "optional artisan command '$args' failed or is unavailable, continuing" 'yellow'
        ;;
    artisan:*)
        # artisan wrapper script already has ansi
        eval "/opt/docker/bin/service.d/laravel-artisan.sh ${command#artisan:}"
        ;;
    *)
        eval "$command" || p "exited with $?" 'red'
        ;;
esac
