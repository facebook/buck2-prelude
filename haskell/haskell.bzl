# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

# Implementation of the Haskell build rules.

load("@prelude//utils:arglike.bzl", "ArgLike")
load("@prelude//:paths.bzl", "paths")
load("@prelude//cxx:archive.bzl", "make_archive")
load(
    "@prelude//cxx:cxx.bzl",
    "get_auto_link_group_specs",
)
load(
    "@prelude//cxx:cxx_context.bzl",
    "get_cxx_toolchain_info",
)
load(
    "@prelude//cxx:cxx_toolchain_types.bzl",
    "CxxToolchainInfo",
    "LinkerType",
    "PicBehavior",
)
load("@prelude//cxx:groups.bzl", "get_dedupped_roots_from_groups")
load(
    "@prelude//cxx:link_groups.bzl",
    "LinkGroupContext",
    "create_link_groups",
    "find_relevant_roots",
    "get_filtered_labels_to_links_map",
    "get_filtered_links",
    "get_link_group_info",
    "get_link_group_preferred_linkage",
    "get_public_link_group_nodes",
    "get_transitive_deps_matching_labels",
    "is_link_group_shlib",
)
load(
    "@prelude//cxx:linker.bzl",
    "LINKERS",
    "get_rpath_origin",
    "get_shared_library_flags",
)
load(
    "@prelude//cxx:preprocessor.bzl",
    "CPreprocessor",
    "CPreprocessorArgs",
    "cxx_inherited_preprocessor_infos",
    "cxx_merge_cpreprocessors",
)
load(
    "@prelude//haskell:compile.bzl",
    "CompileResultInfo",
    "compile",
    "get_packages_info2",
    "target_metadata",
)
load(
    "@prelude//haskell:haskell_haddock.bzl",
    "haskell_haddock_lib",
)
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryInfo",
    "HaskellLibraryInfoTSet",
    "HaskellLibraryProvider",
)
load(
    "@prelude//haskell:link_info.bzl",
    "HaskellLinkInfo",
    "HaskellProfLinkInfo",
    "attr_link_style",
    "cxx_toolchain_link_style",
)
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellToolchainInfo",
    "HaskellToolchainLibrary",
    "HaskellPackageDbTSet",
    "DynamicHaskellPackageDbInfo",
)
load(
    "@prelude//haskell:util.bzl",
    "attr_deps",
    "attr_deps_haskell_link_infos_sans_template_deps",
    "attr_deps_haskell_lib_infos",
    "attr_deps_haskell_link_infos",
    "attr_deps_haskell_toolchain_libraries",
    "attr_deps_merged_link_infos",
    "attr_deps_profiling_link_infos",
    "attr_deps_shared_library_infos",
    "get_artifact_suffix",
    "output_extensions",
    "src_to_module_name",
    "get_source_prefixes",
)
load(
    "@prelude//linking:link_groups.bzl",
    "gather_link_group_libs",
    "merge_link_group_lib_info",
)
load(
    "@prelude//linking:link_info.bzl",
    "Archive",
    "ArchiveLinkable",
    "LibOutputStyle",
    "LinkArgs",
    "LinkInfo",
    "LinkInfos",
    "LinkStyle",
    "LinkedObject",
    "MergedLinkInfo",
    "SharedLibLinkable",
    "create_merged_link_info",
    "default_output_style_for_link_strategy",
    "get_lib_output_style",
    "get_link_args_for_strategy",
    "get_output_styles_for_linkage",
    "legacy_output_style_to_link_style",
    "to_link_strategy",
    "unpack_link_args",
)
load(
    "@prelude//linking:linkable_graph.bzl",
    "LinkableGraph",
    "create_linkable_graph",
    "create_linkable_graph_node",
    "create_linkable_node",
    "get_linkable_graph_node_map_func",
)
load(
    "@prelude//linking:linkables.bzl",
    "linkables",
)
load(
    "@prelude//linking:shared_libraries.bzl",
    "SharedLibraryInfo",
    "create_shared_libraries",
    "create_shlib_symlink_tree",
    "merge_shared_libraries",
    "traverse_shared_library_info",
)
load("@prelude//linking:types.bzl", "Linkage")
load(
    "@prelude//python:python.bzl",
    "PythonLibraryInfo",
)
load("@prelude//utils:argfile.bzl", "at_argfile")
load("@prelude//utils:set.bzl", "set")
load("@prelude//utils:utils.bzl", "filter_and_map_idx", "flatten")

HaskellIndexingTSet = transitive_set()

# A list of hie dirs
HaskellIndexInfo = provider(
    fields = {
        "info": provider_field(typing.Any, default = None),  # dict[LinkStyle, HaskellIndexingTset]
    },
)

# This conversion is non-standard, see TODO about link style below
def _to_lib_output_style(link_style: LinkStyle) -> LibOutputStyle:
    return default_output_style_for_link_strategy(to_link_strategy(link_style))

def _attr_preferred_linkage(ctx: AnalysisContext) -> Linkage:
    preferred_linkage = ctx.attrs.preferred_linkage

    # force_static is deprecated, but it has precedence over preferred_linkage
    if getattr(ctx.attrs, "force_static", False):
        preferred_linkage = "static"

    return Linkage(preferred_linkage)

# --

def haskell_toolchain_library_impl(ctx: AnalysisContext):
    return [DefaultInfo(), HaskellToolchainLibrary(name = ctx.attrs.name)]

# --

def _get_haskell_prebuilt_libs(
        ctx,
        link_style: LinkStyle,
        enable_profiling: bool) -> list[Artifact]:
    if link_style == LinkStyle("shared"):
        if enable_profiling:
            # Profiling doesn't support shared libraries
            return []

        return ctx.attrs.shared_libs.values()
    elif link_style == LinkStyle("static"):
        if enable_profiling:
            return ctx.attrs.profiled_static_libs
        return ctx.attrs.static_libs
    elif link_style == LinkStyle("static_pic"):
        if enable_profiling:
            return ctx.attrs.pic_profiled_static_libs
        return ctx.attrs.pic_static_libs
    else:
        fail("Unexpected LinkStyle: " + link_style.value)

