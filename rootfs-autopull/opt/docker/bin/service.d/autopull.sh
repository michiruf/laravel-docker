#!/usr/bin/env sh
# Autopull provisioning trigger, executed by cron every minute:
# - first run: clones GIT_URL and runs INITIAL_DEPLOY_COMMANDS + DEPLOY_COMMANDS
# - subsequent runs: fetches and runs DEPLOY_COMMANDS when upstream changed
# shellcheck shell=sh
set -e
. /opt/docker/etc/print.sh

# A deploy can easily take longer than the one-minute cron interval (initial
# clone + composer install). Hold an exclusive lock so overlapping cron ticks
# exit instead of running concurrent git/composer/artisan pipelines.
exec 9>/var/run/autopull.lock
flock -n 9 || exit 0

# Run a separator-delimited list of deploy commands: run_commands SEPARATOR LIST
run_commands() {
    IFS=$1; for command in $2; do
        p "> $command" 'cyan'
        /opt/docker/bin/service.d/deploy-command.sh "$command"
    done
}

perform_deploy=false

# Check if required GIT_URL exists
if [ -z "$GIT_URL" ]; then
    p 'GIT_URL is not set in the environment variables' 'red'
    exit 1
fi

cd "$APPLICATION_PATH"

# Flag the directory to be usable by both, root and the application user.
# This must happen on every run (not only on the initial clone): the config
# lives in the container filesystem while the repository lives on a volume,
# so a recreated container would otherwise fail all git commands with
# 'detected dubious ownership'.
git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$APPLICATION_PATH" \
    || git config --global --add safe.directory "$APPLICATION_PATH"

# Clone if there is no .git directory yet
if [ ! -d ".git" ]; then
    p "=> initial project setup, because '$APPLICATION_PATH/.git' does not exist" 'purple'

    if [ -n "$BRANCH" ]; then
        p "> clone repository with branch '$BRANCH'" 'cyan'
        git clone -b "$BRANCH" "$GIT_URL" .
    else
        p '> clone repository (remote default branch)' 'cyan'
        git clone "$GIT_URL" .
    fi
    echo 'Done'

    run_commands "$INITIAL_DEPLOY_COMMAND_SEPARATOR" "$INITIAL_DEPLOY_COMMANDS"

    perform_deploy=true
fi

# Check if there is no new stuff and then exit
# See https://stackoverflow.com/questions/3258243/check-if-pull-needed-in-git
git fetch
if [ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}')" ]; then
    p '=> detected changes in the git revision' 'purple'

    perform_deploy=true
fi

if [ "$perform_deploy" = true ] ; then
    p '=> performing deploy now' 'purple'

    run_commands "$DEPLOY_COMMAND_SEPARATOR" "$DEPLOY_COMMANDS"

    p '> adjust rights' 'cyan'
    chown -R "$APPLICATION_UID":"$APPLICATION_GID" .

    p '=> deploy completed' 'purple'
fi

exit 0
