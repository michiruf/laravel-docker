# Laravel Docker

[![Test](https://github.com/michiruf/laravel-docker/actions/workflows/test.yml/badge.svg)](https://github.com/michiruf/laravel-docker/actions/workflows/test.yml)
[![Publish Docker Images](https://github.com/michiruf/laravel-docker/actions/workflows/publish.yml/badge.svg)](https://github.com/michiruf/laravel-docker/actions/workflows/publish.yml)

Production container images for Laravel applications, built on
[webdevops/php-nginx](https://dockerfile.readthedocs.io/en/latest/content/DockerImages/dockerfiles/php-nginx.html)
(nginx + php-fpm + supervisor, alpine).

The images do the **provisioning**: they install, configure and migrate the
application inside the container, on the first start and on every deploy after
that.

## Quickstart

### Autopull

The container clones `GIT_URL` and provisions the application. After that it
checks the repository every minute, so a push is live one minute later.

```sh
cd examples/autopull
cp .env.example .env   # set GIT_URL (+ credentials for mysql)
docker compose up -d
```

See
[examples/autopull/compose.yml](examples/autopull/compose.yml) for the full
stack with mysql and redis.

### Baked

Add a `Dockerfile` next to the Laravel application:

```dockerfile
FROM ghcr.io/michiruf/laravel-docker:baked-latest
COPY --chown=$APPLICATION_UID:$APPLICATION_GID . /app-src
RUN cd /app-src \
    && composer install --no-dev --no-progress --optimize-autoloader --ansi \
    && chown -R "$APPLICATION_UID":"$APPLICATION_GID" /app-src
```

Then build and start it:

```sh
docker build -t my-app .
docker run -p 8080:80 -e LARAVEL_APP_ENV=production my-app
```

On the first start the application is moved into place, an `APP_KEY` is
generated and the deploy commands run. See
[examples/baked/compose.yml](examples/baked/compose.yml) for the full stack with
mysql and redis.

## Variants

| Image                                             | Deployment model                                                                                       |
|---------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| `ghcr.io/michiruf/laravel-docker:autopull-latest` | Pulls a git repository and deploys again when it changes (cron, every minute).                         |
| `ghcr.io/michiruf/laravel-docker:baked-latest`    | Starter image: the application is copied in at build time, provisioning runs on first container start. |
| `ghcr.io/michiruf/laravel-docker:base-latest`     | Provisioning engine only, no deploy trigger. Base for a custom variant.                                |

### Autopull

The repository is cloned on the first start. It uses the branch from `BRANCH`,
or the default branch of the remote if `BRANCH` is empty. Every change on the
remote leads to a new deploy.

A failed deploy is retried every minute until it works. The open step is stored
in `.git/autopull-state` on the application volume. So a deploy that was stopped
by a crash or a new container is picked up again.

#### Update detection (`DETECT_COMMAND`)

Once a minute, autopull runs `DETECT_COMMAND` (any command token, default
`git:detect`). Exit code 0 starts a deploy. A custom command changes what counts
as an update, for example only changes in one folder of a monorepo:

```yaml
DETECT_COMMAND: git fetch && ! git diff --quiet HEAD @{u} -- apps/api
```

The detect command has to fetch on its own, so a detector can also fetch tags
instead. The built-in `git:detect` fetches and compares HEAD with the remote.

#### Private repositories

To authenticate agains a private repository, there are two ways:

**HTTPS token in the URL:**

```sh
GIT_URL=https://x-access-token:<token>@github.com/you/app.git
```

**SSH deploy key:**

Put the private key into `GIT_SSH_KEY`, either as raw PEM or
base64 encoded (`base64 -w0 < key`).

```sh
GIT_URL=ssh://git@github.com/you/app.git
GIT_SSH_KEY=<base64 of the private deploy key>
```

The key is written into the container on every update. Host keys are trusted
on first use. For production set `GIT_SSH_KNOWN_HOSTS` to a `known_hosts`
line (for example from `ssh-keyscan -t ed25519 github.com`). A changed host
key then fails instead of being accepted.

### Baked

The application needs to be copied into the image at build time. The build
Every container start runs a deploy, so a new image is rolled out by recreating
the container.

See the example in [examples/baked/Dockerfile](examples/baked/Dockerfile).

## Provisioning

A deploy runs on the first start and on every change. It runs all `DEPLOY_COMMANDS`
and writes `=> deploy completed` into the log when it is done.
The first start differs per variant. Autopull runs `INITIAL_DEPLOY_COMMANDS`
before the first deploy. Baked moves `/app-src` into place and generates the
`APP_KEY`.
The autopull variant automatically executes `permissions:fix` after every deploy.

### Deploy commands

`DEPLOY_COMMANDS` and `INITIAL_DEPLOY_COMMANDS` are lists of command tokens.
`DEPLOY_COMMAND_SEPARATOR` (default `;`) splits them:

| Token             | Action                                                                                        |
|-------------------|-----------------------------------------------------------------------------------------------|
| `-<anything>`     | Skipped / commented out                                                                       |
| `git:detect`      | `git fetch`, then exit 0 if the remote is ahead of HEAD. Default `DETECT_COMMAND` (autopull). |
| `git:update`      | `git reset --hard origin/<current branch>`                                                    |
| `composer:<args>` | Runs composer, for example `composer:install --no-progress`                                   |
| `artisan:<args>`  | Runs artisan. Fails if the application is not provisioned yet.                                |
| `artisan?:<args>` | Same, but a missing or failing command only logs, for example `artisan?:horizon:terminate`    |
| `permissions:fix` | `chown -R $APPLICATION_UID:$APPLICATION_GID .`                                                |
| anything else     | Runs as a shell command                                                                       |

A failing command stops the deploy. Autopull tries again a minute later, baked
stops the container start. If a command may fail, write it as `artisan?:` or provide
a custom command with `|| true`.

Please refer to the [Dockerfile](Dockerfile) for a list of the default deploy commands.

### Configuration from the container environment

Every container variable that starts with `LARAVEL_` is passed to all processes
in the container without that prefix. `LARAVEL_DB_HOST=mysql` on the container
becomes `DB_HOST=mysql` for php-fpm, artisan and the deploy commands. Names that
the container itself needs (e.g. `PATH`, `HOME` and `LANG`) or invalid
variable names are skipped and logged.

The `.env` of the application is never rewritten. It is only copied from
`.env.example` if it is missing, so that `artisan key:generate` has a file for
the `APP_KEY`. Laravel does not let the `.env` overwrite variables that are
already set, so the container environment always wins.

### Workers

Supervisor ships three programs. Each one waits until the application is
provisioned and then starts. If the needed package is missing, the program idles
and checks again later, so a deploy that adds the package starts the worker
without a container restart.

| Program             | Runs                    | Needs                       |
|---------------------|-------------------------|-----------------------------|
| `laravel-scheduler` | `artisan schedule:work` | —                           |
| `laravel-horizon`   | `artisan horizon`       | `laravel/horizon` installed |
| `laravel-pulse`     | `artisan pulse:check`   | `laravel/pulse` installed   |

## Environment reference

All variables of
the [webdevops base image](https://dockerfile.readthedocs.io/en/latest/content/DockerImages/dockerfiles/php-nginx.html#environment-variables)
are configurable, for example `APPLICATION_PATH`, `APPLICATION_UID`,
`APPLICATION_GID` and `WEB_DOCUMENT_ROOT`. These images add:

| Variable                           | Default                          | Purpose                                               |
|------------------------------------|----------------------------------|-------------------------------------------------------|
| `GIT_URL`                          | — (required, autopull)           | Repository to deploy (https or ssh)                   |
| `BRANCH`                           | empty (autopull)                 | Branch to deploy, empty uses the default branch       |
| `GIT_SSH_KEY`                      | empty (autopull)                 | Private deploy key for ssh URLs, raw PEM or base64    |
| `GIT_SSH_KNOWN_HOSTS`              | empty (autopull)                 | Pinned host key line(s), empty trusts on first use    |
| `DETECT_COMMAND`                   | `git:detect`                     | Command that decides about a deploy (exit 0 = deploy) |
| `DEPLOY_COMMANDS`                  | see [Dockerfile](Dockerfile)     | Commands of every deploy                              |
| `DEPLOY_COMMAND_SEPARATOR`         | `;`                              | Separator of the list                                 |
| `INITIAL_DEPLOY_COMMANDS`          | see [Dockerfile](Dockerfile)     | Commands of the first deploy (autopull)               |
| `INITIAL_DEPLOY_COMMAND_SEPARATOR` | `;`                              | Separator of the list                                 |
| `LARAVEL_*`                        | —                                | Passed to the application without the prefix          |
| `APPLICATION_ENV_FILE`             | `$APPLICATION_PATH/.env`         | Path of the `.env`                                    |
| `APPLICATION_ENV_EXAMPLE_FILE`     | `$APPLICATION_PATH/.env.example` | File the `.env` is copied from if it is missing       |

## Extending

PHP extensions and system packages can be added on top of the image, for example:

```dockerfile
FROM ghcr.io/michiruf/laravel-docker:autopull-latest
RUN set -x \
  && apk-install $PHPIZE_DEPS linux-headers imap-dev openssl-dev krb5-dev \
  && pecl install imap \
  && docker-php-ext-enable imap \
  && apk del -f --purge $PHPIZE_DEPS linux-headers imap-dev openssl-dev krb5-dev
```

## Tests

The integration tests use [bats-core](https://github.com/bats-core/bats-core).
They deploy the original [laravel/laravel](https://github.com/laravel/laravel)
skeleton with both variants, with a full stack, a real database and real
deploys:

```sh
bats tests/autopull.bats
bats tests/baked.bats
bats tests/autopull-private.bats   # private repository auth against a local Gitea
```

You need docker to run the tests. Every suite uses its own compose
project name and port (8080/8081/8082) and cleans up after itself. The private
suite needs no secrets: it runs the private repository in a throwaway Gitea
container and tests the ssh key and the https token against it.
