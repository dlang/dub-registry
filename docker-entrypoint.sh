#!/bin/bash

# Based on https://github.com/rracariu/docker

set -euo pipefail

# Connecting to mongo and wait until its online
echo "Connecting to mongo..."
while ! nc -z mongo 27017; do
 sleep 0.1
done

echo "Starting dub registry"
export PATH="/opt/dub-registry:/dub:$PATH"
cd /opt/dub-registry

if [[ -e /dub/settings.json ]] ; then
    ln -s /dub/settings.json /opt/dub-registry/settings.json
fi

# start the registry
./dub-registry --bind 0.0.0.0 --p 9095
