# Copyright 2017 GRAIL, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Compilation database generation Bazel rules.

compilation_database will generate a compile_commands.json file for the
given targets. This approach uses the aspects feature of bazel.

An alternative approach is the one used by the kythe project using
(experimental) action listeners.
https://github.com/google/kythe/blob/master/tools/cpp/generate_compilation_database.sh
"""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load(
    "@bazel_tools//tools/build_defs/cc:action_names.bzl",
    "CPP_COMPILE_ACTION_NAME",
    "C_COMPILE_ACTION_NAME",
)

CompilationDbAspect = provider(
    fields = {
        "compilation_db": "depset of json objects of compilation commands",
    }
)

_cc_rules = [
    "cc_library",
    "cc_binary",
    "cc_test",
    "cc_inc_library",
    "cc_proto_library",
]

_objc_rules = [
    "objc_library",
    "objc_binary",
]

_all_rules = _cc_rules + _objc_rules

def _get_action_name(feature_configuration):
    for action_name in [
        CPP_COMPILE_ACTION_NAME,
        C_COMPILE_ACTION_NAME,
    ]:
        if cc_common.action_is_enabled(
            feature_configuration = feature_configuration,
            action_name = action_name
        ):
            return action_name
    return None

def _get_command_line(target, ctx, src, cc_toolchain):
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    action_name = _get_action_name(feature_configuration)
    if not action_name:
        return None
    compiler = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = action_name,
    )
    compilation_context = target[CcInfo].compilation_context
    compile_variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        source_file = src.path,
        user_compile_flags = ctx.fragments.cpp.cxxopts +
                                ctx.fragments.cpp.copts,
        include_directories = compilation_context.includes,
        quote_include_directories = compilation_context.quote_includes,
        system_include_directories = compilation_context.system_includes,
        framework_include_directories = compilation_context.framework_includes,
        preprocessor_defines = compilation_context.defines,
    )
    compiler_options = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = action_name,
        variables = compile_variables,
    )
    return "\"{}\" {}".format(compiler, ' '.join(compiler_options))


def _compilation_db_json(compilation_db):
    # Return a JSON string for the compilation db entries.

    entries = [entry.to_json() for entry in compilation_db]
    return ",\n ".join(entries)


def _sources(target, ctx):
    srcs = []
    if "srcs" in dir(ctx.rule.attr):
        srcs += [f for src in ctx.rule.attr.srcs for f in src.files.to_list()]
    if "hdrs" in dir(ctx.rule.attr):
        srcs += [f for src in ctx.rule.attr.hdrs for f in src.files.to_list()]

    if ctx.rule.kind == "cc_proto_library":
        srcs += [f for f in target.files.to_list() if f.extension in ["h", "cc"]]

    return srcs

def _compilation_database_aspect_impl(target, ctx):
    """Write the compile commands for this target to a file, and return the commands for the transitive closure."""

    # We support only these rule kinds.
    if ctx.rule.kind not in _all_rules:
        return []
    if ctx.label.workspace_name:
        return []

    compilation_db = []

    cc_toolchain = find_cpp_toolchain(ctx)
    srcs = _sources(target, ctx)
    for src in srcs:
        command_line = _get_command_line(
            target = target,
            ctx = ctx,
            src = src,
            cc_toolchain = cc_toolchain,
        )
        if command_line:
            compilation_db.append(
                struct(
                    command = command_line,
                    directory = "__BAZEL_EXECUTION_ROOT__",
                    file = "__BAZEL_WORKSPACE__/" + src.path,
                )
            )
        
    return [
        CompilationDbAspect(
            compilation_db = depset(
                direct = compilation_db,
                transitive = [
                    dep[CompilationDbAspect].compilation_db
                    for dep in ctx.rule.attr.deps
                    if CompilationDbAspect in dep
                ]
            )
        )
    ]

compilation_database_aspect = aspect(
    attr_aspects = ["deps"],
    attrs = {
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    fragments = ["cpp"],
    required_aspect_providers = [CcInfo],
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    implementation = _compilation_database_aspect_impl,
)

def _compilation_database_impl(ctx):
    # Generates a single compile_commands.json file with the
    # transitive depset of specified targets.

    compilation_db = []
    for target in ctx.attr.targets:
        compilation_db.append(target[CompilationDbAspect].compilation_db)

    compilation_db = depset(transitive = compilation_db)

    content = "[\n" + _compilation_db_json(compilation_db.to_list()) + "\n]\n"
    # content = content.replace("-isysroot __BAZEL_XCODE_SDKROOT__", "")
    ctx.actions.write(output = ctx.outputs.filename, content = content)

compilation_database = rule(
    attrs = {
        "targets": attr.label_list(
            aspects = [compilation_database_aspect],
            doc = "List of all cc targets which should be included.",
        ),
    },
    outputs = {
        "filename": "compile_commands.json",
    },
    implementation = _compilation_database_impl,
)
