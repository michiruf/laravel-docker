#!/usr/bin/env sh
# shellcheck shell=sh
set -e
. /opt/docker/etc/laravel-env.sh
# Autopull provisioning trigger, executed by cron every minute:
# - first run: clones GIT_URL and runs INITIAL_DEPLOY_COMMANDS + DEPLOY_COMMANDS
# - subsequent runs: runs DEPLOY_COMMANDS when DETECT_COMMAND (default
#   git:detect) reports an update, resuming unfinished deploys on the next tick

# A deploy can easily take longer than the one-minute cron interval (initial
# clone + composer install). Hold an exclusive lock so overlapping cron ticks
# exit instead of running concurrent git/composer/artisan pipelines.
exec 9>/var/run/autopull.lock
flock -n 9 || exit 0

# Run a separator-delimited list of deploy commands: run_commands SEPARATOR LIST
# Returns the exit code of the first failing command. The explicit || exit is
# required: when called inside an 'if', set -e is suspended and the loop would
# otherwise keep running past a failed step.
# The body is a subshell so the IFS needed for splitting stays contained.
run_commands() (
    IFS=$1
    for command in $2; do
        p "> $command" 'cyan'
        /opt/docker/bin/run-command.sh "$command" || exit $?
    done
)

# Pending work is tracked in a single state file: 'initial' is written right
# after the clone, 'deploy' before any deploy starts, and the file is removed
# once a deploy completed. An interrupted run therefore resumes at the right
# phase on the next tick, which git:detect alone could not do once git:update
# already moved HEAD.
# It lives inside .git, so it is tied to this checkout (on the application
# volume) rather than to the container: a deployment provisioned by an earlier
# image has no state file and is correctly treated as up to date, and a
# recreated container does not lose a pending deploy.
# With GIT_SUBDIRECTORY the application path points into the checkout, so the
# clone (and with it the state file) belongs to GIT_REPOSITORY_PATH.
repository_path=${GIT_REPOSITORY_PATH:-$APPLICATION_PATH}
state_file="$repository_path/.git/autopull-state"

# Keep the variable and the file in sync - the file is what survives a crash,
# the variable is what the rest of this run branches on.
# The file is written via a temporary file and renamed into place, so a crash
# mid-write leaves the previous state intact instead of a truncated file that
# would read as 'nothing pending'.
set_state() {
    state=$1
    echo "$1" > "$state_file.tmp"
    mv "$state_file.tmp" "$state_file"
}

# Check if required GIT_URL exists
if [ -z "$GIT_URL" ]; then
    p 'GIT_URL is not set in the environment variables' 'red'
    exit 1
fi

# Provision ssh credentials for private repositories (no-op when GIT_SSH_KEY
# is unset); sourced so the exported GIT_SSH_COMMAND applies to clone/fetch
. /opt/docker/bin/git-credentials.sh

cd "$repository_path"

# Flag the directory to be usable by both, root and the application user.
# This must happen on every run (not only on the initial clone): the config
# lives in the container filesystem while the repository lives on a volume,
# so a recreated container would otherwise fail all git commands with
# 'detected dubious ownership'.
git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$repository_path" \
    || git config --global --add safe.directory "$repository_path"

# Clone if there is no .git directory yet
if [ ! -d ".git" ]; then
    p "=> initial project setup, because '$repository_path/.git' does not exist" 'purple'

    if [ -n "$BRANCH" ]; then
        p "> clone repository with branch '$BRANCH'" 'cyan'
        git clone -b "$BRANCH" "$GIT_URL" .
    else
        p '> clone repository (remote default branch)' 'cyan'
        git clone "$GIT_URL" .
    fi
    echo 'Done'

    # Before anything else can fail: a clone without the state file would look
    # like a finished deployment on the next run and never be provisioned.
    set_state initial
fi

# Everything outside the deployed subdirectory is of no use to the application.
# Cone mode keeps the files at the top level of the repository, so shared root
# level tooling stays available. This runs on every tick, and 'set' is
# idempotent, so a changed GIT_SUBDIRECTORY reaches an existing checkout too.
if [ -n "$GIT_SUBDIRECTORY" ]; then
    git sparse-checkout set --cone "$GIT_SUBDIRECTORY"
fi

# A sparse checkout accepts directories that do not exist in the repository, so
# a mistyped GIT_SUBDIRECTORY would only show up as a bare 'cd' error once per
# minute. The next run retries, the directory may appear with a later commit.
if [ ! -d "$APPLICATION_PATH" ]; then
    p "the subdirectory '$GIT_SUBDIRECTORY' does not exist in the repository" 'red'
    exit 1
fi

# The detect and deploy commands belong to the application, not to the
# checkout: composer and artisan need the application directory, and git
# resolves the repository from it just as well.
cd "$APPLICATION_PATH"

# Reload the state after a possible clone. An absent (or unreadable, or
# truncated) file means 'nothing pending' and falls through to the detection
# below, which is the safe direction: at worst one deploy is detected late.
state=$(cat "$state_file" 2>/dev/null || true)

# Decide what this tick has to do:
# - 'initial': the initial commands are not a subset of DEPLOY_COMMANDS - they
#   generate the APP_KEY. Retrying them has to stay an initial run until they
#   succeed once: falling back to a plain deploy would leave the application
#   without a key while every following run reports a completed deploy.
# - 'deploy': a previous deploy did not finish, so pick it up again.
# - otherwise: ask the detect command (default: git:detect, which fetches and
#   compares HEAD against upstream). Exit code 0 means deploy.
if [ "$state" = initial ]; then
    p '=> performing initial provisioning now' 'purple'

    if ! run_commands "$INITIAL_DEPLOY_COMMAND_SEPARATOR" "$INITIAL_DEPLOY_COMMANDS"; then
        p '=> initial provisioning failed, retrying on next run' 'red'
        exit 1
    fi

    set_state deploy
elif [ "$state" = deploy ]; then
    p '=> resuming previously unfinished deploy' 'purple'
elif /opt/docker/bin/run-command.sh "${DETECT_COMMAND:-git:detect}"; then
    p '=> detected changes in the git revision' 'purple'

    set_state deploy
fi

if [ "$state" = deploy ]; then
    p '=> performing deploy now' 'purple'

    if ! run_commands "$DEPLOY_COMMAND_SEPARATOR" "$DEPLOY_COMMANDS"; then
        p '=> deploy failed, retrying on next run' 'red'
        exit 1
    fi
    rm -f "$state_file"

    p '> adjust rights' 'cyan'
    chown -R "$APPLICATION_UID":"$APPLICATION_GID" "$repository_path"

    p '=> deploy completed' 'purple'
fi

exit 0
