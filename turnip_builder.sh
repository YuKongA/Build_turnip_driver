#!/bin/bash -e

GITHUB_ENV="$1"
MESA_BRANCH="$2"
A750_FIX="$3"
WORK_DIR="$(pwd)/turnip_workdir"
NDK_DIR="android-ndk-r26c"
SDK_VER="31"
MESA_GIT="https://gitlab.freedesktop.org/mesa/mesa.git"

DATA=$(date +'%y%m%d')
echo "DATA="${DATA}"" >>$GITHUB_ENV

clear

# there are 3 functions here, simply comment to disable.
# you can insert your own function and make a pull request.
run_all() {
	prepare_workdir
	if [ "$A750_FIX" = "true" ]; then
		fix_8g3
	fi
	build_for_android
}

prepare_workdir() {
	echo "Creating and entering to work directory ..." $'\n'
	mkdir -p "$WORK_DIR" && cd "$_"

	echo "Downloading android-ndk ..." $'\n'
	curl https://dl.google.com/android/repository/"$NDK_DIR"-linux.zip --output "$NDK_DIR"-linux.zip

	echo "Exracting android-ndk ..." $'\n'
	unzip "$NDK_DIR"-linux.zip &>/dev/null

	echo "Cloning mesa ..." $'\n'
	git clone --depth=1 "$MESA_GIT" -b "$MESA_BRANCH" &>/dev/null
	cd mesa

	mesa_version=$(cat VERSION | xargs)
	version=$(awk -F'COMPLETE VK_MAKE_API_VERSION(|)' '{print $2}' <<<$(cat include/vulkan/vulkan_core.h) | xargs)
	major=$(echo $version | cut -d "," -f 2 | xargs)
	minor=$(echo $version | cut -d "," -f 3 | xargs)
	patch=$(awk -F'VK_HEADER_VERSION |\n#define' '{print $2}' <<<$(cat include/vulkan/vulkan_core.h) | xargs)
	vulkan_version="$major.$minor.$patch"
	echo "MESA_VERSION="${mesa_version}"" >>$GITHUB_ENV
	echo "VULKAN_VERSION="${vulkan_version}"" >>$GITHUB_ENV
}

fix_8g3() {
	echo "Patched to fix 8g3 ..." $'\n'
	curl https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/27912.patch --output "27912.patch"
	git apply "27912.patch"
}

build_for_android() {
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
}

run_all
