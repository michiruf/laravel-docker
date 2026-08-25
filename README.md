# Laravel Docker

[![Test](https://github.com/michiruf/laravel-docker/actions/workflows/test.yml/badge.svg)](https://github.com/michiruf/laravel-docker/actions/workflows/test.yml)
[![Publish Docker Images](https://github.com/michiruf/laravel-docker/actions/workflows/publish.yml/badge.svg)](https://github.com/michiruf/laravel-docker/actions/workflows/publish.yml)

Production container images for Laravel applications, built on
[webdevops/php-nginx](https://dockerfile.readthedocs.io/en/latest/content/DockerImages/dockerfiles/php-nginx.html)
(nginx + php-fpm + supervisor, alpine).

The heavy lifting these images do is **provisioning**: getting your application
installed, configured and migrated inside the container — on first start and on
every subsequent deploy — driven entirely by environment variables.

## Variants

| Image                                      | Deployment model                                                                                   |
|--------------------------------------------|----------------------------------------------------------------------------------------------------|
| `ghcr.io/michiruf/laravel:base-latest`     | Provisioning engine only, no deploy trigger. Extend it for custom variants.                        |
| `ghcr.io/michiruf/laravel:autopull-latest` | Pulls a git repository and redeploys automatically when upstream changes (cron, every minute).     |
| `ghcr.io/michiruf/laravel:baked-latest`    | Starter image: copy your application in at build time, provisioning runs on first container start. |

## Quickstart: baked

Add a `Dockerfile` to your Laravel application:

```dockerfile
FROM ghcr.io/michiruf/laravel:baked-latest
COPY --chown=$APPLICATION_UID:$APPLICATION_GID . /app-src
RUN cd /app-src \
    && composer install --no-dev --no-progress --optimize-autoloader --ansi \
    && chown -R "$APPLICATION_UID":"$APPLICATION_GID" /app-src
```

Building the application is up to you: adjust the composer flags or add asset
builds as your application needs them. `--no-dev` keeps development
dependencies out of the image; drop it if your application needs them at
runtime.

Build and run it (see [examples/baked/compose.yml](examples/baked/compose.yml)
for a full stack with mysql and redis). On first start the application is moved
into place, an `APP_KEY` is generated and the deploy commands run.

## Quickstart: autopull

```sh
cd examples/autopull
cp .env.example .env   # set GIT_URL (+ credentials for mysql)
docker compose up -d
```

The container clones `GIT_URL` (branch `BRANCH`, or the remote default branch if
empty), provisions the application, and from then on checks upstream every
minute — a push to the repository is live one cron tick later.
See [examples/autopull/compose.yml](examples/autopull/compose.yml).

## Provisioning

Both variants run the same pipeline:

```
trigger (first start / new commit)
  → INITIAL_DEPLOY_COMMANDS   (autopull first provision only)
  → DEPLOY_COMMANDS           (every deploy)
  → ownership normalization   (APPLICATION_UID:APPLICATION_GID)
  → "=> deploy completed"     (log marker, usable for monitoring/tests)
```

### Deploy command DSL

`DEPLOY_COMMANDS` (and `INITIAL_DEPLOY_COMMANDS`) are lists of command tokens,
split by `DEPLOY_COMMAND_SEPARATOR` (default `;`):

| Token             | Action                                                                                                                     |
|-------------------|----------------------------------------------------------------------------------------------------------------------------|
| `-<anything>`     | Skipped. Disable a single default without redefining the whole list.                                                       |
| `git:detect`      | `git fetch`, then exit 0 when upstream moved past HEAD (deploy needed), 1 otherwise. Default `DETECT_COMMAND`.             |
| `git:update`      | `git reset --hard origin/<current branch>`                                                                                 |
| `composer:<args>` | Run composer, e.g. `composer:install --no-progress`                                                                        |
| `artisan:<args>`  | Run artisan (guarded: fails when the app is not provisioned yet)                                                           |
| `artisan?:<args>` | Optional artisan command: logs and continues when unsupported, e.g. `artisan?:horizon:terminate` on an app without horizon |
| `permissions:fix` | `chown -R $APPLICATION_UID:$APPLICATION_GID .`                                                                             |
| anything else     | Executed as raw shell (escape hatch)                                                                                       |

A failing command aborts the deploy; the run is retried on the next cron tick
until a deploy completes. Autopull records the pending phase in
`.git/autopull-state` on the application volume, so a deploy interrupted by a
crash or a container recreate is resumed as well. Tolerate an expected failure
explicitly with `artisan?:` or a `<command> || true` shell suffix.

### Update detection (`DETECT_COMMAND`)

Every cron tick, autopull runs `DETECT_COMMAND` (any DSL token, default
`git:detect`) — exit code 0 triggers a deploy. Override it to customize what
counts as an update, e.g. only changes under a subpath of a monorepo:

```yaml
DETECT_COMMAND: git fetch && ! git diff --quiet HEAD @{u} -- apps/api
```

The detect command owns its own `git fetch` (so a tag-based detector can fetch
tags instead); the built-in `git:detect` fetches and compares HEAD against
upstream.

The defaults for all three variants are defined in the [Dockerfile](Dockerfile).
Override the whole list via the environment, or prefix single commands with `-`
to disable them.

### Configuration from the container environment

Every container environment variable prefixed with `LARAVEL_` is exported with
the prefix stripped into every process the container runs: `LARAVEL_DB_HOST=mysql`
on the container becomes `DB_HOST=mysql` for php-fpm, artisan and the deploy
commands. Names that are not valid shell identifiers, or that the container
itself runs on (`PATH`, `HOME`, `LANG`, …), are refused and logged.

The application `.env` is never rewritten. It is only copied from `.env.example`
when it does not exist yet, so `artisan key:generate` has a file to write the
`APP_KEY` into. Laravel does not let the `.env` override variables that are
already set, so the container environment wins over any value the `.env` carries.

Result: application configuration lives entirely in your compose file or
orchestrator; no `.env` files to manage on servers.

### Auto-detected workers

Supervisor ships three programs; each waits until the application is
provisioned, then starts — or idles cleanly when the application does not use
the package (re-checking periodically, so a deploy that adds the package starts
the worker without a container restart):

| Program             | Runs                    | Requires                    |
|---------------------|-------------------------|-----------------------------|
| `laravel-scheduler` | `artisan schedule:work` | —                           |
| `laravel-horizon`   | `artisan horizon`       | `laravel/horizon` installed |
| `laravel-pulse`     | `artisan pulse:check`   | `laravel/pulse` installed   |

A plain `laravel/laravel` skeleton therefore runs with zero configuration.

## Environment reference

| Variable                                                                         | Default                      | Purpose                                                                                                                                                      |
|----------------------------------------------------------------------------------|------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `GIT_URL`                                                                        | — (required, autopull)       | Repository to deploy (https or ssh)                                                                                                                          |
| `BRANCH`                                                                         | empty (autopull)             | Branch to deploy; empty uses the remote default branch                                                                                                       |
| `GIT_SSH_KEY`                                                                    | empty (autopull)             | Private deploy key for ssh URLs, raw PEM or base64                                                                                                           |
| `GIT_SSH_KNOWN_HOSTS`                                                            | empty (autopull)             | Pinned host key line(s); empty trusts on first use                                                                                                           |
| `DETECT_COMMAND`                                                                 | `git:detect`                 | DSL token deciding whether to deploy (exit 0 = deploy)                                                                                                       |
| `DEPLOY_COMMANDS`                                                                | see [Dockerfile](Dockerfile) | Commands run on every deploy                                                                                                                                 |
| `DEPLOY_COMMAND_SEPARATOR`                                                       | `;`                          | Token separator                                                                                                                                              |
| `INITIAL_DEPLOY_COMMANDS`                                                        | see [Dockerfile](Dockerfile) | Commands run on first provision (autopull)                                                                                                                   |
| `INITIAL_DEPLOY_COMMAND_SEPARATOR`                                               | `;`                          | Token separator                                                                                                                                              |
| `LARAVEL_*`                                                                      | —                            | Exported into the application environment (prefix stripped)                                                                                                  |
| `APPLICATION_PATH`, `APPLICATION_UID`, `APPLICATION_GID`, `WEB_DOCUMENT_ROOT`, … |                              | Inherited from the [webdevops base image](https://dockerfile.readthedocs.io/en/latest/content/DockerImages/dockerfiles/php-nginx.html#environment-variables) |

## Extending

Need PHP extensions or system packages? Extend the published image:

```dockerfile
FROM ghcr.io/michiruf/laravel:autopull-latest
RUN set -x \
  && apk-install $PHPIZE_DEPS linux-headers imap-dev openssl-dev krb5-dev \
  && pecl install imap \
  && docker-php-ext-enable imap \
  && apk del -f --purge $PHPIZE_DEPS linux-headers imap-dev openssl-dev krb5-dev
```

## Private repositories (autopull)

Two supported mechanisms:

**HTTPS token in the URL** — no configuration beyond the URL itself:

```sh
GIT_URL=https://x-access-token:<token>@github.com/you/app.git
```

Note the token is visible to anyone who can read the container environment
(`docker inspect`).

**SSH deploy key** — set `GIT_SSH_KEY` to the private key, either raw PEM or
base64-encoded (`base64 -w0 < key`; required when passing it through an
`.env` file, which cannot hold multi-line values):

```sh
GIT_URL=ssh://git@github.com/you/app.git
GIT_SSH_KEY=<base64 of the private deploy key>
```

The key is provisioned into the container on every deploy tick, so it
survives container recreation, and rotating it is just updating the env and
recreating the container. Host keys are trusted on first use by default;
pin them for production with `GIT_SSH_KNOWN_HOSTS` (a `known_hosts` line,
e.g. from `ssh-keyscan -t ed25519 github.com`) — then a changed host key
fails hard instead of being accepted.

## Tests

Integration tests use [bats-core](https://github.com/bats-core/bats-core) and
deploy the official [laravel/laravel](https://github.com/laravel/laravel)
skeleton through both variants — full stack, real database, real deploys:

```sh
bats tests/autopull.bats
bats tests/baked.bats
bats tests/autopull-private.bats   # autopull private-repo auth against a local Gitea fixture
```

Requires docker with the compose plugin; suites use separate compose project
names and ports (8080/8081/8082) and clean up after themselves. The private
suite needs no external secrets — it hosts the private repository itself in
a throwaway Gitea container and exercises both the ssh deploy key and the
https token flow against it.
