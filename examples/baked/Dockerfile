# Consumer Dockerfile for the baked variant: copy your application in and build it.
# In your own project, replace the FROM with the published image:
#   FROM ghcr.io/michiruf/laravel:baked-latest
FROM laravel-docker:baked

COPY --chown=$APPLICATION_UID:$APPLICATION_GID . /app-src
RUN /opt/docker/bin/service.d/baked-build.sh
