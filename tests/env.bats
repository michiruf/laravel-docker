#!/usr/bin/env bats
# Regression tests for the .env synthesis (env:update / laravel-env.sh).
#
# These assert the *effective* value Laravel ends up with - the value
# vlucas/phpdotenv parses out of the generated file - not the file text.
# The distinction matters: an unquoted value containing whitespace makes
# phpdotenv reject the whole file, and '#' or '${...}' silently change the
# value, so a file that merely looks right can still break the application.
#
# Unlike the other suites this one needs no compose stack: it runs
# laravel-env.sh directly in a base-image container.

load 'helpers/common'

BASE_IMAGE=laravel-docker:base-test
# The base image plus phpdotenv, so the assertions parse the generated file
# exactly as Laravel would. Baked into the image rather than bind-mounted:
# composer runs as root and would leave a vendor tree the runner cannot clean.
IMAGE=laravel-docker:env-test

setup_file() {
    docker build --target base -t "$BASE_IMAGE" "$REPO_ROOT"
    docker build -t "$IMAGE" - <<EOF
FROM $BASE_IMAGE
ENV COMPOSER_ALLOW_SUPERUSER=1
RUN mkdir -p /dt && composer require vlucas/phpdotenv \
    --no-interaction --quiet --working-dir=/dt
EOF
}

teardown_file() {
    docker rmi -f "$IMAGE" "$BASE_IMAGE" || true
}

# fixture <example-contents> <current-env-contents>; prints the app directory
fixture() {
    local dir="$BATS_TEST_TMPDIR/app"
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '%s\n' "$1" > "$dir/.env.example"
    printf '%s\n' "$2" > "$dir/.env"
    echo "$dir"
}

# env_update <app-dir> [extra docker args...]
env_update() {
    local dir=$1
    shift
    docker run --rm -v "$dir:/app" "$@" --entrypoint bash "$IMAGE" -c '
        set -o errexit
        . /opt/docker/provision/entrypoint.d/10-prepare-env.sh >/dev/null
        /opt/docker/bin/laravel-env.sh >/dev/null'
}

# effective <app-dir> <key>; prints the value phpdotenv parses, or fails
effective() {
    docker run --rm -v "$1:/app" --entrypoint php "$IMAGE" -r '
        require "/dt/vendor/autoload.php";
        $r = Dotenv\Dotenv::createArrayBacked("/app")->load();
        echo array_key_exists($argv[1], $r) ? $r[$argv[1]] : "<missing>";' "$2"
}

@test "env: LARAVEL_ values with whitespace stay parseable and exact" {
    dir=$(fixture 'APP_NAME=Example' 'APP_NAME=Example')
    env_update "$dir" -e 'LARAVEL_APP_NAME=My Company'
    [ "$(effective "$dir" APP_NAME)" = 'My Company' ]
}

@test "env: LARAVEL_ values are not truncated at '#' or interpolated" {
    dir=$(fixture 'DB_PASSWORD=' 'DB_PASSWORD=')
    env_update "$dir" -e 'LARAVEL_DB_PASSWORD=pa#ss ${OTHER} x'
    [ "$(effective "$dir" DB_PASSWORD)" = 'pa#ss ${OTHER} x' ]
}

@test "env: an inline comment is not absorbed into a preserved value" {
    # phpdotenv reads 'Laravel' here; the comment must not become part of it
    dir=$(fixture 'APP_NAME=Example' 'APP_NAME=Laravel # trailing comment')
    env_update "$dir"
    [ "$(effective "$dir" APP_NAME)" = 'Laravel' ]
}

@test "env: '#' inside a quoted value is preserved" {
    dir=$(fixture 'A=x
B=x' 'A="My # App"
B='"'"'My # App'"'"'')
    env_update "$dir"
    [ "$(effective "$dir" A)" = 'My # App' ]
    [ "$(effective "$dir" B)" = 'My # App' ]
}

@test "env: a comment after a quoted value is not absorbed" {
    dir=$(fixture 'APP_NAME=Example' 'APP_NAME="My App" # note')
    env_update "$dir"
    [ "$(effective "$dir" APP_NAME)" = 'My App' ]
}

@test "env: escaped characters survive a round trip" {
    dir=$(fixture 'V=x' 'V="it'"'"'s \"q\" \\ \${VAR} end"')
    env_update "$dir"
    [ "$(effective "$dir" V)" = 'it'"'"'s "q" \ ${VAR} end' ]
}

@test "env: APP_KEY is preserved and repeated runs are idempotent" {
    dir=$(fixture 'APP_KEY=
APP_NAME=Example' 'APP_KEY=base64:AAAA/BBB+CCC=
APP_NAME=Example')
    env_update "$dir" -e 'LARAVEL_APP_NAME=My Company'
    first=$(cat "$dir/.env")

    env_update "$dir" -e 'LARAVEL_APP_NAME=My Company'
    env_update "$dir" -e 'LARAVEL_APP_NAME=My Company'
    [ "$(cat "$dir/.env")" = "$first" ]

    [ "$(effective "$dir" APP_KEY)" = 'base64:AAAA/BBB+CCC=' ]
    [ "$(effective "$dir" APP_NAME)" = 'My Company' ]
}
