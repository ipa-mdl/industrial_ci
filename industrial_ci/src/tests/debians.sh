#!/bin/bash

# Copyright (c) 2021, Mathias Lüdtke
# All rights reserved.
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

# Based on https://github.com/ros-industrial/industrial_ci/issues/697#issuecomment-876293987

function prepare_debians() {
    ici_forward_variable "TEST_DISTRO" "$ROS_DISTRO"
    ici_forward_variable "OS_NAME"
    ici_forward_variable "OS_CODE_NAME"

    export DOCKER_IMAGE=${DOCKER_IMAGE:-ros:$ROS_DISTRO-ros-core}
}

function run_bloom() (
    local pkg_path=$1
    shift
    cd "$pkg_path"
    # debian-inc=2 in case there are packages published from the build farm already
    bloom-generate rosdebian --ros-distro="$ROS_DISTRO" --debian-inc=2
    # https://github.com/ros-infrastructure/bloom/pull/643
    echo 11 > debian/compat
)

function build_debian() (
    local pkg_path=$1
    local repo=$2
    shift 2
    mkdir "$repo"
    cd "$pkg_path"
    # dpkg-source-opts: no need for upstream.tar.gz
    sbuild --extra-repository="deb $ROS_REPOSITORY_PATH $OS_CODE_NAME main" \
          --extra-repository-key="$_ROS_KEYRING" --no-run-lintian \
          --extra-package="$repo"  --dpkg-source-opts="-Zgzip -z1 --format=1.0 -sn"
    # https://bugs.debian.org/990734
    mv ../*.deb "$repo/"
)

function run_debians() {
    export BUILDER=colcon
    ici_source_builder
    ici_run "${BUILDER}_setup" ici_quiet builder_setup
    ici_run "setup_bloom" ici_quiet ici_install_pkgs_for_command bloom-generate python3-bloom
    ici_run "setup_sbuild" ici_quiet ici_install_pkgs_for_command --install-recommends sbuild fakeroot debhelper

    export ROS_DISTRO=$TEST_DISTRO
    ici_configure_ros
    ici_run "setup_rosdep" ici_setup_rosdep

    if [ ! -f "$_ROS_KEYRING" ]; then
      ici_run "setup_gpg_key" ici_setup_gpg_key
    fi

    local sourcespace
    ici_make_temp_dir sourcespace

    local sources=()
    ici_parse_env_array sources TARGET_WORKSPACE
    ici_run "prepare_sourcespace" ici_prepare_sourcespace "$sourcespace" "${sources[@]}"

    while read -r -a pkg; do
      ici_run "bloom_${pkg[0]}" run_bloom "$sourcespace/${pkg[1]}"
      ici_run "build_${pkg[0]}" build_debian "$sourcespace/${pkg[1]}" "$BASEDIR/debians"
    done < <(cd "$sourcespace" && colcon list -t)
}
