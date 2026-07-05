#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export GLASSDB_INTEGRATION_DATABASES=1
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-.build/clang-module-cache}"

swift test --disable-sandbox --filter DatabaseIntegrationTests
