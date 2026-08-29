#!/usr/bin/env bats
# Integration tests for the autopull variant, deploying the official Laravel
# skeleton (https://github.com/laravel/laravel) via git.
# The last tests redeploy the same skeleton from a monorepo built for them, to
# cover GIT_SUBDIRECTORY. That fixture is copied into the app container and
# deployed from there, so the suite still needs no git server.
# Tests are ordered and share one compose stack (started in setup_file).

load 'helpers/common'

COMPOSE_PROJECT=ldk-autopull
COMPOSE_FILE="$REPO_ROOT/examples/autopull/compose.yml"

# The bare monorepo fixture is built in setup_file, but every bats test runs in
# its own process, so both paths are derived instead of exported
export MONOREPO_PATH="$BATS_FILE_TMPDIR/monorepo.git"
export MONOREPO_PATH_IN_CONTAINER=/srv/monorepo.git

# The active scenario (repository root, then the subdirectory, then the switch
# to a sibling one) is persisted so every bats test process exports the matching
# env for compose
SCENARIO=$([ -f "$BATS_FILE_TMPDIR/scenario" ] && cat "$BATS_FILE_TMPDIR/scenario" || echo root)
if [ "$SCENARIO" = root ]; then
    export GIT_URL=https://github.com/laravel/laravel.git
    export GIT_SUBDIRECTORY=
    export BRANCH=
else
    export GIT_URL="$MONOREPO_PATH_IN_CONTAINER"
    export GIT_SUBDIRECTORY=$([ "$SCENARIO" = switched ] && echo apps/web || echo apps/api)
    export BRANCH=main
fi

export HOST_PORT=8080
export MYSQL_ROOT_PASSWORD=test-root
export MYSQL_DATABASE=test
export MYSQL_USER=test
export MYSQL_PASSWORD=test

setup_file() {
    # Monorepo fixture for the GIT_SUBDIRECTORY tests: the Laravel skeleton in
    # 'apps/api', a sibling application that must stay out of the checkout (and
    # that the deploy can be switched to) and a file at the repository root that
    # cone mode keeps available.
    # 'apps/api' arrives in a second commit, so the checkout can be rewound to
    # before the subdirectory existed.
    local work="$BATS_FILE_TMPDIR/monorepo"
    local skeleton="$BATS_FILE_TMPDIR/skeleton"
    rm -rf "$work" "$MONOREPO_PATH" "$skeleton"
    git clone --depth 1 https://github.com/laravel/laravel.git "$skeleton"
    rm -rf "$skeleton/.git"

    mkdir -p "$work/apps"
    echo 'monorepo' > "$work/README.md"
    cp -r "$skeleton" "$work/apps/web"
    git -C "$work" init -q -b main
    git -C "$work" add -A
    git -C "$work" -c user.email=test@example.com -c user.name=test commit -q -m 'monorepo fixture'

    cp -r "$skeleton" "$work/apps/api"
    git -C "$work" add -A
    git -C "$work" -c user.email=test@example.com -c user.name=test commit -q -m 'add the api application'
    git clone -q --bare "$work" "$MONOREPO_PATH"

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
    completed_before=$(log_count '=> deploy completed')

    # Rewind the checkout so it diverges from upstream; the next cron tick must redeploy
    compose exec -T app sh -c 'cd "$APPLICATION_PATH" && git reset --hard HEAD~1'
    wait_for_log '=> deploy completed' 240 "$((completed_before + 1))"

    app_key_after=$(app_key)
    [ -n "$app_key_before" ]
    [ "$app_key_before" = "$app_key_after" ]
    assert_http_ok "http://localhost:$HOST_PORT"
}

