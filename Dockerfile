FROM bitnami/mongodb:3.6-debian-8

# Based on https://github.com/rracariu/docker

MAINTAINER "DLang Community <community@dlang.io>"

EXPOSE 9095

RUN apt-get update && apt-get install -y netcat unzip imagemagick libssl-dev

COPY dub-registry /opt/dub-registry/dub-registry
COPY public /opt/dub-registry/public
COPY categories.json /opt/dub-registry/categories.json
COPY docker-entrypoint.sh /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh" ]
