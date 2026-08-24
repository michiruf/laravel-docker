#!/usr/bin/env sh
# Regenerates the applications .env from its .env.example and injects every
# container env var prefixed with 'LARAVEL_' (prefix stripped) into it.
# Values already present in the current .env (notably the generated APP_KEY)
# are preserved unless overridden by a LARAVEL_* variable.
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
# Read a raw .env value the way phpdotenv does, so what we carry over is the
# value the application actually saw: a quoted value ends at its closing quote
# and whatever follows is a comment, an unquoted value ends at the first '#'
# and keeps no trailing whitespace. This also undoes the escaping applied when
# writing (see quote_env_value), so a value a previous run wrote comes back as
# the literal it stood for instead of gaining another layer of quotes.
unquote_env_value() {
    case $1 in
        \"*)
            # Hide escaped backslashes and quotes so the first '"' left is the
            # closing one, then restore them as the literal characters
            esc_bs=$(printf '\001')
            esc_dq=$(printf '\002')
            value=$(printf '%s' "$1" | sed -e "s/\\\\\\\\/$esc_bs/g" -e "s/\\\\\"/$esc_dq/g")
            value=${value#\"}
            value=${value%%\"*}
            printf '%s' "$value" | sed -e 's/\\\$/$/g' -e "s/$esc_dq/\"/g" -e "s/$esc_bs/\\\\/g"
            ;;
        \'*)
            # phpdotenv single quotes carry no escapes, so the next one closes
            value=${1#\'}
            printf '%s' "${value%%\'*}"
            ;;
        *)
            value=${1%%#*}
            printf '%s' "${value%"${value##*[![:space:]]}"}"
            ;;
    esac
}

# Laravel parses the .env with vlucas/phpdotenv, which only accepts bare values
# for a restricted character set: an unquoted value containing whitespace aborts
# parsing of the whole file, '#' truncates the value at the comment marker and
# '${...}' is interpolated. Anything outside that set is double-quoted with \, "
# and $ escaped — unlike phpdotenv single quotes, that form can also carry a
# literal single quote.
quote_env_value() {
    case $1 in
        *[!A-Za-z0-9_./:@%+,=-]*)
            printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"$]/\\&/g')" ;;
        *)
            printf '%s' "$1" ;;
    esac
}

if [ -f "$laravel_env_file" ]; then
    while IFS= read -r line; do
        name=${line%%=*}
        # Skip comments, empty lines and anything that is no valid variable name
        case $name in
            ''|*[!A-Za-z0-9_]*) continue ;;
        esac
        export "${prefix}${name}=$(unquote_env_value "${line#*=}")"
    done < "$laravel_env_file"

    set -a; . /etc/environment; set +a
fi

cp -f "$laravel_example_env_file" "$laravel_env_file"

# sed only emits valid variable names, skipping e.g. continuation lines
# of multiline values that happen to match the prefix
printenv | sed -n "s/^\(${prefix}[A-Za-z0-9_]*\)=.*/\1/p" | sort -u | while IFS= read -r original_var_name; do
    var_name="${original_var_name#"$prefix"}"
    var_value=$(printenv "$original_var_name") || continue

    # Quote first (for the dotenv parser), then escape sed replacement
    # metacharacters (\ & and the | delimiter), otherwise values like generated
    # passwords corrupt the .env or abort the substitution
    quoted_var_value=$(quote_env_value "$var_value")
    escaped_var_value=$(printf '%s' "$quoted_var_value" | sed 's/[\\&|]/\\&/g')

    # Anchored at line start so e.g. APP_NAME does not also match VITE_APP_NAME
    sed -i "s|^\(# \?\)\?$var_name=.*|$var_name=$escaped_var_value|" "$laravel_env_file"
done
