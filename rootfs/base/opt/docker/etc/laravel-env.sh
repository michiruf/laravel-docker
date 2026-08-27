#!/usr/bin/env sh
# shellcheck shell=sh
set -e
. /opt/docker/etc/print.sh

# Load prepared environment file containing aliases
# 'set -a' ensures they are treated as exported
# See https://superuser.com/a/1240860
set -a; . /etc/environment; set +a

# A subdirectory deploy (autopull with GIT_SUBDIRECTORY) clones the repository
# into the application volume and runs the application from a directory inside
# it, so both the application path and the document root move down there while
# the checkout itself stays reachable as GIT_REPOSITORY_PATH.
# Only the autopull stage declares the variable, and this file is also sourced
# by entrypoints running with 'set -u', hence the spelled out default.
if [ -n "${GIT_SUBDIRECTORY:-}" ]; then
  case $APPLICATION_PATH in
    # already derived: this file is sourced again in every child process, and
    # without the check the subdirectory would be appended once per level
    */"$GIT_SUBDIRECTORY") ;;
    *)
      export GIT_REPOSITORY_PATH="$APPLICATION_PATH"
      export APPLICATION_PATH="$APPLICATION_PATH/$GIT_SUBDIRECTORY"
      export WEB_DOCUMENT_ROOT="$APPLICATION_PATH/public"
      ;;
  esac
fi

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
