#!/usr/bin/env sh
# shellcheck shell=sh
set -e
. /opt/docker/etc/laravel-env.sh
# Command dispatcher: executes a single command token from the DSL
# (deploy steps, detect commands). See the README for the full reference.

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
    git:detect)
        # Exit 0 when upstream moved past HEAD (deploy needed), 1 otherwise.
        # Owns the fetch so custom detect commands can fetch differently.
        git fetch
        [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]
        ;;
    git:update)
        current_branch=$(git symbolic-ref --short HEAD)
        git reset --hard "origin/$current_branch"
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
        eval "/opt/docker/bin/laravel-artisan.sh $args" \
            || p "optional artisan command '$args' failed or is unavailable, continuing" 'yellow'
        ;;
    artisan:key:generate*)
        # An APP_KEY is generated once and then kept
        env_file=${APPLICATION_ENV_FILE:-"$APPLICATION_PATH/.env"}
        env_key=$(sed -n 's/^APP_KEY=//p' "$env_file" 2>/dev/null | tail -n1 | tr -d "\"' ")
        if [ -n "${APP_KEY:-}" ] || [ -n "$env_key" ]; then
            p 'the application has an APP_KEY already, skipping the key generation' 'yellow'
        else
            eval "/opt/docker/bin/laravel-artisan.sh ${command#artisan:}"
        fi
        ;;
    artisan:*)
        # artisan wrapper script already has ansi
        eval "/opt/docker/bin/laravel-artisan.sh ${command#artisan:}"
        ;;
    *)
        eval "$command"
        ;;
esac
