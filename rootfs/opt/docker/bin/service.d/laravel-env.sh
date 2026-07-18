#!/usr/bin/env sh
# Regenerates the applications .env from its .env.example and injects every
# container env var prefixed with 'LARAVEL_' (prefix stripped) into it.
# Values already present in the current .env (notably the generated APP_KEY)
# are preserved unless overridden by a LARAVEL_* variable.
# shellcheck shell=sh
# shellcheck disable=SC1090 # disable 'cannot follow non constant source' because it just works
set -e
. /opt/docker/etc/print.sh

# Load environment file
# 'set -a' ensures they are treated as exported
# See https://superuser.com/a/1240860
set -a; . /etc/environment; set +a

prefix="LARAVEL_"
laravel_env_file=${APPLICATION_ENV_FILE:-"$APPLICATION_PATH/.env"}
laravel_example_env_file=${APPLICATION_ENV_EXAMPLE_FILE:-"$APPLICATION_PATH/.env.example"}

p "> generating '$laravel_env_file' from '$laravel_example_env_file'" 'cyan'
if [ ! -f "$laravel_example_env_file" ]; then
    p "there is no '$laravel_example_env_file' to copy over, exiting" 'red'
    exit 1
fi

# If the laravel env file already exists, load it first so we do not lose any values like the APP_KEY
# But then we need to merge theses values with the env from docker again
# To do so we prepend the values from the laravel env file with the prefix and then just overwrite them
# with the existing ones from docker by loading this file again
# We could also go the other way around and just take the env without prefixing first, but we introduced
# the prefix to not have any collision in environment variables and should stay with this approach
if [ -f "$laravel_env_file" ]; then
    while IFS= read -r line; do
        name=${line%%=*}
        value=${line#*=}
        # Skip comments, empty lines and anything that is no valid variable name
        case $name in
            ''|\#*|*[!A-Za-z0-9_]*) continue ;;
        esac
        export "${prefix}${name}=${value}"
    done < "$laravel_env_file"

    set -a; . /etc/environment; set +a
fi

cp -f "$laravel_example_env_file" "$laravel_env_file"

printenv | grep "^${prefix}" | cut -d '=' -f 1 | sort -u | while IFS= read -r original_var_name; do
    # Skip tokens that are no valid variable names (e.g. continuation lines
    # of multiline values that happen to match the prefix)
    case $original_var_name in
        ''|*[!A-Za-z0-9_]*) continue ;;
    esac
    var_name="${original_var_name#"$prefix"}"
    var_value=$(printenv "$original_var_name") || continue

    # Escape sed replacement metacharacters (\ & and the | delimiter), otherwise
    # values like generated passwords corrupt the .env or abort the substitution
    escaped_var_value=$(printf '%s' "$var_value" | sed 's/[\\&|]/\\&/g')

    # Anchored at line start so e.g. APP_NAME does not also match VITE_APP_NAME
    sed -i "s|^\(# \?\)\?$var_name=.*|$var_name=$escaped_var_value|" "$laravel_env_file"
done

exit 0
