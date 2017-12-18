#!/bin/bash
source ./color.sh

function set_proxy() {
    export http_proxy=file.rdu.redhat.com:3128
    export https_proxy=file.rdu.redhat.com:3128
}


function check_ip() {
    #check ip
    echo -e "$BBlue Check if the IP is in-use. $NC"
    ping -c1 $EGRESS_IP
    if [ $? -ne 1 ]
        then
        echo -e "EGRESS IP is being used"
        exit 1
    fi
}

function prepare_user() {
    #copy admin kubeconfig
    scp root@$MASTER_IP:/etc/origin/master/admin.kubeconfig ./
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to copy admin kubeconfig${NC}"
        exit 1
    fi
    
    # login to server
    oc login https://$MASTER_IP:8443 -u bmeng -p redhat --insecure-skip-tls-verify=false
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to login${NC}"
        exit 1
    fi
    
    oc delete project $PROJECT
    echo -e "$BBlue Delete the project if already existed. $NC"
    until [ `oc get project | grep $PROJECT | wc -l` -eq 0 ]
    do 
        echo -e "Waiting for project to be deleted on server"
        sleep 5
    done
    
    sleep 10

    # create project
    oc new-project $PROJECT
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to create project${NC}"
        exit 1
    fi
    
    #add privileged scc to user
    echo -e "$BBlue Add privileged scc to user. $NC"
    oc adm policy add-scc-to-user privileged system:serviceaccount:$PROJECT:default --config admin.kubeconfig
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to grant privileged permission${NC}"
        exit 1
    fi
}

function get_router_info() {
    EGRESS_SVC=`oc get svc egress-svc --template={{.spec.clusterIP}}`
    EGRESS_NODE=`oc get po -l name=egress-router -o wide | grep Running | awk -F' ' '{print $7}'`
}

function wait_for_pod_running() {
    local POD=$1
    local NUM=$2
    TRY=20
    COUNT=0
    while [ $COUNT -lt $TRY ]; do
        if [ `oc get po -n $PROJECT | grep $POD | grep Running | wc -l` -eq $NUM ]; then
                break
        fi
        sleep 10
        let COUNT=$COUNT+1
    done
    if [ $COUNT -eq 20 ]
        then
        echo -e "Pod creation failed"
        exit 1
    fi
}

function create_legacy_egress_router() {
    #create egress router pod with svc
    echo -e "$BBlue Create egress router with legacy mode $NC"
    curl -s https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egress-ingress/egress-router/legacy-egress-router-list.json | sed "s#egress-router-image#$EGRESS_ROUTER_IMAGE#g;s#egress_ip#$EGRESS_IP#g;s#egress_gw#$EGRESS_GATEWAY#g;s#egress_dest#$EGRESS_DEST_EXT#g" | oc create -f - -n $PROJECT
}

function test_old_scenarios() {
    #access the router
    echo -e "$BBlue Access youdao  $NC"
    oc exec hello-pod -- curl -IsSL $EGRESS_SVC:80 | grep youdao.com
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to access remote server${NC}"
        exit 1
    fi
    
    while [ `oc get po -l name=egress-router -o wide | grep Running | awk -F' ' '{print $7}'` = $EGRESS_NODE ]
    do
        oc delete po -l name=egress-router
        sleep 20
    done
    
    wait_for_pod_running egress 1
    
    echo -e "$BBlue Access youdao  $NC"
    oc exec hello-pod -- curl -sSIL $EGRESS_SVC:80 | grep youdao.com
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to access remote server${NC}"
        exit 1
    fi
    
    #connect the node via the egress ip
    echo -e "$BBlue Connect node via egress ip  $NC"
    telnet $EGRESS_IP 22 || true
}

function create_init_egress_router() {
    echo -e "$BBlue Create egress router with initContainer mode $NC"
    local DEST=$1
    curl -s https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egress-ingress/egress-router/egress-router-init-container.json | sed "s#openshift3/ose-egress-router#$EGRESS_ROUTER_IMAGE#g;s#egress_ip#$EGRESS_IP#g;s#egress_gw#$EGRESS_GATEWAY#g;s#egress_dest#$DEST#g" | oc create -f - -n $PROJECT
}

function test_init_container(){
    echo -e "$BBlue Test UDP port 7777 to 9999 $NC"
    oc exec hello-pod -- bash -c "(echo -e UDP_TEST `date`) | ncat -u $EGRESS_SVC 7777"
    ssh bmeng@fedorabmeng.usersys.redhat.com "sudo docker logs ncat-udp"
    
    echo -e "$BBlue Access hello-openshift $NC"
    oc exec hello-pod -- curl -sL $EGRESS_SVC:2015 
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to access remote server${NC}"
        exit 1
    fi
    
    echo -e "$BBlue Access youdao $NC"
    oc exec hello-pod -- curl -sIL $EGRESS_SVC | grep youdao.com
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to access remote server${NC}"
        exit 1
    fi
}

