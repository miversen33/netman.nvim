#!/usr/bin/sh

provider="$@"
if [ -z "${provider}" ]; then
    echo "Please provider a provider to test!"
    exit 1
fi

export PROVIDER=$provider
busted -m "../?.lua" --helper lua.netman.tools.bootstrap provider
unset PROVIDER
