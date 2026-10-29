# WordPress + nginx + PHP-FPM 을 한 컨테이너에 (실서버와 같은 단일 호스트 구성)
FROM wordpress:6.6-php8.2-fpm
RUN apt-get update && apt-get install -y --no-install-recommends nginx unzip procps mariadb-client >/dev/null && rm -rf /var/lib/apt/lists/*
COPY nginx-site.conf /etc/nginx/sites-enabled/default
COPY start.sh /start.sh
RUN chmod +x /start.sh
CMD ["/start.sh"]
