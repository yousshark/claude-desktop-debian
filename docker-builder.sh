#!/bin/sh
mkdir -p output
chmod 777 output
docker build -t claude-desktop-debian .
docker run \
  -it \
  -v ./output:/home/builder/output \
  claude-desktop-debian

#unused
  # --cap-add SYS_ADMIN \
  # --privileged \
  # --device /dev/fuse \