def haskell_prebuilt_library_impl(ctx: AnalysisContext) -> list[Provider]:
    # MergedLinkInfo for both with and without profiling
    native_infos = []
    prof_native_infos = []

    haskell_infos = []
    shared_library_infos = []
    for dep in ctx.attrs.deps:
        used = False
        if HaskellLinkInfo in dep:
            used = True
            haskell_infos.append(dep[HaskellLinkInfo])
        li = dep.get(MergedLinkInfo)
        if li != None:
            used = True
            native_infos.append(li)
            if HaskellLinkInfo not in dep:
                prof_native_infos.append(li)
        if HaskellProfLinkInfo in dep:
            prof_native_infos.append(dep[HaskellProfLinkInfo].prof_infos)
        if SharedLibraryInfo in dep:
            used = True
            shared_library_infos.append(dep[SharedLibraryInfo])
        if PythonLibraryInfo in dep:
            used = True
        if not used:
            fail("Unexpected link info encountered")

    hlibinfos = {}
    prof_hlibinfos = {}
    hlinkinfos = {}
    prof_hlinkinfos = {}
    link_infos = {}
    prof_link_infos = {}
    for link_style in LinkStyle:
        libs = _get_haskell_prebuilt_libs(ctx, link_style, False)
        prof_libs = _get_haskell_prebuilt_libs(ctx, link_style, True)

        hlibinfo = HaskellLibraryInfo(
            name = ctx.attrs.name,
            db = ctx.attrs.db,
            import_dirs = {},
            stub_dirs = [],
            id = ctx.attrs.id,
            dynamic = None,
            libs = libs,
            version = ctx.attrs.version,
            is_prebuilt = True,
            profiling_enabled = False,
        )
        prof_hlibinfo = HaskellLibraryInfo(
            name = ctx.attrs.name,
            db = ctx.attrs.db,
            import_dirs = {},
            stub_dirs = [],
            id = ctx.attrs.id,
            dynamic = None,
            libs = prof_libs,
            version = ctx.attrs.version,
            is_prebuilt = True,
            profiling_enabled = True,
        )

        def archive_linkable(lib):
            return ArchiveLinkable(
                archive = Archive(artifact = lib),
                linker_type = LinkerType("gnu"),
            )

        def shared_linkable(lib):
            return SharedLibLinkable(
                lib = lib,
            )

        linkables = [
            (shared_linkable if link_style == LinkStyle("shared") else archive_linkable)(lib)
            for lib in libs
        ]
        prof_linkables = [
            (shared_linkable if link_style == LinkStyle("shared") else archive_linkable)(lib)
            for lib in prof_libs
        ]

        hlibinfos[link_style] = hlibinfo
        hlinkinfos[link_style] = ctx.actions.tset(
            HaskellLibraryInfoTSet,
            value = hlibinfo,
            children = [lib.info[link_style] for lib in haskell_infos],
        )
        prof_hlibinfos[link_style] = prof_hlibinfo
        prof_hlinkinfos[link_style] = ctx.actions.tset(
            HaskellLibraryInfoTSet,
            value = prof_hlibinfo,
            children = [lib.prof_info[link_style] for lib in haskell_infos],
        )
        link_infos[link_style] = LinkInfos(
            default = LinkInfo(
                pre_flags = ctx.attrs.exported_linker_flags,
                post_flags = ctx.attrs.exported_post_linker_flags,
                linkables = linkables,
            ),
        )
        prof_link_infos[link_style] = LinkInfos(
            default = LinkInfo(
                pre_flags = ctx.attrs.exported_linker_flags,
                post_flags = ctx.attrs.exported_post_linker_flags,
                linkables = prof_linkables,
            ),
        )

    haskell_link_infos = HaskellLinkInfo(
        info = hlinkinfos,
        prof_info = prof_hlinkinfos,
    )
    haskell_lib_provider = HaskellLibraryProvider(
        lib = hlibinfos,
        prof_lib = prof_hlibinfos,
    )

    # The link info that will be used when this library is a dependency of a non-Haskell
    # target (e.g. a cxx_library()). We need to pick the profiling libs if we're in
    # profiling mode.
    default_link_infos = prof_link_infos if ctx.attrs.enable_profiling else link_infos
    default_native_infos = prof_native_infos if ctx.attrs.enable_profiling else native_infos
    merged_link_info = create_merged_link_info(
        ctx,
        # We don't have access to a CxxToolchain here (yet).
        # Give that it's already built, this doesn't mean much, use a sane default.
        pic_behavior = PicBehavior("supported"),
        link_infos = {_to_lib_output_style(s): v for s, v in default_link_infos.items()},
        exported_deps = default_native_infos,
    )

    prof_merged_link_info = create_merged_link_info(
        ctx,
        # We don't have access to a CxxToolchain here (yet).
        # Give that it's already built, this doesn't mean much, use a sane default.
        pic_behavior = PicBehavior("supported"),
        link_infos = {_to_lib_output_style(s): v for s, v in prof_link_infos.items()},
        exported_deps = prof_native_infos,
    )

    solibs = {}
    for soname, lib in ctx.attrs.shared_libs.items():
        solibs[soname] = LinkedObject(output = lib, unstripped_output = lib)
    shared_libs = create_shared_libraries(ctx, solibs)

    linkable_graph = create_linkable_graph(
        ctx,
        node = create_linkable_graph_node(
            ctx,
            linkable_node = create_linkable_node(
                ctx = ctx,
                exported_deps = ctx.attrs.deps,
                link_infos = {_to_lib_output_style(s): v for s, v in link_infos.items()},
                shared_libs = shared_libs,
                default_soname = None,
            ),
        ),
        deps = ctx.attrs.deps,
    )

    inherited_pp_info = cxx_inherited_preprocessor_infos(ctx.attrs.deps)
    own_pp_info = CPreprocessor(
        args = CPreprocessorArgs(args = flatten([["-isystem", d] for d in ctx.attrs.cxx_header_dirs])),
    )

    return [
        DefaultInfo(),
        haskell_lib_provider,
        cxx_merge_cpreprocessors(ctx, [own_pp_info], inherited_pp_info),
        merge_shared_libraries(
            ctx.actions,
            shared_libs,
            shared_library_infos,
        ),
        merge_link_group_lib_info(deps = ctx.attrs.deps),
        haskell_link_infos,
        merged_link_info,
        HaskellProfLinkInfo(
            prof_infos = prof_merged_link_info,
        ),
        linkable_graph,
    ]

