FROM php:8.4-apache

RUN a2enmod rewrite

RUN docker-php-ext-install opcache gettext mysqli

# iftest dev toolchains: Bun + Go (only to develop and test the runners)
# Bun pinned to 1.4 for reproducible builds (live runtime resolved oven/bun:1 to 1.4.0)
COPY --from=oven/bun:1.4 /usr/local/bin/bun /usr/local/bin/bun

RUN apt-get update \
 && apt-get install -y --no-install-recommends git golang-go \
 && rm -rf /var/lib/apt/lists/*

# Go as www-data (Apache) has no HOME: point the toolchain caches at a writable path
# or `go run` dies with "build cache is required, but could not be located".
ENV GOCACHE=/tmp/iftest-gocache \
    GOPATH=/tmp/iftest-gopath

RUN cat > /etc/apache2/sites-enabled/localhost.conf <<EOF
ServerName localhost
<VirtualHost *:80>
    DocumentRoot /var/www/html
    <Directory "/var/www/html">
        Options +FollowSymLinks -Indexes -Multiviews
        AllowOverride All
        Order allow,deny
        Allow from all
    </Directory>
</VirtualHost>
EOF

RUN cat > /usr/local/etc/php/conf.d/php.ini <<EOF
log_errors = on
expose_php = off
session.use_strict_mode    = 1
session.cookie_secure      = 1      ; HTTPS only
session.cookie_httponly    = 1      ; JS disabled
session.cookie_samesite    = Strict
EOF

EXPOSE 80

CMD ["bash", "-c", "apache2-foreground"]