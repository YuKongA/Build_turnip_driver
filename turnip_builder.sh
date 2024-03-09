#!/bin/bash

GITHUB_ENV="$1"
MESA_BRANCH="$2"
NDK_DIR="$3"
SDK_VER="$4"
A750_FIX="$5"
MAGISK="$6"
ADRENOTOOL="$7"

MESA_GIT="https://gitlab.freedesktop.org/mesa/mesa.git"
NDK_DIR="android-ndk-$NDK_DIR"
WORK_DIR="$(pwd)/turnip_workdir"
MAGISK_DIR="$WORK_DIR/turnip_module"
PACKAGE_DIR="$WORK_DIR/turnip_package"

DATA=$(date +'%y%m%d')
echo "DATA="${DATA}"" >>$GITHUB_ENV

# there are 5 functions here, simply comment to disable.
# you can insert your own function and make a pull request.
run_all() {
	prepare_workdir

	if [ "$A750_FIX" = "true" ]; then
		fix_8g3
	fi

	build_lib_for_android

	if [ "$MAGISK" = "true" ]; then
		port_lib_for_magisk
	fi

	if [ "$ADRENOTOOL" = "true" ]; then
		port_lib_for_adrenotool
	fi
}

prepare_workdir() {
	echo "Creating and entering to work directory ..." $'\n'
	mkdir -p "$WORK_DIR" && cd "$_"

	echo "Downloading "$NDK_DIR" ..." $'\n'
	curl https://dl.google.com/android/repository/"$NDK_DIR"-linux.zip --output "$NDK_DIR"-linux.zip

	echo "Exracting "$NDK_DIR" ..." $'\n'
	unzip "$NDK_DIR"-linux.zip &>/dev/null
	rm -rf "$NDK_DIR"-linux.zip

	echo "Cloning mesa ..." $'\n'
	git clone --depth=1 "$MESA_GIT" -b "$MESA_BRANCH" &>/dev/null
	cd mesa

	MESA_VERSION=$(cat VERSION | xargs)
	VERSION=$(awk -F'COMPLETE VK_MAKE_API_VERSION(|)' '{print $2}' <<<$(cat include/vulkan/vulkan_core.h) | xargs)
	MAJOR=$(echo $VERSION | cut -d "," -f 2 | xargs)
	MINOR=$(echo $VERSION | cut -d "," -f 3 | xargs)
	PATCH=$(awk -F'VK_HEADER_VERSION |\n#define' '{print $2}' <<<$(cat include/vulkan/vulkan_core.h) | xargs)
	VULKAN_VERSION="$MAJOR.$MINOR.$PATCH"
	echo "MESA_VERSION="${MESA_VERSION}"" >>$GITHUB_ENV
	echo "VULKAN_VERSION="${VULKAN_VERSION}"" >>$GITHUB_ENV
}

fix_8g3() {
	echo "Patched to fix 8g3 ..." $'\n'
	curl https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/27912.patch --output "27912.patch"
	git apply "27912.patch"
}