# Script to generate a GHC package-db entry for a new package.
#
# Sets --force so that ghc-pkg does not check for .hi, .so, ... files.
# This way package actions can be scheduled before actual build actions,
# don't lie on the critical path for a build, and don't form a bottleneck.
_REGISTER_PACKAGE = """\
set -eu
GHC_PKG=$1
DB=$2
PKGCONF=$3
"$GHC_PKG" init "$DB"
"$GHC_PKG" register --package-conf "$DB" --no-expand-pkgroot "$PKGCONF" --force
"""

# Create a package
#
# The way we use packages is a bit strange. We're not using them
# at link time at all: all the linking info is in the
# HaskellLibraryInfo and we construct linker command lines
# manually. Packages are used for:
#
#  - finding .hi files at compile time
#
#  - symbol namespacing (so that modules with the same name in
#    different libraries don't clash).
#
#  - controlling module visibility: only dependencies that are
#    directly declared as dependencies may be used
#
#  - by GHCi when loading packages into the repl
#
#  - when linking binaries statically, in order to pass libraries
#    to the linker in the correct order
def _make_package(
        ctx: AnalysisContext,
        link_style: LinkStyle,
        pkgname: str,
        libname: str | None,
        hlis: list[HaskellLibraryInfo],
        profiling: list[bool],
        enable_profiling: bool,
        use_empty_lib: bool,
        md_file: Artifact,
        for_deps: bool = False) -> Artifact:
    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    def mk_artifact_dir(dir_prefix: str, profiled: bool, subdir: str = "") -> str:
        suffix = get_artifact_suffix(link_style, profiled)
        if subdir:
            suffix = paths.join(suffix, subdir)
        return "\"${pkgroot}/" + dir_prefix + "-" + suffix + "\""

    if for_deps:
        pkg_conf = ctx.actions.declare_output("pkg-" + artifact_suffix + "_deps.conf")
        db = ctx.actions.declare_output("db-" + artifact_suffix + "_deps", dir = True)
    elif use_empty_lib:
        pkg_conf = ctx.actions.declare_output("pkg-" + artifact_suffix + "_empty.conf")
        db = ctx.actions.declare_output("db-" + artifact_suffix + "_empty", dir = True)
    else:
        pkg_conf = ctx.actions.declare_output("pkg-" + artifact_suffix + ".conf")
        db = ctx.actions.declare_output("db-" + artifact_suffix, dir = True)

    def write_package_conf(ctx, artifacts, outputs, md_file=md_file, libname=libname):
        md = artifacts[md_file].read_json()
        module_map = md["module_mapping"]

        source_prefixes = get_source_prefixes(ctx.attrs.srcs, module_map)

        modules = [
            module
            for module in md["module_graph"].keys()
            if not module.endswith("-boot")
        ]

        # XXX use a single import dir when this package db is used for resolving dependencies with ghc -M,
        #     which works around an issue with multiple import dirs resulting in GHC trying to locate interface files
        #     for each exposed module
        import_dirs = ["."] if for_deps else [
            mk_artifact_dir("mod", profiled, src_prefix) for profiled in profiling for src_prefix in source_prefixes
        ]

        conf = [
            "name: " + pkgname,
            "version: 1.0.0",
            "id: " + pkgname,
            "key: " + pkgname,
            "exposed: False",
            "exposed-modules: " + ", ".join(modules),
            "import-dirs:" + ", ".join(import_dirs),
            "depends: " + ", ".join([lib.id for lib in hlis]),
        ]

        if not use_empty_lib:
            if not libname:
                fail("argument `libname` cannot be empty, when use_empty_lib == False")

            if enable_profiling:
                # Add the `-p` suffix otherwise ghc will look for objects
                # following this logic (https://fburl.com/code/3gmobm5x) and will fail.
                libname += "_p"

            library_dirs = [mk_artifact_dir("lib", profiled) for profiled in profiling]
            conf.append("library-dirs:" + ", ".join(library_dirs))
            conf.append("extra-libraries: " + libname)

        ctx.actions.write(outputs[pkg_conf].as_output(), conf)

        db_deps = [x.db for x in hlis]

        # So that ghc-pkg can find the DBs for the dependencies. We might
        # be able to use flags for this instead, but this works.
        ghc_package_path = cmd_args(
            db_deps,
            delimiter = ":",
        )

        haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
        ctx.actions.run(
            cmd_args([
                "sh",
                "-c",
                _REGISTER_PACKAGE,
                "",
                haskell_toolchain.packager,
                outputs[db].as_output(),
                pkg_conf,
            ]),
            category = "haskell_package_" + artifact_suffix.replace("-", "_"),
            identifier = "empty" if use_empty_lib else "final",
            env = {"GHC_PACKAGE_PATH": ghc_package_path} if db_deps else {},
        )

    ctx.actions.dynamic_output(
        dynamic = [md_file],
        inputs = [],
        outputs = [pkg_conf.as_output(), db.as_output()],
        f = write_package_conf
    )

    return db

HaskellLibBuildOutput = record(
    hlib = HaskellLibraryInfo,
    solibs = dict[str, LinkedObject],
    link_infos = LinkInfos,
    compiled = CompileResultInfo,
    libs = list[Artifact],
)

def _get_haskell_shared_library_name_linker_flags(
        linker_type: LinkerType,
        soname: str) -> list[str]:
    if linker_type == LinkerType("gnu"):
        return ["-Wl,-soname,{}".format(soname)]
    elif linker_type == LinkerType("darwin"):
        # Passing `-install_name @rpath/...` or
        # `-Xlinker -install_name -Xlinker @rpath/...` instead causes
        # ghc-9.6.3: panic! (the 'impossible' happened)
        return ["-Wl,-install_name,@rpath/{}".format(soname)]
    else:
        fail("Unknown linker type '{}'.".format(linker_type))

