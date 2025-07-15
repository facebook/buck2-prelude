# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//utils:arglike.bzl", "ArgLike")

load(
    "@prelude//cxx:preprocessor.bzl",
    "cxx_inherited_preprocessor_infos",
    "cxx_merge_cpreprocessors_actions",
)
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryProvider",
    "HaskellLibraryInfoTSet",
)
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryInfo",
)
load(
    "@prelude//haskell:link_info.bzl",
    "HaskellLinkInfo",
)
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellToolchainInfo",
    "HaskellToolchainLibrary",
    "DynamicHaskellPackageDbInfo",
    "HaskellPackageDbTSet",
    "NativeToolchainLibrary",
)
load(
    "@prelude//haskell:util.bzl",
    "attr_deps",
    "attr_deps_haskell_lib_infos",
    "attr_deps_haskell_link_infos",
    "attr_deps_haskell_toolchain_libraries",
    "get_artifact_suffix",
    "get_source_prefixes",
    "is_haskell_boot",
    "is_haskell_src",
    "output_extensions",
    "src_to_module_name",
    "srcs_to_pairs",
)
load(
    "@prelude//linking:link_info.bzl",
    "LinkStyle",
)
load("@prelude//utils:argfile.bzl", "argfile", "at_argfile")
load("@prelude//:paths.bzl", "paths")
load("@prelude//utils:graph_utils.bzl", "post_order_traversal")
load("@prelude//utils:strings.bzl", "strip_prefix")
load("@prelude//haskell:util.bzl", "to_hash")

CompiledModuleInfo = provider(fields = {
    "abi": provider_field(Artifact),
    "interfaces": provider_field(list[Artifact]),
    # TODO[AH] track this module's package-name/id & package-db instead.
    "db_deps": provider_field(list[Artifact]),
})

def _compiled_module_project_as_abi(mod: CompiledModuleInfo) -> cmd_args:
    return cmd_args(mod.abi)

def _compiled_module_project_as_interfaces(mod: CompiledModuleInfo) -> cmd_args:
    return cmd_args(mod.interfaces)

def _compiled_module_reduce_as_packagedb_deps(children: list[dict[Artifact, None]], mod: CompiledModuleInfo | None) -> dict[Artifact, None]:
    # TODO[AH] is there a better way to avoid duplicate package-dbs?
    #   Using a projection instead would produce duplicates.
    result = {db: None for db in mod.db_deps} if mod else {}
    for child in children:
        result.update(child)
    return result

CompiledModuleTSet = transitive_set(
    args_projections = {
        "abi": _compiled_module_project_as_abi,
        "interfaces": _compiled_module_project_as_interfaces,
    },
    reductions = {
        "packagedb_deps": _compiled_module_reduce_as_packagedb_deps,
    },
)

DynamicCompileResultInfo = provider(fields = {
    "modules": dict[str, CompiledModuleTSet],
})

# The type of the return value of the `_compile()` function.
CompileResultInfo = record(
    objects = field(list[Artifact]),
    hi = field(list[Artifact]),
    stubs = field(Artifact),
    hashes = field(list[Artifact]),
    producing_indices = field(bool),
    module_tsets = field(DynamicValue),
)

CompileArgsInfo = record(
    srcs = field(cmd_args),
    args_for_cmd = field(cmd_args),
    args_for_file = field(cmd_args),
)

PackagesInfo = record(
    exposed_package_args = cmd_args,
    packagedb_args = cmd_args,
    transitive_deps = field(HaskellLibraryInfoTSet),
)

_Module = record(
    source = field(Artifact),
    interfaces = field(list[Artifact]),
    hash = field(Artifact | None),
    objects = field(list[Artifact]),
    stub_dir = field(Artifact | None),
    prefix_dir = field(str),
)


def _strip_prefix(prefix, s):
    stripped = strip_prefix(prefix, s)

    return stripped if stripped != None else s


def _modules_by_name(ctx: AnalysisContext, *, sources: list[Artifact], link_style: LinkStyle, enable_profiling: bool, suffix: str, module_prefix: str | None) -> dict[str, _Module]:
    modules = {}

    osuf, hisuf = output_extensions(link_style, enable_profiling)

    for src in sources:
        bootsuf = ""
        if is_haskell_boot(src.short_path):
            bootsuf = "-boot"
        elif not is_haskell_src(src.short_path):
            continue

        module_name = src_to_module_name(src.short_path) + bootsuf
        if module_prefix:
            interface_path = paths.replace_extension(module_prefix.replace(".", "/") + "/" + src.short_path, "." + hisuf + bootsuf)
        else:
            interface_path = paths.replace_extension(src.short_path, "." + hisuf + bootsuf)
        interface = ctx.actions.declare_output("mod-" + suffix, interface_path)
        interfaces = [interface]
        object_path = paths.replace_extension(src.short_path, "." + osuf + bootsuf)
        object = ctx.actions.declare_output("mod-" + suffix, object_path)
        objects = [object]
        if ctx.attrs.incremental:
            hash = ctx.actions.declare_output("mod-" + suffix, interface_path + ".hash")
        else:
            hash = None

        if link_style in [LinkStyle("static"), LinkStyle("static_pic")]:
            dyn_osuf, dyn_hisuf = output_extensions(LinkStyle("shared"), enable_profiling)
            interface_path = paths.replace_extension(src.short_path, "." + dyn_hisuf + bootsuf)
            interface = ctx.actions.declare_output("mod-" + suffix, interface_path)
            interfaces.append(interface)
            object_path = paths.replace_extension(src.short_path, "." + dyn_osuf + bootsuf)
            object = ctx.actions.declare_output("mod-" + suffix, object_path)
            objects.append(object)

        if ctx.attrs.incremental:
            if bootsuf == "":
                stub_dir = ctx.actions.declare_output("stub-" + suffix + "-" + module_name, dir=True)
            else:
                stub_dir = None
        else:
            stub_dir = None

        prefix_dir = "mod-" + suffix

        modules[module_name] = _Module(
            source = src,
            interfaces = interfaces,
            hash = hash,
            objects = objects,
            stub_dir = stub_dir,
            prefix_dir = prefix_dir)

    return modules

