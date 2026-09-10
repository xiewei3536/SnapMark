#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
for t in uidrv wins inputsrc; do swiftc -O "$t.swift" -o "bin/$t" 2>&1 | grep -v warning || true; done
ls -1 bin
