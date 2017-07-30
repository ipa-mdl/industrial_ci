#!/bin/bash

# Copyright (c) 2017, Mathias Lüdtke
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

function install_abi_tracker() {
    sudo apt-get update -qq
    sudo apt-get install -y -qq libelf-dev wdiff elfutils autoconf pkg-config links bsdtar wget sudo

    wget -q -O - https://raw.githubusercontent.com/lvc/installer/master/installer.pl | sudo perl - -install -prefix /usr abi-tracker

    git clone https://github.com/universal-ctags/ctags.git /tmp/ctags
    (cd /tmp/ctags && ./autogen.sh && ./configure && sudo make install)

    mkdir -p "/abicheck/db/$TARGET_REPO_NAME/" "/abicheck/src/$TARGET_REPO_NAME"/{current,0.0.0}
    cp -a "$TARGET_REPO_PATH" "/abicheck/src/$TARGET_REPO_NAME/current/src"
}


function abi_prepare_src() {
    local target_dir=$1
    local url=$2

    mkdir -p "$target_dir"

    if [ -d "$url" ]; then
        cp -a "$url" "$target_dir"
    else
        set -o pipefail
        wget -q -O - "$url" | bsdtar -C "$target_dir" -xf-
        set +o pipefail
    fi
}

function abi_build_workspace() {
    local base=$1
    local version=$2
    local workspace="$base/$version"
    local url=$3

    local cflags="-g -Og"

    abi_prepare_src "$workspace/src" "$url"

    rosdep install -q --from-paths "$workspace/src" --ignore-src -y

    catkin config --init --install -w "$workspace" --extend "/opt/ros/$ROS_DISTRO" --cmake-args -DCMAKE_C_FLAGS="$cflags" -DCMAKE_CXX_FLAGS="$cflags"
    catkin build -w "$workspace"

    mkdir "$workspace/abi_dumps"
    for l in "$workspace/install/lib"/*.so; do
        abi-dumper "$l" -o "$workspace/abi_dumps/$(basename $l ".so").dump" -lver "$version" -public-headers "$workspace/install/include"
    done
}

function run_abi_check() {
    if [ -z "$ABICHECK_URL" ]; then
        error 'please specify ABICHECK_URL'
    fi

    local target_ext=$(grep -Pio '\.(zip|tar\.\w+|tgz|tbz2)\Z' <<< "$ABICHECK_URL")
    local target_version=$(basename "$ABICHECK_URL" "$target_ext")
    ici_require_run_in_docker # this script must be run in docker

    ici_time_start install_abi_tracker
    install_abi_tracker > /dev/null
    ici_time_end  # install_abi_tracker

    ici_time_start setup_rosdep

    # Setup rosdep
    rosdep --version
    if ! [ -d /etc/ros/rosdep/sources.list.d ]; then
        sudo rosdep init
    fi
    ret_rosdep=1
    rosdep update || while [ $ret_rosdep != 0 ]; do sleep 1; rosdep update && ret_rosdep=0 || echo "rosdep update failed"; done
    rosdep install -q --from-paths "$TARGET_REPO_PATH" --ignore-src -y > /dev/null
    ici_time_end  # setup_rosdep

    ici_time_start abi_build_new
    abi_build_workspace /abicheck new "$TARGET_REPO_PATH"
    ici_time_end  # abi_build_new

    ici_time_start abi_build_old
    abi_build_workspace /abicheck/old $target_version "$ABICHECK_URL"
    ici_time_end  # abi_build_old

    local reports_dir="/abicheck/reports/$target_version"
    mkdir -p "$reports_dir"

    local broken=()
    for n in /abicheck/new/abi_dumps/*.dump; do
        local l=$(basename "$n" ".dump")
        local o="/abicheck/old/$target_version/abi_dumps/$l.dump"
        if [ -f "$o" ]; then
            ici_time_start "abi_check_$l"
            local ret=0
            abi-compliance-checker -report-path "$reports_dir/$l.html" -l "$l" -n "$n" -o "$o" || ret=$?
            if [ "$ret" -eq "0" ]; then
                ici_time_end # abi_check_*
            elif [ "$ret" -eq "1" ]; then
                links -dump "$reports_dir/$l.html"
                broken+=("$l")
                ici_time_end 33 "$ret" # abi_check_*, yellow
            else
                ici_exit "$ret"
            fi
        fi
    done

    if [ "${#broken[@]}" -gt "0" ]; then
        error "Broken libraries: ${broken[*]}"
    fi
}
