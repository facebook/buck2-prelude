# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

# TODO(cjhopman): This was generated by scripts/hacks/rules_shim_with_docs.py,
# but should be manually edited going forward. There may be some errors in
# the generated docs, and so those should be verified to be accurate and
# well-formatted (and then delete this TODO)

load(":common.bzl", "AbiGenerationMode", "UnusedDependenciesAction")

def _test_env():
    return {
        "env": attrs.dict(key = attrs.string(), value = attrs.arg(), sorted = False, default = {}, doc = """
    A map of environment names and values to set when running the test.
"""),
    }

def _resources_arg():
    return {
        "resources": attrs.list(attrs.source(), default = [], doc = """
    Static files to include with the compiled `.class` files.
     These files can be loaded
     via [Class.getResource()](http://docs.oracle.com/javase/7/docs/api/java/lang/Class.html#getResource(java.lang.String)).


    **Note:** If `resources_root` isn't set,
     Buck uses the ``.buckconfig``
     property in `.buckconfig` to
     determine where resources should be placed within the generated JAR
     file.
"""),
        "resources_root": attrs.option(attrs.source(), default = None, doc = """
    The path that resources are resolved against. For example, if `resources_root` is `"res"` and
     `resources` contains the file `"res/com/example/foo.txt"`, that file will end up as `"com/example/foo.txt"` in the output JAR. This parameter
     overrides the ``.buckconfig`` property in `.buckconfig`.
"""),
    }

def _remove_classes_arg():
    return {
        "remove_classes": attrs.list(attrs.regex(), default = [], doc = """
    Specifies a list of `Patterns` that are used to exclude
     `classes` from the `JAR`. The pattern matching is
     based on the name of the class. This can be used to exclude a member
     class or delete a local view of a class that will be replaced during
     a later stage of the build.
"""),
    }

def _provided_deps():
    return {
        "provided_deps": attrs.list(attrs.dep(), default = [], doc = """
    These represent dependencies that are known to be provided at run
     time, but are required in order for the code to compile. Examples of
     `provided_deps` include the JEE servlet APIs. When this
     rule is included in a , the
     `provided_deps` will not be packaged into the output.
"""),
    }

def _exported_deps():
    return {
        "exported_deps": attrs.list(attrs.dep(), default = [], doc = """
    Other  rules that depend on this rule will also
     include its `exported_deps` in their classpaths. This is useful
     when the public API of a rule has return types or checked exceptions that are
     defined in another rule, which would otherwise require callers to add an
     extra dependency. It's also useful for exposing e.g. a collection of
     `prebuilt_jar` rules as a single target for callers to depend
     on. Targets in `exported_deps` are implicitly included in the
     `deps` of this rule, so they don't need to be repeated there.
"""),
    }

def _exported_provided_deps():
    return {
        "exported_provided_deps": attrs.list(attrs.dep(), default = [], doc = """
    This is a combination of `provided_deps` and `exported_deps`. Rules listed
     in this parameter will be added to classpath of rules that depend on this rule, but they will not
     be included in a binary if binary depends on a such target.
"""),
    }

def _source_only_abi_deps():
    return {
        "source_only_abi_deps": attrs.list(attrs.dep(), default = [], doc = """
    These are dependencies that must be present during
     `source-only ABI generation`.
     Typically such dependencies are added when some property of the code in this rule prevents source-only ABI
     generation from being correct without these dependencies being present.


     Having `source_only_abi_deps` prevents Buck from
     completely flattening the build graph, thus reducing the performance win from source-only
     ABI generation. They should be avoided when possible. Often only a small code change is needed to avoid them.
     For more information on such code changes, read about
     `source-only ABI generation`.
"""),
    }

def _abi_generation_mode():
    return {
        "abi_generation_mode": attrs.option(attrs.enum(AbiGenerationMode), default = None, doc = """
    Overrides `.buckconfig`
    for this rule.
"""),
    }

def _required_for_source_only_abi():
    return {
        "required_for_source_only_abi": attrs.bool(default = False, doc = """
    Indicates that this rule must be present on the classpath during
     `source-only ABI generation`
     of any rule that depends on it. Typically this is done when a rule contains annotations,
     enums, constants, or interfaces.


     Having rules present on the classpath during source-only ABI generation prevents Buck from
     completely flattening the build graph, thus reducing the performance win from source-only
     ABI generation. These rules should be kept small (ideally just containing annotations,
     constants, enums, and interfaces) and with minimal dependencies of their own.
"""),
    }

def _on_unused_dependencies():
    return {
        "on_unused_dependencies": attrs.option(attrs.enum(UnusedDependenciesAction), default = None, doc = """
    Action performed when Buck detects that some dependencies are not used during Java compilation.


    Note that this feature is experimental and does not handle runtime dependencies.


    The valid values are:
     * `ignore` (default): ignore unused dependencies,
    * `warn`: emit a warning to the console,
    * `fail`: fail the compilation.



    This option overrides the default value from
    .
"""),
    }

def _k2():
    return {
        "k2": attrs.bool(default = False, doc = """
    Enables the Kotlin K2 compiler.
    """),
    }

def _incremental():
    return {
        "incremental": attrs.bool(default = False, doc = """
    Enables Kotlin incremental compilation.
    """),
    }

jvm_common = struct(
    test_env = _test_env,
    resources_arg = _resources_arg,
    remove_classes_arg = _remove_classes_arg,
    provided_deps = _provided_deps,
    exported_deps = _exported_deps,
    exported_provided_deps = _exported_provided_deps,
    source_only_abi_deps = _source_only_abi_deps,
    abi_generation_mode = _abi_generation_mode,
    required_for_source_only_abi = _required_for_source_only_abi,
    on_unused_dependencies = _on_unused_dependencies,
    k2 = _k2,
    incremental = _incremental,
)
