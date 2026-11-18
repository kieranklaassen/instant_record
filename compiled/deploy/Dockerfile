# Static host for the compiled browser build: the files in site/ behind nginx.
# site/ is the output of pipeline/build.py (web/dist), built for the sync server you want.
FROM nginx:stable-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY site/ /site/

# Compress once at build time; nginx serves the .gz next to each file (gzip_static).
RUN find /site -type f \( -name "*.wasm" -o -name "*.js" -o -name "*.css" -o -name "*.svg" -o -name "*.html" \) \
      -exec gzip -9 -k {} +

EXPOSE 80