def _dynamic_target_metadata_impl(actions, output, arg, pkg_deps) -> list[Provider]:
    # Add -package-db and -package/-expose-package flags for each Haskell
    # library dependency.

    packages_info = get_packages_info(
        actions,
        arg.deps,
        arg.direct_deps_link_info,
        arg.haskell_toolchain,
        arg.haskell_direct_deps_lib_infos,
        LinkStyle("shared"),
        specify_pkg_version = False,
        enable_profiling = False,
        use_empty_lib = True,
        for_deps = True,
        pkg_deps = pkg_deps,
    )
    package_flag = _package_flag(arg.haskell_toolchain)
    ghc_args = cmd_args()
    ghc_args.add("-j")
    ghc_args.add("-hide-all-packages")

    ghc_args.add(cmd_args(arg.toolchain_libs, prepend=package_flag))
    ghc_args.add(cmd_args(packages_info.exposed_package_args))
    ghc_args.add(cmd_args(packages_info.packagedb_args, prepend = "-package-db"))
    ghc_args.add(arg.compiler_flags)

    md_args = cmd_args()
    md_args.add(cmd_args(
        arg.external_tool_paths,
        format="--bin-exe={}",
    ))

    md_args.add("--ghc", arg.haskell_toolchain.compiler)
    md_args.add(cmd_args(ghc_args, format="--ghc-arg={}"))
    md_args.add(
        "--source-prefix",
        arg.strip_prefix,
    )
    md_args.add(cmd_args(arg.sources, format="--source={}"))

    md_args.add(
        arg.lib_package_name_and_prefix,
    )
    md_args.add("--output", output)

    haskell_toolchain = arg.haskell_toolchain
    if arg.allow_worker and haskell_toolchain.use_worker and haskell_toolchain.worker_make:
        bp_args = cmd_args()
        bp_args.add("--ghc", arg.haskell_toolchain.compiler)
        bp_args.add("--ghc-dir", haskell_toolchain.ghc_dir)
        add_worker_args(haskell_toolchain, bp_args, arg.pkgname)

        build_plan = actions.declare_output(arg.pkgname + ".depends.json")
        makefile = actions.declare_output(arg.pkgname + ".depends.make")

        bp_args.add("-j")
        bp_args.add("-hide-all-packages")
        bp_args.add("-include-pkg-deps")
        bp_args.add(cmd_args(
            arg.external_tool_paths,
            format="--bin-exe={}",
        ))
        bp_args.add(cmd_args(arg.toolchain_libs, prepend=package_flag))
        bp_args.add(cmd_args(packages_info.exposed_package_args))
        bp_args.add(cmd_args(packages_info.packagedb_args, prepend = "-package-db"))
        bp_args.add(arg.compiler_flags)
        bp_args.add("-M")
        bp_args.add("-dep-json", build_plan.as_output())
        bp_args.add("-dep-makefile", makefile.as_output())
        bp_args.add("-outputdir", ".")
        bp_args.add("-this-unit-id", arg.pkgname)
        bp_args.add(cmd_args(arg.sources))

        actions.run(
            bp_args,
            category = "haskell_buildplan",
            identifier = arg.suffix if arg.suffix else None,
            exe = WorkerRunInfo(worker = arg.worker),
        )
        md_args.add("--build-plan", build_plan)

    md_args_output = actions.declare_output("dynamic_target_metadata_args")
    actions.write(
        md_args_output.as_output(),
        md_args,
        allow_args = True,
    )

    md_args_outer = cmd_args(arg.md_gen)
    md_args_outer.add(cmd_args(md_args_output, format="@{}", hidden = md_args))

    actions.run(
        md_args_outer,
        category = "haskell_metadata",
        identifier = arg.suffix if arg.suffix else None,
        # explicit turn this on for local_only actions to upload their results.
        allow_cache_upload = True,
    )

    return []

_dynamic_target_metadata = dynamic_actions(
    impl = _dynamic_target_metadata_impl,
    attrs = {
        "output": dynattrs.output(),
        "arg": dynattrs.value(typing.Any),
        "pkg_deps": dynattrs.option(dynattrs.dynamic_value()),
    },
)

