#!/usr/bin/env python3
import argparse
import json
import os
import sys

CANDIDATES = [
    os.path.join("apps", "wfcli", "priv", "languages.json"),
    os.path.join("build", "cache", "rebar3", "default", "lib", "wfcli", "priv", "languages.json"),
]


def load_json(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as handle:
        return json.load(handle)


def find_lang_file():
    for path in CANDIDATES:
        if os.path.exists(path):
            return path
    return None


def main():
    parser = argparse.ArgumentParser(description="Lookup a key in languages.json.")
    parser.add_argument("key", help="language key to lookup")
    parser.add_argument("--file", help="path to languages.json")
    args = parser.parse_args()

    path = args.file or find_lang_file()
    if not path or not os.path.exists(path):
        print("error: languages.json not found", file=sys.stderr)
        return 1

    data = load_json(path)
    key = args.key
    if key in data:
        print(data[key])
        return 0

    print("not found")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
