#!/usr/bin/env sh
# shellcheck shell=sh
set -e
. /opt/docker/etc/print.sh # we must not load the current env to avoid any conflicts

# Names the container itself runs on. Replacing one of these breaks every
# command that runs afterwards, so they are refused rather than carried over.
is_reserved_name() {
    case $1 in
        PATH|HOME|USER|LOGNAME|SHELL|PWD|OLDPWD|IFS|TERM|HOSTNAME|LANG|LC_*|LD_*) return 0 ;;
        *) return 1 ;;
    esac
}

# Hand env vars matching a prefix to /etc/environment, so it can get read again by the
# /opt/docker/etc/laravel-env.sh script, which is sourced everywhere.
# The reason behind that is, that we create an alias for LARAVEL_ prefixed variables without
# that alias.
prepare_stripped_env() {
    prefix="$1"

    # sed only emits valid variable names, skipping e.g. continuation lines
    # of multiline values that happen to match the prefix
    printenv | sed -n "s/^\(${prefix}[A-Za-z0-9_]*\)=.*/\1/p" | sort -u | while IFS= read -r original_var_name; do
        var_name="${original_var_name#"$prefix"}"
        var_value=$(printenv "$original_var_name") || continue

        if is_reserved_name "$var_name"; then
            p "  refusing '$original_var_name', '$var_name' is reserved by the container" 'yellow'
            continue
        fi

        # Escape sed replacement metacharacters (\ & and the | delimiter), otherwise
        # values like generated passwords corrupt the .env or abort the substitution
        escaped_var_value=$(printf '%s' "$var_value" | sed "s/'/'\\\\''/g")
        printf "%s='%s'\n" "$var_name" "$escaped_var_value" >> /etc/environment
    done
}

p "> preparing and stripping docker environment for laravel (env with prefix 'LARAVEL_')" 'cyan'
prepare_stripped_env 'LARAVEL_'

# Source to export the envs regularly
. /opt/docker/etc/laravel-env.sh
