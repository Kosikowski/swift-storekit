#!/bin/sh
#
# PurchaseCore's layers are named in each file's banner rather than split into
# targets, so that an app imports one module instead of three. This is what stops
# that being a gentleman's agreement: a Domain file may not reach for the actor, the
# observation machinery or the store, and a Port may not reach for the store.
#
# Comment lines are skipped, so a file may still *talk* about what it must not use.

set -eu
cd "$(dirname "$0")/.."
status=0

check() { # layer, forbidden pattern
    for file in $(grep -l "^//  Layer: $1\$" Sources/PurchaseCore/*.swift); do
        if grep -v '^[[:space:]]*//' "$file" | grep -n -E "$2" >/dev/null; then
            echo "layers: $file is a $1 file and mentions: $(grep -v '^[[:space:]]*//' "$file" | grep -o -E "$2" | sort -u | tr '\n' ' ')"
            status=1
        fi
    done
}

check Domain '@MainActor|import Observation|@Observable|PurchaseStore|PurchaseCommanding|PurchaseStateProviding'
check Port '@MainActor|import Observation|@Observable|PurchaseStore[^F]'

for file in Sources/PurchaseCore/*.swift; do
    grep -q -E '^//  Layer: (Domain|Port|Application)$' "$file" || { echo "layers: $file names no layer"; status=1; }
done

# Core imports Foundation and Observation, and nothing else from Apple.
if grep -n -E '^(public |internal )?import (StoreKit|SwiftUI|AppKit|UIKit|Combine)' Sources/PurchaseCore/*.swift; then
    echo "layers: PurchaseCore must not import an Apple UI or store framework"
    status=1
fi

[ "$status" -eq 0 ] && echo "layers: clean"
exit "$status"
