#!/usr/bin/env sh
# shellcheck shell=sh
set -e
. /opt/docker/etc/print.sh

# Append env vars matching a prefix to /etc/environment as properly
# single-quoted assignments, so values containing spaces or shell
# metacharacters survive being sourced by the other scripts.
append_env() {
    # sed only emits valid variable names and, unlike grep, exits 0 when
    # nothing matches — this script is sourced by the webdevops entrypoint
    # under 'set -o pipefail -o errexit', where a no-match grep would kill
    # the whole container startup
    printenv | sed -n "s/^\($1[A-Za-z0-9_]*\)=.*/\1/p" | sort -u | while IFS= read -r name; do
        value=$(printenv "$name") || continue
        escaped=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
        printf "%s='%s'\n" "$name" "$escaped" >> /etc/environment
    done
}

p "> preparing general docker environment" 'cyan'
append_env 'APPLICATION_'

p "> preparing docker environment for laravel (env with prefix 'LARAVEL_')" 'cyan'
append_env 'LARAVEL_'
