# Consumer Dockerfile for the baked variant: copy your application in and build it.
# In your own project, replace the FROM with the published image:
#   FROM ghcr.io/michiruf/laravel-docker:baked-latest
FROM laravel-docker:baked

COPY --chown=$APPLICATION_UID:$APPLICATION_GID . /app-src

# Build the application. This step belongs to the consumer: adjust the composer
# flags or add asset builds as your application needs them.
# The chown covers what composer creates as root, which COPY --chown cannot.
RUN cd /app-src \
    && composer install --no-dev --no-progress --optimize-autoloader --ansi \
    && chown -R "$APPLICATION_UID":"$APPLICATION_GID" /app-src