def _dynamic_link_shared_impl(actions, artifacts, dynamic_values, outputs, arg):
    pkg_deps = dynamic_values[arg.haskell_toolchain.packages.dynamic]
    package_db = pkg_deps.providers[DynamicHaskellPackageDbInfo].packages

    package_db_tset = actions.tset(
        HaskellPackageDbTSet,
        children = [package_db[name] for name in arg.toolchain_libs if name in package_db]
    )

    link_args = cmd_args()
    link_cmd_args = [cmd_args(arg.haskell_toolchain.linker)]
    link_cmd_hidden = []

    link_args.add(arg.haskell_toolchain.linker_flags)
    link_args.add(arg.linker_flags)
    link_args.add("-hide-all-packages")
    link_args.add(cmd_args(arg.toolchain_libs, prepend = "-package"))
    link_args.add(cmd_args(package_db_tset.project_as_args("package_db"), prepend="-package-db"))
    link_args.add(
        get_shared_library_flags(arg.linker_info.type),
        "-dynamic",
        cmd_args(
            _get_haskell_shared_library_name_linker_flags(arg.linker_info.type, arg.libfile),
            prepend = "-optl",
        ),
    )

    link_args.add(arg.objects)

    link_args.add(cmd_args(unpack_link_args(arg.infos), prepend = "-optl"))

    if arg.use_argsfile_at_link:
        link_cmd_args.append(at_argfile(
            actions = actions,
            name = "haskell_link_" + arg.artifact_suffix.replace("-", "_") + ".argsfile",
            args = link_args,
            allow_args = True,
        ))
    else:
        link_cmd_args.append(link_args)

    link_cmd = cmd_args(link_cmd_args, hidden = link_cmd_hidden)
    link_cmd.add("-o", outputs[arg.lib].as_output())

    actions.run(
        link_cmd,
        category = "haskell_link" + arg.artifact_suffix.replace("-", "_"),
    )

    return []

_dynamic_link_shared = dynamic_actions(impl = _dynamic_link_shared_impl)

def _build_haskell_lib(
        ctx,
        libname: str,
        pkgname: str,
        hlis: list[HaskellLinkInfo],  # haskell link infos from all deps
        nlis: list[MergedLinkInfo],  # native link infos from all deps
        link_style: LinkStyle,
        enable_profiling: bool,
        enable_haddock: bool,
        md_file: Artifact,
        # The non-profiling artifacts are also needed to build the package for
        # profiling, so it should be passed when `enable_profiling` is True.
        non_profiling_hlib: [HaskellLibBuildOutput, None] = None) -> HaskellLibBuildOutput:
    linker_info = ctx.attrs._cxx_toolchain[CxxToolchainInfo].linker_info

    # Link the objects into a library
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    # Compile the sources
    compiled = compile(
        ctx,
        link_style,
        enable_profiling = enable_profiling,
        enable_haddock = enable_haddock,
        md_file = md_file,
        pkgname = pkgname,
    )
    solibs = {}
    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    libstem = libname
    if link_style == LinkStyle("static_pic"):
        libstem += "_pic"

    dynamic_lib_suffix = "." + LINKERS[linker_info.type].default_shared_library_extension
    static_lib_suffix = "_p.a" if enable_profiling else ".a"
    libfile = "lib" + libstem + (dynamic_lib_suffix if link_style == LinkStyle("shared") else static_lib_suffix)

    lib_short_path = paths.join("lib-{}".format(artifact_suffix), libfile)

    linfos = [x.prof_info if enable_profiling else x.info for x in hlis]

    # only gather direct dependencies
    uniq_infos = [x[link_style].value for x in linfos]

    toolchain_libs = [dep.name for dep in attr_deps_haskell_toolchain_libraries(ctx)] 

    if link_style == LinkStyle("shared"):
        lib = ctx.actions.declare_output(lib_short_path)
        objects = [
            object
            for object in compiled.objects
            if not object.extension.endswith("-boot")
        ]

        infos = get_link_args_for_strategy(
            ctx,
            nlis,
            to_link_strategy(link_style),
        )

        ctx.actions.dynamic_output_new(_dynamic_link_shared(
            dynamic = [],
            dynamic_values = [haskell_toolchain.packages.dynamic],
            outputs = [lib.as_output()],
            arg = struct(
                artifact_suffix = artifact_suffix,
                haskell_toolchain = haskell_toolchain,
                infos = infos,
                lib = lib,
                libfile = libfile,
                linker_flags = ctx.attrs.linker_flags,
                linker_info = linker_info,
                objects = objects,
                toolchain_libs = toolchain_libs,
                use_argsfile_at_link = ctx.attrs.use_argsfile_at_link,
            ),
        ))

        solibs[libfile] = LinkedObject(output = lib, unstripped_output = lib)
        libs = [lib]
        link_infos = LinkInfos(
            default = LinkInfo(linkables = [SharedLibLinkable(lib = lib)]),
        )

    else:  # static flavours
        # TODO: avoid making an archive for a single object, like cxx does
        # (but would that work with Template Haskell?)
        archive = make_archive(ctx, lib_short_path, compiled.objects)
        lib = archive.artifact
        libs = [lib] + archive.external_objects
        link_infos = LinkInfos(
            default = LinkInfo(
                linkables = [
                    ArchiveLinkable(
                        archive = archive,
                        linker_type = linker_info.type,
                        link_whole = ctx.attrs.link_whole,
                    ),
                ],
            ),
        )

    if enable_profiling and link_style != LinkStyle("shared"):
        if not non_profiling_hlib:
            fail("Non-profiling HaskellLibBuildOutput wasn't provided when building profiling lib")

        dynamic = {
            True: compiled.module_tsets,
            False: non_profiling_hlib.compiled.module_tsets,
        }
        import_artifacts = {
            True: compiled.hi,
            False: non_profiling_hlib.compiled.hi,
        }
        object_artifacts = {
            True: compiled.objects,
            False: non_profiling_hlib.compiled.objects,
        }
        all_libs = libs + non_profiling_hlib.libs
        stub_dirs = [compiled.stubs] + [non_profiling_hlib.compiled.stubs]
    else:
        dynamic = {
            False: compiled.module_tsets,
        }
        import_artifacts = {
            False: compiled.hi,
        }
        object_artifacts = {
            False: compiled.objects,
        }
        all_libs = libs
        stub_dirs = [compiled.stubs]

    db = _make_package(
        ctx,
        link_style,
        pkgname,
        libstem,
        uniq_infos,
        import_artifacts.keys(),
        enable_profiling = enable_profiling,
        use_empty_lib = False,
        md_file = md_file,
    )
    empty_db = _make_package(
        ctx,
        link_style,
        pkgname,
        None,
        uniq_infos,
        import_artifacts.keys(),
        enable_profiling = enable_profiling,
        use_empty_lib = True,
        md_file = md_file,
    )
    deps_db = _make_package(
        ctx,
        link_style,
        pkgname,
        None,
        uniq_infos,
        import_artifacts.keys(),
        enable_profiling = enable_profiling,
        use_empty_lib = True,
        md_file = md_file,
        for_deps = True,
    )


    hlib = HaskellLibraryInfo(
        name = pkgname,
        db = db,
        empty_db = empty_db,
        deps_db = deps_db,
        id = pkgname,
        dynamic = dynamic,  # TODO(ah) refine with dynamic projections
        import_dirs = import_artifacts,
        objects = object_artifacts,
        stub_dirs = stub_dirs,
        libs = all_libs,
        version = "1.0.0",
        is_prebuilt = False,
        profiling_enabled = enable_profiling,
        dependencies = toolchain_libs,
    )

    return HaskellLibBuildOutput(
        hlib = hlib,
        solibs = solibs,
        link_infos = link_infos,
        compiled = compiled,
        libs = libs,
    )

