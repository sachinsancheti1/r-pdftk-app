#!/bin/sh
set -e

: "${BASIC_AUTH_USER:?BASIC_AUTH_USER must be set}"
: "${BASIC_AUTH_PASS:?BASIC_AUTH_PASS must be set}"
: "${PORT:=3838}"

htpasswd -bc /etc/nginx/.htpasswd "$BASIC_AUTH_USER" "$BASIC_AUTH_PASS"

export PORT
envsubst '${PORT}' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf

Rscript -e "shiny::runApp('/app', host='127.0.0.1', port=3838)" &

exec nginx -g "daemon off;"
