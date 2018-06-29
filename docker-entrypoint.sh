#!/bin/bash

# Based on https://github.com/rracariu/docker

set -euo pipefail

# start mongo
/app-entrypoint.sh /run.sh &
# and wait until its online
while ! nc -z localhost 27017; do
 sleep 0.1
done

echo Starting dub registry
export PATH="/opt/dub-registry:/dub:$PATH"
cd /opt/dub-registry

if [[ -e /dub/settings.json ]] ; then
    ln -s /dub/settings.json /opt/dub-registry/settings.json
fi

# start the registry
./dub-registry --bind 0.0.0.0 --p 9095
