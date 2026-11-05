# claude-box "php" profile: PHP 8.3 CLI with the extensions PrestaShop needs,
# composer and the MariaDB client, layered on top of the claude-box base image.
#
# PHP 8.3 is not packaged in Debian bookworm (it ships 8.2). Instead of adding a
# third-party apt repository, the PHP build is taken from the official
# php:8.3-cli-bookworm image (same Debian release, same ABI) and only its
# runtime libraries are installed from Debian.
ARG BASE_IMAGE=claude-box/base:latest
ARG PHP_IMAGE=php:8.3-cli-bookworm
ARG COMPOSER_IMAGE=composer:2

FROM ${PHP_IMAGE} AS php-build
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libfreetype6-dev libicu-dev libjpeg62-turbo-dev libpng-dev libzip-dev \
 && docker-php-ext-configure gd --with-freetype --with-jpeg \
 && docker-php-ext-install -j"$(nproc)" gd intl mysqli pdo_mysql zip \
 # Record which Debian packages provide the shared libraries PHP links against,
 # so the final stage installs exactly those.
 && { ldd /usr/local/bin/php /usr/local/lib/php/extensions/*/*.so \
        | awk '/=> \//{print $3}' | sort -u \
        | while read -r lib; do dpkg -S "$(readlink -f "$lib")" 2>/dev/null || dpkg -S "$lib"; done \
        | cut -d: -f1 | sort -u > /php-runtime-packages; } \
 && cat /php-runtime-packages

FROM ${COMPOSER_IMAGE} AS composer

FROM ${BASE_IMAGE}
USER root
COPY --from=php-build /php-runtime-packages /tmp/php-runtime-packages
RUN apt-get update \
 && xargs apt-get install -y --no-install-recommends < /tmp/php-runtime-packages \
 && apt-get install -y --no-install-recommends mariadb-client unzip \
 && rm -rf /var/lib/apt/lists/* /tmp/php-runtime-packages
COPY --from=php-build /usr/local/bin/php /usr/local/bin/php
COPY --from=php-build /usr/local/lib/php /usr/local/lib/php
COPY --from=php-build /usr/local/etc/php /usr/local/etc/php
COPY --from=composer /usr/bin/composer /usr/local/bin/composer
RUN set -e; \
    for m in curl gd intl mbstring mysqli pdo_mysql xml zip; do \
      php -m | grep -qix "$m" || { echo "missing PHP module: $m" >&2; exit 1; }; \
    done; \
    php --version; composer --version --no-interaction
ENV COMPOSER_HOME=/home/claude/.composer
USER claude
