#!/usr/bin/env python3

"""Helper script to generate relevant metadata about Haskell targets.

* The mapping from module source file to actual module name.
* The intra-package module dependency graph.
* Which modules require Template Haskell.

The result is a JSON object with the following fields:
* `th_modules`: List of modules that require Template Haskell.
* `module_mapping`: Mapping from source inferred module name to actual module name, if different.
* `module_graph`: Intra-package module dependencies, `dict[modname, list[modname]]`.
"""

import argparse
import json
import os
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        fromfile_prefix_chars="@")
    parser.add_argument(
        "--output",
        required=True,
        type=argparse.FileType("w"),
        help="Write package metadata to this file in JSON format.")
    parser.add_argument(
        "--ghc",
        required=True,
        type=str,
        help="Path to the Haskell compiler GHC.")
    parser.add_argument(
        "--ghc-arg",
        required=False,
        type=str,
        action="append",
        help="GHC compiler argument to forward to `ghc -M`, including package flags.")
    parser.add_argument(
        "--source-prefix",
        required=True,
        type=str,
        help="The path prefix to strip of module sources to extract module names.")
    parser.add_argument(
        "--source",
        required=True,
        type=str,
        action="append",
        help="Haskell module source files of the current package.")
    args = parser.parse_args()

    result = obtain_target_metadata(args)

    json.dump(result, args.output, indent=4)


def obtain_target_metadata(args):
    th_modules = determine_th_modules(args.source, args.source_prefix)
    ghc_depends = run_ghc_depends(args.ghc, args.ghc_arg, args.source)
    module_mapping, module_graph = interpret_ghc_depends(
        ghc_depends, args.source_prefix)
    return {
        "th_modules": th_modules,
        "module_mapping": module_mapping,
        "module_graph": module_graph,
    }


def determine_th_modules(sources, source_prefix):
    result = []

    for fname in sources:
        if uses_th(fname):
            module_name = src_to_module_name(
                strip_prefix_(source_prefix, fname).lstrip("/"))
            result.append(module_name)

    return result


th_regex = re.compile(r"^\s*{-# LANGUAGE (TemplateHaskell|TemplateHaskellQuotes|QuasiQuotes) #-}")


def uses_th(filename):
    """Determine if the given module uses Template Haskell."""
    with open(filename, "r") as file:
        for line in file:
            if th_regex.match(line):
                return True


def run_ghc_depends(ghc, ghc_args, sources):
    with tempfile.TemporaryDirectory() as dname:
        fname = os.path.join(dname, "depends")
        args = [
            ghc, "-M",
            # Note: `-outputdir '.'` removes the prefix of all targets:
            #       backend/src/Foo/Util.<ext> => Foo/Util.<ext>
            "-outputdir", ".",
            "-dep-json", fname,
        ] + ghc_args + sources
        subprocess.run(args, check=True)

        with open(fname) as f:
            return json.load(f)


def interpret_ghc_depends(ghc_depends, source_prefix):
    graph = {}
    mapping = {}

    for k, vs in ghc_depends.items():
        # remove lead `./` caused by using `-outputdir '.'`.
        k = strip_prefix_("./", k)
        vs = [strip_prefix_("./", v) for v in vs]

        module_name = src_to_module_name(k)
        intdeps = parse_module_deps(vs)

        graph.setdefault(module_name, []).extend(intdeps)

        ext = os.path.splitext(k)[1]

        if ext != ".o":
            continue

        sources = list(filter(is_haskell_src, vs))

        if not sources:
            continue

        assert len(sources) == 1, "one object file must correspond to exactly one haskell source "

        hs_file = sources[0]

        hs_module_name = src_to_module_name(
            strip_prefix_(source_prefix, hs_file).lstrip("/"))

        if hs_module_name != module_name:
            mapping[hs_module_name] = module_name

    return mapping, graph


def parse_module_deps(module_deps):
    internal_deps = []

    for module_dep in module_deps:
        if is_haskell_src(module_dep):
            continue

        if os.path.isabs(module_dep):
            continue

        internal_deps.append(src_to_module_name(module_dep))

    return internal_deps


def src_to_module_name(x):
    base, _ = os.path.splitext(x)
    return base.replace("/", ".")


def is_haskell_src(x):
    _, ext = os.path.splitext(x)
    return ext in HASKELL_EXTENSIONS


HASKELL_EXTENSIONS = [
    ".hs",
    ".lhs",
    ".hsc",
    ".chs",
    ".x",
    ".y",
]


def strip_prefix_(prefix, s):
    stripped = strip_prefix(prefix, s)

    if stripped == None:
        return s

    return stripped


def strip_prefix(prefix, s):
    if s.startswith(prefix):
        return s[len(prefix):]

    return None


if __name__ == "__main__":
    main()