def target_metadata(
        ctx: AnalysisContext,
        *,
        sources: list[Artifact],
        suffix: str = "",
        worker: WorkerInfo | None,
    ) -> Artifact:
    md_file = ctx.actions.declare_output(ctx.label.name + suffix + ".md.json")
    md_gen = ctx.attrs._generate_target_metadata[RunInfo]

    libprefix = repr(ctx.label.path).replace("//", "_").replace("/", "_")

    # avoid consecutive "--" in package name, which is not allowed by ghc-pkg.
    if libprefix[-1] == '_':
        libname = libprefix + ctx.label.name
    else:
        libname = libprefix + "_" + ctx.label.name
    pkgname = libname.replace("_", "-")

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    toolchain_libs = [dep.name for dep in attr_deps_haskell_toolchain_libraries(ctx)]

    haskell_direct_deps_lib_infos = attr_deps_haskell_lib_infos(
        ctx,
        LinkStyle("shared"),
        enable_profiling = False,
    )

    # The object and interface file paths are depending on the real module name
    # as inferred by GHC, not the source file path; currently this requires the
    # module name to correspond to the source file path as otherwise GHC will
    # not be able to find the created object or interface files in the search
    # path.
    #
    # (module X.Y.Z must be defined in a file at X/Y/Z.hs)

    ctx.actions.dynamic_output_new(_dynamic_target_metadata(
        pkg_deps = haskell_toolchain.packages.dynamic if haskell_toolchain.packages else None,
        output = md_file.as_output(),
        arg = struct(
            compiler_flags = ctx.attrs.compiler_flags,
            deps = ctx.attrs.deps,
            direct_deps_link_info = attr_deps_haskell_link_infos(ctx),
            haskell_direct_deps_lib_infos = haskell_direct_deps_lib_infos,
            haskell_toolchain = haskell_toolchain,
            lib_package_name_and_prefix =_attr_deps_haskell_lib_package_name_and_prefix(ctx),
            md_gen = md_gen,
            sources = sources,
            external_tool_paths = [tool[RunInfo] for tool in ctx.attrs.external_tools],
            strip_prefix = _strip_prefix(str(ctx.label.cell_root), str(ctx.label.path)),
            suffix = suffix,
            toolchain_libs = toolchain_libs,
            worker = worker,
            allow_worker = ctx.attrs.allow_worker,
            pkgname = pkgname,
            label = ctx.label,
        ),
    ))

    return md_file

def _attr_deps_haskell_lib_package_name_and_prefix(ctx: AnalysisContext) -> cmd_args:
    args = cmd_args(prepend = "--package")

    for dep in attr_deps(ctx) + ctx.attrs.template_deps:
        lib = dep.get(HaskellLibraryProvider)
        if lib == None:
            continue

        lib_info = lib.lib.values()[0]
        args.add(cmd_args(
            lib_info.name,
            cmd_args(lib_info.db, parent = 1),
            delimiter = ":",
        ))

    return args

def _package_flag(toolchain: HaskellToolchainInfo) -> str:
    if toolchain.support_expose_package:
        return "-expose-package"
    else:
        return "-package"

def get_packages_info(
    actions: AnalysisActions,
    deps: list[Dependency],
    direct_deps_link_info: list[HaskellLinkInfo],
    haskell_toolchain: HaskellToolchainInfo,
    haskell_direct_deps_lib_infos: list[HaskellLibraryInfo],
    link_style: LinkStyle,
    specify_pkg_version: bool,
    enable_profiling: bool,
    use_empty_lib: bool,
    pkg_deps: ResolvedDynamicValue | None,
    for_deps: bool = False) -> PackagesInfo:

    # Collect library dependencies. Note that these don't need to be in a
    # particular order.
    libs = actions.tset(
        HaskellLibraryInfoTSet,
        children = [
            lib.prof_info[link_style] if enable_profiling else lib.info[link_style]
            for lib in direct_deps_link_info
        ],
    )

    package_flag = _package_flag(haskell_toolchain)
    hidden_args = [l for lib in libs.traverse() for l in lib.libs]
    exposed_package_libs = cmd_args()
    exposed_package_args = cmd_args()

    if for_deps:
        get_db = lambda l: l.deps_db
    elif use_empty_lib:
        get_db = lambda l: l.empty_db
    else:
        get_db = lambda l: l.db

    packagedb_args = cmd_args()
    packagedb_set = {}

    for lib in libs.traverse():
        packagedb_set[get_db(lib)] = None
        if not for_deps:
            hidden_args = cmd_args(hidden = [
                lib.import_dirs.values(),
                lib.stub_dirs,
                lib.libs,
            ])
            exposed_package_args.add(hidden_args)

    if pkg_deps:
        package_db = pkg_deps.providers[DynamicHaskellPackageDbInfo].packages
    else:
        package_db = {}

    direct_toolchain_libs = [
        dep[HaskellToolchainLibrary].name
        for dep in deps
        if HaskellToolchainLibrary in dep
    ]

    toolchain_libs = direct_toolchain_libs + libs.reduce("packages")

    package_db_tset = actions.tset(
        HaskellPackageDbTSet,
        children = [package_db[name] for name in toolchain_libs if name in package_db]
    )

    # These we need to add for all the packages/dependencies, i.e.
    # direct and transitive (e.g. `fbcode-common-hs-util-hs-array`)
    packagedb_args.add(packagedb_set.keys())

    packagedb_args.add(package_db_tset.project_as_args("package_db"))

    # Expose only the packages we depend on directly
    for lib in haskell_direct_deps_lib_infos:
        pkg_name = lib.name
        if (specify_pkg_version):
            pkg_name += "-{}".format(lib.version)

        exposed_package_args.add(package_flag, pkg_name)

    return PackagesInfo(
        exposed_package_args = exposed_package_args,
        packagedb_args = packagedb_args,
        transitive_deps = libs,
        #bin_paths = bin_paths,
    )

