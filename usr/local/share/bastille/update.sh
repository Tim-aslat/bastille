#!/bin/sh
#
# SPDX-License-Identifier: BSD-3-Clause
#
# Copyright (c) 2018-2025, Christer Edwards <christer.edwards@gmail.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
#
# * Neither the name of the copyright holder nor the names of its
#   contributors may be used to endorse or promote products derived from
#   this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

. /usr/local/share/bastille/common.sh

usage() {
    error_notify "Usage: bastille update [option(s)] TARGET"
    cat << EOF
    Options:

    -a | --auto             Auto mode. Start/stop jail(s) if required.
    -f | --force            Force update a release.
    -x | --debug            Enable debug mode.

EOF
    exit 1
}

if [ $# -gt 2 ] || [ $# -lt 1 ]; then
    usage
fi

# Handle options.
OPTION=""
AUTO=0
while [ "$#" -gt 0 ]; do
    case "${1}" in
        -h|--help|help)
            usage
            ;;
        -a|--auto)
            AUTO=1
            shift
            ;;
        -f|--force)
            OPTION="-F"
            shift
            ;;
        -x|--debug)
            enable_debug
            shift
            ;;
        -*) 
            for _opt in $(echo ${1} | sed 's/-//g' | fold -w1); do
                case ${_opt} in
                    a) AUTO=1 ;;
                    f) OPTION="-F" ;;
                    x) enable_debug ;;
                    *) error_exit "[ERROR]: Unknown Option: \"${1}\"" ;; 
                esac
            done
            shift
            ;;
        *)
            break
            ;;
    esac
done

TARGET="${1}"

bastille_root_check

if [ -f "/bin/midnightbsd-version" ]; then
    error_exit "[ERROR]: Not yet supported on MidnightBSD."
fi

if freebsd-version | grep -qi HBSD; then
    error_exit "[ERROR]: Not yet supported on HardenedBSD."
fi

# Check for alternate/unsupported archs
arch_check() {
    if echo "${TARGET}" | grep -w "[0-9]\{1,2\}\.[0-9]\-RELEASE\-i386"; then
        ARCH_I386="1"
    fi
}

jail_check() {

    # Check if the jail is thick and is running
    set_target_single "${TARGET}"

    check_target_is_running "${TARGET}" || if [ "${AUTO}" -eq 1 ]; then
        bastille start "${TARGET}"
    else
        info "\n[${TARGET}]:"
        error_notify "Jail is not running."
        error_exit "Use [-a|--auto] to auto-start the jail."
    fi

    info "\n[${TARGET}]:"

    if grep -qw "${bastille_jailsdir}/${TARGET}/root/.bastille" "${bastille_jailsdir}/${TARGET}/fstab"; then
        error_notify "[ERROR]: ${TARGET} is not a thick container."
        error_exit "See 'bastille update RELEASE' to update thin jails."
    fi
}

jail_update() {

    local _jailname="${1}"
    local _jailpath="${bastille_jailsdir}/${TARGET}/root"
    local _freebsd_update_conf="${_jailpath}/etc/freebsd-update.conf"
    local _workdir="${_jailpath}/var/db/freebsd-update"

    # Update a thick container
    if [ -d "${bastille_jailsdir}/${TARGET}" ]; then   
        CURRENT_VERSION=$(/usr/sbin/jexec -l "${TARGET}" freebsd-version 2>/dev/null)
        if [ -z "${CURRENT_VERSION}" ]; then
            error_exit "[ERROR]: Can't determine '${TARGET}' version."
        else
            env PAGER="/bin/cat" freebsd-update ${OPTION} \
            --not-running-from-cron \
            -j "${_jailname}" \
            -d "${_workdir}" \
            -f "${_freebsd_update_conf}" \
            fetch install
        fi
    fi
}

release_update() {

    local _releasepath="${bastille_releasesdir}/${TARGET}"
    local _freebsd_update_conf="${_releasepath}/etc/freebsd-update.conf"
    local _workdir="${_releasepath}/var/db/freebsd-update"

    # Update a release base(affects child containers)
    if [ -d "${_releasepath}" ]; then
        TARGET_TRIM="${TARGET}"
        if [ -n "${ARCH_I386}" ]; then
            TARGET_TRIM=$(echo "${TARGET}" | sed 's/-i386//')
        fi
        env PAGER="/bin/cat" freebsd-update ${OPTION} \
        --not-running-from-cron \
        -b "${_releasepath}" \
        -d "${_workdir}" \
        -f "${_freebsd_update_conf}" \
        fetch --currently-running "${TARGET_TRIM}"
        env PAGER="/bin/cat" freebsd-update ${OPTION} \
        --not-running-from-cron \
        -b "${_releasepath}" \
        -d "${_workdir}" \
        -f "${_freebsd_update_conf}" \
        install --currently-running "${TARGET_TRIM}"
    else
        error_exit "[ERROR]: ${TARGET} not found. See 'bastille bootstrap RELEASE'."
    fi
}

template_update() {

    # Update a template
    _template_path=${bastille_templatesdir}/${BASTILLE_TEMPLATE}

    if [ -d $_template_path ]; then
        info "\n[${BASTILLE_TEMPLATE}]:"
        if ! git -C $_template_path pull; then
            error_exit "[ERROR]: ${BASTILLE_TEMPLATE} update unsuccessful."    
        fi
        bastille verify "${BASTILLE_TEMPLATE}"
    else 
        error_exit "[ERROR]: ${BASTILLE_TEMPLATE} not found. See 'bastille bootstrap'."
    fi
}

templates_update() {

    # Update all templates
    _updated_templates=0
    if [ -d  ${bastille_templatesdir} ]; then
        # shellcheck disable=SC2045
        for _template_path in $(ls -d ${bastille_templatesdir}/*/*); do
            if [ -d $_template_path/.git ]; then
                BASTILLE_TEMPLATE=$(echo "$_template_path" | awk -F / '{ print $(NF-1) "/" $NF }')
                template_update

                _updated_templates=$((_updated_templates+1))
            fi
        done
    fi

    if [ "$_updated_templates" -ne "0" ]; then
        info "\n$_updated_templates templates updated."
    else 
        error_exit "[ERROR]: No templates found. See 'bastille bootstrap'."
    fi
}

# Check what we should update
if [ "${TARGET}" = 'TEMPLATES' ]; then
    templates_update
elif echo "${TARGET}" | grep -Eq '^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$'; then
    BASTILLE_TEMPLATE="${TARGET}"
    template_update
elif echo "${TARGET}" | grep -q "[0-9]\{2\}.[0-9]-RELEASE"; then
    arch_check
    release_update
else
    jail_check
    jail_update "${TARGET}"
fi