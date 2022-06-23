#!/usr/bin/env bash

# https://gist.github.com/mohanpedala/1e2ff5661761d3abd0385e8223e16425#file-bash_strict_mode-md
set -euxo pipefail

#####
# Script arguments
#####
slurm_version="$1"
slurm_jwt_key="$2"
# GitHub release tag for UQLE CLI tool
cli_tag="$3"
# GitHub OAuth token - should have read access to UQLE CLI releases, and the UQLE stack repository
machine_user_token="$4"


# global variables
jwt_key_dir=/var/spool/slurm.state
jwt_key_file=$jwt_key_dir/jwt_hs256.key
uqle_api_host="http://10.0.0.18:2323"
slurmdbd_user="slurm"
slurmdbd_password="password"

function modify_slurm_conf() {
    # add JWT auth and accounting config to slurm.conf
    cat >> /opt/slurm/etc/slurm.conf <<EOF
# Enable jwt auth for Slurmrestd
AuthAltTypes=auth/jwt

# ACCOUNTING
JobAcctGatherType=jobacct_gather/linux
AccountingStorageType=accounting_storage/slurmdbd
EOF

}

function install_head_node_dependencies() {
    yum -y update

    # MariaDB repository setup
    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --os-type=rhel --os-version=7 --skip-maxscale --skip-tools

    yum -y clean all

    yum -y install -y epel-release
    yum-config-manager -y --enable epel
    # Slurm build deps
    yum -y install libyaml-devel libjwt-devel http-parser-devel json-c-devel
    # Pyenv build deps
    yum -y install gcc zlib-devel bzip2 bzip2-devel readline-devel sqlite sqlite-devel openssl-devel tk-devel libffi-devel xz-devel
    # mariadb
    yum -y install MariaDB-server
    # docker
    yum -y install docker containerd
    # Install go-task, see https://taskfile.dev/install.sh
    sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin

    # cleanup
    yum -y clean all
    rm -rf /var/cache/yum
}

function configure_slurm_database() {
    systemctl enable mariadb.service
    systemctl start mariadb.service

    mysql --wait -e "CREATE USER '${slurmdbd_user}'@'localhost' identified by '${slurmdbd_password}'"
    mysql --wait -e "GRANT ALL ON *.* to '${slurmdbd_user}'@'localhost' identified by '${slurmdbd_password}' with GRANT option"
}

function configure_docker() {
    # Install compose and enable docker service

    local DOCKER_PLUGINS=/usr/local/lib/docker/cli-plugins
    local COMPOSE_BINARY_URL=https://github.com/docker/compose/releases/download/v2.6.0/docker-compose-linux-x86_64

    # Install docker-compose and make accessible as a cli plugin and a standalone command
    mkdir -p ${DOCKER_PLUGINS}
    curl -SL ${COMPOSE_BINARY_URL} -o ${DOCKER_PLUGINS}/docker-compose
    chmod +x ${DOCKER_PLUGINS}/docker-compose
    sudo ln -s ${DOCKER_PLUGINS}/docker-compose /usr/local/bin/docker-compose

    systemctl enable docker.service
    systemctl start docker.service
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

    wget https://download.schedmd.com/slurm/slurm-${slurm_version}.tar.bz2
    tar xjf slurm-${slurm_version}.tar.bz2
    pushd slurm-${slurm_version}


    CORES=$(grep processor /proc/cpuinfo | wc -l)

    # configure and build slurm
    ./configure --prefix=/opt/slurm --with-pmix=/opt/pmix --enable-slurmrestd
    make -j $CORES
    make install
    make install-contrib
    deactivate

    popd && rm -rf slurm-${slurm_version} .venv
}

function write_jwt_key_file() {
    # set the jwt key
    if [ ${slurm_jwt_key} ]
    then
        echo "- JWT secret variable found, writing..."

        mkdir -p $jwt_key_dir

        echo -n ${slurm_jwt_key} > ${jwt_key_file}
    else
        echo "Error: JWT key not present in environment - aborting cluster deployment" >&2
        return 1
    fi

    chown slurm:slurm $jwt_key_file
    chmod 0600 $jwt_key_file
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
    # create the slurmdbd.conf file
    cat > /opt/slurm/etc/slurmdbd.conf <<EOF
AuthType=auth/munge
DbdHost=localhost
DebugLevel=info
SlurmUser=slurm
LogFile=/var/log/slurmdbd.log
StorageType=accounting_storage/mysql
StorageUser=${slurmdbd_user}
StoragePass=${slurmdbd_password}
StorageHost=localhost
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=${jwt_key_file}
EOF

    chown slurm:slurm /opt/slurm/etc/slurmdbd.conf
    chmod 600 /opt/slurm/etc/slurmdbd.conf
}

function create_slurmrest_service() {
    useradd --system --no-create-home -c "slurm rest daemon user" slurmrestd

    cat >/etc/systemd/system/slurmrestd.service<<EOF
[Unit]
Description=Slurm restd daemon
After=network.target slurmctld.service
Requires=slurmctld.service
ConditionPathExists=/opt/slurm/etc/slurmrestd.conf

[Service]
Environment=SLURM_CONF=/opt/slurm/etc/slurmrestd.conf
ExecStart=/opt/slurm/sbin/slurmrestd -a rest_auth/jwt -s openapi/v0.0.37 -u slurmrestd -g slurmrestd -vvvv 0.0.0.0:8082

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
    systemctl enable slurmrestd.service slurmdbd.service
    systemctl start slurmrestd.service slurmdbd.service slurmctld.service
}

function install_and_run_gitlab_runner() {
    # Clone UQLE repo and spin up compose service for gitlab runner
    pushd /tmp
    git clone -b dev --depth 1 https://${machine_user_token}@github.com/Perpetual-Labs/uqle.git ./uqle
    pushd uqle

    docker network create uqle_network
    UQLE_CLI_TAG=${cli_tag} UQLE_CLI_TOKEN=${machine_user_token} UQLE_API_HOST=${uqle_api_host} docker-compose --file ./docker-compose-gitlab-runner.yml up --detach --build

}

function head_node_action() {
    echo "Running head node boot action"

    systemctl stop slurmctld.service

    install_head_node_dependencies

    configure_slurm_database

    rebuild_slurm

    write_jwt_key_file

    modify_slurm_conf

    create_slurmrest_conf

    create_slurmdb_conf

    create_slurmrest_service

    create_slurmdb_service

    reload_and_enable_services

    chown slurm:slurm /shared

    configure_docker

    install_and_run_gitlab_runner

}

function compute_node_action() {
    echo "Running compute node boot action"
    systemctl stop slurmd.service

    modify_slurm_conf

    systemctl start slurmd.service
}


. "/etc/parallelcluster/cfnconfig"

echo "Node type: ${cfn_node_type}"

if [[ "${cfn_node_type}" == "HeadNode" ]]; then
    head_node_action
elif [[ "${cfn_node_type}" == "ComputeFleet" ]]; then
    compute_node_action
fi
