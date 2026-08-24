#!/usr/bin/env sh

# Debug function
p() {
    case $2 in
        red)    color='\033[0;31m' ;;
        yellow) color='\033[0;33m' ;;
        purple) color='\033[0;35m' ;;
        cyan)   color='\033[0;36m' ;;
        *)      color='' ;;
    esac

    printf '%b\n' "${color}${1}\033[0m"
}

# Load prepared environment file containing aliases
# 'set -a' ensures they are treated as exported
# See https://superuser.com/a/1240860
set -a; . /etc/environment; set +a

# Copy .env.example to .env if nonexistent
if [ -d "$APPLICATION_PATH" ]; then
  laravel_env_file=${APPLICATION_ENV_FILE:-"$APPLICATION_PATH/.env"}
  laravel_example_env_file=${APPLICATION_ENV_EXAMPLE_FILE:-"$APPLICATION_PATH/.env.example"}
  if [ ! -f "$laravel_env_file" ]; then
    if [ -f "$laravel_example_env_file" ]; then
        p "> creating '$laravel_env_file' from '$laravel_example_env_file'" 'cyan'
        cp "$laravel_example_env_file" "$laravel_env_file"
    else
        p "there is no '$laravel_example_env_file' to copy over yet, this might indicate a first time start" 'yellow'
    fi
  fi
fi
