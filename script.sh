#!/usr/bin/env bash

# https://gist.github.com/mohanpedala/1e2ff5661761d3abd0385e8223e16425#file-bash_strict_mode-md
set -euxo pipefail

#####
# Script arguments
#####
SLURM_VERSION="$1"
SLURM_JWT_KEY="$2"
# GitHub release tag for UQLE CLI tool
CLI_TAG="$3"
# GitHub OAuth token - should have read access to UQLE CLI releases, and the UQLE stack repository
MACHINE_USER_TOKEN="$4"
UQLE_API_HOST="$5"


# global variables
JWT_KEY_DIR=/var/spool/slurm.state
JWT_KEY_FILE=$JWT_KEY_DIR/jwt_hs256.key
SLURMDBD_USER="slurm"
SLURM_PASSWORD_FILE=/root/slurmdb.password

. /etc/parallelcluster/cfnconfig

echo "Node type: ${cfn_node_type}"

function configure_yum() {
    cat >> /etc/yum.conf <<EOF
assumeyes=1
clean_requirements_on_remove=1
EOF
}

function modify_slurm_conf() {
    # add JWT auth and accounting config to slurm.conf
    # /opt/slurm is shared via nfs, so this only needs to be configured on head node

    cat >> /opt/slurm/etc/slurm.conf <<EOF
# Enable jwt auth for Slurmrestd
AuthAltTypes=auth/jwt
# ACCOUNTING
JobAcctGatherType=jobacct_gather/linux
AccountingStorageType=accounting_storage/slurmdbd
EOF
}


function yum_cleanup() {
    yum -q clean all
    rm -rf /var/cache/yum
}

function install_head_node_dependencies() {
    # MariaDB repository setup
    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash

    yum_cleanup

    yum -q update

    yum -q install epel-release
    yum-config-manager -y --enable epel
    # Slurm build deps
    yum -q install libyaml-devel libjwt-devel http-parser-devel json-c-devel
    # Pyenv build deps
    yum -q install gcc zlib-devel bzip2 bzip2-devel readline-devel sqlite sqlite-devel openssl-devel tk-devel libffi-devel xz-devel
    # mariadb
    yum -q install MariaDB-server
    # podman
    yum -q install fuse-overlayfs slirp4netns podman

    # Install go-task, see https://taskfile.dev/install.sh
    sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin

    yum_cleanup
}

function install_compute_node_dependencies() {
    yum_cleanup

    yum -q update

    yum -q install podman

    yum_cleanup
}
function create_and_save_slurmdb_password() {
    if [[ -e "$SLURM_PASSWORD_FILE" ]]; then
        echo "Error: create_and_save_slurmdb_password() was called when a password file already exists" >&2
        return 1
    fi

    echo -n $(pwmake 128) > $SLURM_PASSWORD_FILE
}

function configure_slurm_database() {

    systemctl enable mariadb.service
    systemctl start mariadb.service

    create_and_save_slurmdb_password

    local slurmdbd_password=$(cat "${SLURM_PASSWORD_FILE}")

    mysql --wait -e "CREATE USER '${SLURMDBD_USER}'@'localhost' identified by '${slurmdbd_password}'"
    mysql --wait -e "GRANT ALL ON *.* to '${SLURMDBD_USER}'@'localhost' identified by '${slurmdbd_password}' with GRANT option"
}


function configure_users() {

    sysctl user.max_user_namespaces=15000
    usermod --add-subuids 165536-231071 --add-subgids 165536-231071 slurm

    cat << 'EOF' | tee -a /home/centos/.bashrc /home/slurm/.bashrc
# Set variables to avoid podman conflicts between nodes due to nfs-sharing of /home
# See basedir-spec at https://specifications.freedesktop.org/

if [ -z "$XDG_RUNTIME_DIR" ]; then
    XDG_RUNTIME_DIR=/run/user/$(id -u)  # Try systemd default path

    # If this default doesn't exist, create a temporary directory
    if [ ! -d "$XDG_RUNTIME_DIR" ]; then
        XDG_RUNTIME_DIR=$(mktemp -d /tmp/$(id -u)-runtime-XXXXXXXXXX)
    fi

fi

export XDG_RUNTIME_DIR
export XDG_DATA_HOME=$XDG_RUNTIME_DIR/.local/share
export XDG_STATE_HOME=$XDG_RUNTIME_DIR/.state
export XDG_CACHE_HOME=$XDG_RUNTIME_DIR/.cache

# Config files can remain common to all nodes
export XDG_CONFIG_HOME=$HOME/.config

EOF
}

function rebuild_slurm() {
    # rebuild slurm with slurmrest daemon enabled

    # Python3 is requred to build slurm >= 20.02,
    export PYENV_ROOT=/opt/parallelcluster/pyenv
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init --path)"
    pyenv install -s 3.7.13

    pushd /shared

    $PYENV_ROOT/versions/3.7.13/bin/python -m venv .venv

    . .venv/bin/activate

    wget https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2
    tar xjf slurm-${SLURM_VERSION}.tar.bz2
    pushd slurm-${SLURM_VERSION}

    # configure and build slurm
    ./configure --silent --prefix=/opt/slurm --with-pmix=/opt/pmix --enable-slurmrestd
    make -s -j
    make -s install
    make -s install-contrib

    deactivate

    popd && rm -rf "slurm-${SLURM_VERSION}" .venv
}

