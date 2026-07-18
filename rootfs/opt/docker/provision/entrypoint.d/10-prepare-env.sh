#!/usr/bin/env sh
# shellcheck shell=sh
set -e
. /opt/docker/etc/print.sh

# Append env vars matching a prefix to /etc/environment as properly
# single-quoted assignments, so values containing spaces or shell
# metacharacters survive being sourced by the other scripts.
append_env() {
    printenv | grep "^$1" | cut -d '=' -f 1 | sort -u | while IFS= read -r name; do
        # Skip tokens that are no valid variable names (e.g. continuation
        # lines of multiline values that happen to match the prefix)
        case $name in
            *[!A-Za-z0-9_]*|'') continue ;;
        esac
        value=$(printenv "$name") || continue
        escaped=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
        printf "%s='%s'\n" "$name" "$escaped" >> /etc/environment
    done
}

p "> preparing general docker environment" 'cyan'
append_env 'APPLICATION_'

p "> preparing docker environment for laravel (env with prefix 'LARAVEL_')" 'cyan'
append_env 'LARAVEL_'
