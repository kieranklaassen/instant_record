# Static host for the compiled browser build: the files in site/ behind nginx.
# site/ is the output of pipeline/build.py (web/dist), built for the sync server you want.
FROM nginx:stable-alpine

RUN apk add --no-cache nginx-mod-http-brotli brotli && \
    if ! grep -q "ngx_http_brotli_static_module.so" /etc/nginx/nginx.conf && \
       ! grep -q "include /etc/nginx/modules/\*.conf" /etc/nginx/nginx.conf; then \
      sed -i '1i load_module /usr/lib/nginx/modules/ngx_http_brotli_static_module.so;' /etc/nginx/nginx.conf; \
    fi

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY site/ /site/

# Compress once at build time; nginx serves the .br or .gz next to each file.
RUN find /site -type f \( -name "*.wasm" -o -name "*.js" -o -name "*.css" -o -name "*.svg" -o -name "*.html" -o -name "*.json" \) \
      -exec brotli -q 11 -k {} + \
      -exec gzip -9 -k {} + && \
    nginx -t

EXPOSE 80