def haskell_library_impl(ctx: AnalysisContext) -> list[Provider]:
    preferred_linkage = _attr_preferred_linkage(ctx)
    if ctx.attrs.enable_profiling and preferred_linkage == Linkage("any"):
        preferred_linkage = Linkage("static")

    # Get haskell and native link infos from all deps
    hlis = attr_deps_haskell_link_infos_sans_template_deps(ctx)
    nlis = attr_deps_merged_link_infos(ctx)
    prof_nlis = attr_deps_profiling_link_infos(ctx)
    shared_library_infos = attr_deps_shared_library_infos(ctx)

    solibs = {}
    link_infos = {}
    prof_link_infos = {}
    hlib_infos = {}
    hlink_infos = {}
    prof_hlib_infos = {}
    prof_hlink_infos = {}
    indexing_tsets = {}
    sub_targets = {}

    libname = repr(ctx.label.path).replace("//", "_").replace("/", "_") + "_" + ctx.label.name
    pkgname = libname.replace("_", "-")

    md_file = target_metadata(
        ctx,
        sources = ctx.attrs.srcs,
    )

    # The non-profiling library is also needed to build the package with
    # profiling enabled, so we need to keep track of it for each link style.
    non_profiling_hlib = {}
    for enable_profiling in [False, True]:
        for output_style in get_output_styles_for_linkage(preferred_linkage):
            link_style = legacy_output_style_to_link_style(output_style)
            if link_style == LinkStyle("shared") and enable_profiling:
                # Profiling isn't support with dynamic linking
                continue

            hlib_build_out = _build_haskell_lib(
                ctx,
                libname,
                pkgname,
                hlis = hlis,
                nlis = nlis,
                link_style = link_style,
                enable_profiling = enable_profiling,
                # enable haddock only for the first non-profiling hlib
                enable_haddock = not enable_profiling and not non_profiling_hlib,
                md_file = md_file,
                non_profiling_hlib = non_profiling_hlib.get(link_style),
            )
            if not enable_profiling:
                non_profiling_hlib[link_style] = hlib_build_out

            hlib = hlib_build_out.hlib
            solibs.update(hlib_build_out.solibs)
            compiled = hlib_build_out.compiled
            libs = hlib_build_out.libs

            if enable_profiling:
                prof_hlib_infos[link_style] = hlib
                prof_hlink_infos[link_style] = ctx.actions.tset(
                    HaskellLibraryInfoTSet,
                    value = hlib,
                    children = [li.prof_info[link_style] for li in hlis],
                )
                prof_link_infos[link_style] = hlib_build_out.link_infos
            else:
                hlib_infos[link_style] = hlib
                hlink_infos[link_style] = ctx.actions.tset(
                    HaskellLibraryInfoTSet,
                    value = hlib,
                    children = [li.info[link_style] for li in hlis],
                )
                link_infos[link_style] = hlib_build_out.link_infos

            # Build the indices and create subtargets only once, with profiling
            # enabled or disabled based on what was set in the library's
            # target.
            if ctx.attrs.enable_profiling == enable_profiling:
                if compiled.producing_indices:
                    tset = derive_indexing_tset(
                        ctx.actions,
                        link_style,
                        compiled.hi,
                        attr_deps(ctx),
                    )
                    indexing_tsets[link_style] = tset

                sub_targets[link_style.value.replace("_", "-")] = [DefaultInfo(
                    default_outputs = libs,
                    sub_targets = _haskell_module_sub_targets(
                        compiled = compiled,
                        link_style = link_style,
                        enable_profiling = enable_profiling,
                    ),
                )]

    pic_behavior = ctx.attrs._cxx_toolchain[CxxToolchainInfo].pic_behavior
    link_style = cxx_toolchain_link_style(ctx)
    output_style = get_lib_output_style(
        to_link_strategy(link_style),
        preferred_linkage,
        pic_behavior,
    )
    shared_libs = create_shared_libraries(ctx, solibs)

    # TODO(cjhopman): this haskell implementation does not consistently handle LibOutputStyle
    # and LinkStrategy as expected and it's hard to tell what the intent of the existing code is
    # and so we currently just preserve its existing use of the legacy LinkStyle type and just
    # naively convert it at the boundaries of other code. This needs to be cleaned up by someone
    # who understands the intent of the code here.
    actual_link_style = legacy_output_style_to_link_style(output_style)

    if preferred_linkage != Linkage("static"):
        # Profiling isn't support with dynamic linking, but `prof_link_infos`
        # needs entries for all link styles.
        # We only need to set the shared link_style in both `prof_link_infos`
        # and `link_infos` if the target doesn't force static linking.
        prof_link_infos[LinkStyle("shared")] = link_infos[LinkStyle("shared")]

    default_link_infos = prof_link_infos if ctx.attrs.enable_profiling else link_infos
    default_native_infos = prof_nlis if ctx.attrs.enable_profiling else nlis
    merged_link_info = create_merged_link_info(
        ctx,
        pic_behavior = pic_behavior,
        link_infos = {_to_lib_output_style(s): v for s, v in default_link_infos.items()},
        preferred_linkage = preferred_linkage,
        exported_deps = default_native_infos,
    )

    prof_merged_link_info = create_merged_link_info(
        ctx,
        pic_behavior = pic_behavior,
        link_infos = {_to_lib_output_style(s): v for s, v in prof_link_infos.items()},
        preferred_linkage = preferred_linkage,
        exported_deps = prof_nlis,
    )

    linkable_graph = create_linkable_graph(
        ctx,
        node = create_linkable_graph_node(
            ctx,
            linkable_node = create_linkable_node(
                ctx = ctx,
                preferred_linkage = preferred_linkage,
                exported_deps = ctx.attrs.deps,
                link_infos = {_to_lib_output_style(s): v for s, v in link_infos.items()},
                shared_libs = shared_libs,
                # TODO(cjhopman): this should be set to non-None
                default_soname = None,
            ),
        ),
        deps = ctx.attrs.deps,
    )

    default_output = hlib_infos[actual_link_style].libs

    inherited_pp_info = cxx_inherited_preprocessor_infos(attr_deps(ctx))

    # We would like to expose the generated _stub.h headers to C++
    # compilations, but it's hard to do that without overbuilding. Which
    # link_style should we pick below? If we pick a different link_style from
    # the one being used by the root rule, we'll end up building all the
    # Haskell libraries multiple times.
    #
    #    pp = [CPreprocessor(
    #        args =
    #            flatten([["-isystem", dir] for dir in hlib_infos[actual_link_style].stub_dirs]),
    #    )]
    pp = []

    haddock, = haskell_haddock_lib(
        ctx,
        pkgname,
        non_profiling_hlib[LinkStyle("shared")].compiled,
        md_file,
    ),

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    styles = [
        ctx.actions.declare_output("haddock-html", file)
        for file in "synopsis.png linuwial.css quick-jump.css haddock-bundle.min.js".split()
    ]
    ctx.actions.run(
        cmd_args(
            haskell_toolchain.haddock,
            "--gen-index",
            "-o", cmd_args(styles[0].as_output(), parent=1),
            hidden=[file.as_output() for file in styles]
        ),
        category = "haddock_styles",
    )
    sub_targets.update({
        "haddock": [DefaultInfo(
            default_outputs = haddock.html.values(),
            sub_targets = {
                module: [DefaultInfo(default_output = html, other_outputs=styles)]
                for module, html in haddock.html.items()
            }
        )]
    })

    providers = [
        DefaultInfo(
            default_outputs = default_output,
            sub_targets = sub_targets,
        ),
        HaskellLibraryProvider(
            lib = hlib_infos,
            prof_lib = prof_hlib_infos,
        ),
        HaskellLinkInfo(
            info = hlink_infos,
            prof_info = prof_hlink_infos,
        ),
        merged_link_info,
        HaskellProfLinkInfo(
            prof_infos = prof_merged_link_info,
        ),
        linkable_graph,
        cxx_merge_cpreprocessors(ctx, pp, inherited_pp_info),
        merge_shared_libraries(
            ctx.actions,
            shared_libs,
            shared_library_infos,
        ),
        haddock,
    ]

    if indexing_tsets:
        providers.append(HaskellIndexInfo(info = indexing_tsets))

    # TODO(cjhopman): This code is for templ_vars is duplicated from cxx_library
    templ_vars = {}

    # Add in ldflag macros.
    for link_style in (LinkStyle("static"), LinkStyle("static_pic")):
        name = "ldflags-" + link_style.value.replace("_", "-")
        args = cmd_args()
        linker_info = ctx.attrs._cxx_toolchain[CxxToolchainInfo].linker_info
        args.add(linker_info.linker_flags)
        args.add(unpack_link_args(
            get_link_args_for_strategy(
                ctx,
                [merged_link_info],
                to_link_strategy(link_style),
            ),
        ))
        templ_vars[name] = args

    # TODO(T110378127): To implement `$(ldflags-shared ...)` properly, we'd need
    # to setup a symink tree rule for all transitive shared libs.  Since this
    # currently would be pretty costly (O(N^2)?), and since it's not that
    # commonly used anyway, just use `static-pic` instead.  Longer-term, once
    # v1 is gone, macros that use `$(ldflags-shared ...)` (e.g. Haskell's
    # hsc2hs) can move to a v2 rules-based API to avoid needing this macro.
    templ_vars["ldflags-shared"] = templ_vars["ldflags-static-pic"]

    providers.append(TemplatePlaceholderInfo(keyed_variables = templ_vars))

    providers.append(merge_link_group_lib_info(deps = attr_deps(ctx)))

    return providers

