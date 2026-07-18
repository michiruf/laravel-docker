# laravel-docker

Production container images for Laravel applications, built on
[webdevops/php-nginx](https://dockerfile.readthedocs.io/en/latest/content/DockerImages/dockerfiles/php-nginx.html)
(nginx + php-fpm + supervisor, alpine).

The heavy lifting these images do is **provisioning**: getting your application
installed, configured and migrated inside the container — on first start and on
every subsequent deploy — driven entirely by environment variables.

## Variants

| Image | Deployment model |
|---|---|
| `ghcr.io/michiruf/laravel:base-latest` | Provisioning engine only, no deploy trigger. Extend it for custom variants. |
| `ghcr.io/michiruf/laravel:autopull-latest` | Pulls a git repository and redeploys automatically when upstream changes (cron, every minute). |
| `ghcr.io/michiruf/laravel:baked-latest` | Starter image: copy your application in at build time, provisioning runs on first container start. |

## Quickstart: baked

Add a `Dockerfile` to your Laravel application:

```dockerfile
FROM ghcr.io/michiruf/laravel:baked-latest
COPY --chown=$APPLICATION_UID:$APPLICATION_GID . /app-src
RUN /opt/docker/bin/service.d/baked-build.sh
```

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

| Token | Action |
|---|---|
| `-<anything>` | Skipped. Disable a single default without redefining the whole list. |
| `git:update` | `git reset --hard origin/<current branch>` |
| `env:update` | Regenerate the application `.env` (see below) |
| `composer:<args>` | Run composer, e.g. `composer:install --no-progress` |
| `artisan:<args>` | Run artisan (guarded: fails when the app is not provisioned yet) |
| `artisan?:<args>` | Optional artisan command: logs and continues when unsupported, e.g. `artisan?:horizon:terminate` on an app without horizon |
| `permissions:fix` | `chown -R $APPLICATION_UID:$APPLICATION_GID .` |
| anything else | Executed as raw shell (escape hatch); a failure is logged but does not abort |

Defaults (see [Dockerfile](Dockerfile)):

- autopull deploy: `artisan:down ; git:update ; composer:install --no-progress ; env:update ; artisan:storage:link ; artisan:optimize ; artisan:migrate --force ; permissions:fix ; artisan?:horizon:terminate ; artisan?:queue:restart ; artisan?:pulse:restart ; artisan:up`
- autopull initial: `composer:install --no-progress ; env:update ; artisan:key:generate --force ; permissions:fix`
- baked: `env:update ; artisan:storage:link ; artisan:optimize ; artisan:migrate --force ; permissions:fix`

Override the whole list via the environment, or prefix single commands with `-`
to disable them.

### `.env` synthesis (`env:update`)

The application `.env` is regenerated from its `.env.example` on every deploy.
Every container environment variable prefixed with `LARAVEL_` is injected with
the prefix stripped: `LARAVEL_DB_HOST=mysql` on the container becomes
`DB_HOST=mysql` in the `.env` (commented example lines are uncommented).
Values already present in the current `.env` that are not overridden — notably
the generated `APP_KEY` — are preserved across deploys.

Result: application configuration lives entirely in your compose file or
orchestrator; no `.env` files to manage on servers.

### Auto-detected workers

Supervisor ships three programs; each waits until the application is
provisioned, then starts — or idles cleanly when the application does not use
the package (re-checking periodically, so a deploy that adds the package starts
the worker without a container restart):

| Program | Runs | Requires |
|---|---|---|
| `laravel-scheduler` | `artisan schedule:work` | — |
| `laravel-horizon` | `artisan horizon` | `laravel/horizon` installed |
| `laravel-pulse` | `artisan pulse:check` | `laravel/pulse` installed |

A plain `laravel/laravel` skeleton therefore runs with zero configuration.

## Environment reference

| Variable | Default | Purpose |
|---|---|---|
| `GIT_URL` | — (required, autopull) | Repository to deploy (https or ssh) |
| `BRANCH` | empty (autopull) | Branch to deploy; empty uses the remote default branch |
| `DEPLOY_COMMANDS` | see above | Commands run on every deploy |
| `DEPLOY_COMMAND_SEPARATOR` | `;` | Token separator |
| `INITIAL_DEPLOY_COMMANDS` | see above | Commands run on first provision (autopull) |
| `INITIAL_DEPLOY_COMMAND_SEPARATOR` | `;` | Token separator |
| `LARAVEL_*` | — | Injected into the application `.env` (prefix stripped) |
| `APPLICATION_PATH`, `APPLICATION_UID`, `APPLICATION_GID`, `WEB_DOCUMENT_ROOT`, … | | Inherited from the [webdevops base image](https://dockerfile.readthedocs.io/en/latest/content/DockerImages/dockerfiles/php-nginx.html#environment-variables) |

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

Private repositories with autopull: use an ssh `GIT_URL`, mount a deploy key
and keep the `/etc/ssh` volume (see the example compose file) so host keys
persist.

## Tests

Integration tests use [bats-core](https://github.com/bats-core/bats-core) and
deploy the official [laravel/laravel](https://github.com/laravel/laravel)
skeleton through both variants — full stack, real database, real deploys:

```sh
bats tests/autopull.bats
bats tests/baked.bats
```

Requires docker with the compose plugin; suites use separate compose project
names and ports (8080/8081) and clean up after themselves.