build_lib_for_android() {
	echo "Creating meson cross file ..." $'\n'
	NDK="$WORK_DIR/$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"

	cat <<EOF >"android-aarch64"
[binaries]
ar = '$NDK/llvm-ar'
c = ['ccache', '$NDK/aarch64-linux-android$SDK_VER-clang']
cpp = ['ccache', '$NDK/aarch64-linux-android$SDK_VER-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$NDK/llvm-strip'
# Android doesn't come with a pkg-config, but we need one for Meson to be happy not
# finding all the optional deps it looks for.  Use system pkg-config pointing at a
# directory we get to populate with any .pc files we want to add for Android
pkgconfig = ['env', 'PKG_CONFIG_LIBDIR=$NDK_DIR/pkgconfig', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

	echo "Generating build files ..." $'\n'
	meson build-android-aarch64 \
		--cross-file $WORK_DIR/mesa/android-aarch64 \
		-Dplatforms=android \
		-Dplatform-sdk-version=$SDK_VER \
		-Dandroid-stub=true \
		-Dgallium-drivers= \
		-Dvulkan-drivers=freedreno \
		-Dfreedreno-kmds=kgsl \
		-Dbuildtype=release \
		-Dvulkan-beta=true \
		-Db_lto=true

	echo "Compiling build files ..." $'\n'
	meson compile -C build-android-aarch64

	echo "Using patchelf to match soname ..." $'\n'
	cp "$WORK_DIR"/mesa/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$WORK_DIR"
	cd "$WORK_DIR"
	rm -rf mesa android-ndk-r26c
	mv libvulkan_freedreno.so vulkan.adreno.so
	patchelf --set-soname vulkan.adreno.so vulkan.adreno.so
}

port_lib_for_magisk() {
	cd "$WORK_DIR"

	mkdir -p "$MAGISK_DIR" && cd "$_"

	HW="system/vendor/lib64/hw"
	mkdir -p "$HW"

	META="META-INF/com/google/android"
	mkdir -p "$META"

	cat <<EOF >"$META/update-binary"
#################
# Initialization
#################
umask 022
ui_print() { echo "\$1"; }
OUTFD=\$2
ZIPFILE=\$3
. /data/adb/magisk/util_functions.sh
install_module
exit 0
EOF

	cat <<EOF >"$META/updater-script"
#MAGISK
EOF

	cat <<EOF >"module.prop"
id=turnip_driver
name=Turnip Driver $MESA_VERSION $VULKAN_VERSION
version=$DATA
versionCode=$DATA
author=Mesa
description=Turnip is an open-source vulkan driver for devices with adreno GPUs.
EOF

	cat <<EOF >"customize.sh"
set_perm_recursive \$MODPATH/system 0 0 755 u:object_r:system_file:s0
set_perm_recursive \$MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0
set_perm \$MODPATH/$HW/vulkan.adreno.so 0 0 0644 u:object_r:same_process_hal_file:s0
EOF

	echo "Copy necessary files from work directory ..." $'\n'
	cp "$WORK_DIR"/vulkan.adreno.so "$MAGISK_DIR"/"$HW"

	echo "Packing files in to magisk module ..." $'\n'
	MAGISK_FILENAME=[Magisk]TurnipDriver_"$MESA_VERSION"_"$VULKAN_VERSION"_SDK"$SDK_VER"_"$DATA"
	echo "MAGISK_FILENAME="${MAGISK_FILENAME}"" >>$GITHUB_ENV
	zip -r -9 "$WORK_DIR"/"$MAGISK_FILENAME".zip ./*
	rm -rf "$WORK_DIR"/turnip_module
}

port_lib_for_adrenotool() {
	cd "$WORK_DIR"

	mkdir -p "$PACKAGE_DIR" && cd "$_"

	cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Meas Turnip Driver",
  "description": "$MESA_VERSION $DATA",
  "author": "Mesa",
  "packageVersion": 1,
  "vendor": "Mesa",
  "driverVersion": "Vulkan $VULKAN_VERSION",
  "minApi": $SDK_VER,
  "libraryName": "vulkan.adreno.so"
}
EOF

	echo "Copy necessary files from work directory ..." $'\n'
	cp "$WORK_DIR"/vulkan.adreno.so "$PACKAGE_DIR"

	echo "Packing files in to adrenotool package ..." $'\n'
	ADRENOTOOL_FILENAME=[AdrenoTool]TurnipDriver_"$MESA_VERSION"_"$VULKAN_VERSION"_SDK"$SDK_VER"_"$DATA"
	echo "ADRENOTOOL_FILENAME="${ADRENOTOOL_FILENAME}"" >>$GITHUB_ENV
	zip -9 "$WORK_DIR"/"$ADRENOTOOL_FILENAME".zip ./*
	rm -rf "$WORK_DIR"/turnip_package
}

run_all
