# Copyright (C) 2022 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load(
    ":common_providers.bzl",
    "KernelBuildAbiInfo",
    "KernelEnvInfo",
    "KernelModuleInfo",
)
load(":debug.bzl", "debug")
load(":utils.bzl", "utils")

def _extracted_symbols_impl(ctx):
    if ctx.attr.kernel_build_notrim[KernelBuildAbiInfo].trim_nonlisted_kmi:
        fail("{}: Requires `kernel_build` {} to have `trim_nonlisted_kmi = False`.".format(
            ctx.label,
            ctx.attr.kernel_build_notrim.label,
        ))

    if ctx.attr.kmi_symbol_list_add_only and not ctx.file.src:
        fail("{}: kmi_symbol_list_add_only requires kmi_symbol_list.".format(ctx.label))

    out = ctx.actions.declare_file("{}/extracted_symbols".format(ctx.attr.name))
    intermediates_dir = utils.intermediates_dir(ctx)

    vmlinux = utils.find_file(name = "vmlinux", files = ctx.files.kernel_build_notrim, what = "{}: kernel_build_notrim".format(ctx.attr.name), required = True)
    in_tree_modules = utils.find_files(suffix = ".ko", files = ctx.files.kernel_build_notrim, what = "{}: kernel_build_notrim".format(ctx.attr.name))
    srcs = [
        vmlinux,
    ]
    srcs += in_tree_modules
    for kernel_module in ctx.attr.kernel_modules:  # external modules
        srcs += kernel_module[KernelModuleInfo].files

    inputs = [ctx.file._extract_symbols]
    inputs += srcs
    inputs += ctx.attr.kernel_build_notrim[KernelEnvInfo].dependencies

    cp_src_cmd = ""
    flags = ["--symbol-list", out.path]
    if not ctx.attr.module_grouping:
        flags.append("--skip-module-grouping")
    if ctx.attr.kmi_symbol_list_add_only:
        flags.append("--additions-only")
        inputs.append(ctx.file.src)

        # Follow symlinks because we are in the execroot.
        # Do not preserve permissions because we are overwriting the file immediately.
        cp_src_cmd = "cp -L {src} {out}".format(
            src = ctx.file.src.path,
            out = out.path,
        )

    # Get the signed and stripped module archive for the GKI modules
    base_modules_archive = ctx.attr.kernel_build_for_base_modules[KernelBuildAbiInfo].modules_staging_archive
    inputs.append(base_modules_archive)

    command = ctx.attr.kernel_build_notrim[KernelEnvInfo].setup
    command += """
        mkdir -p {intermediates_dir}
        # Extract archive and copy the GKI modules First
        # TODO(/b/243570975): Use tar wildcards & xform once prebuilt supports it, as below:
        # tar --directory={intermediates_dir} --wildcards --xform='s#^.+/##x' -xf {base_modules_archive} '*.ko
        mkdir -p {intermediates_dir}/temp
        tar xf {base_modules_archive} -C {intermediates_dir}/temp
        find {intermediates_dir}/temp -name '*.ko' -exec mv -t {intermediates_dir} {{}} \\;
        rm -rf {intermediates_dir}/temp
        # Copy other inputs including vendor modules; this will overwrite modules being overridden
        cp -pfl {srcs} {intermediates_dir}
        {cp_src_cmd}
        {extract_symbols} {flags} {intermediates_dir}
        rm -rf {intermediates_dir}
    """.format(
        srcs = " ".join([file.path for file in srcs]),
        intermediates_dir = intermediates_dir,
        extract_symbols = ctx.file._extract_symbols.path,
        flags = " ".join(flags),
        cp_src_cmd = cp_src_cmd,
        base_modules_archive = base_modules_archive.path,
    )
    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out],
        command = command,
        progress_message = "Extracting symbols {}".format(ctx.label),
        mnemonic = "KernelExtractedSymbols",
    )

    return DefaultInfo(files = depset([out]))

extracted_symbols = rule(
    implementation = _extracted_symbols_impl,
    attrs = {
        # We can't use kernel_filegroup + hermetic_tools here because
        # - extract_symbols depends on the clang toolchain, which requires us to
        #   know the toolchain_version ahead of time.
        # - We also don't have the necessity to extract symbols from prebuilts.
        "kernel_build_notrim": attr.label(providers = [KernelEnvInfo, KernelBuildAbiInfo]),
        "kernel_modules": attr.label_list(providers = [KernelModuleInfo]),
        "module_grouping": attr.bool(default = True),
        "src": attr.label(doc = "Source `abi_gki_*` file. Used when `kmi_symbol_list_add_only`.", allow_single_file = True),
        "kmi_symbol_list_add_only": attr.bool(),
        "kernel_build_for_base_modules": attr.label(doc = "The `kernel_build` which `modules_staging_archive` is treated as GKI modules.", providers = [KernelBuildAbiInfo]),
        "_extract_symbols": attr.label(default = "//build/kernel:abi/extract_symbols", allow_single_file = True),
        "_debug_print_scripts": attr.label(default = "//build/kernel/kleaf:debug_print_scripts"),
    },
)
