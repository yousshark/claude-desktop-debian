#!/bin/sh
set -eux
mkdir -p output
chmod 777 output
docker build -t claude-desktop-debian .
docker run \
  --rm \
  -it \
  -v ./output:/home/builder/output \
  claude-desktop-debian $@
