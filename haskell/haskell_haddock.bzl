# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//haskell:compile.bzl", "compile_args", "CompileResultInfo", "CompiledModuleTSet", "DynamicCompileResultInfo")
load("@prelude//haskell:library_info.bzl", "HaskellLibraryInfoTSet")
load("@prelude//haskell:link_info.bzl", "cxx_toolchain_link_style")
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellToolchainInfo",
)
load(
    "@prelude//haskell:util.bzl",
    "attr_deps",
    "attr_deps_haskell_link_infos",
    "get_artifact_suffix",
    "is_haskell_src",
    "src_to_module_name",
)
load(
    "@prelude//paths.bzl", "paths"
)
load("@prelude//utils:graph_utils.bzl", "post_order_traversal", "breadth_first_traversal")
load("@prelude//utils:arglike.bzl", "ArgLike")

HaskellHaddockInfo = provider(
    fields = {
        "html": provider_field(list[typing.Any], default = []),
        "interfaces": provider_field(list[typing.Any], default = []),
    },
)


_HaddockInterface = record(
    hi = Artifact,
    output = Artifact,
    html = Artifact,
)

_HaddockInfo = record(
    interface = ArgLike, # FIXME should be Artifact
    dump = Artifact,
    html = Artifact,
)

def _haskell_interfaces_args(info: _HaddockInfo):
    return cmd_args(info.interface, format="--one-shot-dep-hi={}")

_HaddockInfoTSet = transitive_set(
    args_projections = {
        "interfaces": _haskell_interfaces_args
    }
)

def _dump_haddock_interface(
    ctx: AnalysisContext,
    cmd: cmd_args,
    module_name: str,
    module_tsets: dict[str, _HaddockInfoTSet],
    haddock_interfaces: dict[str, _HaddockInterface],
    module_deps: list[CompiledModuleTSet],
    graph: dict[str, list[str]],
    outputs: dict[Artifact, Artifact]) -> _HaddockInfoTSet:

    haddock_interface = haddock_interfaces[module_name]

    #pprint(cmd)

    #print(transitive_deps.keys())
    #deps = [ dep for dep in transitive_deps[module_name] ]

    # Transitive module dependencies from other packages.
    cross_package_modules = ctx.actions.tset(
        CompiledModuleTSet,
        children = module_deps,
    )
    cross_interfaces = cross_package_modules.project_as_args("interfaces")

    # Transitive module dependencies from the same package.
    this_package_modules = [
        module_tsets[dep_name]
        for dep_name in graph[module_name]
    ]
    #pprint(this_package_modules)

    ctx.actions.run(
        cmd.copy().add(
            "--html",
            "--hoogle",
            "--odir", cmd_args(outputs[haddock_interface.html].as_output(), parent = 1),
            "--dump-interface", outputs[haddock_interface.output].as_output(),
            cmd_args(
                haddock_interface.hi,
                format="--one-shot-hi={}"),
            cmd_args(
                [haddock_info.project_as_args("interfaces") for haddock_info in this_package_modules],
            ),
            cmd_args(
                cross_interfaces, format="--one-shot-dep-hi={}"
            )
        ),
        category = "haskell_haddock",
        identifier = module_name,
        no_outputs_cleanup = True,
    )

    #print(module_name, ":", this_package_modules)

    return ctx.actions.tset(
        _HaddockInfoTSet,
        value = _HaddockInfo(interface = haddock_interface.hi, dump = outputs[haddock_interface.output], html = outputs[haddock_interface.html]),
        children = this_package_modules,
    )


