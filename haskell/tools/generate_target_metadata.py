#!/usr/bin/env python3

"""Helper script to generate relevant metadata about Haskell targets.

* The mapping from module source file to actual module name.
* The intra-package module dependency graph.
* The cross-package module dependencies.
* Which modules require Template Haskell.

The result is a JSON object with the following fields:
* `th_modules`: List of modules that require Template Haskell.
* `module_mapping`: Mapping from source inferred module name to actual module name, if different.
* `module_graph`: Intra-package module dependencies, `dict[modname, list[modname]]`.
* `package_deps`": Cross-package module dependencies, `dict[modname, dict[pkgname, list[modname]]`.
* `toolchain_deps`": Toolchain library dependencies, `dict[modname, list[pkgname]]`.
"""

import argparse
import json
import os
from pathlib import Path
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
        "--toolchain-libs",
        required=True,
        type=str,
        help="Path to the toolchain libraries catalog file.")
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
    parser.add_argument(
        "--package",
        required=False,
        type=str,
        action="append",
        default=[],
        help="Package dependencies formated as `NAME:PREFIX_PATH`.")
    parser.add_argument(
        "--bin-path",
        type=Path,
        action="append",
        default=[],
        help="Add given path to PATH.",
    )
    args = parser.parse_args()

    result = obtain_target_metadata(args)

    json.dump(result, args.output, indent=4, default=json_default_handler)


def json_default_handler(o):
    if isinstance(o, set):
        return sorted(o)
    raise TypeError(f'Object of type {o.__class__.__name__} is not JSON serializable')


def obtain_target_metadata(args):
    toolchain_packages = load_toolchain_packages(args.toolchain_libs)
    ghc_args = fix_ghc_args(args.ghc_arg, toolchain_packages)
    paths = [str(binpath) for binpath in args.bin_path if binpath.is_dir()]
    ghc_depends = run_ghc_depends(args.ghc, ghc_args, args.source, paths)
    th_modules = determine_th_modules(ghc_depends)
    module_mapping = determine_module_mapping(ghc_depends, args.source_prefix)
    # TODO(ah) handle .hi-boot dependencies
    module_graph = determine_module_graph(ghc_depends)
    #package_prefixes = calc_package_prefixes(args.package)
    #module_mapping, module_graph, package_deps, toolchain_deps = interpret_ghc_depends(
    #    ghc_depends, args.source_prefix, package_prefixes, toolchain_packages)
    package_deps, toolchain_deps = determine_package_deps(ghc_depends, toolchain_packages)
    return {
        "th_modules": th_modules,
        "module_mapping": module_mapping,
        "module_graph": module_graph,
        "package_deps": package_deps,
        "toolchain_deps": toolchain_deps,
        "ghc_depends": ghc_depends,
    }


def load_toolchain_packages(filepath):
    with open(filepath, "r") as f:
        return json.load(f)


def determine_th_modules(ghc_depends):
    return [
        modname
        for modname, properties in ghc_depends.items()
        if uses_th(properties.get("options", []))
    ]


__TH_EXTENSIONS = ["TemplateHaskell", "TemplateHaskellQuotes", "QuasiQuotes"]


def uses_th(opts):
    """Determine if a Template Haskell extension is enabled."""
    return any([f"-X{ext}" in opts for ext in __TH_EXTENSIONS])


def determine_module_mapping(ghc_depends, source_prefix):
    result = {}

    for modname, properties in ghc_depends.items():
        sources = list(filter(is_haskell_src, properties.get("sources", [])))

        if len(sources) != 1:
            raise RuntimeError(f"Expected exactly one Haskell source for module '{modname}' but got '{sources}'.")

        apparent_name = src_to_module_name(strip_prefix_(source_prefix, sources[0]).lstrip("/"))

        if apparent_name != modname:
            result[apparent_name] = modname

    return result


def determine_module_graph(ghc_depends):
    return {
        modname: description.get("modules", [])
        for modname, description in ghc_depends.items()
    }


def determine_package_deps(ghc_depends, toolchain_packages):
    toolchain_by_name = toolchain_packages["by-package-name"]
    package_deps = {}
    toolchain_deps = {}

    for modname, description in ghc_depends.items():
        for pkgdep in description.get("packages", {}):
            pkgname = pkgdep.get("name")
            pkgid = pkgdep.get("id")

            if pkgname in toolchain_by_name:
                if pkgid == toolchain_by_name[pkgname]:
                    toolchain_deps.setdefault(modname, []).append(pkgname)
                # TODO(ah) is this an error?
            else:
                package_deps.setdefault(modname, {})[pkgname] = pkgdep.get("modules", [])

    return package_deps, toolchain_deps


