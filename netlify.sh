#!/usr/bin/env bash
# A small script to build the registry and download a few pages for a static build

set -euo pipefail
set -x

DMD_VERSION="2.079.0"
BUILD_DIR="build"
MONGO_VERSION="mongodb-linux-x86_64-ubuntu1404-3.6.3"

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

. "$(curl -fsSL --retry 5 --retry-max-time 120 --connect-timeout 5 --speed-time 30 --speed-limit 1024 https://dlang.org/install.sh | bash -s install "dmd-${DMD_VERSION}" --activate)"

DUB_FLAGS="--override-config="vibe-d:tls/botan""
dub build ${DUB_FLAGS}
./dub-registry &
PID_REGISTRY=$!
sleep 5s

REGISTRY_URL="http://127.0.0.1:8005"

mkdir -p ${BUILD_DIR}
wget --mirror --level 6 --convert-links --adjust-extension --page-requisites --no-parent ${REGISTRY_URL} > ${BUILD_DIR}/index.html &
PID_WGET=$!
echo "Finished mirroring."

sleep 10s
kill -9 $PID_WGET || true

# TODO: start registry in mirror mode and download the package dump
mv "127.0.0.1:8005" out
# Netlify doesn't support filenames containing # or ? characters
# TODO: replace all files and links containing a ? with e.g. _
find out -name "*[?]*" | xargs rm -f

kill -9 $PID_MONGO || true
kill -9 $PID_REGISTRY || true
kill -9 $PID_MONGO || true

# Final cleanup (in case something was missed)
pkill -9 -P $$ || true
