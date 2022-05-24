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
yum install -y libyaml-devel libjwt-devel http-parser-devel json-c-devel


# cat > /etc/ld.so.conf.d/slurmrestd.conf <<EOF
# /usr/local/lib
# /usr/local/lib64
# EOF

#####
# Update slurm, with slurmrestd
#####

# Python3 is requred to build slurm >= 20.02,
. /opt/parallelcluster/pyenv/versions/cookbook_virtualenv/bin/activate

cd /shared
# have to use the exact same slurm version as in the released version of ParallelCluster2.10.1 - 20.02.4
# as of May 13, 20.02.4 was removed from schedmd and was replaced with .7
# error could be seen in the cfn-init.log file
# changelog: change to 20.11.7 from 20.02.7 on 2021/09/03 - pcluster 2.11.2
# changelog: change to 20.11.8 from 20.11.7 on 2021/09/16 - pcluster 3
# slurm_version=20.11.8
wget https://download.schedmd.com/slurm/slurm-${slurm_version}.tar.bz2
tar xjf slurm-${slurm_version}.tar.bz2
cd slurm-${slurm_version}

CORES=$(grep processor /proc/cpuinfo | wc -l)
# config and build slurm
./configure --prefix=/opt/slurm --with-pmix=/opt/pmix --enable-slurmrestd
make -j $CORES
make install
make install-contrib
deactivate

# set the jwt key

jwt_key_dir=/var/spool/slurm.state
jwt_key_file=$jwt_key_dir/jwt_hs256.key

if [ ${slurm_jwt_key} ]
then
    mkdir -p $jwt_key_dir
    echo "- JWT secret variable found, writing..."
    echo -n ${slurm_jwt_key} > ${jwt_key_file}
else
    echo "Error: JWT key not present in environment - aborting cluster deployment" >&2
    exit 1
fi

chown slurm $jwt_key_file
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
