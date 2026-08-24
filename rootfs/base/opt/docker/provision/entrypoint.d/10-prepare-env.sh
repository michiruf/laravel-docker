#!/usr/bin/env sh
# shellcheck shell=sh
set -e
. /opt/docker/etc/print.sh

# Names the container itself runs on. Replacing one of these breaks every
# command that runs afterwards, so they are refused rather than carried over.
is_reserved_name() {
    case $1 in
        PATH|HOME|USER|LOGNAME|SHELL|PWD|OLDPWD|IFS|TERM|HOSTNAME|LANG|LC_*|LD_*) return 0 ;;
        *) return 1 ;;
    esac
}

# Append env vars matching a prefix to /etc/environment as properly
# single-quoted assignments, so values containing spaces or shell
# metacharacters survive being sourced by the other scripts.
prepare_stripped_env() {
    # sed only emits valid variable names and, unlike grep, exits 0 when
    # nothing matches — this script is sourced by the webdevops entrypoint
    # under 'set -o pipefail -o errexit', where a no-match grep would kill
    # the whole container startup
    printenv | sed -n "s/^\($1[A-Za-z0-9_]*\)=.*/\1/p" | sort -u | while IFS= read -r name; do
        if is_reserved_name "${name#"$1"}"; then
            p "  refusing '$name', '${name#"$1"}' is reserved by the container" 'yellow'
            continue
        fi

        value=$(printenv "$name") || continue
        escaped=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
        printf "%s='%s'\n" "$name" "$escaped" >> /etc/environment
    done
}

p "> preparing and stripping docker environment for laravel (env with prefix 'LARAVEL_')" 'cyan'
prepare_stripped_env 'LARAVEL_'
