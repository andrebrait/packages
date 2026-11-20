#!/bin/sh
# Run the agent's tests in the dev container (see tests/README).
# Usage: tests/run.sh  (from net/unifi-agent)
set -e
B=/tmp/unifi-build
mkdir -p $B/unifi
cc -O2 -Wall -Werror -fPIC -shared -o $B/unifi/aes.so src/aes.c -lmbedcrypto -lucode
for t in tests/test_*.uc; do
	echo "== $t"
	ucode -L "$B/*.so" -L "$PWD/files/usr/share/ucode/*.uc" -L "$PWD/tests/*.uc" $t
done
