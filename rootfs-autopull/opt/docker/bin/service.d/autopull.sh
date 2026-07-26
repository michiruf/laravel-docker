#!/usr/bin/env sh
# Autopull provisioning trigger, executed by cron every minute:
# - first run: clones GIT_URL and runs INITIAL_DEPLOY_COMMANDS + DEPLOY_COMMANDS
# - subsequent runs: runs DEPLOY_COMMANDS when DETECT_COMMAND (default
#   git:detect) reports an update, retrying failed deploys on the next tick
# shellcheck shell=sh
set -e
. /opt/docker/etc/print.sh

# A deploy can easily take longer than the one-minute cron interval (initial
# clone + composer install). Hold an exclusive lock so overlapping cron ticks
# exit instead of running concurrent git/composer/artisan pipelines.
exec 9>/var/run/autopull.lock
flock -n 9 || exit 0

# Run a separator-delimited list of deploy commands: run_commands SEPARATOR LIST
# Returns the exit code of the first failing command. The explicit || return is
# required: when called inside an 'if', set -e is suspended and the loop would
# otherwise keep running past a failed step.
run_commands() {
    IFS=$1; for command in $2; do
        p "> $command" 'cyan'
        /opt/docker/bin/service.d/run-command.sh "$command" || return $?
    done
}

perform_deploy=false
failed_marker=/var/run/autopull.deploy-failed

# Check if required GIT_URL exists
if [ -z "$GIT_URL" ]; then
    p 'GIT_URL is not set in the environment variables' 'red'
    exit 1
fi

# Provision ssh credentials for private repositories (no-op when GIT_SSH_KEY
# is unset); sourced so the exported GIT_SSH_COMMAND applies to clone/fetch
. /opt/docker/bin/service.d/git-credentials.sh

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

    if ! run_commands "$INITIAL_DEPLOY_COMMAND_SEPARATOR" "$INITIAL_DEPLOY_COMMANDS"; then
        touch "$failed_marker"
        p '=> initial provisioning failed, retrying deploy on next run' 'red'
        exit 1
    fi

    perform_deploy=true
fi

# Check for an update via the detect command (default: git:detect, which
# fetches and compares HEAD against upstream). Exit code 0 means deploy.
# A leftover failure marker forces a retry of a previously failed deploy,
# which git:detect alone would miss once git:update already moved HEAD.
if [ "$perform_deploy" != true ]; then
    if [ -f "$failed_marker" ]; then
        p '=> retrying previously failed deploy' 'purple'

        perform_deploy=true
    elif /opt/docker/bin/service.d/run-command.sh "${DETECT_COMMAND:-git:detect}"; then
        p '=> detected changes in the git revision' 'purple'

        perform_deploy=true
    fi
fi

if [ "$perform_deploy" = true ] ; then
    p '=> performing deploy now' 'purple'

    if ! run_commands "$DEPLOY_COMMAND_SEPARATOR" "$DEPLOY_COMMANDS"; then
        touch "$failed_marker"
        p '=> deploy failed, retrying on next run' 'red'
        exit 1
    fi
    rm -f "$failed_marker"

    p '> adjust rights' 'cyan'
    chown -R "$APPLICATION_UID":"$APPLICATION_GID" .

    p '=> deploy completed' 'purple'
fi

exit 0