function write_jwt_key_file() {
    # set the jwt key
    if [ ${SLURM_JWT_KEY} ]
    then
        echo "- JWT secret variable found, writing..."

        mkdir -p $JWT_KEY_DIR

        echo -n ${SLURM_JWT_KEY} > ${JWT_KEY_FILE}
    else
        echo "Error: JWT key not present in environment - aborting cluster deployment" >&2
        return 1
    fi

    chown slurm:slurm $JWT_KEY_FILE
    chmod 0600 $JWT_KEY_FILE
}

function create_slurmrest_conf() {
    # create the slurmrestd.conf file
    # this file can be owned by root, because the slurmrestd service is run by root
    cat > /opt/slurm/etc/slurmrestd.conf <<EOF
include /opt/slurm/etc/slurm.conf
AuthType=auth/jwt
EOF

}

function create_slurmdb_conf() {
    local slurmdbd_password=$(cat "${SLURM_PASSWORD_FILE}")

    # create the slurmdbd.conf file
    cat > /opt/slurm/etc/slurmdbd.conf <<EOF
AuthType=auth/munge
DbdHost=localhost
DebugLevel=info
SlurmUser=slurm
LogFile=/var/log/slurmdbd.log
StorageType=accounting_storage/mysql
StorageUser=${SLURMDBD_USER}
StoragePass=${slurmdbd_password}
StorageHost=localhost
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=${JWT_KEY_FILE}
EOF

    chown slurm:slurm /opt/slurm/etc/slurmdbd.conf
    chmod 600 /opt/slurm/etc/slurmdbd.conf
}

function create_slurmrest_service() {

    cat >/etc/systemd/system/slurmrestd.service<<EOF
[Unit]
Description=Slurm restd daemon
After=network.target slurmctld.service
Requires=slurmctld.service
ConditionPathExists=/opt/slurm/etc/slurmrestd.conf

[Service]
Environment=SLURM_CONF=/opt/slurm/etc/slurmrestd.conf
ExecStart=/opt/slurm/sbin/slurmrestd -a rest_auth/jwt -s openapi/v0.0.37 -u slurmrestd -g slurmrestd 0.0.0.0:8082

[Install]
WantedBy=multi-user.target
EOF
}

function create_slurmdb_service() {
    cat >/etc/systemd/system/slurmdbd.service<<EOF
[Unit]
Description=Slurm database daemon
After=network.target
Before=slurmctld.service
ConditionPathExists=/opt/slurm/etc/slurmdbd.conf

[Service]
Environment=SLURM_CONF=/opt/slurm/etc/slurmdbd.conf
ExecStart=/opt/slurm/sbin/slurmdbd -D

[Install]
WantedBy=multi-user.target
RequiredBy=slurmctld.service
EOF
}

function reload_and_enable_services() {
    systemctl daemon-reload
    systemctl enable slurmrestd.service slurmdbd.service slurmctld.service
    systemctl start slurmrestd.service slurmdbd.service slurmctld.service
}

function install_and_run_gitlab_runner() {
    # reload shell to load docker context
    exec ${SHELL} --login

    # Clone UQLE repo and spin up compose service for gitlab runner
    pushd /tmp
    git clone -b dev --depth 1 https://${MACHINE_USER_TOKEN}@github.com/Perpetual-Labs/uqle.git ./uqle
    pushd uqle

    docker network create uqle_network
    UQLE_CLI_TAG=${CLI_TAG} UQLE_CLI_TOKEN=${MACHINE_USER_TOKEN} UQLE_API_HOST=${UQLE_API_HOST} docker-compose --file ./docker-compose-gitlab-runner.yml up --detach --build
}


function head_node_action() {
    echo "Running head node boot action"

    systemctl disable slurmctld.service
    systemctl stop slurmctld.service

    configure_users

    configure_yum

    install_head_node_dependencies

    configure_slurm_database

    rebuild_slurm

    write_jwt_key_file

    modify_slurm_conf

    create_slurmrest_conf

    create_slurmdb_conf

    useradd --system --no-create-home -c "slurm rest daemon user" slurmrestd
    create_slurmrest_service

    create_slurmdb_service

    reload_and_enable_services

    chown slurm:slurm /shared

    # install_and_run_gitlab_runner

}

function compute_node_action() {
    echo "Running compute node boot action"
    systemctl disable slurmd.service
    systemctl stop slurmd.service

    configure_users

    configure_yum

    install_compute_node_dependencies

    systemctl enable slurmd.service
    systemctl start slurmd.service
}

if [[ "${cfn_node_type}" == "HeadNode" ]]; then
    head_node_action
elif [[ "${cfn_node_type}" == "ComputeFleet" ]]; then
    compute_node_action
fi
