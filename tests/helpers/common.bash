# Shared helpers for the integration test suites.
# Each suite sets COMPOSE_PROJECT and COMPOSE_FILE before using compose().

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

compose() {
    docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" "$@"
}

# Application directory inside the container. A plain 'docker exec' only sees
# the image default, so suites deploying a GIT_SUBDIRECTORY override this.
: "${APP_PATH:=/app}"

# Count how often the app service log contains a pattern so far.
log_count() {
    compose logs app 2>&1 | grep -c "$1" || true
}

# Wait until the app service log contains a pattern at least $3 times (default 1).
# Dumps the full log and fails on timeout.
wait_for_log() {
    local pattern=$1
    local timeout=${2:-300}
    local min_count=${3:-1}
    local waited=0
    until [ "$(compose logs app 2>&1 | grep -c "$pattern")" -ge "$min_count" ]; do
        if [ "$waited" -ge "$timeout" ]; then
            echo "timed out after ${timeout}s waiting for log pattern: $pattern (x$min_count)" >&2
            compose logs app >&2
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
}

# Expect an HTTP status in the 2xx/3xx range, retrying for up to 60s.
assert_http_ok() {
    local url=$1
    local status=0
    for _ in $(seq 1 60); do
        status=$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)
        if [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
            return 0
        fi
        sleep 1
    done
    echo "expected 2xx/3xx from $url, last status: $status" >&2
    compose logs app >&2
    return 1
}

# Print the APP_KEY line from the application's .env.
app_key() {
    compose exec -T app grep '^APP_KEY=' "$APP_PATH/.env"
}

# The application must be configured from the container environment. The
# LARAVEL_* variables are handed over as environment variables, so this asserts
# the value the application resolves - and that the .env holds a different one.
assert_configured_from_environment() {
    # Guard the assertions below: they only prove anything as long as the .env
    # itself carries different values. The skeleton ships 'DB_CONNECTION=sqlite'
    # and keeps DB_HOST commented out, so a resolved 'mysql' can only come from
    # the container environment. If upstream ever changes that, fail here
    # instead of silently asserting nothing.
    run compose exec -T app grep '^DB_CONNECTION=' "$APP_PATH/.env"
    [ "$status" -eq 0 ]
    [[ "$output" != *mysql* ]]

    run compose exec -T app sh -c "grep '^DB_HOST=' '$APP_PATH/.env' || true"
    [[ "$output" != *mysql* ]]

    run compose exec -T app /opt/docker/bin/laravel-artisan.sh config:show database.default
    [ "$status" -eq 0 ]
    [[ "$output" == *mysql* ]]

    run compose exec -T app /opt/docker/bin/laravel-artisan.sh config:show database.connections.mysql.host
    [ "$status" -eq 0 ]
    [[ "$output" == *mysql* ]]

    # the generated APP_KEY does still live in the .env
    run compose exec -T app cat "$APP_PATH/.env"
    [ "$status" -eq 0 ]
    [[ "$output" == *"APP_KEY=base64:"* ]]
}

# The whole application tree must be owned by the application user, not root.
assert_no_root_owned_files() {
    local owners
    owners=$(compose exec -T app sh -c "find '$APP_PATH' -exec ls -ld {} + | awk '{print \$3}' | sort -u")
    echo "owners found: $owners"
    [[ "$owners" != *root* ]]
}

# Supervisor must report the program as RUNNING (not FATAL/BACKOFF/EXITED).
assert_supervisor_running() {
    local program=$1
    local status
    status=$(compose exec -T app supervisorctl status "$program" || true)
    echo "$status"
    [[ "$status" == *RUNNING* ]]
}