# TODO(cjhopman): should this be LibOutputType or LinkStrategy?
def derive_indexing_tset(
        actions: AnalysisActions,
        link_style: LinkStyle,
        value: list[Artifact] | None,
        children: list[Dependency]) -> HaskellIndexingTSet:
    index_children = []
    for dep in children:
        li = dep.get(HaskellIndexInfo)
        if li:
            if (link_style in li.info):
                index_children.append(li.info[link_style])

    return actions.tset(
        HaskellIndexingTSet,
        value = value,
        children = index_children,
    )

def _make_link_package(
        ctx: AnalysisContext,
        link_style: LinkStyle,
        pkgname: str,
        hlis: list[HaskellLibraryInfo],
        static_libs: ArgLike) -> Artifact:
    artifact_suffix = get_artifact_suffix(link_style, False)

    conf = cmd_args(
        "name: " + pkgname,
        "version: 1.0.0",
        "id: " + pkgname,
        "key: " + pkgname,
        "exposed: False",
        cmd_args(cmd_args(static_libs, delimiter = ", "), format = "ld-options: {}"),
        "depends: " + ", ".join([lib.id for lib in hlis]),
    )

    pkg_conf = ctx.actions.write("pkg-" + artifact_suffix + "_link.conf", conf)
    db = ctx.actions.declare_output("db-" + artifact_suffix + "_link", dir = True)

    # While the list of hlis is unique, there may be multiple packages in the same db.
    # Cutting down the GHC_PACKAGE_PATH significantly speeds up GHC.
    db_deps = {x.db: None for x in hlis}.keys()

    # So that ghc-pkg can find the DBs for the dependencies. We might
    # be able to use flags for this instead, but this works.
    ghc_package_path = cmd_args(
        db_deps,
        delimiter = ":",
    )

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    ctx.actions.run(
        cmd_args([
            "sh",
            "-c",
            _REGISTER_PACKAGE,
            "",
            haskell_toolchain.packager,
            db.as_output(),
            pkg_conf,
        ]),
        category = "haskell_package_link" + artifact_suffix.replace("-", "_"),
        env = {"GHC_PACKAGE_PATH": ghc_package_path},
    )

    return db