CommonCompileModuleArgs = record(
    command = field(cmd_args),
    args_for_file = field(cmd_args),
    package_env_args = field(cmd_args),
)

def add_worker_args(
    haskell_toolchain: HaskellToolchainInfo,
    command: cmd_args,
    pkgname: str | None,
) -> None:
    if pkgname != None:
        command.add("--worker-target-id", "singleton" if haskell_toolchain.worker_make else to_hash(pkgname))


def make_package_env(
    actions,
    haskell_toolchain,
    label,
    link_style,
    enable_profiling,
    allow_worker,
    packagedb_args,
) -> Artifact:
    # TODO[AH] Avoid duplicates and share identical env files.
    #   The set of package-dbs can be known at the package level, not just the
    #   module level. So, we could generate this file outside of the
    #   dynamic_output action.
    package_env_file = actions.declare_output(".".join([
        label.name,
        "package-db",
        output_extensions(link_style, enable_profiling)[1],
        "env",
    ]))
    package_env = cmd_args(delimiter = "\n")
    if not (allow_worker and haskell_toolchain.use_worker and haskell_toolchain.worker_make):
        package_env.add(cmd_args(
            packagedb_args,
            format = "package-db {}",
        ).relative_to(package_env_file, parent = 1))
    actions.write(
        package_env_file,
        package_env,
    )
    return package_env_file

def _common_compile_module_args(
    actions: AnalysisActions,
    *,
    compiler_flags: list[ArgLike],
    ghc_wrapper: RunInfo,
    haskell_toolchain: HaskellToolchainInfo,
    pkg_deps: ResolvedDynamicValue | None,
    enable_haddock: bool,
    enable_profiling: bool,
    link_style: LinkStyle,
    main: None | str,
    label: Label,
    deps: list[Dependency],
    external_tool_paths: list[RunInfo],
    extra_libraries: list[Dependency],
    sources: list[Artifact],
    direct_deps_info: list[HaskellLibraryInfoTSet],
    allow_worker: bool,
    pkgname: str | None = None,
) -> CommonCompileModuleArgs:

    command = cmd_args(ghc_wrapper)
    command.add("--ghc", haskell_toolchain.compiler)
    command.add("--ghc-dir", haskell_toolchain.ghc_dir)

    if allow_worker and haskell_toolchain.use_worker:
        add_worker_args(haskell_toolchain, command, pkgname)

    # Some rules pass in RTS (e.g. `+RTS ... -RTS`) options for GHC, which can't
    # be parsed when inside an argsfile.
    command.add(haskell_toolchain.compiler_flags)
    command.add(compiler_flags)

    command.add("-c")

    if main != None:
        command.add(["-main-is", main])

    if enable_haddock:
        command.add("-haddock")

    non_haskell_sources = [
        src
        for (path, src) in srcs_to_pairs(sources)
        if not is_haskell_src(path) and not is_haskell_boot(path)
    ]

    if non_haskell_sources:
        warning("{} specifies non-haskell file in `srcs`, consider using `srcs_deps` instead".format(label))

    args_for_file = cmd_args(hidden = non_haskell_sources)

    args_for_file.add("-no-link", "-i")
    args_for_file.add("-hide-all-packages")

    if enable_profiling:
        args_for_file.add("-prof")

    if link_style == LinkStyle("shared"):
        args_for_file.add("-dynamic", "-fPIC")
    elif link_style == LinkStyle("static_pic"):
        args_for_file.add("-fPIC", "-fexternal-dynamic-refs")

    osuf, hisuf = output_extensions(link_style, enable_profiling)
    args_for_file.add("-osuf", osuf, "-hisuf", hisuf)

    # Add args from preprocess-able inputs.
    inherited_pre = cxx_inherited_preprocessor_infos(deps)
    pre = cxx_merge_cpreprocessors_actions(actions, [], inherited_pre)
    pre_args = pre.set.project_as_args("args")
    args_for_file.add(cmd_args(pre_args, format = "-optP={}"))

    if pkgname:
        args_for_file.add(["-this-unit-id", pkgname])

    # Add -package-db and -package/-expose-package flags for each Haskell
    # library dependency.

    libs = actions.tset(HaskellLibraryInfoTSet, children = direct_deps_info)

    direct_toolchain_libs = [
        dep[HaskellToolchainLibrary].name
        for dep in deps
        if HaskellToolchainLibrary in dep
    ]
    toolchain_libs = direct_toolchain_libs + libs.reduce("packages")

    if haskell_toolchain.packages:
        package_db = pkg_deps.providers[DynamicHaskellPackageDbInfo].packages
    else:
        package_db = []

    package_db_tset = actions.tset(
        HaskellPackageDbTSet,
        children = [package_db[name] for name in toolchain_libs if name in package_db]
    )

    args_for_file.add(cmd_args(
        external_tool_paths,
        format="--bin-exe={}",
    ))

    packagedb_args = cmd_args(libs.project_as_args("empty_package_db"))
    packagedb_args.add(package_db_tset.project_as_args("package_db"))

    package_env_file = make_package_env(
        actions,
        haskell_toolchain,
        label,
        link_style,
        enable_profiling,
        allow_worker,
        packagedb_args
    )
    package_env_args = cmd_args(
        package_env_file,
        prepend = "-package-env",
        hidden = packagedb_args,
    )

    return CommonCompileModuleArgs(
        command = command,
        args_for_file = args_for_file,
        package_env_args = package_env_args,
    )

