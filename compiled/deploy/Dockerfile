# Static host for the compiled browser build: the files in site/ behind nginx.
# site/ is the output of pipeline/build.rb (web/dist), built for the sync server you want.
# Install nginx and nginx-mod-http-brotli from the same Alpine repo so their
# versions always match (nginx:stable-alpine ships nginx from nginx.org, which
# drifts ahead of Alpine's brotli module).
FROM alpine:3.23

RUN apk add --no-cache nginx nginx-mod-http-brotli brotli && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log && \
    grep -q "application/wasm" /etc/nginx/mime.types

COPY nginx.conf /etc/nginx/http.d/default.conf
COPY site/ /site/

# Compress once at build time; nginx serves the .br or .gz next to each file.
RUN find /site -type f \( -name "*.wasm" -o -name "*.js" -o -name "*.css" -o -name "*.svg" -o -name "*.html" -o -name "*.json" \) \
      -exec brotli -q 11 -k {} + \
      -exec gzip -9 -k {} + && \
    nginx -t

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
