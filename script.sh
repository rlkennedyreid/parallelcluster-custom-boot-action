#!/usr/bin/env bash

# https://gist.github.com/mohanpedala/1e2ff5661761d3abd0385e8223e16425#file-bash_strict_mode-md
set -euxo pipefail

. "/etc/parallelcluster/cfnconfig"

if [[ "${cfn_node_type}" != "HeadNode" ]]; then
  echo "ERROR: Node type is not HeadNode. Node type: ${cfn_node_type}"
  exit 1
fi

#####
# Script arguments
#####
slurm_version="$1"
slurm_jwt_key="$2"

yum update -y

rm /var/spool/slurm.state/*

#####
#install pre-requisites
#####
yum install -y epel-release
yum-config-manager --enable epel
# Slurm build deps
yum install -y libyaml-devel libjwt-devel http-parser-devel json-c-devel
# Pyenv build deps
yum install -y gcc zlib-devel bzip2 bzip2-devel readline-devel sqlite sqlite-devel openssl-devel tk-devel libffi-devel xz-devel
yum clean all
rm -rf /var/cache/yum

#####
# Update slurm, with slurmrestd
#####

# Python3 is requred to build slurm >= 20.02,
export PYENV_ROOT=/opt/parallelcluster/pyenv
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init --path)"
pyenv install -s 3.7.13

pushd /shared

$PYENV_ROOT/versions/3.7.13/bin/python -m venv --upgrade-deps .venv

. .venv/bin/activate


# have to use the exact same slurm version as in the released version of ParallelCluster2.10.1 - 20.02.4
# as of May 13, 20.02.4 was removed from schedmd and was replaced with .7
# error could be seen in the cfn-init.log file
# changelog: change to 20.11.7 from 20.02.7 on 2021/09/03 - pcluster 2.11.2
# changelog: change to 20.11.8 from 20.11.7 on 2021/09/16 - pcluster 3
# slurm_version=20.11.8
wget https://download.schedmd.com/slurm/slurm-${slurm_version}.tar.bz2
tar xjf slurm-${slurm_version}.tar.bz2
pushd slurm-${slurm_version}


CORES=$(grep processor /proc/cpuinfo | wc -l)
# config and build slurm
./configure --prefix=/opt/slurm --with-pmix=/opt/pmix --enable-slurmrestd
make -j $CORES
make install
make install-contrib
deactivate

popd && rm -rf slurm-${slurm_version} .venv


# set the jwt key
if [ ${slurm_jwt_key} ]
then
    echo "- JWT secret variable found, writing..."

    jwt_key_dir=/var/spool/slurm.state
    jwt_key_file=$jwt_key_dir/jwt_hs256.key
    mkdir -p $jwt_key_dir

    echo -n ${slurm_jwt_key} > ${jwt_key_file}
else
    echo "Error: JWT key not present in environment - aborting cluster deployment" >&2
    exit 1
fi

chown slurm:slurm $jwt_key_file
chmod 0600 $jwt_key_file

# add 'AuthAltTypes=auth/jwt' to slurm.conf
cat >> /opt/slurm/etc/slurm.conf <<EOF
# Enable jwt auth for Slurmrestd
AuthAltTypes=auth/jwt
EOF

# create the slurmrestd.conf file
cat >/opt/slurm/etc/slurmrestd.conf<<EOF
include /opt/slurm/etc/slurm.conf
AuthType=auth/jwt
EOF


#####
# Enable slurmrestd to run as a service
# ExecStart=/opt/slurm/sbin/slurmrestd -vvvv 0.0.0.0:8082 -a jwt -u slurm
# slurm20.02.4 version doesn't support -a command line option.
#
#####
cat >/etc/systemd/system/slurmrestd.service<<EOF
[Unit]
Description=Slurm restd daemon
After=network.target slurmctl.service
ConditionPathExists=/opt/slurm/etc/slurmrestd.conf

[Service]
Environment=SLURM_CONF=/opt/slurm/etc/slurmrestd.conf
ExecStart=/opt/slurm/sbin/slurmrestd -vvvv 0.0.0.0:8082 -u slurm
PIDFile=/var/run/slurmrestd.pid

[Install]
WantedBy=multi-user.target
EOF


##### restart the daemon and start the slurmrestd
systemctl daemon-reload
systemctl start slurmrestd
systemctl restart slurmctld


#####
# we will be using /shared/tmp for running our program nad store the output files.
#####
mkdir -p /shared/tmp
chown slurm:slurm /shared/tmp