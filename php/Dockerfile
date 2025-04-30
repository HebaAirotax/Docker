FROM php:8.2-fpm

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git unzip curl zip libpng-dev libonig-dev libxml2-dev \
    libzip-dev libjpeg-dev libfreetype6-dev \
    librdkafka-dev \
    libssl-dev \
    libmagickwand-dev imagemagick ghostscript tesseract-ocr \
    supervisor

# Install PHP extensions
RUN docker-php-ext-install pdo_mysql mbstring exif pcntl bcmath gd zip

# Install MongoDB extension
RUN pecl install mongodb-1.21.0 \
    && docker-php-ext-enable mongodb

# Install PECL extensions
RUN pecl install imagick redis rdkafka \
    && docker-php-ext-enable imagick redis rdkafka

# Node.js (for Vue dev server)
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && apt-get install -y nodejs

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Working directory
WORKDIR /var/www/html

# Supervisor config
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

EXPOSE 8000 5173
CMD ["supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
