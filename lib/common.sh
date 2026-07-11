#!/usr/bin/env bash

# Compatibility import for repository scripts. Domain helpers live beside this file.

set -euo pipefail

_LIB_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIB_DIR/runtime.sh"
source "$_LIB_DIR/results.sh"
source "$_LIB_DIR/components.sh"
source "$_LIB_DIR/packages.sh"
source "$_LIB_DIR/preflight.sh"
source "$_LIB_DIR/downloads.sh"
source "$_LIB_DIR/state.sh"
source "$_LIB_DIR/btrfs.sh"
source "$_LIB_DIR/boot.sh"
unset _LIB_DIR
