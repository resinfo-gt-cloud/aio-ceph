#############################################################################
#
# PROVISIONER SECTION **silently** executed as root
#
#############################################################################
LIMA0_IP="$(
    ip -4 -j address show lima0 \
  | jq --raw-output '.[]|.addr_info|.[]|.local'
)"

hostnamectl set-hostname "${HOST_NAME}"
echo '192.168.64.1 lima.localnet' >> /etc/hosts
echo "${LIMA0_IP} self.localnet" >> /etc/hosts

curl -Ssf https://pkgx.sh | sh

useradd -s /bin/bash -d "${USER_HOME}" -m "${USER_NAME}"
chmod +x ${USER_HOME}
echo "${USER_NAME} ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/user
cd "${USER_HOME}"

cat > /tmp/environment.bash <<EOF
set -a
CEPH_RELEASE_NAME=${CEPH_RELEASE_NAME}
DATA_DISKS_COUNT=${DATA_DISKS_COUNT}
CEPHADM_RELEASE=${CEPH_RELEASE_VERSION}
CEPHADM_INSTALLER_PATH=/tmp/cephadm-installer
#
# ceph osd stat | cut -d' ' -f 3
#
FIELD_OSD_UP=3
set +a
EOF

#############################################################################
#
# PROVISIONER SCRIPT executable as $USER
#
#############################################################################
cat > /tmp/provisioner.bash <<'PROVISIONER'

sudo bash <<-'AS_ROOT'
    set -e
    set -x
    source /tmp/environment.bash
    

    apt update && apt -y install net-tools

    pkgx +ceph.com/cephadm^${CEPHADM_RELEASE} +bash^5 bash <<-CEPHADM
        cephadm add-repo --release ${CEPH_RELEASE_NAME}
        cephadm install
        cephadm install ceph-common
CEPHADM

    ceph -v
    mkdir -p /etc/ceph
    cephadm bootstrap \
            --mon-ip 192.168.5.15 \
            --initial-dashboard-user admin \
            --initial-dashboard-password poiuyt \
            --single-host-defaults \
            --dashboard-password-noupdate

    ceph orch ps
    ceph -s
    lsblk
    ceph orch device ls
    ceph orch apply osd --all-available-devices
    OSD_UP_COUNT=0
    while [ ${OSD_UP_COUNT} -ne ${DATA_DISKS_COUNT} ]; do
        ceph osd df
        #echo 'waiting for all OSD to be up'
        sleep 10
        OSD_UP_COUNT=$(ceph osd stat | cut -d' ' -f${FIELD_OSD_UP})
    done
    ceph osd df
    ceph osd tree

    ceph osd pool create openstack-rbd
    rbd pool init openstack-rbd
    ceph auth get-or-create client.openstack-rbd \
              mon 'profile rbd' \
              osd 'profile rbd pool=openstack-rbd' \
              mgr 'profile rbd pool=openstack-rbd' \
              --format json \
              --out-file /opt/credential.json

    ceph mon dump \
             --format json \
             --out-file /opt/mon_dump.json
AS_ROOT
PROVISIONER
