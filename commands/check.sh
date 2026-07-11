#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT_DIR/manage.sh" setup stage1 --check
bash "$ROOT_DIR/manage.sh" setup stage2 --check
bash "$ROOT_DIR/manage.sh" update --check
bash "$ROOT_DIR/manage.sh" update apps --check
bash "$ROOT_DIR/manage.sh" driver nvidia --check