#def haskell_haddock_lib(ctx: AnalysisContext, pkgname: str, sources: list[Artifact], compiled: CompileResultInfo, md_file: Artifact) -> Provider:
def haskell_haddock_lib(ctx: AnalysisContext, pkgname: str, compiled: CompileResultInfo, md_file: Artifact) -> Provider:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    link_style = cxx_toolchain_link_style(ctx)
    # args = compile_args(
    #     ctx,
    #     link_style,
    #     enable_profiling = False,
    #     enable_th = True,
    #     suffix = "-haddock",
    #     pkgname = pkgname,
    # )

    touch = ctx.actions.declare_output("haddock-stamp")
    ctx.actions.write(touch, "")
    cmd = cmd_args(haskell_toolchain.haddock)
    #cmd.add(cmd_args(args.args_for_cmd, format = "--optghc={}"))

    cmd.add(
        "--use-index",
        "doc-index.html",
        "--use-contents",
        "index.html",
        #"--html",
        #"--hoogle",
        "--no-tmp-comp-dir",
        "--no-warnings",
        #"--dump-interface",
        #iface.as_output(),
        #"--trace-args",
        #"--odir",
        #odir.as_output(),
        "--package-name",
        pkgname,
    )

    cmd.add(ctx.attrs.haddock_flags)

    source_entity = read_root_config("haskell", "haddock_source_entity", None)
    if source_entity:
        cmd.add("--source-entity", source_entity)

    # if args.args_for_file:
    #     if haskell_toolchain.use_argsfile:
    #         argsfile = ctx.actions.declare_output(
    #             "haskell_haddock.argsfile",
    #         )
    #         ghcargs = cmd_args(args.args_for_file, format = "--optghc={}")
    #         fileargs = cmd_args(ghcargs).add(args.srcs)
    #         ctx.actions.write(argsfile.as_output(), fileargs, allow_args = True)
    #         cmd.add(cmd_args(argsfile, format = "@{}"))
    #         cmd.hidden(fileargs)
    #     else:
    #         cmd.add(cmd_args(args.args_for_file, format = "--optghc={}"))

    cmd.add(
        cmd_args(
            cmd_args(touch, format = "--optghc=-i{}").parent(),
            "mod-shared",
            delimiter="/"
        ),
        # cmd_args(
        #     "-hidir",
        #     cmd_args(cmd_args(touch).parent(), "mod-shared", delimiter="/"),
        #     format="--optghc={}"
        # )
    )

    artifact_suffix = get_artifact_suffix(link_style, enable_profiling = False)

    #modules = modules_by_name(ctx, sources = ctx.attrs.srcs, link_style = link_style, enable_profiling = False, suffix = artifact_suffix)

    haddock_interfaces = {
        src_to_module_name(hi.short_path): _HaddockInterface(
            hi = hi,
            output = ctx.actions.declare_output("haddock-interface/{}.haddock".format(src_to_module_name(hi.short_path))),
            html = ctx.actions.declare_output("haddock-html/{}.html".format(src_to_module_name(hi.short_path).replace(".", "-"))),
        )
        for hi in compiled.hi
    }

    # for haddock in haddock_interfaces.values():
    #     ctx.actions.run(
    #         cmd_args("touch", haddock.output.as_output()),
    #         category = "touch_haddock",
    #         identifier = haddock.output.short_path,
    #     )
    cmd.hidden(hifaces) # TODO remove once no longer needed

    direct_deps_link_info = attr_deps_haskell_link_infos(ctx)

    def dump_haddock_interfaces(ctx, artifacts, resolved, outputs, md_file=md_file, dyn_cmd=cmd.copy(), haddock_interfaces=haddock_interfaces):
        md = artifacts[md_file].read_json()
        th_modules = md["th_modules"]
        module_map = md["module_mapping"]
        graph = md["module_graph"]
        package_deps = md["package_deps"]

        print(ctx.label.name, package_deps)
        # libs = ctx.actions.tset(HaskellLibraryInfoTSet, children = [
        #     lib.info[link_style]
        #     for lib in direct_deps_link_info
        # ])


        dynamic_info_lib = {}

        for lib in direct_deps_link_info:
            info = lib.info[link_style]
            direct = info.value
            dynamic = direct.dynamic[False]
            dynamic_info = resolved[dynamic][DynamicCompileResultInfo]

            dynamic_info_lib[direct.name] = dynamic_info

        mapped_modules = { module_map.get(k, k): v for k, v in haddock_interfaces.items() }
        module_tsets = {}

        for module_name in post_order_traversal(graph):
            module_deps = [
                info.modules[mod]
                for lib, info in dynamic_info_lib.items()
                for mod in package_deps.get(module_name, {}).get(lib, [])
            ]

            # for lib, info in dynamic_info_lib.items():
            #     for mod in package_deps.get(module_name, {}).get(lib, []):
            #         module_deps.append(info.modules[mod])

            module_tsets[module_name] = _dump_haddock_interface(
                ctx,
                dyn_cmd.copy(),
                module_name = module_name,
                module_tsets = module_tsets,
                haddock_interfaces = mapped_modules,
                module_deps = module_deps,
                graph = graph,
                outputs = outputs
            )

    #print(haddock_interfaces)
    ctx.actions.dynamic_output(
        dynamic = [md_file],
        promises = [
            info.value.dynamic[False]
            for lib in direct_deps_link_info
            for info in [
                #lib.prof_info[link_style]
                #if enable_profiling else
                lib.info[link_style]
            ]
        ],
        inputs = compiled.hi,
        outputs = [output.as_output() for haddock in haddock_interfaces.values() for output in [haddock.output, haddock.html]],
        f = dump_haddock_interfaces
    )

    # for haddock in haddock_interfaces.values():
    #     ctx.actions.run(
    #         cmd.copy().add(
    #             #"--odir", mod_odir,
    #             "--dump-interface", haddock.output.as_output(),
    #             # TODO add specific reference to hi artifact
    #             cmd_args(
    #                 cmd_args(
    #                     cmd_args(haddock.output.as_output(), parent = 2),
    #                     "mod-shared",
    #                     paths.replace_extension(haddock.src.short_path, ".dyn_hi"), delimiter='/'),
    #                 format="--one-shot-hi={}"),
    #         ),
    #         category = "haskell_haddock_x",
    #         identifier = src_to_module_name(haddock.src.short_path),
    #         no_outputs_cleanup = True,
    #     )

        #mod_odir = ctx.actions.declare_output("haddock-out_{}".format(module), dir=True)

        #pprint(iface)

        # ctx.actions.run(
        #     cmd_args(
        #         "mkdir",
        #         mod_odir.as_output(),
        #     ),
        #     category = "haddock_odir",
        #     identifier = module,
        # )

    # cmd.add(
    #     "--use-index",
    #     "doc-index.html",
    #     "--use-contents",
    #     "index.html",
    #     "--html",
    #     "--hoogle",
    #     "--no-tmp-comp-dir",
    #     "--no-warnings",
    #     "--odir",
    #     odir.as_output(),
    #     #cmd_args(ifaces, format="--read-interface={}"),
    # )

    # #cmd.add(args.srcs)
    # #print([h.short_path for h in hifaces])
    # #pprint(cmd)

    # # Buck2 requires that the output artifacts are always produced, but Haddock only
    # # creates them if it needs to, so we need a wrapper script to mkdir the outputs.
    # script = ctx.actions.declare_output("haddock-script-{}".format(ctx.label.name))
    # script_args = cmd_args(["/nix/store/mb488rr560vq1xnl10hinnyfflcrd51n-coreutils-9.4/bin/ls "] + hifaces + [
    #     #"mkdir",
    #     #"-p",
    #     #args.result.objects[0].as_output(),
    #     #args.result.hi[0].as_output(),
    #     #args.result.stubs.as_output(),
    #     #"&& set -x &&",
    #     "&& /nix/store/mb488rr560vq1xnl10hinnyfflcrd51n-coreutils-9.4/bin/ls -lh &&",
    #     cmd_args(cmd, quote = "shell"),
    #     " >&2",
    # ], delimiter = " \\\n  ")
    # ctx.actions.write(
    #     script,
    #     cmd_args("#!/bin/sh", script_args),
    #     is_executable = True,
    #     allow_args = True,
    # )

    # ctx.actions.run(
    #     cmd_args(script).hidden(cmd),
    #     category = "haskell_haddock",
    #     identifier = "html",
    #     no_outputs_cleanup = True,
    # )


    return HaskellHaddockInfo(
        interfaces = [i.output for i in haddock_interfaces.values()],
        html = [i.html for i in  haddock_interfaces.values()]
    )