def _compile_module(
    actions: AnalysisActions,
    *,
    common_args: CommonCompileModuleArgs,
    link_style: LinkStyle,
    enable_profiling: bool,
    enable_th: bool,
    haskell_toolchain: HaskellToolchainInfo,
    label: Label,
    module_name: str,
    module: _Module,
    module_tsets: dict[str, CompiledModuleTSet],
    md_file: Artifact,
    graph: dict[str, list[str]],
    package_deps: dict[str, list[str]],
    outputs: dict[Artifact, OutputArtifact],
    artifact_suffix: str,
    direct_deps_by_name: dict[str, typing.Any],
    toolchain_deps_by_name: dict[str, None],
    aux_deps: None | list[Artifact],
    src_envs: None | dict[str, ArgLike],
    source_prefixes: list[str],
    extra_libraries: list[Dependency],
    worker: None | WorkerInfo,
    allow_worker: bool,
) -> CompiledModuleTSet:
    # These compiler arguments can be passed in a response file.
    compile_args_for_file = cmd_args(common_args.args_for_file, hidden = aux_deps or [])

    packagedb_tag = actions.artifact_tag()
    compile_args_for_file.add(packagedb_tag.tag_artifacts(common_args.package_env_args))

    dep_file = actions.declare_output(".".join([
        label.name,
        module_name or "pkg",
        "package-db",
        output_extensions(link_style, enable_profiling)[1],
        "dep",
    ])).as_output()
    tagged_dep_file = packagedb_tag.tag_artifacts(dep_file)
    compile_args_for_file.add("--buck2-packagedb-dep", tagged_dep_file)

    objects = [outputs[obj] for obj in module.objects]
    his = [outputs[hi] for hi in module.interfaces]

    compile_args_for_file.add("-o", objects[0])
    compile_args_for_file.add("-ohi", his[0])

    # Set the output directories. We do not use the -outputdir flag, but set the directories individually.
    # Note, the -outputdir option is shorthand for the combination of -odir, -hidir, -hiedir, -stubdir and -dumpdir.
    # But setting -hidir effectively disables the use of the search path to look up interface files,
    # as ghc exclusively looks in that directory when it is set.
    for dir in ["o", "hie", "dump"]:
        compile_args_for_file.add(
           "-{}dir".format(dir), cmd_args([cmd_args(md_file, ignore_artifacts=True, parent=1), module.prefix_dir], delimiter="/"),
        )
    if module.stub_dir != None:
        stubs = outputs[module.stub_dir]
        compile_args_for_file.add("-stubdir", stubs)

    if link_style in [LinkStyle("static_pic"), LinkStyle("static")]:
        compile_args_for_file.add("-dynamic-too")
        compile_args_for_file.add("-dyno", objects[1])
        compile_args_for_file.add("-dynohi", his[1])

    compile_args_for_file.add(module.source)

    abi_tag = actions.artifact_tag()

    toolchain_deps = []
    library_deps = []
    exposed_package_modules = []
    exposed_package_dbs = []
    for dep_pkgname, dep_modules in package_deps.items():
        if dep_pkgname in toolchain_deps_by_name:
            toolchain_deps.append(dep_pkgname)
        elif dep_pkgname in direct_deps_by_name:
            library_deps.append(dep_pkgname)
            exposed_package_dbs.append(direct_deps_by_name[dep_pkgname][0])
            for dep_modname in dep_modules:
                exposed_package_modules.append(direct_deps_by_name[dep_pkgname][1].providers[DynamicCompileResultInfo].modules[dep_modname])
        else:
            fail("Unknown library dependency '{}'. Add the library to the `deps` attribute".format(dep_pkgname))

    # Transitive module dependencies from other packages.
    cross_package_modules = actions.tset(
        CompiledModuleTSet,
        children = exposed_package_modules,
    )
    # Transitive module dependencies from the same package.
    this_package_modules = [
        module_tsets[dep_name]
        for dep_name in graph[module_name]
    ]

    dependency_modules = actions.tset(
        CompiledModuleTSet,
        children = [cross_package_modules] + this_package_modules,
    )

    compile_cmd_args = [common_args.command]
    compile_cmd_hidden = [
        abi_tag.tag_artifacts(dependency_modules.project_as_args("interfaces")),
        dependency_modules.project_as_args("abi"),
    ]
    if src_envs:
        for k, v in src_envs.items():
            compile_args_for_file.add(cmd_args(
                k,
                format="--extra-env-key={}",
            ))
            compile_args_for_file.add(cmd_args(
                v,
                format="--extra-env-value={}",
            ))
    if haskell_toolchain.use_argsfile:
        compile_cmd_args.append(at_argfile(
            actions = actions,
            name = "haskell_compile_" + artifact_suffix + ".argsfile",
            args = compile_args_for_file,
            allow_args = True,
        ))
    else:
        compile_cmd_args.append(compile_args_for_file)

    compile_cmd = cmd_args(compile_cmd_args, hidden = compile_cmd_hidden)

    # add each module dir prefix to search path
    for prefix in source_prefixes:
        compile_cmd.add(
            cmd_args(
                cmd_args(md_file, format = "-i{}", ignore_artifacts=True, parent=1),
                "/",
                paths.join(module.prefix_dir, prefix),
                delimiter=""
            )
        )


    compile_cmd.add(cmd_args(library_deps, prepend = "-package"))
    compile_cmd.add(cmd_args(toolchain_deps, prepend = "-package"))

    # extra-libraries
    extra_libs = [
        lib[NativeToolchainLibrary]
        for lib in extra_libraries
        if NativeToolchainLibrary in lib
    ]
    for l in extra_libs:
        compile_cmd.add(l.lib_path)
        compile_cmd.add("-l{}".format(l.name))

    compile_cmd.add("-fbyte-code-and-object-code")

    if enable_th:
        compile_cmd.add("-fprefer-byte-code")

    compile_cmd.add(cmd_args(dependency_modules.reduce("packagedb_deps").keys(), prepend = "--buck2-package-db"))

    dep_file = actions.declare_output("dep-{}_{}".format(module_name, artifact_suffix)).as_output()

    tagged_dep_file = abi_tag.tag_artifacts(dep_file)

    compile_cmd.add("--buck2-dep", tagged_dep_file)
    compile_cmd.add("--abi-out", outputs[module.hash])

    if worker == None:
        worker_args = dict()
    elif allow_worker and haskell_toolchain.use_worker:
        worker_args = dict(exe = WorkerRunInfo(worker = worker))
    else:
        worker_args = dict()

    actions.run(
        compile_cmd, category = "haskell_compile_" + artifact_suffix.replace("-", "_"), identifier = module_name,
        dep_files = {
            "abi": abi_tag,
            "packagedb": packagedb_tag,
        },
        # explicit turn this on for local_only actions to upload their results.
        allow_cache_upload = True,
        **worker_args,
    )

    module_tset = actions.tset(
        CompiledModuleTSet,
        value = CompiledModuleInfo(
            abi = module.hash,
            interfaces = module.interfaces,
            db_deps = exposed_package_dbs,
        ),
        children = [cross_package_modules] + this_package_modules,
    )

    return module_tset

