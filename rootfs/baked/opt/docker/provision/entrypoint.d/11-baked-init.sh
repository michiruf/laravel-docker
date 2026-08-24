#!/usr/bin/env sh
# Baked provisioning trigger, executed on every container start:
# - first run (empty application path): moves /app-src into place and generates the APP_KEY
# - every run: executes DEPLOY_COMMANDS
# shellcheck shell=sh
set -e
. /opt/docker/etc/laravel-env.sh

cd "$APPLICATION_PATH"

# Move project over if app directory empty and perform initial setups
if [ -z "$(ls -A "$APPLICATION_PATH")" ]; then
    p "=> initial project setup, because '$APPLICATION_PATH' was empty" 'purple'

    p "> make project source available in '$APPLICATION_PATH'" 'cyan'
    find /app-src -maxdepth 1 -mindepth 1 -exec mv {} "$APPLICATION_PATH" \;

    # The .env must exist before key:generate can write the APP_KEY into it
    p '> generate env file' 'cyan'
    /opt/docker/bin/run-command.sh env:update

    p '> generate app key' 'cyan'
    /opt/docker/bin/run-command.sh artisan:key:generate --force
fi

p '=> performing deploy now' 'purple'

# Split the command list in a subshell: the webdevops entrypoint sources this
# file rather than executing it, so an IFS left at the separator would leak into
# the entrypoint scripts running after us. The 20-php* ones iterate over
# unquoted $(envListVars ...) output, which needs the default IFS to split the
# one-name-per-line listing, and abort container startup otherwise.
(
    IFS=$DEPLOY_COMMAND_SEPARATOR
    for command in $DEPLOY_COMMANDS; do
        p "> $command" 'cyan'
        /opt/docker/bin/run-command.sh "$command"
    done
)

p '=> deploy completed' 'purple'