def fix_ghc_args(ghc_args, toolchain_packages):
    """Replaces -package flags by -package-id where applicable.

    Packages that have hidden internal packages cause failures of the form:

        Could not load module ‘Data.Attoparsec.Text’.
        It is a member of the hidden package ‘attoparsec-0.14.4’.

    This can be avoided by specifying the corresponding packages by package-id
    rather than package name.

    The toolchain libraries catalog tracks a mapping from package name to
    package id. We apply it here to any toolchain library dependencies.
    """
    result = []
    mapping = toolchain_packages["by-package-name"]

    args_iter = iter(ghc_args)
    for arg in args_iter:
        if arg == "-package":
            package_name = next(args_iter)
            if package_name is None:
                raise RuntimeError("Missing package name argument for -package flag")

            if (package_id := mapping.get(package_name, None)) is not None:
                result.extend(["-package-id", package_id])
            else:
                result.extend(["-package", package_name])
        else:
            result.append(arg)

    return result


def run_ghc_depends(ghc, ghc_args, sources, aux_paths):
    with tempfile.TemporaryDirectory() as dname:
        json_fname = os.path.join(dname, "depends.json")
        make_fname = os.path.join(dname, "depends.make")
        args = [
            ghc, "-M", "-include-pkg-deps",
            # Note: `-outputdir '.'` removes the prefix of all targets:
            #       backend/src/Foo/Util.<ext> => Foo/Util.<ext>
            "-outputdir", ".",
            "-dep-json", json_fname,
            "-dep-makefile", make_fname,
        ] + ghc_args + sources

        env = os.environ.copy()
        path = env.get("PATH", "")
        env["PATH"] = os.pathsep.join([path] + aux_paths)

        subprocess.run(args, env=env, check=True)

        with open(json_fname) as f:
            return json.load(f)


def calc_package_prefixes(package_specs):
    """Creates a trie to look up modules in dependency packages.

    Package names are stored under the marker key `//pkgname`. This is
    unambiguous since path components may not contain `/` characters.
    """
    result = {}
    for pkgname, path in (spec.split(":", 1) for spec in package_specs):
        layer = result
        for part in Path(path).parts:
            layer = layer.setdefault(part, {})
        layer["//pkgname"] = pkgname
    return result


def lookup_toolchain_dep(module_dep, toolchain_packages):
    module_path = Path(module_dep)
    layer = toolchain_packages["by-import-dirs"]
    for part in module_path.parts:
        if (layer := layer.get(part)) is None:
            return None

        if (pkgid := layer.get("//pkgid")) is not None:
            return pkgid


def lookup_package_dep(module_dep, package_prefixes):
    """Look up a cross-packge module dependency.

    Assumes that `module_dep` is a relative path to an interface file of the form
    `buck-out/.../__my_package__/mod-shared/Some/Package.hi`.
    """
    module_path = Path(module_dep)
    layer = package_prefixes
    for offset, part in enumerate(module_path.parts):
        if (layer := layer.get(part)) is None:
            return None

        if (pkgname := layer.get("//pkgname")) is not None:
            modname = src_to_module_name("/".join(module_path.parts[offset+2:]))
            return pkgname, modname


def interpret_ghc_depends(ghc_depends, source_prefix, package_prefixes, toolchain_packages):
    mapping = {}
    graph = {}
    extgraph = {}
    toolchaingraph = {}

    for k, vs in ghc_depends.items():
        module_name = src_to_module_name(k)
        intdeps, extdeps, toolchaindeps = parse_module_deps(vs, package_prefixes, toolchain_packages)

        graph.setdefault(module_name, []).extend(intdeps)
        for pkg, mods in extdeps.items():
            extgraph.setdefault(module_name, {}).setdefault(pkg, []).extend(mods)
        for pkg in toolchaindeps:
            toolchaingraph.setdefault(module_name, set()).add(pkg)

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

    return mapping, graph, extgraph, toolchaingraph


def parse_module_deps(module_deps, package_prefixes, toolchain_packages):
    internal_deps = []
    external_deps = {}
    toolchain_deps = set()

    for module_dep in module_deps:
        if is_haskell_src(module_dep):
            continue

        if (tooldep := lookup_toolchain_dep(module_dep, toolchain_packages)) is not None:
            toolchain_deps.add(tooldep)
            continue

        if os.path.isabs(module_dep):
            raise RuntimeError(f"Unexpected module dependency `{module_dep}`. Perhaps a missing `haskell_toolchain_library`?")

        if (pkgdep := lookup_package_dep(module_dep, package_prefixes)) is not None:
            pkgname, modname = pkgdep
            external_deps.setdefault(pkgname, []).append(modname)
            continue

        internal_deps.append(src_to_module_name(module_dep))

    return internal_deps, external_deps, toolchain_deps


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