def _dynamic_link_binary_impl(actions, artifacts, dynamic_values, outputs, arg):
    link_cmd = arg.link.copy() # link is already frozen, make a copy

    # Add -package-db and -package/-expose-package flags for each Haskell
    # library dependency.
    packages_info = get_packages_info2(
        actions,
        deps = arg.deps,
        direct_deps_link_info = arg.direct_deps_link_info,
        haskell_toolchain = arg.haskell_toolchain,
        haskell_direct_deps_lib_infos = arg.haskell_direct_deps_lib_infos,
        link_style = arg.link_style,
        resolved = dynamic_values,
        specify_pkg_version = False,
        enable_profiling = arg.enable_profiling,
        use_empty_lib = False,
    )

    link_cmd.add("-hide-all-packages")
    link_cmd.add(cmd_args(arg.toolchain_libs, prepend = "-package"))
    link_cmd.add(cmd_args(packages_info.exposed_package_args))
    link_cmd.add(cmd_args(packages_info.packagedb_args, prepend = "-package-db"))
    link_cmd.add(arg.haskell_toolchain.linker_flags)
    link_cmd.add(arg.linker_flags)

    link_cmd.add("-o", outputs[arg.output].as_output())

    actions.run(link_cmd, category = "haskell_link")

    return []

_dynamic_link_binary = dynamic_actions(impl = _dynamic_link_binary_impl)

