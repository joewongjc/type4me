#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
resource_dir="$project_dir/Sources/Type4Me/Resources/Jieba"
temporary_dir="$(mktemp -d /tmp/type4me-jieba-budget.XXXXXX)"
trap 'rm -rf "$temporary_dir"' EXIT

if [ -e "$resource_dir/jieba.dict.utf8" ]; then
    echo "Standard jieba.dict.utf8 must not be bundled" >&2
    exit 1
fi

raw_bytes="$(find "$resource_dir" -type f -exec stat -f '%z' {} + | awk '{total += $1} END {print total + 0}')"
ditto -c -k --sequesterRsrc --keepParent "$resource_dir" "$temporary_dir/jieba.zip"
compressed_bytes="$(stat -f '%z' "$temporary_dir/jieba.zip")"

printf 'jieba_raw_bytes=%s\n' "$raw_bytes"
printf 'jieba_compressed_bytes=%s\n' "$compressed_bytes"

if [ "$raw_bytes" -gt 2621440 ]; then
    echo "Jieba resources exceed the 2.5 MiB raw budget" >&2
    exit 1
fi
if [ "$compressed_bytes" -gt 1258291 ]; then
    echo "Jieba resources exceed the 1.2 MiB compressed budget" >&2
    exit 1
fi
