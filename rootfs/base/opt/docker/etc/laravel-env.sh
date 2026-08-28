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
# by entrypoints running with 'set -u', hence the spelled out defaults.
# GIT_REPOSITORY_PATH doubles as the marker that the paths were derived
# already: this file is sourced again in every child process, and deriving
# twice would append the subdirectory once per level.
if [ -n "${GIT_SUBDIRECTORY:-}" ] && [ -z "${GIT_REPOSITORY_PATH:-}" ]; then
  # A document root that was configured explicitly is left alone; only the
  # default one follows the application. Both still read the path of the
  # checkout here, the application path moves last.
  if [ "${WEB_DOCUMENT_ROOT:-}" = "$APPLICATION_PATH/public" ]; then
    export WEB_DOCUMENT_ROOT="$APPLICATION_PATH/$GIT_SUBDIRECTORY/public"
  fi
  export GIT_REPOSITORY_PATH="$APPLICATION_PATH"
  export APPLICATION_PATH="$APPLICATION_PATH/$GIT_SUBDIRECTORY"
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
