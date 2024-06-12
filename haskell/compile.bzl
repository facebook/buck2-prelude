# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load(
    "@prelude//cxx:preprocessor.bzl",
    "cxx_inherited_preprocessor_infos",
    "cxx_merge_cpreprocessors",
)
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryProvider",
    "HaskellLibraryInfoTSet",
)
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellToolchainInfo",
    "HaskellToolchainLibrary",
    "DynamicHaskellPackageDbInfo",
    "HaskellPackageDbTSet",
)
load(
    "@prelude//haskell:util.bzl",
    "attr_deps",
    "attr_deps_haskell_lib_infos",
    "attr_deps_haskell_link_infos",
    "get_artifact_suffix",
    "is_haskell_src",
    "output_extensions",
    "src_to_module_name",
    "srcs_to_pairs",
)
load(
    "@prelude//linking:link_info.bzl",
    "LinkStyle",
)
load("@prelude//:paths.bzl", "paths")
load("@prelude//utils:graph_utils.bzl", "post_order_traversal")
load("@prelude//utils:strings.bzl", "strip_prefix")

CompiledModuleInfo = provider(fields = {
    "abi": provider_field(Artifact),
    "interfaces": provider_field(list[Artifact]),
    "objects": provider_field(list[Artifact]),
    "dyn_object_dot_o": provider_field(Artifact),
    # TODO[AH] track this module's package-name/id & package-db instead.
    "db_deps": provider_field(list[Artifact]),
    "package_deps": provider_field(list[str]),
    "toolchain_deps": provider_field(list[str]),
})

def _compiled_module_project_as_abi(mod: CompiledModuleInfo) -> cmd_args:
    return cmd_args(mod.abi)

def _compiled_module_project_as_interfaces(mod: CompiledModuleInfo) -> cmd_args:
    return cmd_args(mod.interfaces)

def _compiled_module_project_as_objects(mod: CompiledModuleInfo) -> cmd_args:
    return cmd_args(mod.objects)

def _compiled_module_project_as_dyn_objects_dot_o(mod: CompiledModuleInfo) -> cmd_args:
    return cmd_args(mod.dyn_object_dot_o)

def _compiled_module_reduce_as_package_deps(children: list[dict[str, None]], mod: CompiledModuleInfo | None) -> dict[str, None]:
    # TODO[AH] is there a better way to avoid duplicate -package flags?
    #   Using a projection instead would produce duplicates.
    result = {pkg: None for pkg in mod.package_deps} if mod else {}
    for child in children:
        result.update(child)
    return result

def _compiled_module_reduce_as_packagedb_deps(children: list[dict[Artifact, None]], mod: CompiledModuleInfo | None) -> dict[Artifact, None]:
    # TODO[AH] is there a better way to avoid duplicate package-dbs?
    #   Using a projection instead would produce duplicates.
    result = {db: None for db in mod.db_deps} if mod else {}
    for child in children:
        result.update(child)
    return result

def _compiled_module_reduce_as_toolchain_deps(children: list[dict[str, None]], mod: CompiledModuleInfo | None) -> dict[str, None]:
    # TODO[AH] is there a better way to avoid duplicate -package-id flags?
    #   Using a projection instead would produce duplicates.
    result = {pkg: None for pkg in mod.toolchain_deps} if mod else {}
    for child in children:
        result.update(child)
    return result

