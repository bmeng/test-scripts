#!/bin/bash

function update_packages() {
    ssh $MASTER_IP "yum update -y && systemctl restart atomic-openshift-master"
    ssh $NODE_IP_1 "yum update -y && systemctl restart atomic-openshift-node"
    ssh $NODE_IP_2 "yum update -y && systemctl restart atomic-openshift-node"
}

function sync_images() {
    ssh bmeng@$LOCAL_REGISTRY sync_images $IMAGE_VERSION
    ssh root@$NODE_IP_1 /root/sync_images.sh $IMAGE_VERSION
    ssh root@$NODE_IP_2 /root/sync_images.sh $IMAGE_VERSION
}

function get_ocp_version(){
    IMAGE_VERSION=`ssh root@$MASTER_IP "oc version | grep oc | cut -d' ' -f 2"`
}

update_packages
get_ocp_version
sync_images
