#!/bin/bash



function getrclonepid() {
    local __pidvar=$1

    pid=$(ps aux | grep rclone | grep ${ONEDIR} | awk '{print $2}')
    [[ -z "pid" ]] && eval ${__pidvar=0} || eval ${__pidvar}=${pid}
}

function mountonedrive() {
    local __onedir=$1
    local __rcloneshare=$2
    local __success=$3

    test -d ${__onedir} || mkdir -p ${__onedir}
    getrclonepid pidnumber
    if [[ ${pidnumber} -eq 0 ]]; then
        rclone --vfs-cache-mode writes mount ${__rcloneshare}: ${__onedir} &
        sleep 2
        getrclonepid pid2
        eval ${__success}=${pid2}
    fi
}

function createtmplv() {
    local __lv=$1
    local __result=$2
    local __duplicitytempdir=$3
    local __create=$4
    local __lvname=$(cut -d '/' -f4 <<<${__lv})
    local __vgname=$(cut -d '/' -f3 <<<${__lv})

    if [[ "${__create}" == 1 ]]; then
        if (! test -b ${__lv}); then
            $LVCRT -y -L5G -n ${__lvname} ${__vgname} &&
                mkfs.ext4 "/dev/${__vgname}/${__lvname}" &&
                mkdir "/tmp/${__duplicitytempdir}" &&
                mount "/dev/${__vgname}/${__lvname}" "/tmp/${__duplicitytempdir}"
            eval ${__result}=1
        else
            eval ${__result}=0
        fi
    else
        if (test -b ${__lv}); then
            umount -fl "/tmp/${__duplicitytempdir}" &&
                rm -r "/tmp/${__duplicitytempdir}" &&
                $LVRM -f ${__lv}
            eval ${__result}=1
        else
            eval ${__result}=0
        fi
    fi

}
function randomstring() {
    local __random=$1
    eval ${__random}=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
}

function savedata() {
    local __lv=$1
    local __result=$2
    local __duplicitytempdir=$3
    local __lvname=$(cut -d '/' -f4 <<<$__lv)
    local __vgname=$(cut -d '/' -f3 <<<$__lv)

    #checking the existance of the lv to save
    if (! test -b ${__lv}); then eval ${__result}=1 && return; fi

    if (test -e ${__lv}-bs); then
        $LVRM ${__lv}-bs
        if [[ "$?" != 0 ]]; then eval ${__result}=2 && return; fi
    fi

    sync
    $LVCRT -s -L ${SNAPSIZE} -n ${__lvname}-bs $__lv
    if [[ "$?" != 0 ]]; then eval ${__result}=3 && return; fi

    #mount the lv to backup point --> needs to unmount
    mount -o acl,user_xattr $__lv-bs ${BACKUPDIR}
    if [[ "$?" != 0 ]]; then eval ${__result}=4 && return; fi

    test -d "${ARCHIVE}/${__lvname}" || mkdir -p "${ARCHIVE}/${__lvname}"
    test -d "${ONEDIR}/backup" || mkdir -p "${ONEDIR}/backup"

    ${NICE} duplicity -v0 --no-print-statistics --tempdir "/tmp/${__duplicitytempdir}" --no-encryption --archive-dir "${ARCHIVE}/${__lvname}" --volsize ${VOLSIZE} --asynchronous-upload --full-if-older-than ${FULL} ${BACKUPDIR} "file://${ONEDIR}/backup/${HOSTNAME}_${__vgname}/${__lvname}/"

    if [[ "$?" != 0 ]]; then
        eval ${__result}=5 && return
    else
        ${NICE} duplicity -v0 remove-all-but-n-full ${KEEP} --archive-dir ${ARCHIVE}/${__lvname} --force "file://${ONEDIR}/backup/${HOSTNAME}_${__vgname}/${__lvname}/"
        if [[ "$?" != 0 ]]; then eval ${__result}=6 && sleep 2 && umount -fl ${BACKUPDIR} && return; fi
    fi

    sleep 2
    umount ${BACKUPDIR}

    $LVRM $__lv-bs
    if [[ "$?" != 0 ]]; then eval ${__result}=7 && return; fi

    eval ${__result}=0
}

#checking input/settings file
if [ -z "$1" ]; then
    echo "You must set the settings file! Aborting!" && exit 1
fi

#set up variables
LVCRT="/sbin/lvcreate"
LVRM="/sbin/lvremove -f"
BACKUPDIR=$(jq -r '.backupdir' $1)
ONEDIR=$(jq -r '.onedir' $1)
ARCHIVE=$(jq -r '.archive' $1)
NICE=$(jq -r '.nice' $1)
LVS=$(jq -r '.lv[]' $1)
SNAPSIZE=$(jq -r '.snapsize' $1)
VOLSIZE=$(jq -r '.volsize' $1)
FULL=$(jq -r '.full' $1)
KEEP=$(jq -r '.keep' $1)
RCLONESHARE=$(jq -r '.rcloneshare' $1)
TEMPLV=$(jq -r '.templv' $1)
export PASSPHRASE=$(jq -r '.password' $1)

#generating temprary directory for duplicity
randomstring duplicitytempdir

#check if duplicity directory exists
test -d ${ARCHIVE} || mkdir -p ${ARCHIVE}

#check if this backup script is still running started previously. In this case it will exit
test -f /run/backup.pid && test -d /proc/$(cat /run/backup.pid) && exit 1

# #register the pid
echo $$ >/run/backup.pid

#lets mount the Microsoft OneDrive share
mountonedrive ${ONEDIR} ${RCLONESHARE} success

if [[ $success == "0" ]]; then
    echo "Could not mount OneDrive. Aborting!" 1>&2
    exit 1
fi

#lets do the saving
test -d ${BACKUPDIR} || mkdir -p ${BACKUPDIR}

##Create tempary lv and dir for duplicity temp directory
createtmplv ${TEMPLV} result ${duplicitytempdir} 1
if [[ $result == 0 ]]; then
    echo "The temporary lvm could not be made. Aborting!" 1>&2
    exit 1
fi

#Saving
for lv in $LVS; do
    savedata $lv result ${duplicitytempdir}
    case ${result} in
    0)
        echo "The ${lv} has just been saved @$(date), hip-hip-hurray!"
        ;;
    1)
        echo "The given lv (${lv}) does not exists, can not be saved!"
        ;;
    2)
        echo "The ${lv} snapshot can not be deleted, saving is NOT possible!"
        ;;
    3)
        echo "Creating ${lv}-bs snapshot was not successfull, saving is NOT possible!"
        ;;
    4)
        echo "Could not mount ${lv} for some reason, this lv can not be saved!"
        ;;
    5)
        echo "Running duplicity command failed on ${lv}!"
        ;;
    6)
        echo "${lv} has been saved successfully, but could not remove the old saves for some reason! It is not a fault yet, but needs to be checked manually!"
        ;;
    7)
        echo "${lv} has been saved successfully, but the snapshot couldn't be deleted! Should be checked as soon as possible!"
        ;;
    esac
done

#Cleaning up
#Removing the temporary directories and lv
createtmplv ${TEMPLV} result ${duplicitytempdir} 0
if [[ $result == 0 ]]; then
    echo "Could not clean up! Please, check ${TEMPLV} logical volume, and fix if needed!" 1>&2
    exit 1
fi

#umounting network storage from the local filesystem
getrclonepid pid
if [[ "${pid}" != 0 ]]; then
    kill ${pid}
fi

#removing the pid file, so next time it can run
rm /run/backup.pid