@test "autopull: an unfinished deploy is resumed without an upstream change" {
    # A deploy that dies mid-run (failing command, crash, container recreate)
    # leaves the state file behind. git:detect cannot notice that on its own
    # once git:update already moved HEAD onto upstream.
    resuming_before=$(log_count '=> resuming previously unfinished deploy')
    completed_before=$(log_count '=> deploy completed')

    compose exec -T app sh -c 'echo deploy > "$APPLICATION_PATH/.git/autopull-state"'
    wait_for_log '=> resuming previously unfinished deploy' 240 "$((resuming_before + 1))"
    wait_for_log '=> deploy completed' 240 "$((completed_before + 1))"

    # a completed deploy clears the state again
    run compose exec -T app sh -c 'test -e "$APPLICATION_PATH/.git/autopull-state"'
    [ "$status" -ne 0 ]

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

@test "subdirectory: switching to GIT_SUBDIRECTORY provisions from scratch" {
    # Recreate the app container for the monorepo fixture; a fresh app-data
    # volume forces a full re-provision
    compose rm -sf app
    docker volume rm -f "${COMPOSE_PROJECT}_app-data"
    echo subdirectory > "$BATS_FILE_TMPDIR/scenario"
    export GIT_URL="$MONOREPO_PATH_IN_CONTAINER"
    export GIT_SUBDIRECTORY=apps/api
    export BRANCH=main

    # The fixture is copied into the container before it runs, so the first
    # cron tick already finds the repository the deploy pulls from. 'cp' keeps
    # the ownership of the test host, which git refuses to work with as root,
    # so the copy is handed over right after the start (a tick hitting the
    # container in between just retries a minute later).
    compose create app
    compose cp "$MONOREPO_PATH" "app:$MONOREPO_PATH_IN_CONTAINER"
    compose start app
    compose exec -T app chown -R root:root "$MONOREPO_PATH_IN_CONTAINER"

    # The recreated container starts with an empty log, so the first completed
    # deploy is the one of this scenario
    wait_for_log '=> deploy completed' 600
}

@test "subdirectory: the application lives in the subdirectory of the checkout" {
    compose exec -T app test -d /app/.git
    compose exec -T app test -f /app/apps/api/artisan
    compose exec -T app /opt/docker/bin/laravel-artisan.sh --version

    # the environment of the image resolves the moved paths
    run compose exec -T app sh -c '. /opt/docker/etc/laravel-env.sh; echo "$APPLICATION_PATH $WEB_DOCUMENT_ROOT"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"/app/apps/api /app/apps/api/public"* ]]
}

@test "subdirectory: the checkout is restricted to the subdirectory" {
    # cone mode keeps the files at the repository root, but not the sibling
    # application next to the deployed one
    compose exec -T app test -f /app/README.md
    run compose exec -T app test -e /app/apps/web
    [ "$status" -ne 0 ]
}

@test "subdirectory: website is served from the subdirectory" {
    assert_http_ok "http://localhost:$HOST_PORT"
}

@test "subdirectory: application is configured from the container environment" {
    assert_configured_from_environment
}

@test "subdirectory: no root-owned files in the whole checkout" {
    assert_no_root_owned_files
    local owners
    owners=$(compose exec -T app sh -c "find /app -exec ls -ld {} + | awk '{print \$3}' | sort -u")
    echo "owners found: $owners"
    [[ "$owners" != *root* ]]
}

@test "subdirectory: an upstream commit triggers a redeploy" {
    local completed_before
    completed_before=$(log_count '=> deploy completed')

    # The fixture lives in the container, so the commit is made there too
    compose exec -T app sh -c "
        rm -rf /srv/probe
        git clone -q --branch main '$MONOREPO_PATH_IN_CONTAINER' /srv/probe
        echo 'deployed change' > /srv/probe/apps/api/public/probe.txt
        git -C /srv/probe add -A
        git -C /srv/probe -c user.email=test@example.com -c user.name=test commit -q -m 'redeploy probe'
        git -C /srv/probe push -q"

    wait_for_log '=> deploy completed' 240 "$((completed_before + 1))"
    compose exec -T app grep -q 'deployed change' /app/apps/api/public/probe.txt
    assert_http_ok "http://localhost:$HOST_PORT"
}

@test "subdirectory: a subdirectory missing from the checkout is restored" {
    # The subdirectory only exists from the second fixture commit on, so a
    # checkout rewound to the root commit has no application directory while
    # the already fetched upstream ref has one. Refusing to continue there is
    # fatal rather than a retry: moving HEAD is part of the deploy, which the
    # refusal keeps the run from ever reaching.
    local completed_before restored_before initial_before
    completed_before=$(log_count '=> deploy completed')
    restored_before=$(log_count 'arrives with a newer revision')
    initial_before=$(log_count '=> performing initial provisioning now')

    # 'git reset' only drops the tracked files, so the deployed artifacts
    # (vendor, .env) have to go with them - they are what a first deploy into
    # the subdirectory would not have either
    compose exec -T app sh -c '
        cd /app
        git reset --hard "$(git rev-list --max-parents=0 HEAD)"
        rm -rf /app/apps/api'
    run compose exec -T app test -e /app/apps/api
    [ "$status" -ne 0 ]

    wait_for_log 'arrives with a newer revision' 240 "$((restored_before + 1))"

    # a subdirectory appearing for the first time has no vendor directory and
    # no .env, so it needs the initial commands, not a plain deploy
    wait_for_log '=> performing initial provisioning now' 240 "$((initial_before + 1))"
    wait_for_log '=> deploy completed' 600 "$((completed_before + 1))"

    compose exec -T app test -f /app/apps/api/artisan
    run compose exec -T app cat /app/apps/api/.env
    [[ "$output" == *"APP_KEY=base64:"* ]]
    assert_http_ok "http://localhost:$HOST_PORT"
}

@test "subdirectory: changing GIT_SUBDIRECTORY provisions the new application" {
    # Both subdirectories exist at the same revision, so the checkout the switch
    # lands on is up to date and no detect command can report the change - while
    # the application now deployed from it was never provisioned.
    # The volume is kept on purpose: the checkout, and with it the record of the
    # previously deployed subdirectory, has to survive the recreate.
    compose rm -sf app
    echo switched > "$BATS_FILE_TMPDIR/scenario"
    export GIT_URL="$MONOREPO_PATH_IN_CONTAINER"
    export GIT_SUBDIRECTORY=apps/web
    export BRANCH=main

    # The fixture lives in the container filesystem, not on a volume, so the
    # recreate drops it - and 'origin' would point at a path that no longer
    # exists, which fails every fetch from here on. It is copied in again the
    # same way the scenario before did it.
    compose create app
    compose cp "$MONOREPO_PATH" "app:$MONOREPO_PATH_IN_CONTAINER"
    compose start app
    compose exec -T app chown -R root:root "$MONOREPO_PATH_IN_CONTAINER"

    wait_for_log "the deployed subdirectory changed to 'apps/web'" 240
    wait_for_log '=> performing initial provisioning now' 240
    wait_for_log '=> deploy completed' 600

    # the new application is provisioned and served
    compose exec -T app test -f /app/apps/web/artisan
    run compose exec -T app cat /app/apps/web/.env
    [[ "$output" == *"APP_KEY=base64:"* ]]

    # the previous application left the checkout - only its tracked files, the
    # deploy artifacts (vendor, .env) are untracked and stay behind
    run compose exec -T app test -e /app/apps/api/artisan
    [ "$status" -ne 0 ]
    assert_http_ok "http://localhost:$HOST_PORT"
}

@test "subdirectory: an unchanged GIT_SUBDIRECTORY does not provision again" {
    local key_before
    key_before=$(app_key)

    # the record the comparison runs against
    run compose exec -T app cat /app/.git/autopull-subdirectory
    [ "$status" -eq 0 ]
    [[ "$output" == "apps/web" ]]

    # a further run must be a no-op: no switch, no initial provisioning and
    # above all the same APP_KEY, which an initial run would regenerate
    run compose exec -T app /opt/docker/bin/autopull.sh
    [ "$status" -eq 0 ]
    [[ "$output" != *'subdirectory changed'* ]]
    [[ "$output" != *'initial provisioning'* ]]
    [ "$(app_key)" = "$key_before" ]
}