function create_multiple_router_with_nodename() {
    echo -e "$BBlue Create multiple router with single svc on same node $NC"
    local DEST=$1
    local EGRESS_IP_2=10.66.141.252
    curl -s https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egress-ingress/egress-router/egress-router-init-container.json | sed "s#openshift3/ose-egress-router#$EGRESS_ROUTER_IMAGE#g;s#egress_ip#$EGRESS_IP#g;s#egress_gw#$EGRESS_GATEWAY#g;s#egress_dest#$DEST#g" | jq '.items[0].spec.template.spec.nodeName = "ose-node1.bmeng.local"' | jq '.items[0].spec.replicas = 1' | oc create -f - -n $PROJECT
    curl -s https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egress-ingress/egress-router/egress-router-init-container.json | sed "s#openshift3/ose-egress-router#$EGRESS_ROUTER_IMAGE#g;s#egress_ip#$EGRESS_IP_2#g;s#egress_gw#$EGRESS_GATEWAY#g;s#egress_dest#$DEST#g" | jq '.items[0].spec.template.spec.nodeName = "ose-node1.bmeng.local"' | jq '.items[0].spec.replicas = 1' | sed 's/egress-rc/egress-rc-2/g' |  oc create -f - -n $PROJECT
}

function test_router_with_nodename() {
    oc get po -o wide -n $PROJECT

    echo -e "$BBlue Access youdao $NC"
    oc exec hello-pod -- curl -sIL $EGRESS_SVC:80 | grep youdao.com
    echo -e "$BBlue Access youdao $NC"
    oc exec hello-pod -- curl -sIL $EGRESS_SVC:80 | grep youdao.com
    echo -e "$BBlue Access youdao $NC"
    oc exec hello-pod -- curl -sIL $EGRESS_SVC:80 | grep youdao.com
    echo -e "$BBlue Access youdao $NC"
    oc exec hello-pod -- curl -sIL $EGRESS_SVC:80 | grep youdao.com
}

function create_with_configmap() {
    echo -e "$BBlue Create egress router with config map $NC"
    cat << EOF > egress-dest.txt
    # Redirect connection to udp port 9999 to destination IP udp port 9999
    9999 udp $LOCAL_SERVER
    
    # Redirect connection to tcp port 8888 to detination IP tcp port 2015
    8888 tcp 45.62.99.61 2015
    
    # Fallback IP
    61.135.218.24
EOF

    oc create configmap egress-routes --from-file=destination=egress-dest.txt

    curl -s https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egress-ingress/egress-router/egress-router-configmap.json | sed "s#openshift3/ose-egress-router#$EGRESS_ROUTER_IMAGE#g;s#egress_ip#$EGRESS_IP#g;s#egress_gw#$EGRESS_GATEWAY#g" | oc create -f - -n $PROJECT
}

function test_configmap(){
    echo -e "$BBlue UDP Test port 9999 $NC"
    oc exec hello-pod -- bash -c "(echo -e UDP_TEST `date`) | ncat -u $EGRESS_SVC 9999"
    echo -e
    echo -e
    echo -e
    ssh bmeng@fedorabmeng.usersys.redhat.com "sudo docker logs ncat-udp"
    
    echo -e "$BBlue Access hello openshift from 8888 to 2015$NC"
    oc exec hello-pod -- curl -sL $EGRESS_SVC:8888
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to access remote server${NC}"
        exit 1
    fi
    
    echo -e "$BBlue Access youdao $NC"
    oc exec hello-pod -- curl -sIL $EGRESS_SVC | grep youdao.com
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to access remote server${NC}"
        exit 1
    fi
}

function clean_up(){
    echo -e "$BBlue Delete the egress router pod and svc $NC"
    oc delete rc,svc --all -n $PROJECT ; sleep 20
}

if [ -z $USE_PROXY ]
    then 
    set_proxy
fi

if [ -z $IMAGE_VERSION ]
    then
    echo "$BRed Missing image version! $NC"
    exit 1
fi

EGRESS_DEST_EXT=61.135.218.25
PROJECT=egressproject
EGRESS_ROUTER_IMAGE="$LOCAL_REGISTRY/openshift3/ose-egress-router:$IMAGE_VERSION"
LOCAL_SERVER=`ping fedorabmeng.usersys.redhat.com -c1  | grep ttl | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'`

prepare_user
check_ip

echo -e "$BBlue Create hello pod for access $NC"
oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/pod-for-ping.json
wait_for_pod_running hello-pod 1

echo '


'
echo -e "${BGreen} Test OLD Scenarios ${NC}"
create_legacy_egress_router
wait_for_pod_running egress 1
get_router_info
test_old_scenarios
clean_up
echo '




'
echo -e "${BGreen} Test init container fallback ${NC}"
create_init_egress_router '2015 tcp 45.62.99.61\\n7777 udp 10.66.141.175 9999\\n61.135.218.24'
wait_for_pod_running egress 1
get_router_info
test_init_container
clean_up
echo '




'
echo -e "${BGreen} Test init container configmap ${NC}"
create_with_configmap
wait_for_pod_running egress 1
get_router_info
test_configmap
clean_up
echo '




'
echo -e "${BGreen} Test multiple routers ${NC}"
create_multiple_router_with_nodename '61.135.218.24'
wait_for_pod_running egress 2
get_router_info
test_router_with_nodename
clean_up
echo '


'

# clean all in the ned
oc delete project $PROJECT

