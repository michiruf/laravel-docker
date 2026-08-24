#!/usr/bin/env bats
# Integration tests for the baked variant: the official Laravel skeleton is
# cloned at test time, built into a consumer image using the documented
# 3-line Dockerfile, and provisioned on first container start.
# Tests are ordered and share one compose stack (started in setup_file).

load 'helpers/common'

COMPOSE_PROJECT=ldk-baked
COMPOSE_FILE="$REPO_ROOT/examples/baked/compose.yml"

export APP_CONTEXT="${BATS_TMPDIR:-/tmp}/ldk-baked-app"
export HOST_PORT=8081
export MYSQL_ROOT_PASSWORD=test-root
export MYSQL_DATABASE=test
export MYSQL_USER=test
export MYSQL_PASSWORD=test

setup_file() {
    # The consumer image builds FROM the local baked starter image
    docker build --target baked -t laravel-docker:baked "$REPO_ROOT"

    rm -rf "$APP_CONTEXT"
    git clone --depth 1 https://github.com/laravel/laravel "$APP_CONTEXT"
    cp "$REPO_ROOT/examples/baked/Dockerfile" "$APP_CONTEXT/Dockerfile"

    compose down -v --remove-orphans || true
    compose up -d --build
}

teardown_file() {
    compose down -v --remove-orphans
    rm -rf "$APP_CONTEXT"
}

@test "baked: container starts up" {
    wait_for_log 'syslogd entered RUNNING' 120
}

@test "baked: first-start provisioning completes" {
    wait_for_log '=> initial project setup' 60
    wait_for_log '=> deploy completed' 600
}

@test "baked: website is reachable" {
    assert_http_ok "http://localhost:$HOST_PORT"
}

@test "baked: artisan is usable inside the container" {
    compose exec -T app /opt/docker/bin/laravel-artisan.sh --version
}

@test "baked: no root-owned files in the application" {
    assert_no_root_owned_files
}

@test "baked: supervisor programs are running, optional ones idle" {
    assert_supervisor_running laravel-scheduler
    assert_supervisor_running laravel-horizon
    assert_supervisor_running laravel-pulse
    wait_for_log "package 'laravel/horizon' is not installed, idling" 60
    wait_for_log "package 'laravel/pulse' is not installed, idling" 60
}

@test "baked: provisioning synthesized .env from container environment" {
    assert_env_synthesized
}

@test "baked: restart re-provisions idempotently, APP_KEY is preserved" {
    app_key_before=$(app_key)

    compose restart app
    wait_for_log '=> deploy completed' 240 2

    # The initial setup must not run again (application path is populated)
    [ "$(compose logs app | grep -c '=> initial project setup')" -eq 1 ]

    app_key_after=$(app_key)
    [ -n "$app_key_before" ]
    [ "$app_key_before" = "$app_key_after" ]
    assert_http_ok "http://localhost:$HOST_PORT"
}
