# Shared helpers for the integration test suites.
# Each suite sets COMPOSE_PROJECT and COMPOSE_FILE before using compose().

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

compose() {
    docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" "$@"
}

# Wait until the app service log contains a pattern at least $3 times (default 1).
# Dumps the full log and fails on timeout.
wait_for_log() {
    local pattern=$1
    local timeout=${2:-300}
    local min_count=${3:-1}
    local waited=0
    while true; do
        if [ "$(compose logs app 2>&1 | grep -c "$pattern")" -ge "$min_count" ]; then
            return 0
        fi
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

# The whole application tree must be owned by the application user, not root.
assert_no_root_owned_files() {
    local owners
    owners=$(compose exec -T app sh -c 'find "$APPLICATION_PATH" -exec ls -ld {} + | awk "{print \$3}" | sort -u')
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