# Compile incrementally and fill module_tsets accordingly.
def _compile_incr(
    actions,
    module_tsets,
    arg,
    common_args,
    graph,
    mapped_modules,
    th_modules,
    package_deps,
    direct_deps_by_name,
    source_prefixes,
    outputs,
) -> None:
    for module_name in post_order_traversal(graph):
        module = mapped_modules[module_name]
        module_tsets[module_name] = _compile_module(
            actions,
            aux_deps = arg.sources_deps.get(module.source),
            src_envs = arg.srcs_envs.get(module.source),
            common_args = common_args,
            link_style = arg.link_style,
            enable_profiling = arg.enable_profiling,
            enable_th = module_name in th_modules,
            haskell_toolchain = arg.haskell_toolchain,
            label = arg.label,
            module_name = module_name,
            module = module,
            module_tsets = module_tsets,
            graph = graph,
            package_deps = package_deps.get(module_name, {}),
            outputs = outputs,
            md_file = arg.md_file,
            artifact_suffix = arg.artifact_suffix,
            direct_deps_by_name = direct_deps_by_name,
            toolchain_deps_by_name = arg.toolchain_deps_by_name,
            source_prefixes = source_prefixes,
            extra_libraries = arg.extra_libraries,
            worker = arg.worker,
            allow_worker = arg.allow_worker,
        )


def _dynamic_get_module_tsets_impl(actions) -> list[Provider]:
    return []

_dynamic_get_module_tsets = dynamic_actions(
    impl = _dynamic_get_module_tsets_impl,
    attrs = {},
)

