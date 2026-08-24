#!/usr/bin/env bats
# Integration tests for the autopull variant, deploying the official Laravel
# skeleton (https://github.com/laravel/laravel) via git.
# Tests are ordered and share one compose stack (started in setup_file).

load 'helpers/common'

COMPOSE_PROJECT=ldk-autopull
COMPOSE_FILE="$REPO_ROOT/examples/autopull/compose.yml"

export GIT_URL=https://github.com/laravel/laravel.git
export BRANCH=
export HOST_PORT=8080
export MYSQL_ROOT_PASSWORD=test-root
export MYSQL_DATABASE=test
export MYSQL_USER=test
export MYSQL_PASSWORD=test

setup_file() {
    compose down -v --remove-orphans || true
    compose up -d --build
}

teardown_file() {
    compose down -v --remove-orphans
}

@test "autopull: container starts up" {
    wait_for_log 'syslogd entered RUNNING' 120
}

@test "autopull: initial provisioning completes" {
    wait_for_log '=> deploy completed' 600
}

@test "autopull: website is reachable" {
    assert_http_ok "http://localhost:$HOST_PORT"
}

@test "autopull: artisan is usable inside the container" {
    compose exec -T app /opt/docker/bin/laravel-artisan.sh --version
}

@test "autopull: no root-owned files in the application" {
    assert_no_root_owned_files
}

@test "autopull: supervisor programs are running, optional ones idle" {
    assert_supervisor_running laravel-scheduler
    assert_supervisor_running laravel-horizon
    assert_supervisor_running laravel-pulse
    # laravel/laravel ships neither horizon nor pulse, so both must idle
    wait_for_log "package 'laravel/horizon' is not installed, idling" 60
    wait_for_log "package 'laravel/pulse' is not installed, idling" 60
}

@test "autopull: application is configured from the container environment" {
    assert_configured_from_environment
}

@test "autopull: upstream change triggers a redeploy, APP_KEY is preserved" {
    app_key_before=$(app_key)

    # Rewind the checkout so it diverges from upstream; the next cron tick must redeploy
    compose exec -T app sh -c 'cd "$APPLICATION_PATH" && git reset --hard HEAD~1'
    wait_for_log '=> deploy completed' 240 2

    app_key_after=$(app_key)
    [ -n "$app_key_before" ]
    [ "$app_key_before" = "$app_key_after" ]
    assert_http_ok "http://localhost:$HOST_PORT"
}

@test "autopull: deploy command DSL semantics" {
    # '-' prefix skips
    run compose exec -T app /opt/docker/bin/run-command.sh -artisan:migrate
    [ "$status" -eq 0 ]
    [[ "$output" == *skipping* ]]

    # 'artisan?:' tolerates commands the application does not support
    run compose exec -T app /opt/docker/bin/run-command.sh 'artisan?:horizon:terminate'
    [ "$status" -eq 0 ]
    [[ "$output" == *optional* ]]

    # raw shell command failures propagate (abort the deploy, trigger a retry)
    run compose exec -T app /opt/docker/bin/run-command.sh 'false'
    [ "$status" -ne 0 ]

    # git:detect exits 1 when HEAD matches upstream (nothing to deploy)
    run compose exec -T app sh -c 'cd "$APPLICATION_PATH" && /opt/docker/bin/run-command.sh git:detect'
    [ "$status" -eq 1 ]
}
