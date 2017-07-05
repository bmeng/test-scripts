#!/bin/bash
set -x 
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

function check_ip() {
    #check ip
    ping -c1 $EGRESS_IP
    if [ $? -ne 1 ]
        then
        echo "EGRESS IP is being used"
        exit 1
    fi
}

function prepare_user() {
    #copy admin kubeconfig
    scp root@$MASTER_IP:/etc/origin/master/admin.kubeconfig ./
    if [ $? -ne 0 ]
        then
        echo "Failed to copy admin kubeconfig"
        exit 1
    fi
    
    # login to server
    oc login https://$MASTER_IP:8443 -u bmeng -p redhat --insecure-skip-tls-verify=false
    if [ $? -ne 0 ]
        then
        echo "Failed to login"
        exit 1
    fi
    
    oc delete project $PROJECT
    until [ `oc get project | grep $PROJECT | wc -l` -eq 0 ]
    do 
        echo "Waiting for project to be deleted on server"
        sleep 5
    done
    
    # create project
    oc new-project $PROJECT
    if [ $? -ne 0 ]
        then
        echo "Failed to create project"
        exit 1
    fi
    
    #add privileged scc to user
    oadm policy add-scc-to-user privileged system:serviceaccount:$PROJECT:default --config admin.kubeconfig
    if [ $? -ne 0 ]
        then
        echo "Failed to grant privileged permission"
        exit 1
    fi
}

function create_legacy_egress_router() {
    #create egress router pod with svc
    curl -s https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egress-ingress/egress-router/legacy-egress-router-list.json | sed "s#egress-router-image#$EGRESS_ROUTER_IMAGE#g;s#egress_ip#$EGRESS_IP#g;s#egress_gw#$EGRESS_GATEWAY#g;s#egress_dest#$EGRESS_DEST_EXT#g" | oc create -f - -n $PROJECT
}

function wait_for_pod_running() {
    local POD=$1
    TRY=20
    COUNT=0
    while [ $COUNT -lt $TRY ]; do
        if [ `oc get po -n $PROJECT | grep $POD | grep Running | wc -l` -eq 1 ]; then
                break
        fi
        sleep 10
        let COUNT=$COUNT+1
    done
    if [ $COUNT -eq 20 ]
        then
        echo "Pod creation failed"
        exit 1
    fi
}

function create_init_egress_router() {
    local DEST=$1
    curl -s https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egress-ingress/egress-router/egress-router-init-container.json | sed "s#openshift3/ose-egress-router#$EGRESS_ROUTER_IMAGE#g;s#egress_ip#$EGRESS_IP#g;s#egress_gw#$EGRESS_GATEWAY#g;s#egress_dest#$DEST#g" | oc create -f - -n $PROJECT
}

function get_router_info() {
    EGRESS_SVC=`oc get svc egress-svc --template={{.spec.clusterIP}}`
    EGRESS_NODE=`oc get po -l name=egress-router -o wide | grep Running | awk -F' ' '{print $7}'`
}

function test_old_scenarios() {
    #access the router
    oc exec hello-pod -- curl -sSL $EGRESS_SVC:80
    if [ $? -ne 0 ]
        then
        echo "Failed to access remote server"
        exit 1
    fi
    
    while [ `oc get po -l name=egress-router -o wide | grep Running | awk -F' ' '{print $7}'` = $EGRESS_NODE ]
    do
        oc delete po -l name=egress-router
        sleep 20
    done
    
    wait_for_pod_running egress
    
    oc exec hello-pod -- curl -sSL $EGRESS_SVC:80
    if [ $? -ne 0 ]
        then
        echo "Failed to access remote server"
        exit 1
    fi
    
    #connect the node via the egress ip
    telnet $EGRESS_IP 22 || true
}

function test_init_container(){
    oc exec hello-pod -- bash -c "(echo UDP_TEST `date`) | ncat -u $EGRESS_SVC 7777"
    echo
    echo
    echo
    ssh bmeng@fedorabmeng.usersys.redhat.com "sudo docker logs ncat-udp"
    
    oc exec hello-pod -- curl -sL $EGRESS_SVC:2015
    if [ $? -ne 0 ]
        then
        echo "Failed to access remote server"
        exit 1
    fi
    
    oc exec hello-pod -- curl -sL $EGRESS_SVC
    if [ $? -ne 0 ]
        then
        echo "Failed to access remote server"
        exit 1
    fi
}

function test_configmap(){
    oc exec hello-pod -- bash -c "(echo UDP_TEST `date`) | ncat -u $EGRESS_SVC 9999"
    echo
    echo
    echo
    ssh bmeng@fedorabmeng.usersys.redhat.com "sudo docker logs ncat-udp"
    
    oc exec hello-pod -- curl -sL $EGRESS_SVC:8888
    if [ $? -ne 0 ]
        then
        echo "Failed to access remote server"
        exit 1
    fi
    
    oc exec hello-pod -- curl -sL $EGRESS_SVC
    if [ $? -ne 0 ]
        then
        echo "Failed to access remote server"
        exit 1
    fi
}

function create_with_configmap() {
    cat << EOF > egress-dest.txt
    # Redirect connection to udp port 9999 to destination IP udp port 9999
    9999 udp $LOCAL_SERVER
    
    # Redirect connection to tcp port 8888 to detination IP tcp port 2015
    8888 tcp 198.12.70.53 2015
    
    # Fallback IP
    61.135.218.24
EOF

    oc create configmap egress-routes --from-file=destination=egress-dest.txt

    curl -s https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egress-ingress/egress-router/egress-router-configmap.json | sed "s#openshift3/ose-egress-router#$EGRESS_ROUTER_IMAGE#g;s#egress_ip#$EGRESS_IP#g;s#egress_gw#$EGRESS_GATEWAY#g" | oc create -f - -n $PROJECT
}

function clean_up(){
    oc delete all --all -n $PROJECT ; sleep 20
}

if [ -z $IMAGE_VERSION ]
    then
    IMAGE_VERSION=v`curl -s http://download-node-02.eng.bos.redhat.com/rcm-guest/puddles/RHAOS/AtomicOpenShift/3.6/latest/x86_64/os/Packages/ | grep -oE 'atomic-openshift-3.[0-9].[0-9]{2,3}' | grep -oE '3.[0-9].[0-9]{2,3}' | uniq`
    sync_images
    update_packages
fi

EGRESS_DEST_EXT=61.135.218.25
PROJECT=egressproject
EGRESS_ROUTER_IMAGE="openshift3/ose-egress-router:$IMAGE_VERSION"
LOCAL_SERVER=`ping fedorabmeng.usersys.redhat.com -c1  | grep ttl | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'`

    prepare_user
    check_ip

if [ $TEST_OLD_SCENARIOS = true ]
then
    create_legacy_egress_router
    wait_for_pod_running egress
    get_router_info
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/pod-for-ping.json
    wait_for_pod_running hello-pod
    test_old_scenarios
    clean_up
fi

if [ $TEST_CONFIGMAP = true ]
then
    create_with_configmap
    wait_for_pod_running egress
    get_router_info
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/pod-for-ping.json
    wait_for_pod_running hello-pod
    test_configmap
    clean_up
fi

if [ $TEST_FALLBACK = true ]
then
    create_init_egress_router "2015 tcp 198.12.70.53\\n7777 udp $LOCAL_SERVER 9999\\n61.135.218.24"
    wait_for_pod_running egress
    get_router_info
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/pod-for-ping.json
    wait_for_pod_running hello-pod
    test_init_container
    clean_up
fi

# clean all in the ned
oc delete project $PROJECT

set +x