def compile_args(
        actions,
        haskell_toolchain,
        md_file,
        compiler_flags,
        main,
        deps,
        sources,
        link_style: LinkStyle,
        enable_profiling: bool,
        package_env_args: cmd_args,
        pkgname = None,
        suffix: str = "") -> CompileArgsInfo:

    # for now
    direct_deps_link_info = []
    haskell_direct_deps_lib_infos = []

    compile_cmd = cmd_args()
    compile_cmd.add(haskell_toolchain.compiler_flags)

    # Some rules pass in RTS (e.g. `+RTS ... -RTS`) options for GHC, which can't
    # be parsed when inside an argsfile.
    compile_cmd.add(compiler_flags)

    compile_args = cmd_args()
    compile_args.add("-no-link", "-i")

    compile_args.add(package_env_args)

    if enable_profiling:
        compile_args.add("-prof")

    if link_style == LinkStyle("shared"):
        compile_args.add("-dynamic", "-fPIC")
    elif link_style == LinkStyle("static_pic"):
        compile_args.add("-fPIC", "-fexternal-dynamic-refs")

    osuf, hisuf = output_extensions(link_style, enable_profiling)
    compile_args.add("-osuf", osuf, "-hisuf", hisuf)

    if main != None:
        compile_args.add(["-main-is", main])

    artifact_suffix = get_artifact_suffix(link_style, enable_profiling, suffix)

    for dir in ["o", "hi", "hie"]:
        compile_args.add(
           "-{}dir".format(dir), cmd_args([cmd_args(md_file, ignore_artifacts=True, parent=1), "mod-" + artifact_suffix], delimiter="/"),
        )

    # Add -package-db and -package/-expose-package flags for each Haskell
    # library dependency.
    packages_info = get_packages_info(
        actions,
        deps,
        direct_deps_link_info,
        haskell_toolchain,
        haskell_direct_deps_lib_infos,
        LinkStyle("shared"),
        specify_pkg_version = False,
        enable_profiling = enable_profiling,
        use_empty_lib = False,
        for_deps = False,
        pkg_deps = None,
    )

    compile_args.add(packages_info.exposed_package_args)
    compile_args.add(packages_info.packagedb_args)

    # Add args from preprocess-able inputs.
    inherited_pre = cxx_inherited_preprocessor_infos(deps)
    pre = cxx_merge_cpreprocessors_actions(actions, [], inherited_pre)
    pre_args = pre.set.project_as_args("args")
    compile_args.add(cmd_args(pre_args, format = "-optP={}"))

    if pkgname:
        compile_args.add(["-this-unit-id", pkgname])

    arg_srcs = []
    hidden_srcs = []
    for (path, src) in srcs_to_pairs(sources):
        # hs-boot files aren't expected to be an argument to compiler but does need
        # to be included in the directory of the associated src file
        if is_haskell_src(path):
            arg_srcs.append(src)
        else:
            hidden_srcs.append(src)
    srcs = cmd_args(
        arg_srcs,
        hidden = hidden_srcs,
    )

    producing_indices = "-fwrite-ide-info" in compiler_flags

    return CompileArgsInfo(
        srcs = srcs,
        args_for_cmd = compile_cmd,
        args_for_file = compile_args,
    )

# Compile in one step all the context's sources
def _compile_non_incr(
    actions,
    module_tsets,
    arg,
    common_args,
    graph,
    mapped_modules,
    th_modules,
    package_deps,
    direct_deps_by_name,
    source_prefixes,
    outputs,
) -> None:
    haskell_toolchain = arg.haskell_toolchain
    link_style = arg.link_style
    enable_profiling = arg.enable_profiling

    compile_cmd = cmd_args(haskell_toolchain.compiler, hidden = outputs.values())


    args = compile_args(
        actions,
        haskell_toolchain = haskell_toolchain,
        md_file = arg.md_file,
        compiler_flags = arg.compiler_flags,
        main = arg.main,
        deps = arg.deps,
        sources = arg.sources,
        link_style = link_style,
        enable_profiling = enable_profiling,
        package_env_args = common_args.package_env_args,
        pkgname = arg.pkgname,
    )

    compile_cmd.add(args.args_for_cmd)

    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    if args.args_for_file:
        if haskell_toolchain.use_argsfile:
            compile_cmd.add(at_argfile(
                actions = actions,
                name = artifact_suffix + ".haskell_compile_argsfile",
                args = [args.args_for_file, args.srcs],
                allow_args = True,
            ))
        else:
            compile_cmd.add(args.args_for_file)
            compile_cmd.add(args.srcs)

    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)
    actions.run(
        compile_cmd,
        category = "haskell_compile_" + artifact_suffix.replace("-", "_"),
        # We can't use no_outputs_cleanup because GHC's recompilation checking
        # is based on file timestamps, and Buck doesn't maintain timestamps when
        # artifacts may come from RE.
        # TODO: enable this for GHC 9.4 which tracks file changes using hashes
        # not timestamps.
        # no_outputs_cleanup = True,
    )


def _dynamic_do_compile_impl(actions, incremental, md_file, pkg_deps, arg, direct_deps_by_name, outputs):
    common_args = _common_compile_module_args(
        actions,
        compiler_flags = arg.compiler_flags,
        deps = arg.deps,
        external_tool_paths = arg.external_tool_paths,
        extra_libraries = arg.extra_libraries,
        ghc_wrapper = arg.ghc_wrapper,
        haskell_toolchain = arg.haskell_toolchain,
        label = arg.label,
        main = arg.main,
        pkg_deps = pkg_deps,
        sources = arg.sources,
        enable_haddock = arg.enable_haddock,
        enable_profiling = arg.enable_profiling,
        link_style = arg.link_style,
        direct_deps_info = arg.direct_deps_info,
        allow_worker = arg.allow_worker,
        pkgname = arg.pkgname,
    )

    md = md_file.read_json()
    th_modules = md["th_modules"]
    module_map = md["module_mapping"]
    graph = md["module_graph"]
    package_deps = md["package_deps"]

    mapped_modules = { module_map.get(k, k): v for k, v in arg.modules.items() }
    module_tsets = {}
    source_prefixes = get_source_prefixes(arg.sources, module_map)

    if incremental:
        _compile_incr(
            actions,
            module_tsets,
            arg,
            common_args,
            graph,
            mapped_modules,
            th_modules,
            package_deps,
            direct_deps_by_name,
            source_prefixes,
            outputs,
        )
    else:
        _compile_non_incr(
            actions,
            module_tsets,
            arg,
            common_args,
            graph,
            mapped_modules,
            th_modules,
            package_deps,
            direct_deps_by_name,
            source_prefixes,
            outputs,
        )

    return [DynamicCompileResultInfo(modules = module_tsets)]

