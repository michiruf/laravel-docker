#!/usr/bin/env sh
# Autopull provisioning trigger, executed by cron every minute:
# - first run: clones GIT_URL and runs INITIAL_DEPLOY_COMMANDS + DEPLOY_COMMANDS
# - subsequent runs: fetches and runs DEPLOY_COMMANDS when upstream changed
# shellcheck shell=sh
set -e
. /opt/docker/etc/print.sh

perform_deploy=false

# Check if required GIT_URL exists
if [ -z "$GIT_URL" ]; then
    p 'GIT_URL is not set in the environment variables' 'red'
    exit 1
fi

cd "$APPLICATION_PATH"

# Clone if there is no .git directory yet
if [ ! -d ".git" ]; then
    p "=> initial project setup, because '$APPLICATION_PATH/.git' does not exist" 'purple'

    # Flag the directory to be usable by both, root and the application user
    git config --global --add safe.directory "$APPLICATION_PATH"

    if [ -n "$BRANCH" ]; then
        p "> clone repository with branch '$BRANCH'" 'cyan'
        git clone -b "$BRANCH" "$GIT_URL" .
    else
        p '> clone repository (remote default branch)' 'cyan'
        git clone "$GIT_URL" .
    fi
    echo 'Done'

    IFS=$INITIAL_DEPLOY_COMMAND_SEPARATOR; for command in $INITIAL_DEPLOY_COMMANDS; do
        p "> $command" 'cyan'
        /opt/docker/bin/service.d/deploy-command.sh "$command"
    done

    perform_deploy=true
fi

# Check if there is no new stuff and then exit
# See https://stackoverflow.com/questions/3258243/check-if-pull-needed-in-git
git fetch
if [ "$(git rev-parse HEAD)" != "$(git rev-parse @\{u\})" ]; then
    p '=> detected changes in the git revision' 'purple'

    perform_deploy=true
fi

if [ "$perform_deploy" = true ] ; then
    p '=> performing deploy now' 'purple'

    IFS=$DEPLOY_COMMAND_SEPARATOR; for command in $DEPLOY_COMMANDS; do
        p "> $command" 'cyan'
        /opt/docker/bin/service.d/deploy-command.sh "$command"
    done

    p '> adjust rights' 'cyan'
    chown -R "$APPLICATION_UID":"$APPLICATION_GID" .

    p '=> deploy completed' 'purple'
fi

exit 0
