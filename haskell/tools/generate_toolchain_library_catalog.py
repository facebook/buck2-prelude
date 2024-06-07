#!/usr/bin/env python3

"""Helper script to generate a mapping from interface paths to toolchain library names.

The result is a JSON object with the following fields:
* `by-import-dirs`: A trie mapping import directory prefixes to package names. Encoded as nested dictionaries with leafs denoted by the special key `//pkgid`.
* `by-package-name`: A mapping from package name to package id.
"""

import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        fromfile_prefix_chars="@")
    parser.add_argument(
        "--output",
        required=True,
        type=argparse.FileType("w"),
        help="Write package mapping to this file in JSON format.")
    parser.add_argument(
        "--ghc-pkg",
        required=True,
        type=str,
        help="Path to the Haskell compiler's ghc-pkg utilty.")
    parser.add_argument(
        "--package-db",
        required=False,
        type=str,
        help="Path to the package db including all haskell libraries.")
    args = parser.parse_args()

    with subprocess.Popen(_ghc_pkg_command(args.ghc_pkg, args.package_db), stdout=subprocess.PIPE, text=True) as proc:
        packages = list(_parse_ghc_pkg_dump(proc.stdout))
        result = _construct_package_mappings(packages)

    json.dump(result, args.output)


def _ghc_pkg_command(ghc_pkg, package_db):
    return [
        ghc_pkg,
        "dump",
        "--global",
        "--no-user-package-db",
        "--simple-output",
        "--expand-pkgroot",
    ] + (["--package-db", package_db] if package_db else [])


def _parse_ghc_pkg_dump(lines):
    current_package = {}
    current_key = None

    for line in lines:
        if "---" == line.strip():
            if current_package:
                yield(current_package)

            current_package = {}
        elif ":" in line:
            key, value = map(str.strip, line.split(":", 1))

            if key == "name":
                current_key = "name"
                if value:
                    current_package["name"] = value
            elif key == "id":
                current_key = "id"
                if value:
                    current_package["id"] = value
            elif key == "import-dirs":
                current_key = "import-dirs"
                if value:
                    current_package.setdefault("import-dirs", []).append(value)
            else:
                current_key = None
        elif line.strip():
            if current_key in ["name", "id"]:
                current_package[current_key] = line.strip()
            elif current_key == "import-dirs":
                current_package.setdefault("import-dirs", []).append(line.strip())

    if current_package:
        yield current_package


def _construct_package_mappings(packages):
    result = {
        "by-import-dirs": {},
        "by-package-name": {},
    }

    for package in packages:
        result["by-package-name"][package["name"]] = package["id"]
        for import_dir in package.get("import-dirs", []):
            layer = result["by-import-dirs"]

            for part in Path(import_dir).parts:
                layer = layer.setdefault(part, {})

            layer["//pkgid"] = package["id"]

    return result


if __name__ == "__main__":
    main()