_dynamic_do_compile = dynamic_actions(
    impl = _dynamic_do_compile_impl,
    attrs = {
        "incremental": dynattrs.value(bool),
        "md_file" : dynattrs.artifact_value(),
        "arg" : dynattrs.value(typing.Any),
        "pkg_deps": dynattrs.option(dynattrs.dynamic_value()),
        "outputs": dynattrs.dict(Artifact, dynattrs.output()),
        "direct_deps_by_name": dynattrs.dict(str, dynattrs.tuple(dynattrs.value(Artifact), dynattrs.dynamic_value())),
    },
)

# Compile all the context's sources.
def compile(
        ctx: AnalysisContext,
        link_style: LinkStyle,
        enable_profiling: bool,
        enable_haddock: bool,
        md_file: Artifact,
        worker: WorkerInfo | None = None,
        incremental: bool = False,
        pkgname: str | None = None) -> CompileResultInfo:
    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    modules = _modules_by_name(ctx, sources = ctx.attrs.srcs, link_style = link_style, enable_profiling = enable_profiling, suffix = artifact_suffix, module_prefix = ctx.attrs.module_prefix)

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    interfaces = [interface for module in modules.values() for interface in module.interfaces]
    objects = [object for module in modules.values() for object in module.objects]
    stub_dirs = [
        module.stub_dir
        for module in modules.values()
        if module.stub_dir != None
    ]
    abi_hashes = [
        module.hash
        for module in modules.values()
        if module.stub_dir != None
    ]

    # Collect library dependencies. Note that these don't need to be in a
    # particular order.
    toolchain_deps_by_name = {
        lib.name: None
        for lib in attr_deps_haskell_toolchain_libraries(ctx)
    }
    direct_deps_info = [
        lib.prof_info[link_style] if enable_profiling else lib.info[link_style]
        for lib in attr_deps_haskell_link_infos(ctx)
    ]

    dyn_module_tsets = ctx.actions.dynamic_output_new(_dynamic_do_compile(
        incremental = incremental,
        md_file = md_file,
        pkg_deps = haskell_toolchain.packages.dynamic if haskell_toolchain.packages else None,
        outputs = {o: o.as_output() for o in interfaces + objects + stub_dirs + abi_hashes},
        direct_deps_by_name = {
            info.value.name: (info.value.empty_db, info.value.dynamic[enable_profiling])
            for info in direct_deps_info
        },
        arg = struct(
            artifact_suffix = artifact_suffix,
            compiler_flags = ctx.attrs.compiler_flags,
            deps = ctx.attrs.deps,
            direct_deps_info = direct_deps_info,
            enable_haddock = enable_haddock,
            enable_profiling = enable_profiling,
            external_tool_paths = [tool[RunInfo] for tool in ctx.attrs.external_tools],
            ghc_wrapper = ctx.attrs._ghc_wrapper[RunInfo],
            haskell_toolchain = haskell_toolchain,
            label = ctx.label,
            link_style = link_style,
            main = getattr(ctx.attrs, "main", None),
            md_file = md_file,
            modules = modules,
            pkgname = pkgname,
            sources = ctx.attrs.srcs,
            sources_deps = ctx.attrs.srcs_deps,
            srcs_envs = ctx.attrs.srcs_envs,
            toolchain_deps_by_name = toolchain_deps_by_name,
            extra_libraries = ctx.attrs.extra_libraries,
            worker = worker,
            allow_worker = ctx.attrs.allow_worker,
        ),
    ))

    stubs_dir = ctx.actions.declare_output("stubs-" + artifact_suffix, dir=True)

    # collect the stubs from all modules into the stubs_dir
    if ctx.attrs.use_argsfile_at_link:
        stub_copy_cmd = cmd_args([
            "bash", "-euc",
            """\
            mkdir -p \"$0\"
            cat $1 | while read stub; do
              find \"$stub\" -mindepth 1 -maxdepth 1 -exec cp -r -t \"$0\" '{}' ';'
            done
            """,
        ])
        stub_copy_cmd.add(stubs_dir.as_output())
        stub_copy_cmd.add(argfile(
            actions = ctx.actions,
            name = "haskell_stubs_" + artifact_suffix + ".argsfile",
            args = stub_dirs,
            allow_args = True,
        ))
    else:
        stub_copy_cmd = cmd_args([
            "bash", "-euc",
            """\
            mkdir -p \"$0\"
            for stub; do
              find \"$stub\" -mindepth 1 -maxdepth 1 -exec cp -r -t \"$0\" '{}' ';'
            done
            """,
        ])
        stub_copy_cmd.add(stubs_dir.as_output())
        stub_copy_cmd.add(stub_dirs)

    ctx.actions.run(
        stub_copy_cmd,
        category = "haskell_stubs",
        identifier = artifact_suffix,
        local_only = True,
    )

    return CompileResultInfo(
        objects = objects,
        hi = interfaces,
        hashes = abi_hashes,
        stubs = stubs_dir,
        producing_indices = False,
        module_tsets = dyn_module_tsets,
    )
