load("@bazel_skylib//rules:write_file.bzl", "write_file")
load(":kleaf-scripts/msm_kernel_extensions.bzl", "get_custom_dtbo_img_list", "get_dtb_list", "get_dtbo_list", "get_dtstree", "get_techpack_dtbo_list")
load("//build/kernel/kleaf:kernel.bzl", "kernel_build", "kernel_build_config")

def define_qcom_dtb_setup():
    write_file(
        name = "dtb_build_config",
        out = "build.config.qcom.dtbs",
        content = [
            "KERNEL_DIR=common",
            "SOC_DIR={}".format(native.package_name()),
            "export DTC_INCLUDE=${ROOT_DIR}/${SOC_DIR}/include",
            "BOOT_IMAGE_HEADER_VERSION=4",
            "BUILD_INIT_BOOT_IMG=1",
            "LZ4_RAMDISK=1",
            "PAGE_SIZE=4096",
            "BASE_ADDRESS=0x80000000",
            "VENDOR_BOOTCONFIG+='androidboot.first_stage_console=1 androidboot.hardware=qcom_kp'",
            'DTC_FLAGS="-@"',
            "KERNEL_BINARY=Image",
            "",
        ],
    )

    kernel_build_config(
        name = "build.config.qcom.dtb",
        srcs = [
            ":dtb_build_config",
            "//common:build.config.common",
        ],
    )

def define_qcom_dtbs(
        stem,
        target,
        defconfig,
        cmdline = [""]):
    """Build a the dtbs for a target/variant.

    Args:
        stem: The name of the rule
        target: Configuration to use to build the DTBs
        defconfig: defconfig for the kernel_build.

    Returns:
        A tuple:
        - the first item is the list of DTBs to be built
        - the second item is the list of DTBOs to be built
    """

    write_file(
        name = "{}_cmdline_extras".format(stem),
        out = "{}.cmdline.extras".format(stem),
        content = ["KERNEL_VENDOR_CMDLINE='{}'".format(" ".join(cmdline)), ""],
    )

    kernel_build_config(
        name = "{}.build.config.qcom.dtb".format(stem),
        srcs = [
            ":{}_cmdline_extras".format(stem),
            ":build.config.qcom.dtb",
        ],
    )

    dtb_list = get_dtb_list(target)
    dtbo_list = get_dtbo_list(target)
    custom_dtbo_img_list = get_custom_dtbo_img_list(target)

    dtb_build_kwargs = dict(
        srcs = [
            # keep sorted
            ":additional_msm_headers_aarch64_globs",
            "//common:kernel_aarch64_sources",
        ],
        build_config = ":{}.build.config.qcom.dtb".format(stem),
        dtstree = get_dtstree(target),
        base_kernel = ":{}_base_kernel".format(stem),
        kconfig_ext = ":kconfig.msm.generated",
        makefile = "//common:Makefile",
        defconfig = defconfig,
        post_defconfig_fragments = [
            ":{}_merged_defconfig".format(stem),
        ],
        make_goals = [
            "dtbs",
        ],
        visibility = ["//visibility:public"],
    )

    techpack_groups = _techpack_dtbo_groups(target)

    kernel_build(
        name = "{}_dtb_build".format(stem),
        outs = dtb_list + dtbo_list + (techpack_groups[0] if techpack_groups else []) + ["vmlinux", "Module.symvers", "Image", "System.map", ".config"],
        **dtb_build_kwargs
    )

    # kernel_build outputs need unique basenames, build the overlays sharing
    # one (e.g. nfc/nxp/foo.dtbo and nfc/st/foo.dtbo) separately.
    for index, group in enumerate(techpack_groups[1:], 1):
        kernel_build(
            name = _techpack_dtb_build(stem, index),
            outs = group,
            **dtb_build_kwargs
        )

    return [dtb_list, dtbo_list, custom_dtbo_img_list]

def _techpack_dtb_build(stem, index):
    return "{}_dtb_build".format(stem) if index == 0 else "{}_dtb_build_techpack{}".format(stem, index)

def _techpack_dtbo_groups(target):
    """Splits the techpack overlays of a target into groups of unique basenames."""
    groups = []
    for dtbo in get_techpack_dtbo_list(target):
        basename = dtbo.split("/")[-1]
        placed = False
        for group in groups:
            if basename not in group:
                group[basename] = dtbo
                placed = True
                break
        if not placed:
            groups.append({basename: dtbo})
    return [group.values() for group in groups]

def techpack_dtbo_labels(stem, target, product = None):
    """Labels of the techpack overlays of a target (and product) built by define_qcom_dtbs."""
    wanted = get_techpack_dtbo_list(target, product = product)
    labels = []
    for index, group in enumerate(_techpack_dtbo_groups(target)):
        labels += [":{}/{}".format(_techpack_dtb_build(stem, index), dtbo) for dtbo in group if dtbo in wanted]
    return labels

def techpack_dtbo_renames(stem, target, product = None):
    """Map of techpack overlay labels to their relative paths under dtbs/techpack."""
    wanted = get_techpack_dtbo_list(target, product = product)
    renames = {}
    for index, group in enumerate(_techpack_dtbo_groups(target)):
        build_name = _techpack_dtb_build(stem, index)
        for dtbo in group:
            if dtbo in wanted:
                label = ":{}/{}".format(build_name, dtbo)
                dest = dtbo[len("qcom/"):] if dtbo.startswith("qcom/") else dtbo
                renames[label] = dest
    return renames