CompiledModuleTSet = transitive_set(
    args_projections = {
        "abi": _compiled_module_project_as_abi,
        "interfaces": _compiled_module_project_as_interfaces,
        "objects": _compiled_module_project_as_objects,
        "dyn_objects_dot_o": _compiled_module_project_as_dyn_objects_dot_o,
    },
    reductions = {
        "package_deps": _compiled_module_reduce_as_package_deps,
        "packagedb_deps": _compiled_module_reduce_as_packagedb_deps,
        "toolchain_deps": _compiled_module_reduce_as_toolchain_deps,
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

PackagesInfo = record(
    exposed_package_modules = field(None | list[CompiledModuleTSet]),
    exposed_package_imports = field(list[Artifact]),
    exposed_package_objects = field(list[Artifact]),
    exposed_package_libs = cmd_args,
    exposed_package_args = cmd_args,
    exposed_package_dbs = field(list[Artifact]),
    packagedb_args = cmd_args,
    transitive_deps = field(HaskellLibraryInfoTSet),
    bin_paths = cmd_args,
)

_Module = record(
    source = field(Artifact),
    interfaces = field(list[Artifact]),
    hash = field(Artifact),
    objects = field(list[Artifact]),
    stub_dir = field(Artifact),
    prefix_dir = field(str),
)


def _strip_prefix(prefix, s):
    stripped = strip_prefix(prefix, s)

    return stripped if stripped != None else s


def _modules_by_name(ctx: AnalysisContext, *, sources: list[Artifact], link_style: LinkStyle, enable_profiling: bool, suffix: str) -> dict[str, _Module]:
    modules = {}

    osuf, hisuf = output_extensions(link_style, enable_profiling)

    for src in sources:
        if not is_haskell_src(src.short_path):
            continue

        module_name = src_to_module_name(src.short_path)
        interface_path = paths.replace_extension(src.short_path, "." + hisuf)
        interface = ctx.actions.declare_output("mod-" + suffix, interface_path)
        interfaces = [interface]
        object_path = paths.replace_extension(src.short_path, "." + osuf)
        object = ctx.actions.declare_output("mod-" + suffix, object_path)
        objects = [object]
        hash = ctx.actions.declare_output("mod-" + suffix, interface_path + ".hash")

        if link_style in [LinkStyle("static"), LinkStyle("static_pic")]:
            dyn_osuf, dyn_hisuf = output_extensions(LinkStyle("shared"), enable_profiling)
            interface_path = paths.replace_extension(src.short_path, "." + dyn_hisuf)
            interface = ctx.actions.declare_output("mod-" + suffix, interface_path)
            interfaces.append(interface)
            object_path = paths.replace_extension(src.short_path, "." + dyn_osuf)
            object = ctx.actions.declare_output("mod-" + suffix, object_path)
            objects.append(object)

        stub_dir = ctx.actions.declare_output("stub-" + suffix + "-" + module_name, dir=True)
        modules[module_name] = _Module(
            source = src,
            interfaces = interfaces,
            hash = hash,
            objects = objects,
            stub_dir = stub_dir,
            prefix_dir = "mod-" + suffix)

    return modules

def _toolchain_library_catalog_impl(ctx: AnalysisContext) -> list[Provider]:
    haskell_toolchain = ctx.attrs.toolchain[HaskellToolchainInfo]

    ghc_pkg = haskell_toolchain.packager

    catalog_gen = ctx.attrs.generate_toolchain_library_catalog[RunInfo]
    catalog = ctx.actions.declare_output("haskell_toolchain_libraries.json")

    cmd = cmd_args(catalog_gen, "--ghc-pkg", ghc_pkg, "--output", catalog.as_output())

    if haskell_toolchain.packages:
        cmd.add("--package-db", haskell_toolchain.packages.package_db)

    ctx.actions.run(cmd, category = "haskell_toolchain_library_catalog")

    return [DefaultInfo(default_output = catalog)]

_toolchain_library_catalog = anon_rule(
    impl = _toolchain_library_catalog_impl,
    attrs = {
        "toolchain": attrs.dep(
            providers = [HaskellToolchainInfo],
        ),
        "generate_toolchain_library_catalog": attrs.dep(
            providers = [RunInfo],
        ),
    },
    artifact_promise_mappings = {
        "catalog": lambda x: x[DefaultInfo].default_outputs[0],
    }
)

def target_metadata(
        ctx: AnalysisContext,
        *,
        sources: list[Artifact],
        suffix: str = "",
    ) -> Artifact:
    md_file = ctx.actions.declare_output(ctx.attrs.name + suffix + ".md.json")
    md_gen = ctx.attrs._generate_target_metadata[RunInfo]

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    toolchain_libs = [
        dep[HaskellToolchainLibrary].name
        for dep in ctx.attrs.deps
        if HaskellToolchainLibrary in dep
    ]

    toolchain_libs_catalog = ctx.actions.anon_target(_toolchain_library_catalog, {
        "toolchain": ctx.attrs._haskell_toolchain,
        "generate_toolchain_library_catalog": ctx.attrs._generate_toolchain_library_catalog,
    })

    # The object and interface file paths are depending on the real module name
    # as inferred by GHC, not the source file path; currently this requires the
    # module name to correspond to the source file path as otherwise GHC will
    # not be able to find the created object or interface files in the search
    # path.
    #
    # (module X.Y.Z must be defined in a file at X/Y/Z.hs)

    catalog = toolchain_libs_catalog.artifact("catalog")

    def get_metadata(ctx, _artifacts, resolved, outputs, catalog=catalog):

        # Add -package-db and -package/-expose-package flags for each Haskell
        # library dependency.

        packages_info = get_packages_info(
            ctx,
            LinkStyle("shared"),
            specify_pkg_version = False,
            enable_profiling = False,
            use_empty_lib = True,
            resolved = resolved,
        )
        package_flag = _package_flag(haskell_toolchain)
        ghc_args = cmd_args()
        ghc_args.add("-hide-all-packages")
        ghc_args.add(package_flag, "base")

        ghc_args.add(cmd_args(toolchain_libs, prepend=package_flag))
        ghc_args.add(cmd_args(packages_info.exposed_package_args))
        ghc_args.add(cmd_args(packages_info.packagedb_args, prepend = "-package-db"))
        ghc_args.add(ctx.attrs.compiler_flags)

        md_args = cmd_args(md_gen)
        md_args.add(packages_info.bin_paths)
        md_args.add("--toolchain-libs", catalog)
        md_args.add("--ghc", haskell_toolchain.compiler)
        md_args.add(cmd_args(ghc_args, format="--ghc-arg={}"))
        md_args.add(
            "--source-prefix",
            _strip_prefix(str(ctx.label.cell_root), str(ctx.label.path)),
        )
        md_args.add(cmd_args(sources, format="--source={}"))

        md_args.add(
            _attr_deps_haskell_lib_package_name_and_prefix(ctx),
        )
        md_args.add("--output", outputs[md_file].as_output())

        ctx.actions.run(md_args, category = "haskell_metadata", identifier = suffix if suffix else None)

    ctx.actions.dynamic_output(
        dynamic = [],
        promises = [haskell_toolchain.packages.dynamic],
        inputs = [],
        outputs = [md_file.as_output()],
        f = get_metadata,
    )

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
        ctx: AnalysisContext,
        link_style: LinkStyle,
        specify_pkg_version: bool,
        enable_profiling: bool,
        use_empty_lib: bool,
        resolved: None | dict[DynamicValue, ResolvedDynamicValue] = None,
        package_deps: None | dict[str, list[str]] = None) -> PackagesInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    # Collect library dependencies. Note that these don't need to be in a
    # particular order.
    direct_deps_link_info = attr_deps_haskell_link_infos(ctx)
    libs = ctx.actions.tset(HaskellLibraryInfoTSet, children = [
        lib.prof_info[link_style] if enable_profiling else lib.info[link_style]
        for lib in direct_deps_link_info
    ])

    # base is special and gets exposed by default
    package_flag = _package_flag(haskell_toolchain)
    exposed_package_modules = None
    exposed_package_imports = []
    exposed_package_objects = []
    exposed_package_libs = cmd_args()
    exposed_package_args = cmd_args([package_flag, "base"])
    exposed_package_dbs = []

    if resolved != None and package_deps != None:
        exposed_package_modules = []

        for lib in direct_deps_link_info:
            info = lib.prof_info[link_style] if enable_profiling else lib.info[link_style]
            direct = info.value
            dynamic = direct.dynamic[enable_profiling]
            dynamic_info = resolved[dynamic][DynamicCompileResultInfo]

            for mod in package_deps.get(direct.name, []):
                exposed_package_modules.append(dynamic_info.modules[mod])

            if direct.name in package_deps:
                db = direct.empty_db if use_empty_lib else direct.db
                exposed_package_dbs.append(db)
    else:
        for lib in libs.traverse():
            exposed_package_imports.extend(lib.import_dirs[enable_profiling])
            exposed_package_objects.extend(lib.objects[enable_profiling])
            # libs of dependencies might be needed at compile time if
            # we're using Template Haskell:
            exposed_package_libs.hidden(lib.libs)

    packagedb_args = cmd_args(libs.project_as_args(
        "empty_package_db" if use_empty_lib else "package_db",
    ))

    haskell_direct_deps_lib_infos = attr_deps_haskell_lib_infos(
        ctx,
        link_style,
        enable_profiling,
    )

    if haskell_toolchain.packages and resolved != None:
        haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
        pkg_deps = resolved[haskell_toolchain.packages.dynamic]
        package_db = pkg_deps[DynamicHaskellPackageDbInfo].packages

        toolchain_libs = [
            dep[HaskellToolchainLibrary].name
            for dep in ctx.attrs.deps
            if HaskellToolchainLibrary in dep
        ] + libs.reduce("packages")

        package_db_tset = ctx.actions.tset(
            HaskellPackageDbTSet,
            children = [package_db[name] for name in toolchain_libs if name in package_db]
        )

        packagedb_args.add(package_db_tset.project_as_args("package_db"))
        bin_paths = cmd_args(package_db_tset.project_as_args("path"), format="--bin-path={}/bin")
    else:
        packagedb_args.add(haskell_toolchain.packages.package_db)
        bin_paths = cmd_args()

    # Expose only the packages we depend on directly
    for lib in haskell_direct_deps_lib_infos:
        pkg_name = lib.name
        if (specify_pkg_version):
            pkg_name += "-{}".format(lib.version)

        exposed_package_args.add(package_flag, pkg_name)

    return PackagesInfo(
        exposed_package_modules = exposed_package_modules,
        exposed_package_imports = exposed_package_imports,
        exposed_package_objects = exposed_package_objects,
        exposed_package_libs = exposed_package_libs,
        exposed_package_args = exposed_package_args,
        exposed_package_dbs = exposed_package_dbs,
        packagedb_args = packagedb_args,
        transitive_deps = libs,
        bin_paths = bin_paths,
    )

def _compile_module(
    ctx: AnalysisContext,
    *,
    link_style: LinkStyle,
    enable_profiling: bool,
    enable_haddock: bool,
    enable_th: bool,
    module_name: str,
    modules: dict[str, _Module],
    module_tsets: dict[str, CompiledModuleTSet],
    md_file: Artifact,
    graph: dict[str, list[str]],
    package_deps: dict[str, list[str]],
    toolchain_deps: list[str],
    outputs: dict[Artifact, Artifact],
    resolved: dict[DynamicValue, ResolvedDynamicValue],
    artifact_suffix: str,
    pkgname: str | None = None,
) -> CompiledModuleTSet:
    module = modules[module_name]

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    compile_cmd = cmd_args(ctx.attrs._ghc_wrapper[RunInfo])
    compile_cmd.add("--ghc", haskell_toolchain.compiler)

    compile_cmd.add(haskell_toolchain.compiler_flags)

    # Some rules pass in RTS (e.g. `+RTS ... -RTS`) options for GHC, which can't
    # be parsed when inside an argsfile.
    compile_cmd.add(ctx.attrs.compiler_flags)
    compile_cmd.add("-c")

    if enable_haddock:
        compile_cmd.add("-haddock")

    # These compiler arguments can be passed in a response file.
    compile_args_for_file = cmd_args()
    compile_args_for_file.add("-no-link", "-i")
    compile_args_for_file.add("-hide-all-packages")

    if enable_profiling:
        compile_args_for_file.add("-prof")

    if link_style == LinkStyle("shared"):
        compile_args_for_file.add("-dynamic", "-fPIC")
    elif link_style == LinkStyle("static_pic"):
        compile_args_for_file.add("-fPIC", "-fexternal-dynamic-refs")

    osuf, hisuf = output_extensions(link_style, enable_profiling)
    compile_args_for_file.add("-osuf", osuf, "-hisuf", hisuf)

    # ------------------------------------------------------------

    # Add -package-db and -package/-expose-package flags for each Haskell
    # library dependency.
    #packages_info = get_packages_info(
    #    ctx,
    #    link_style,
    #    specify_pkg_version = False,
    #    enable_profiling = enable_profiling,
    #    use_empty_lib = True,
    #    resolved = resolved,
    #    package_deps = package_deps,
    #)

    # Collect library dependencies. Note that these don't need to be in a
    # particular order.
    direct_deps_link_info = attr_deps_haskell_link_infos(ctx)
    libs = ctx.actions.tset(HaskellLibraryInfoTSet, children = [
        lib.prof_info[link_style] if enable_profiling else lib.info[link_style]
        for lib in direct_deps_link_info
    ])

    # base is special and gets exposed by default
    package_flag = _package_flag(haskell_toolchain)
    exposed_package_modules = []
    exposed_package_imports = []
    exposed_package_objects = []
    exposed_package_args = cmd_args([package_flag, "base"])
    exposed_package_dbs = []

    for lib in direct_deps_link_info:
        info = lib.prof_info[link_style] if enable_profiling else lib.info[link_style]
        direct = info.value
        dynamic = direct.dynamic[enable_profiling]
        dynamic_info = resolved[dynamic][DynamicCompileResultInfo]

        for mod in package_deps.get(direct.name, []):
            exposed_package_modules.append(dynamic_info.modules[mod])

        if direct.name in package_deps:
            db = direct.empty_db
            exposed_package_dbs.append(db)

    packagedb_args = cmd_args(libs.project_as_args("empty_package_db"))

    haskell_direct_deps_lib_infos = attr_deps_haskell_lib_infos(
        ctx,
        link_style,
        enable_profiling,
    )

    pkg_deps = resolved[haskell_toolchain.packages.dynamic]
    package_db = pkg_deps[DynamicHaskellPackageDbInfo].packages

    toolchain_libs = [
        dep[HaskellToolchainLibrary].name
        for dep in ctx.attrs.deps
        if HaskellToolchainLibrary in dep
    ] + libs.reduce("packages")

    package_db_tset = ctx.actions.tset(
        HaskellPackageDbTSet,
        children = [package_db[name] for name in toolchain_libs if name in package_db]
    )

    packagedb_args.add(package_db_tset.project_as_args("package_db"))

    # Expose only the packages we depend on directly
    for lib in haskell_direct_deps_lib_infos:
        exposed_package_args.add(package_flag, lib.name)

    packages_info = PackagesInfo(
        exposed_package_modules = [],
        exposed_package_imports = exposed_package_imports,
        exposed_package_objects = exposed_package_objects,
        exposed_package_libs = cmd_args(),
        exposed_package_args = exposed_package_args,
        exposed_package_dbs = [],
        packagedb_args = cmd_args(),
        transitive_deps = libs,
    )

    # ------------------------------------------------------------

    packagedb_tag = ctx.actions.artifact_tag()

    # TODO[AH] Avoid duplicates and share identical env files.
    #   The set of package-dbs can be known at the package level, not just the
    #   module level. So, we could generate this file outside of the
    #   dynamic_output action.
    package_env_file = ctx.actions.declare_output(".".join([
        ctx.label.name,
        module_name or "pkg",
        "package-db",
        output_extensions(link_style, enable_profiling)[1],
        "env",
    ]))
    package_env = cmd_args(delimiter = "\n")
    packagedb_args_tagged = packagedb_tag.tag_artifacts(packagedb_args)
    package_env.add(cmd_args(
        packagedb_args_tagged,
        format = "package-db {}",
    ).relative_to(package_env_file, parent = 1))
    ctx.actions.write(
        package_env_file,
        package_env,
    )
    compile_args_for_file.add(cmd_args(
        packagedb_tag.tag_artifacts(package_env_file),
        prepend = "-package-env",
        hidden = packagedb_args_tagged,
    ))

    dep_file = ctx.actions.declare_output(".".join([
        ctx.label.name,
        module_name or "pkg",
        "package-db",
        output_extensions(link_style, enable_profiling)[1],
        "dep",
    ])).as_output()
    tagged_dep_file = packagedb_tag.tag_artifacts(dep_file)
    compile_args_for_file.add("--buck2-packagedb-dep", tagged_dep_file)

    # Add args from preprocess-able inputs.
    inherited_pre = cxx_inherited_preprocessor_infos(ctx.attrs.deps)
    pre = cxx_merge_cpreprocessors(ctx, [], inherited_pre)
    pre_args = pre.set.project_as_args("args")
    compile_args_for_file.add(cmd_args(pre_args, format = "-optP={}"))

    if pkgname:
        compile_args_for_file.add(["-this-unit-id", pkgname])

    objects = [outputs[obj] for obj in module.objects]
    his = [outputs[hi] for hi in module.interfaces]
    stubs = outputs[module.stub_dir]

    compile_args_for_file.add("-outputdir", cmd_args([cmd_args(stubs.as_output()).parent(), module.prefix_dir], delimiter="/"))
    compile_args_for_file.add("-o", objects[0].as_output())
    compile_args_for_file.add("-ohi", his[0].as_output())
    compile_args_for_file.add("-stubdir", stubs.as_output())
    compile_args_for_file.add(packages_info.bin_paths)

    if link_style in [LinkStyle("static_pic"), LinkStyle("static")]:
        compile_args_for_file.add("-dynamic-too")
        compile_args_for_file.add("-dyno", objects[1].as_output())
        compile_args_for_file.add("-dynohi", his[1].as_output())

    compile_args_for_file.add(module.source)

    aux_deps = ctx.attrs.srcs_deps.get(module.source)
    if aux_deps:
        compile_args_for_file.hidden(aux_deps)

    non_haskell_sources = [src for (path, src) in srcs_to_pairs(ctx.attrs.srcs) if not is_haskell_src(path)]

    if non_haskell_sources:
        warning("{} specifies non-haskell file in `srcs`, consider using `srcs_deps` instead".format(ctx.label))

        compile_args_for_file.hidden(non_haskell_sources)

    if haskell_toolchain.use_argsfile:
        argsfile = ctx.actions.declare_output(
            "haskell_compile_" + artifact_suffix + ".argsfile",
        )
        ctx.actions.write(argsfile.as_output(), compile_args_for_file, allow_args = True)
        compile_cmd.add(cmd_args(argsfile, format = "@{}"))
        compile_cmd.hidden(compile_args_for_file)
    else:
        compile_cmd.add(compile_args_for_file)

    compile_cmd.add(
        cmd_args(
            cmd_args(md_file, format = "-i{}").parent(),
            "/",
            module.prefix_dir,
            delimiter=""
        )
    )

    # Transitive module dependencies from other packages.
    cross_package_modules = ctx.actions.tset(
        CompiledModuleTSet,
        children = exposed_package_modules,
    )
    # Transitive module dependencies from the same package.
    this_package_modules = [
        module_tsets[dep_name]
        for dep_name in graph[module_name]
    ]

    dependency_modules = ctx.actions.tset(
        CompiledModuleTSet,
        children = [cross_package_modules] + this_package_modules,
    )

    compile_cmd.add(cmd_args(toolchain_deps, prepend = "-package-id"))
    compile_cmd.add(cmd_args(package_deps.keys(), prepend = "-package"))

    abi_tag = ctx.actions.artifact_tag()

    compile_cmd.hidden(
        abi_tag.tag_artifacts(dependency_modules.project_as_args("interfaces")))
    if enable_th:
        compile_cmd.hidden(dependency_modules.project_as_args("objects"))
        compile_cmd.add(dependency_modules.project_as_args("dyn_objects_dot_o"))
        compile_cmd.add(cmd_args(dependency_modules.reduce("package_deps").keys(), prepend = "-package"))
        compile_cmd.add(cmd_args(dependency_modules.reduce("toolchain_deps").keys(), prepend = "-package-id"))

    compile_cmd.add(cmd_args(dependency_modules.reduce("packagedb_deps").keys(), prepend = "--buck2-package-db"))

    dep_file = ctx.actions.declare_output("dep-{}_{}".format(module_name, artifact_suffix)).as_output()

    tagged_dep_file = abi_tag.tag_artifacts(dep_file)

    compile_cmd.add("--buck2-dep", tagged_dep_file)
    compile_cmd.add("--abi-out", outputs[module.hash].as_output())
    compile_cmd.hidden(dependency_modules.project_as_args("abi"))

    ctx.actions.run(
        compile_cmd, category = "haskell_compile_" + artifact_suffix.replace("-", "_"), identifier = module_name,
        dep_files = {
            "abi": abi_tag,
            "packagedb": packagedb_tag,
        }
    )

    object = module.objects[-1]
    if object.extension == ".o":
        dyn_object_dot_o = object
    else:
        dyn_object_dot_o = ctx.actions.declare_output("dot-o", paths.replace_extension(object.short_path, ".o"))
        ctx.actions.symlink_file(dyn_object_dot_o, object)

    module_tset = ctx.actions.tset(
        CompiledModuleTSet,
        value = CompiledModuleInfo(
            abi = module.hash,
            interfaces = module.interfaces,
            objects = module.objects,
            dyn_object_dot_o = dyn_object_dot_o,
            package_deps = package_deps.keys(),
            toolchain_deps = toolchain_deps,
            db_deps = exposed_package_dbs,
        ),
        children = [cross_package_modules] + this_package_modules,
    )

    return module_tset


# Compile all the context's sources.
def compile(
        ctx: AnalysisContext,
        link_style: LinkStyle,
        enable_profiling: bool,
        enable_haddock: bool,
        md_file: Artifact,
        pkgname: str | None = None) -> CompileResultInfo:
    artifact_suffix = get_artifact_suffix(link_style, enable_profiling)

    modules = _modules_by_name(ctx, sources = ctx.attrs.srcs, link_style = link_style, enable_profiling = enable_profiling, suffix = artifact_suffix)

    def do_compile(ctx, artifacts, resolved, outputs, md_file=md_file, modules=modules):
        md = artifacts[md_file].read_json()
        th_modules = md["th_modules"]
        module_map = md["module_mapping"]
        graph = md["module_graph"]
        package_deps = md["package_deps"]
        toolchain_deps = md["toolchain_deps"]

        mapped_modules = { module_map.get(k, k): v for k, v in modules.items() }
        module_tsets = {}

        for module_name in post_order_traversal(graph):
            module_tsets[module_name] = _compile_module(
                ctx,
                link_style = link_style,
                enable_profiling = enable_profiling,
                enable_haddock = enable_haddock,
                enable_th = module_name in th_modules,
                module_name = module_name,
                modules = mapped_modules,
                module_tsets = module_tsets,
                graph = graph,
                package_deps = package_deps.get(module_name, {}),
                toolchain_deps = toolchain_deps.get(module_name, []),
                outputs = outputs,
                resolved = resolved,
                md_file=md_file,
                artifact_suffix = artifact_suffix,
                pkgname = pkgname,
            )

        return [DynamicCompileResultInfo(modules = module_tsets)]

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    interfaces = [interface for module in modules.values() for interface in module.interfaces]
    objects = [object for module in modules.values() for object in module.objects]
    stub_dirs = [module.stub_dir for module in modules.values()]
    abi_hashes = [module.hash for module in modules.values()]

    dyn_module_tsets = ctx.actions.dynamic_output(
        dynamic = [md_file],
        promises = [
            info.value.dynamic[enable_profiling]
            for lib in attr_deps_haskell_link_infos(ctx)
            for info in [
                lib.prof_info[link_style]
                if enable_profiling else
                lib.info[link_style]
            ]
        ] + [ haskell_toolchain.packages.dynamic ],
        inputs = ctx.attrs.srcs,
        outputs = [o.as_output() for o in interfaces + objects + stub_dirs + abi_hashes],
        f = do_compile)

    stubs_dir = ctx.actions.declare_output("stubs-" + artifact_suffix, dir=True)

    # collect the stubs from all modules into the stubs_dir
    ctx.actions.run(
        cmd_args([
            "bash", "-exuc",
            """\
            mkdir -p \"$0\"
            for stub; do
              find \"$stub\" -mindepth 1 -maxdepth 1 -exec cp -r -t \"$0\" '{}' ';'
            done
            """,
            stubs_dir.as_output(),
            stub_dirs
        ]),
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
