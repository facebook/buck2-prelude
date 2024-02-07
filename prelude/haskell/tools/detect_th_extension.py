#!/usr/bin/env python3

"""Helper script to detect when a Haskell module uses Template Haskell.

Looks for the relevant language pragmas in source files.
"""

import argparse
import re

th_regex = re.compile(r"^\s*{-# LANGUAGE (TemplateHaskell|TemplateHaskellQuotes|QuasiQuotes) #-}")


def uses_th(filename):
    """Determine if the given module uses Template Haskell."""
    with open(filename, "r") as file:
        for line in file:
            if th_regex.match(line):
                return True

    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        required=True,
        type=argparse.FileType("w"),
        help="Write the list of modules using Template Haskell to this file, separated by newline characters.")
    parser.add_argument(
        "modules",
        nargs="+",
        help="The Haskell module source files to parse.")
    args = parser.parse_args()

    output = args.output
    for module in args.modules:
        if uses_th(module):
            output.write(module + "\n")


if __name__ == "__main__":
    main()
