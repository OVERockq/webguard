#!/bin/bash
nginx
exec docker-entrypoint.sh php-fpm
