# syntax=docker/dockerfile:1

FROM buildpack-deps:bookworm AS build

RUN set -eux; \
    wget -O ldc2-1.40.1-linux-x86_64.tar.xz https://github.com/ldc-developers/ldc/releases/download/v1.40.1/ldc2-1.40.1-linux-x86_64.tar.xz; \
    echo "085a593dba4b1385ec03e7521aa97356e5a7d9f6194303eccb3c1e35935c69d8 *ldc2-1.40.1-linux-x86_64.tar.xz" | sha256sum -c -; \
    tar --strip-components=1 -C /usr/local -Jxf ldc2-1.40.1-linux-x86_64.tar.xz; \
    rm ldc2-1.40.1-linux-x86_64.tar.xz
WORKDIR /app
COPY . .
RUN dub build

# Based on https://github.com/rracariu/docker

FROM debian:bookworm-slim AS final

LABEL maintainer="DLang Community <community@dlang.io>"

EXPOSE 9095

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        netcat-traditional \
        unzip \
        imagemagick \
        libssl-dev; \
    rm -fr /var/lib/apt/lists/*

COPY public /opt/dub-registry/public
COPY categories.json /opt/dub-registry/categories.json
COPY docker-entrypoint.sh /entrypoint.sh
COPY --from=build /app/dub-registry /opt/dub-registry/dub-registry

ENTRYPOINT [ "/entrypoint.sh" ]
