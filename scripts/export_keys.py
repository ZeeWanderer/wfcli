#!/usr/bin/env python3
import json
import os
import sys

EXPORT_DIR = os.path.join("apps", "wfcli", "priv")


def load_json(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as handle:
        return json.load(handle)


def iter_entries(obj):
    if isinstance(obj, list):
        for item in obj:
            if isinstance(item, dict):
                yield item
    elif isinstance(obj, dict):
        for value in obj.values():
            if isinstance(value, list):
                for item in value:
                    if isinstance(item, dict):
                        yield item


def main():
    if len(sys.argv) < 2:
        print("usage: export_keys.py ExportFile.json [key ...]", file=sys.stderr)
        return 1

    export_file = sys.argv[1]
    keys = sys.argv[2:] or ["uniqueName", "name", "locName"]
    path = export_file
    if not os.path.isabs(path):
        path = os.path.join(EXPORT_DIR, export_file)

    if not os.path.exists(path):
        print(f"error: not found: {path}", file=sys.stderr)
        return 1

    data = load_json(path)
    for entry in iter_entries(data):
        for key in keys:
            val = entry.get(key)
            if val:
                print(val)
                break

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
