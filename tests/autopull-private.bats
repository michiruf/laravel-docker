#!/usr/bin/env bats
# Integration tests for private repositories with the autopull variant.
# A local Gitea instance (tests/fixtures/private/compose.override.yml) hosts
# a private mirror of laravel/laravel; the suite deploys it over an ssh
# deploy key first, then switches the app container to an https token URL.
# Tests are ordered and share one compose stack (started in setup_file).

load 'helpers/common'

COMPOSE_PROJECT=ldk-private
COMPOSE_FILE="$REPO_ROOT/examples/autopull/compose.yml"
OVERLAY_FILE="$REPO_ROOT/tests/fixtures/private/compose.override.yml"

# Both compose files, same project
compose() {
    docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" -f "$OVERLAY_FILE" "$@"
}

export HOST_PORT=8082
export GITEA_HTTP_PORT=3300
export MYSQL_ROOT_PASSWORD=test-root
export MYSQL_DATABASE=test
export MYSQL_USER=test
export MYSQL_PASSWORD=test

GITEA_API=http://localhost:3300/api/v1

# The deployed branch is pinned explicitly (persisted by setup_file) instead
# of relying on the fixture's default-branch handling
if [ -f "$BATS_FILE_TMPDIR/branch" ]; then
    export BRANCH=$(cat "$BATS_FILE_TMPDIR/branch")
else
    export BRANCH=
fi

# The active scenario (ssh first, https after the switch) is persisted so
# every bats test process exports the matching env for compose calls
if [ -f "$BATS_FILE_TMPDIR/scenario" ] && [ "$(cat "$BATS_FILE_TMPDIR/scenario")" = https ]; then
    export GIT_URL="http://seeder:$(cat "$BATS_FILE_TMPDIR/token")@gitea:3000/seeder/laravel.git"
    export GIT_SSH_KEY=
else
    export GIT_URL=ssh://git@gitea/seeder/laravel.git
    if [ -f "$BATS_FILE_TMPDIR/deploy_key" ]; then
        GIT_SSH_KEY=$(base64 -w0 < "$BATS_FILE_TMPDIR/deploy_key")
    else
        GIT_SSH_KEY=
    fi
    export GIT_SSH_KEY
fi

gitea_api() {
    local method=$1 path=$2 data=${3:-}
    curl -fsS -X "$method" "$GITEA_API$path" \
        -H "Authorization: token $(cat "$BATS_FILE_TMPDIR/token")" \
        -H 'Content-Type: application/json' ${data:+-d "$data"}
}

setup_file() {
    compose down -v --remove-orphans || true

    ssh-keygen -t ed25519 -N '' -f "$BATS_FILE_TMPDIR/deploy_key" -q

    # Gitea up and seeded: admin user, token, private mirror of
    # laravel/laravel with matching default branch, read-only deploy key
    compose up -d gitea
    local i
    for i in $(seq 1 60); do
        curl -fsS http://localhost:3300/api/healthz >/dev/null 2>&1 && break
        sleep 2
    done
    curl -fsS http://localhost:3300/api/healthz >/dev/null

    for i in $(seq 1 5); do
        compose exec -T -u git gitea gitea admin user create --username seeder \
            --password secret123 --email seeder@example.com --admin \
            --must-change-password=false && break
        sleep 3
    done
    compose exec -T -u git gitea gitea admin user generate-access-token \
        --username seeder --scopes all --raw | tr -d '\r\n' > "$BATS_FILE_TMPDIR/token"

    gitea_api POST /user/repos '{"name":"laravel","private":true}' >/dev/null

    git clone --bare https://github.com/laravel/laravel.git "$BATS_FILE_TMPDIR/seed.git"
    git -C "$BATS_FILE_TMPDIR/seed.git" symbolic-ref --short HEAD > "$BATS_FILE_TMPDIR/branch"
    git -C "$BATS_FILE_TMPDIR/seed.git" push --mirror \
        "http://seeder:$(cat "$BATS_FILE_TMPDIR/token")@localhost:3300/seeder/laravel.git"

    gitea_api POST /repos/seeder/laravel/keys \
        "{\"title\":\"deploy\",\"key\":\"$(cat "$BATS_FILE_TMPDIR/deploy_key.pub")\",\"read_only\":true}" >/dev/null

    export BRANCH=$(cat "$BATS_FILE_TMPDIR/branch")
    export GIT_SSH_KEY=$(base64 -w0 < "$BATS_FILE_TMPDIR/deploy_key")
    compose up -d --build
}

teardown_file() {
    compose down -v --remove-orphans
}

@test "private ssh: repository rejects anonymous access" {
    run curl -fsS -o /dev/null "http://localhost:3300/seeder/laravel.git/info/refs?service=git-upload-pack"
    [ "$status" -ne 0 ]
}

@test "private ssh: initial deploy over the deploy key completes" {
    wait_for_log 'syslogd entered RUNNING' 120
    wait_for_log '=> deploy completed' 600
}

@test "private ssh: website is reachable" {
    assert_http_ok "http://localhost:$HOST_PORT"
}

@test "private ssh: origin points at the ssh fixture URL" {
    run compose exec -T app sh -c 'git -C "$APPLICATION_PATH" remote get-url origin'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ssh://git@gitea"* ]]
}

@test "private ssh: upstream push triggers a redeploy" {
    local work="$BATS_FILE_TMPDIR/push-probe"
    rm -rf "$work"
    git clone --branch "$BRANCH" \
        "http://seeder:$(cat "$BATS_FILE_TMPDIR/token")@localhost:3300/seeder/laravel.git" "$work"
    git -C "$work" -c user.email=test@example.com -c user.name=test \
        commit --allow-empty -m 'redeploy probe'
    git -C "$work" push
    wait_for_log '=> deploy completed' 240 2
    assert_http_ok "http://localhost:$HOST_PORT"
}

@test "private ssh: strict host key pinning is honored" {
    local hostline
    hostline=$(compose exec -T app ssh-keyscan -t ed25519 gitea 2>/dev/null)
    compose exec -T -e GIT_SSH_KNOWN_HOSTS="$hostline" app sh -c \
        '. /opt/docker/etc/print.sh; . /opt/docker/bin/service.d/git-credentials.sh && git ls-remote "$GIT_URL" HEAD >/dev/null'
    run compose exec -T -e GIT_SSH_KNOWN_HOSTS='gitea ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' app sh -c \
        '. /opt/docker/etc/print.sh; . /opt/docker/bin/service.d/git-credentials.sh && git ls-remote "$GIT_URL" HEAD >/dev/null'
    [ "$status" -ne 0 ]
}

@test "private https: switching to a token URL provisions from scratch" {
    # Recreate the app container with the https token URL and no ssh key;
    # a fresh app-data volume forces a full re-provision
    compose rm -sf app
    docker volume rm -f "${COMPOSE_PROJECT}_app-data"
    echo https > "$BATS_FILE_TMPDIR/scenario"
    export GIT_URL="http://seeder:$(cat "$BATS_FILE_TMPDIR/token")@gitea:3000/seeder/laravel.git"
    export GIT_SSH_KEY=
    compose up -d app
    wait_for_log '=> deploy completed' 600
}

@test "private https: website is reachable and origin is the token URL" {
    assert_http_ok "http://localhost:$HOST_PORT"
    run compose exec -T app sh -c 'git -C "$APPLICATION_PATH" remote get-url origin'
    [ "$status" -eq 0 ]
    [[ "$output" == *"@gitea:3000/seeder/laravel.git"* ]]
}
