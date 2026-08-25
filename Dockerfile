# Production container for Laravel applications.
#
# Stages:
#   base     - nginx + php-fpm + supervisor with the provisioning engine, no deploy trigger
#   autopull - base + cron-driven git deployment (set GIT_URL, optionally BRANCH)
#   baked    - base + first-start provisioning for applications copied to /app-src at build time
#
# Build: docker build --target <base|autopull|baked> .

FROM webdevops/php-nginx:8.4-alpine AS base

# Patch fastcgi to use the realpath_root instead of the document_root, so we do not need to reload fpm
# See https://deployer.org/docs/7.x/avoid-php-fpm-reloading
# hadolint ignore=SC2016
RUN sed -i 's|fastcgi_param.\+SCRIPT_FILENAME.\+\$request_filename\;|fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;|' /opt/docker/etc/nginx/vhost.common.d/10-php.conf

# Provisioning engine: scripts, entrypoints and supervisor programs
# (file modes are preserved from the build context)
COPY rootfs/base/ /

# Patch the web document root from webdevops container for laravels structure
ENV WEB_DOCUMENT_ROOT=${APPLICATION_PATH}/public


FROM base AS autopull

COPY rootfs/autopull/ /

# Register a crontab to periodically run the autopull deploy trigger
RUN printf '*\t*\t*\t*\t*\t/opt/docker/bin/autopull.sh\n' >> /etc/crontabs/root

# Git branch to deploy; empty means the remote default branch
ENV BRANCH=

# Private-repository ssh credentials (see git-credentials.sh):
# private deploy key (raw PEM or base64) and optional pinned host key(s)
ENV GIT_SSH_KEY=
ENV GIT_SSH_KNOWN_HOSTS=

# Command deciding whether an update occurred (exit 0 triggers a deploy)
ENV DETECT_COMMAND=git:detect

# Set the default deploy commands and their separator
ENV DEPLOY_COMMAND_SEPARATOR=; \
    DEPLOY_COMMANDS="\
  artisan:down ; \
  git:update ; \
  composer:install --no-progress ; \
  artisan:storage:link ; \
  artisan:optimize ; \
  artisan:migrate --force ; \
  permissions:fix ; \
  artisan?:horizon:terminate ; \
  artisan?:queue:restart ; \
  artisan?:pulse:restart ; \
  artisan:up"
ENV INITIAL_DEPLOY_COMMAND_SEPARATOR=; \
    INITIAL_DEPLOY_COMMANDS="\
  composer:install --no-progress ; \
  artisan:key:generate --force ; \
  permissions:fix"


FROM base AS baked

COPY rootfs/baked/ /

# Set the default deploy commands and their separator
ENV DEPLOY_COMMAND_SEPARATOR=; \
    DEPLOY_COMMANDS="\
  artisan:storage:link ; \
  artisan:optimize ; \
  artisan:migrate --force ; \
  permissions:fix"