def haskell_haddock_impl(ctx: AnalysisContext) -> list[Provider]:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    out = ctx.actions.declare_output("haddock-html", dir = True)

    cmd = cmd_args(haskell_toolchain.haddock)

    cmd.add(
        "--gen-index",
        "--gen-contents",
        "-o",
        out.as_output(),
    )

    dep_htmls = []
    for lib in attr_deps(ctx):
        hi = lib.get(HaskellHaddockInfo)
        if hi != None:
            cmd.add(cmd_args(hi.interfaces, format="--read-interface={}"))
            if hi.html:
                dep_htmls.extend(hi.html)

    cmd.add(ctx.attrs.haddock_flags)

    script = ctx.actions.declare_output("haddock-script")
    script_args = cmd_args([
        "#!/bin/sh",
        cmd_args(
            cmd_args(cmd, delimiter = " ", quote = "shell"),
            [
                cmd_args(
                    ["cp", "-f", "--reflink=auto", html, out.as_output()],
                    delimiter = " ",
                ) for html in dep_htmls
            ],
            delimiter = " && \\\n  "
        )
    ])

    ctx.actions.write(
        script,
        script_args,
        is_executable = True,
        allow_args = True,
    )

    ctx.actions.run(
        cmd_args(script).hidden(script_args),
        category = "haskell_haddock",
        no_outputs_cleanup = True,
    )

    return [DefaultInfo(default_outputs = [out])]
