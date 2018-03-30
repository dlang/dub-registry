#!/usr/bin/env bash
# A small script to build the registry and download a few pages for a static build

set -euo pipefail
set -x

DMD_VERSION="2.079.0"
BUILD_DIR="build"
MONGO_VERSION="mongodb-linux-x86_64-ubuntu1404-3.6.3"
CURL_FLAGS=(-fsSL --retry 10 --retry-delay 30 --retry-max-time 600 --connect-timeout 5 --speed-time 30 --speed-limit 1024)

# install mongo
if [ ! -f mongo.tgz ] ; then
    curl -fsSL --retry 5 "https://fastdl.mongodb.org/linux/${MONGO_VERSION}.tgz" > mongo.tgz
    tar xfvz mongo.tgz
fi

mkdir -p ~/.mongo
${MONGO_VERSION}/bin/mongod --dbpath ~/.mongo --fork --logpath ~/.mongolog &
PID_MONGO=$!

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "${DIR}"

. "$(curl "${CURL_FLAGS[@]}" https://dlang.org/install.sh | bash -s install "dmd-${DMD_VERSION}" --activate)"

curl "${CURL_FLAGS[@]}" https://code.dlang.org/api/packages/dump | gunzip > mirror.json

DUB_FLAGS="--override-config="vibe-d:tls/botan""
dub build ${DUB_FLAGS}
./dub-registry --mirror="mirror.json" &
PID_REGISTRY=$!
sleep 60s

# Now kill the registry and start in "full mode" (with the mirrored database)
kill -9 $PID_REGISTRY || true
./dub-registry --no-monitoring &
PID_REGISTRY=$!
sleep 10s

REGISTRY_URL="http://127.0.0.1:8005"

mkdir -p ${BUILD_DIR}
# ignore pages with a ? (not supported by netlify)
# Netlify doesn't support filenames containing # or ? characters
# TODO: replace all files and links containing a ? with e.g. _
# with the reject files with ? + most package version listings are rejected
wget --mirror --level 6 --convert-links --adjust-extension --page-requisites --no-parent ${REGISTRY_URL} \
    --reject-regex ".*[?].*|.*[/]packages[/].*[/]versions|.*[/]packages[/].*[/][0-9]*[.].*" \
    > ${BUILD_DIR}/index.html &
PID_WGET=$!
echo "Finished mirroring."

sleep 60s
kill -9 $PID_WGET || true

mv "127.0.0.1:8005" out

################################################################################
# Download all JSON responses from the local registry
################################################################################

mapfile -t packages < <(jq -r '.[] | .name' mirror.json)
OUT=out/packages
mkdir -p "$OUT"
for package in "${packages[@]}" ; do
    echo "Downloading JSON for ${package}"
    curl -fsSL "http://localhost:8005/packages/${package}.json" > "${OUT}/${package}.json" || true
done

################################################################################
# Kill the running registry + mongod instance
################################################################################

kill -9 $PID_MONGO || true
kill -9 $PID_REGISTRY || true
kill -9 $PID_MONGO || true

# Final cleanup (in case something was missed)
pkill -9 -P $$ || true
