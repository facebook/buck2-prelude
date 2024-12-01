# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//utils:utils.bzl", "flatten", "dedupe_by_value")

# If the target is a haskell library, the HaskellLibraryProvider
# contains its HaskellLibraryInfo. (in contrast to a HaskellLinkInfo,
# which contains the HaskellLibraryInfo for all the transitive
# dependencies). Direct dependencies are treated differently from
# indirect dependencies for the purposes of module visibility.
HaskellLibraryProvider = provider(
    fields = {
        "lib": provider_field(typing.Any, default = None),  # dict[LinkStyle, HaskellLibraryInfo]
        "prof_lib": provider_field(typing.Any, default = None),  # dict[LinkStyle, HaskellLibraryInfo]
    },
)

# A record of a Haskell library.
HaskellLibraryInfo = record(
    # The library target name: e.g. "rts"
    name = str,
    # package config database: e.g. platform009/build/ghc/lib/package.conf.d
    db = Artifact,
    # package config database, referring to the empty lib which is only used for compilation
    empty_db = Artifact,
    # pacakge config database, used for ghc -M
    deps_db = Artifact,
    # e.g. "base-4.13.0.0"
    id = str,
    # dynamic dependency information
    dynamic = None | dict[bool, DynamicValue],
    # Import dirs indexed by profiling enabled/disabled
    import_dirs = dict[bool, list[Artifact]],
    # Object files indexed by profiling enabled/disabled
    objects = dict[bool, list[Artifact]],
    stub_dirs = list[Artifact],

    # This field is only used as hidden inputs to compilation, to
    # support Template Haskell which may need access to the libraries
    # at compile time.  The real library flags are propagated up the
    # dependency graph via MergedLinkInfo.
    libs = field(list[Artifact], []),
    # Package version, used to specify the full package when exposing it,
    # e.g. filepath-1.4.2.1, deepseq-1.4.4.0.
    # Internal packages default to 1.0.0, e.g. `fbcode-dsi-logger-hs-types-1.0.0`.
    version = str,
    is_prebuilt = bool,
    profiling_enabled = bool,
    # Package dependencies
    dependencies = list[str],
)

def _project_as_package_db(lib: HaskellLibraryInfo):
  return cmd_args(lib.db)

def _project_as_empty_package_db(lib: HaskellLibraryInfo):
  return cmd_args(lib.empty_db)

def _project_as_deps_package_db(lib: HaskellLibraryInfo):
  return cmd_args(lib.deps_db)

def _get_package_deps(children: list[list[str]], lib: HaskellLibraryInfo | None):
    flatted = flatten(children)
    if lib:
        flatted.extend(lib.dependencies)
    return dedupe_by_value(flatted)

HaskellLibraryInfoTSet = transitive_set(
    args_projections = {
        "package_db": _project_as_package_db,
        "empty_package_db": _project_as_empty_package_db,
        "deps_package_db": _project_as_deps_package_db,
    },
    reductions = {
        "packages": _get_package_deps,
    },
)
