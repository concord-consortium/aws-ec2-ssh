#!/bin/bash

if [ `id -u 2>/dev/null` != 0 ]; then
    echo "You must be root to run this script."
    exit 1
fi

show_help() {
cat << EOF
Usage: ${0##*/} [-hv] [-a ARN] [-i GROUP,GROUP,...] [-l GROUP,GROUP,...] [-s GROUP] [-p PROGRAM] [-u "ARGUMENTS"]
Install import_users.sh and authorized_key_commands.

    -h                 display this help and exit
    -v                 verbose mode.
    -f                 Force installation without specifying groups.

    -a arn             Assume a role before contacting AWS IAM to get users and keys.
                       This can be used if you define your users in one AWS account, while the EC2
                       instance you use this script runs in another.
    -i group,group     Which IAM groups have access to this instance
                       Comma seperated list of IAM groups. Leave empty for all available IAM users
    -l group,group     Give the users these local UNIX groups
                       Comma seperated list
    -s group,group     Specify IAM group(s) for users who should be given sudo privileges, or leave
                       empty to not change sudo access, or give it the value '##ALL##' to have all
                       users be given sudo rights.
                       Comma seperated list
    -p program         Specify your useradd program to use.
                       Defaults to '/usr/sbin/useradd'
    -u "useradd args"  Specify arguments to use with useradd.
                       Defaults to '--create-home --shell /bin/bash'


EOF
}

#
# By default we install on Ubuntu 16
#
DISTRO=16
grep DISTRIB_RELEASE=14 /etc/lsb-release
if [ "$?" == 0 ]; then
    DISTRO=14
fi

#
# Set service name depending on distro.
#
SERVICE=sshd
if [ "$DISTRO" == "14" ]; then
    SERVICE=ssh
fi


IAM_GROUPS=""
SUDO_GROUPS=""
LOCAL_GROUPS=""
ASSUME_ROLE=""
USERADD_PROGRAM=""
USERADD_ARGS=""

FORCE=0

while getopts :hvfa:i:l:s: opt
do
    case $opt in
        h)
            show_help
            exit 0
            ;;
        i)
            IAM_GROUPS="$OPTARG"
            ;;
        s)
            SUDO_GROUPS="$OPTARG"
            ;;
        l)
            LOCAL_GROUPS="$OPTARG"
            ;;
        v)
            set -x
            ;;
        f)
            FORCE=1
            ;;
        a)
            ASSUME_ROLE="$OPTARG"
            ;;
        p)
            USERADD_PROGRAM="$OPTARG"
            ;;
        u)
            USERADD_ARGS="$OPTARG"
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            show_help
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            show_help
            exit 1
    esac
done

#
# Check that groups are passed. Require forceful install
# if no IAM or SUDO groups are specified.
#
if [ "${IAM_GROUPS}" == "" -o "${SUDO_GROUPS}" == "" ]; then
    if [ $FORCE == 0 ]; then
        echo "No IAM group(s) or SUDO group(s) specified."
        echo "Use -f to force installation without specifying groups."
        exit 1
    fi
fi

#
# Copy scripts to /opt
#
echo "Installing scripts... "

cp authorized_keys_command.sh /opt/authorized_keys_command.sh
cp import_users.sh /opt/import_users.sh

#
# Create config file
#
echo "Creating new aws-ec2-ssh.conf file... "

CONFIG_FILE=/etc/aws-ec2-ssh.conf
rm $CONFIG_FILE

if [ "${IAM_GROUPS}" != "" ]
then
    echo "IAM_AUTHORIZED_GROUPS=\"${IAM_GROUPS}\"" >> /etc/aws-ec2-ssh.conf
fi

if [ "${SUDO_GROUPS}" != "" ]
then
    echo "SUDOERS_GROUPS=\"${SUDO_GROUPS}\"" >> /etc/aws-ec2-ssh.conf
fi

if [ "${LOCAL_GROUPS}" != "" ]
then
    echo "LOCAL_GROUPS=\"${LOCAL_GROUPS}\"" >> /etc/aws-ec2-ssh.conf
fi

if [ "${ASSUME_ROLE}" != "" ]
then
    echo "ASSUMEROLE=\"${ASSUME_ROLE}\"" >> /etc/aws-ec2-ssh.conf
fi

if [ "${USERADD_PROGRAM}" != "" ]
then
    echo "USERADD_PROGRAM=\"${USERADD_PROGRAM}\"" >> /etc/aws-ec2-ssh.conf
fi

if [ "${USERADD_ARGS}" != "" ]
then
    echo "USERADD_ARGS=\"${USERADD_ARGS}\"" >> /etc/aws-ec2-ssh.conf
fi

#
# Update sshd config
#
echo "Updating sshd_config... "

sed -i 's:#AuthorizedKeysCommand none:AuthorizedKeysCommand /opt/authorized_keys_command.sh:g' /etc/ssh/sshd_config
sed -i 's:#AuthorizedKeysCommandUser nobody:AuthorizedKeysCommandUser nobody:g' /etc/ssh/sshd_config

#
# Handle cases where the commented out configs are not present
#
add_config() {
    name=$1
    value=$2

    grep "^$1 $2" /etc/ssh/sshd_config >/dev/null 2>&1

    if [ $? != 0 ]; then
    echo "$1 $2" >> /etc/ssh/sshd_config
    fi
}

add_config AuthorizedKeysCommand /opt/authorized_keys_command.sh
add_config AuthorizedKeysCommandUser nobody

#
# Install AWS CLI
#
echo "Installing AWS CLI... "

#
# For Ubuntu 16, the aws cli in the repo has all the features we need.
#
if [ "$DISTRO" == "16" ]; then
    apt-get update
    apt-get install -y awscli
fi

#
# For Ubuntu 14 we need features not available in the aws cli from 
# ubuntu the repo. Install from pip instead. 
# This only installs locally to the user
# so require the "ubuntu" user has ~/.local accessible and then
# symlink to that. We require user "nobody" be able to run this command. 
#
if [ "$DISTRO" == "14" ]; then
    if [ -f "/usr/bin/aws" ]; then
        rm /usr/bin/aws
    fi
    sudo apt-get install -y curl unzip
    curl "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o "awscli-bundle.zip"
    unzip -o awscli-bundle.zip
    ./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws 
fi

#
# Add cron job
#
echo "Adding cron job... "

cat > /etc/cron.d/import_users << EOF
SHELL=/bin/bash
PATH=/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/opt/aws/bin
MAILTO=root
HOME=/
*/10 * * * * root /opt/import_users.sh
EOF
chmod 0644 /etc/cron.d/import_users

#
# Import users
#
echo "Importing users... "

/opt/import_users.sh

#
# Restart sshd service
#
echo "Restarting sshd service... "

service $SERVICE restart