def haskell_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    enable_profiling = ctx.attrs.enable_profiling

    # Decide what kind of linking we're doing

    link_style = attr_link_style(ctx)

    # Link Groups
    link_group_info = get_link_group_info(ctx, filter_and_map_idx(LinkableGraph, attr_deps(ctx)))

    # Profiling doesn't support shared libraries
    if enable_profiling and link_style == LinkStyle("shared"):
        link_style = LinkStyle("static")

    md_file = target_metadata(ctx, sources = ctx.attrs.srcs)

    compiled = compile(
        ctx,
        link_style,
        enable_profiling = enable_profiling,
        enable_haddock = False,
        md_file = md_file,
    )

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    toolchain_libs = [dep[HaskellToolchainLibrary].name for dep in ctx.attrs.deps if HaskellToolchainLibrary in dep]

    output = ctx.actions.declare_output(ctx.attrs.name)
    link = cmd_args(haskell_toolchain.compiler)

    objects = {}

    # only add the first object per module
    # TODO[CB] restructure this to use a record / dict for compiled.objects
    for obj in compiled.objects:
        key = paths.replace_extension(obj.short_path, "")
        if not key in objects:
            objects[key] = obj

    link.add(objects.values())

    indexing_tsets = {}
    if compiled.producing_indices:
        tset = derive_indexing_tset(ctx.actions, link_style, compiled.hi, attr_deps(ctx))
        indexing_tsets[link_style] = tset

    slis = []
    for lib in attr_deps(ctx):
        li = lib.get(SharedLibraryInfo)
        if li != None:
            slis.append(li)
    shlib_info = merge_shared_libraries(
        ctx.actions,
        deps = slis,
    )

    sos = []

    link_strategy = to_link_strategy(link_style)
    if link_group_info != None:
        own_binary_link_flags = []
        auto_link_groups = {}
        link_group_libs = {}
        link_deps = linkables(attr_deps(ctx))
        linkable_graph_node_map = get_linkable_graph_node_map_func(link_group_info.graph)()
        link_group_preferred_linkage = get_link_group_preferred_linkage(link_group_info.groups.values())

        # If we're using auto-link-groups, where we generate the link group links
        # in the prelude, the link group map will give us the link group libs.
        # Otherwise, pull them from the `LinkGroupLibInfo` provider from out deps.
        auto_link_group_specs = get_auto_link_group_specs(ctx, link_group_info)
        executable_deps = [d.linkable_graph.nodes.value.label for d in link_deps if d.linkable_graph != None]
        public_nodes = get_public_link_group_nodes(
            linkable_graph_node_map,
            link_group_info.mappings,
            executable_deps,
            None,
        )
        if auto_link_group_specs != None:
            linked_link_groups = create_link_groups(
                ctx = ctx,
                link_strategy = link_strategy,
                link_group_mappings = link_group_info.mappings,
                link_group_preferred_linkage = link_group_preferred_linkage,
                executable_deps = executable_deps,
                link_group_specs = auto_link_group_specs,
                linkable_graph_node_map = linkable_graph_node_map,
                public_nodes = public_nodes,
            )
            for name, linked_link_group in linked_link_groups.libs.items():
                auto_link_groups[name] = linked_link_group.artifact
                if linked_link_group.library != None:
                    link_group_libs[name] = linked_link_group.library
            own_binary_link_flags += linked_link_groups.symbol_ldflags

        else:
            # NOTE(agallagher): We don't use version scripts and linker scripts
            # for non-auto-link-group flow, as it's note clear it's useful (e.g.
            # it's mainly for supporting dlopen-enabled libs and extensions).
            link_group_libs = gather_link_group_libs(
                children = [d.link_group_lib_info for d in link_deps],
            )

        link_group_relevant_roots = find_relevant_roots(
            linkable_graph_node_map = linkable_graph_node_map,
            link_group_mappings = link_group_info.mappings,
            roots = get_dedupped_roots_from_groups(link_group_info.groups.values()),
        )

        labels_to_links = get_filtered_labels_to_links_map(
            public_nodes = public_nodes,
            linkable_graph_node_map = linkable_graph_node_map,
            link_group = None,
            link_groups = link_group_info.groups,
            link_group_mappings = link_group_info.mappings,
            link_group_preferred_linkage = link_group_preferred_linkage,
            link_group_libs = {
                name: (lib.label, lib.shared_link_infos)
                for name, lib in link_group_libs.items()
            },
            link_strategy = link_strategy,
            roots = (
                [
                    d.linkable_graph.nodes.value.label
                    for d in link_deps
                    if d.linkable_graph != None
                ] +
                link_group_relevant_roots
            ),
            is_executable_link = True,
            force_static_follows_dependents = True,
            pic_behavior = PicBehavior("supported"),
        )

        # NOTE: Our Haskell DLL support impl currently links transitive haskell
        # deps needed by DLLs which get linked into the main executable as link-
        # whole.  To emulate this, we mark Haskell rules with a special label
        # and traverse this to find all the nodes we need to link whole.
        public_nodes = []
        if ctx.attrs.link_group_public_deps_label != None:
            public_nodes = get_transitive_deps_matching_labels(
                linkable_graph_node_map = linkable_graph_node_map,
                label = ctx.attrs.link_group_public_deps_label,
                roots = link_group_relevant_roots,
            )

        link_infos = []
        link_infos.append(
            LinkInfo(
                pre_flags = own_binary_link_flags,
            ),
        )
        link_infos.extend(get_filtered_links(labels_to_links.map, set(public_nodes)))
        infos = LinkArgs(infos = link_infos)

        link_group_ctx = LinkGroupContext(
            link_group_mappings = link_group_info.mappings,
            link_group_libs = link_group_libs,
            link_group_preferred_linkage = link_group_preferred_linkage,
            labels_to_links_map = labels_to_links.map,
            targets_consumed_by_link_groups = {},
        )

        for shared_lib in traverse_shared_library_info(shlib_info):
            label = shared_lib.label
            if is_link_group_shlib(label, link_group_ctx):
                sos.append(shared_lib)

        # When there are no matches for a pattern based link group,
        # `link_group_mappings` will not have an entry associated with the lib.
        for _name, link_group_lib in link_group_libs.items():
            sos.extend(link_group_lib.shared_libs.libraries)

    else:
        nlis = []
        for lib in attr_deps(ctx):
            if enable_profiling:
                hli = lib.get(HaskellProfLinkInfo)
                if hli != None:
                    nlis.append(hli.prof_infos)
                    continue
            li = lib.get(MergedLinkInfo)
            if li != None:
                nlis.append(li)
        sos.extend(traverse_shared_library_info(shlib_info))
        infos = get_link_args_for_strategy(ctx, nlis, to_link_strategy(link_style))

    if link_style in [LinkStyle("static"), LinkStyle("static_pic")]:
        hlis = attr_deps_haskell_link_infos_sans_template_deps(ctx)
        linfos = [x.prof_info if enable_profiling else x.info for x in hlis]
        uniq_infos = [x[link_style].value for x in linfos]

        pkgname = ctx.label.name + "-link"
        linkable_artifacts = [
            f.archive.artifact
            for link in infos.tset.infos.traverse(ordering = "topological")
            for f in link.default.linkables
        ]
        db = _make_link_package(
            ctx,
            link_style,
            pkgname,
            uniq_infos,
            linkable_artifacts,
        )

        link.add(cmd_args(db, prepend = "-package-db"))
        link.add("-package", pkgname)
        link.add(cmd_args(hidden = linkable_artifacts))
    else:
        link.add(cmd_args(unpack_link_args(infos), prepend = "-optl"))

    haskell_direct_deps_lib_infos = attr_deps_haskell_lib_infos(
        ctx,
        link_style,
        enable_profiling = enable_profiling,
    )

    ctx.actions.dynamic_output_new(_dynamic_link_binary(
        dynamic = [],
        dynamic_values = [haskell_toolchain.packages.dynamic] if haskell_toolchain.packages else [ ],
        outputs = [output.as_output()],
        arg = struct(
            deps = ctx.attrs.deps,
            direct_deps_link_info = attr_deps_haskell_link_infos(ctx),
            enable_profiling = enable_profiling,
            haskell_direct_deps_lib_infos = haskell_direct_deps_lib_infos,
            haskell_toolchain = haskell_toolchain,
            link = link,
            link_style = link_style,
            linker_flags = ctx.attrs.linker_flags,
            output = output,
            toolchain_libs = toolchain_libs,
        ),
    ))

    if link_style == LinkStyle("shared") or link_group_info != None:
        sos_dir = "__{}__shared_libs_symlink_tree".format(ctx.attrs.name)
        rpath_ref = get_rpath_origin(get_cxx_toolchain_info(ctx).linker_info.type)
        rpath_ldflag = "-Wl,{}/{}".format(rpath_ref, sos_dir)
        link.add("-optl", "-Wl,-rpath", "-optl", rpath_ldflag)
        symlink_dir = create_shlib_symlink_tree(
            actions = ctx.actions,
            out = sos_dir,
            shared_libs = sos,
        )
        run = cmd_args(output, hidden = symlink_dir)
    else:
        run = cmd_args(output)

    sub_targets = {}
    sub_targets.update(_haskell_module_sub_targets(
        compiled = compiled,
        link_style = link_style,
        enable_profiling = enable_profiling,
    ))

    providers = [
        DefaultInfo(
            default_output = output,
            sub_targets = sub_targets,
        ),
        RunInfo(args = run),
    ]

    if indexing_tsets:
        providers.append(HaskellIndexInfo(info = indexing_tsets))

    return providers

def _haskell_module_sub_targets(*, compiled, link_style, enable_profiling):
    (osuf, hisuf) = output_extensions(link_style, enable_profiling)
    return {
        "interfaces": [DefaultInfo(sub_targets = {
            src_to_module_name(hi.short_path): [DefaultInfo(default_output = hi)]
            for hi in compiled.hi
            if hi.extension[1:] == hisuf
        })],
        "objects": [DefaultInfo(sub_targets = {
            src_to_module_name(o.short_path): [DefaultInfo(default_output = o)]
            for o in compiled.objects
            if o.extension[1:] == osuf
        })],
    }
