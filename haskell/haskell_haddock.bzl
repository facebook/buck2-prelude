# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//haskell:compile.bzl", "CompileResultInfo", "CompiledModuleTSet", "DynamicCompileResultInfo")
load("@prelude//haskell:link_info.bzl", "cxx_toolchain_link_style")
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellToolchainInfo",
)
load(
    "@prelude//haskell:util.bzl",
    "attr_deps",
    "attr_deps_haskell_link_infos",
    "src_to_module_name",
)
load("@prelude//utils:graph_utils.bzl", "post_order_traversal")

HaskellHaddockInfo = provider(
    fields = {
        "html": provider_field(dict[str, typing.Any], default = {}),
        "interfaces": provider_field(list[typing.Any], default = []),
    },
)


_HaddockInfo = record(
    interface = Artifact,
    haddock = Artifact,
    html = Artifact,
)

def _haskell_interfaces_args(info: _HaddockInfo):
    return cmd_args(info.interface, format="--one-shot-dep-hi={}")

_HaddockInfoTSet = transitive_set(
    args_projections = {
        "interfaces": _haskell_interfaces_args
    }
)

def _haddock_dump_interface(
    ctx: AnalysisContext,
    cmd: cmd_args,
    module_name: str,
    module_tsets: dict[str, _HaddockInfoTSet],
    haddock_info: _HaddockInfo,
    module_deps: list[CompiledModuleTSet],
    graph: dict[str, list[str]],
    outputs: dict[Artifact, Artifact]) -> _HaddockInfoTSet:

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

    ctx.actions.run(
        cmd.copy().add(
            "--odir", cmd_args(outputs[haddock_info.html].as_output(), parent = 1),
            "--dump-interface", outputs[haddock_info.haddock].as_output(),
            "--html",
            "--hoogle",
            cmd_args(
                haddock_info.interface,
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

    return ctx.actions.tset(
        _HaddockInfoTSet,
        value = _HaddockInfo(interface = haddock_info.interface, haddock = outputs[haddock_info.haddock], html = outputs[haddock_info.html]),
        children = this_package_modules,
    )


def haskell_haddock_lib(ctx: AnalysisContext, pkgname: str, compiled: CompileResultInfo, md_file: Artifact) -> HaskellHaddockInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    link_style = cxx_toolchain_link_style(ctx)

    cmd = cmd_args(haskell_toolchain.haddock)

    cmd.add(
        "--use-index",
        "doc-index.html",
        "--use-contents",
        "index.html",
        "--no-tmp-comp-dir",
        "--no-warnings",
        "--package-name",
        pkgname,
    )

    cmd.add(ctx.attrs.haddock_flags)

    source_entity = read_root_config("haskell", "haddock_source_entity", None)
    if source_entity:
        cmd.add("--source-entity", source_entity)

    haddock_infos = {
        src_to_module_name(hi.short_path): _HaddockInfo(
            interface = hi,
            haddock = ctx.actions.declare_output("haddock-interface/{}.haddock".format(src_to_module_name(hi.short_path))),
            html = ctx.actions.declare_output("haddock-html/{}.html".format(src_to_module_name(hi.short_path).replace(".", "-"))),
        )
        for hi in compiled.hi
    }

    direct_deps_link_info = attr_deps_haskell_link_infos(ctx)

    def haddock_dump_interfaces(ctx, artifacts, resolved, outputs, md_file=md_file, dyn_cmd=cmd.copy(), haddock_infos=haddock_infos):
        md = artifacts[md_file].read_json()
        module_map = md["module_mapping"]
        graph = md["module_graph"]
        package_deps = md["package_deps"]

        dynamic_info_lib = {}

        for lib in direct_deps_link_info:
            info = lib.info[link_style]
            direct = info.value
            dynamic = direct.dynamic[False]
            dynamic_info = resolved[dynamic][DynamicCompileResultInfo]

            dynamic_info_lib[direct.name] = dynamic_info

        haddock_infos = { module_map.get(k, k): v for k, v in haddock_infos.items() }
        module_tsets = {}

        for module_name in post_order_traversal(graph):
            module_deps = [
                info.modules[mod]
                for lib, info in dynamic_info_lib.items()
                for mod in package_deps.get(module_name, {}).get(lib, [])
            ]

            module_tsets[module_name] = _haddock_dump_interface(
                ctx,
                dyn_cmd.copy(),
                module_name = module_name,
                module_tsets = module_tsets,
                haddock_info = haddock_infos[module_name],
                module_deps = module_deps,
                graph = graph,
                outputs = outputs,
            )

    ctx.actions.dynamic_output(
        dynamic = [md_file],
        promises = [
            info.value.dynamic[False]
            for lib in direct_deps_link_info
            for info in [
                #lib.prof_info[link_style]
                #if enable_profiling else
                lib.info[link_style],
            ]
        ],
        inputs = compiled.hi,
        outputs = [output.as_output() for info in haddock_infos.values() for output in [info.haddock, info.html]],
        f = haddock_dump_interfaces,
    )

    return HaskellHaddockInfo(
        interfaces = [i.haddock for i in haddock_infos.values()],
        html = {module: i.html for module, i in haddock_infos.items()},
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
                dep_htmls.extend(hi.html.values())

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
