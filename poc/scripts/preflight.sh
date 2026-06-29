#!/usr/bin/env bash
set -euo pipefail
docker info >/dev/null 2>&1 || { echo "Docker engine not reachable — start Docker Desktop"; exit 1; }
for tool in python3 jq xxd; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool"; exit 1; }
done
