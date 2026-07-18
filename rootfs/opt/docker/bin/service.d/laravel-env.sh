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
    # shellcheck disable=SC2013 # word-splitting per line is intended (values contain no spaces)
    for laravel_env in $(grep -v '^#' < "$laravel_env_file"); do
        eval "${prefix}${laravel_env}=\$$laravel_env"
        export "${prefix}${laravel_env}"
    done

    set -a; . /etc/environment; set +a
fi

cp -f "$laravel_example_env_file" "$laravel_env_file"

for line in $(printenv | grep "^${prefix}"); do
    original_var_name=$(echo "$line" | cut -d '=' -f 1)
    var_name="${original_var_name#"$prefix"}"
    var_value=$(printenv "$original_var_name")

    # Escape sed replacement metacharacters (\ & and the | delimiter), otherwise
    # values like generated passwords corrupt the .env or abort the substitution
    escaped_var_value=$(printf '%s' "$var_value" | sed 's/[\\&|]/\\&/g')

    sed -i "s|\(# \?\)\?$var_name=.*|$var_name=$escaped_var_value|g" "$laravel_env_file"
done

exit 0
