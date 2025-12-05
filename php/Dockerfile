FROM php:8.2-fpm

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git unzip curl zip libpng-dev libonig-dev libxml2-dev \
    libzip-dev libjpeg-dev libfreetype6-dev \
    librdkafka-dev \
    libssl-dev \
    libmagickwand-dev imagemagick ghostscript tesseract-ocr \
    supervisor \
 && rm -rf /var/lib/apt/lists/*

# ── PHP extensions
RUN docker-php-ext-install mysqli pdo_mysql mbstring exif pcntl bcmath gd zip

# MongoDB
RUN pecl install mongodb-1.21.0 && docker-php-ext-enable mongodb

# PECL: imagick, redis, rdkafka
RUN pecl install imagick redis rdkafka \
 && docker-php-ext-enable imagick redis rdkafka

# ── ionCube Loader (PHP 8.2) ─────────────────────────────────────────────
# Detect arch (x86_64 or aarch64), download, place .so in PHP ext dir, enable as zend_extension
# ── ionCube Loader (PHP 8.2) ─────────────────────────────────────────────
# Needs ca-certificates for curl TLS; handle common arch names; verify file exists.
# ionCube Loader for PHP 8.1
# RUN set -eux; \
#     apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*; \
#     arch="$(uname -m)"; \
#     case "$arch" in \
#       x86_64|amd64)  PKG="ioncube_loaders_lin_x86-64";; \
#       aarch64|arm64|armv8*) PKG="ioncube_loaders_lin_aarch64";; \
#       *) echo "Unsupported architecture: $arch"; exit 1;; \
#     esac; \
#     mkdir -p /usr/local/ioncube; \
#     curl -fsSL "https://downloads.ioncube.com/loader_downloads/${PKG}.tar.gz" | tar -xz -C /usr/local/ioncube; \
#     PHP_EXT_DIR="$(php -r 'echo ini_get("extension_dir");')"; \
#     SO_PATH="$(find /usr/local/ioncube -type f -name 'ioncube_loader_lin_8.1.so' -print -quit)"; \
#     if [ -z "$SO_PATH" ]; then echo "ionCube .so not found for PHP 8.1"; ls -la /usr/local/ioncube; exit 1; fi; \
#     cp "$SO_PATH" "$PHP_EXT_DIR/"; \
#     echo "zend_extension=${PHP_EXT_DIR}/ioncube_loader_lin_8.1.so" > /usr/local/etc/php/conf.d/00-ioncube.ini; \
#     php -v | grep -qi ioncube


# Create PHP error log file
RUN mkdir -p /var/log && touch /var/log/php_errors.log

# Add custom PHP config
COPY php.ini /usr/local/etc/php/conf.d/zz-custom.ini

# Node.js (for Vue dev server)
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
 && apt-get install -y nodejs \
 && rm -rf /var/lib/apt/lists/*

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Working directory
WORKDIR /var/www/html

# Supervisor config
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

EXPOSE 8000 5173
CMD ["supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
