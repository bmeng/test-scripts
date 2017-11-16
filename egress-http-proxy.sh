#!/bin/bash
source ./color.sh
PROJECT=egresshttpproxy
EGRESS_ROUTER_IMAGE="openshift3/ose-egress-router:$IMAGE_VERSION"
EGRESS_HTTP_PROXY_IMAGE="openshift3/ose-egress-http-proxy:$IMAGE_VERSION"

function prepare_user() {
    #copy admin kubeconfig
    scp root@$MASTER_IP:/etc/origin/master/admin.kubeconfig ./
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to copy admin kubeconfig${NC}"
        exit 1
    fi
    
    # login to server
    oc login https://$MASTER_IP:8443 -u bmeng -p redhat --insecure-skip-tls-verify=true
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to login${NC}"
        exit 1
    fi
    
    oc delete project $PROJECT
    until [ `oc get project | grep $PROJECT | wc -l` -eq 0 ]
    do 
        echo -e "Waiting for project to be deleted on server"
        sleep 5
    done
    
    sleep 5

    # create project
    oc new-project $PROJECT
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to create project${NC}"
        exit 1
    fi
    
    #add privileged scc to user
    oadm policy add-scc-to-user privileged system:serviceaccount:$PROJECT:default --config admin.kubeconfig
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to grant privileged permission${NC}"
        exit 1
    fi
}

function check_ip() {
    #check ip
    ping -c1 $EGRESS_IP
    if [ $? -ne 1 ]
        then
        echo -e "EGRESS IP is being used"
        exit 1
    fi
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

function set_proxy() {
    export http_proxy=file.rdu.redhat.com:3128
    export https_proxy=file.rdu.redhat.com:3128
}


function create_egress_http_proxy(){
    curl --connect-timeout 5 -s https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egress-ingress/egress-router/egress-http-proxy.yaml | sed "s#openshift3/ose-egress-router#$EGRESS_ROUTER_IMAGE#g;s#openshift3/ose-egress-http-proxy#$EGRESS_HTTP_PROXY_IMAGE#g;s/egress_ip/$EGRESS_IP/g;s/egress_gateway/$EGRESS_GATEWAY/g;s#proxy_dest#$PROXY_DEST#g" | oc create -f -
}

function get_proxy_ip(){
    proxy_ip=`oc get po egress-http-proxy -o template --template={{.status.podIP}}`
}

function create_pod_for_ping(){
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/pod-for-ping.json
    wait_for_pod_running hello-pod 1
}

function test_single_ip(){
    echo -e "$BGreen Test single ip $NC"
    PROXY_DEST=`ping www.youdao.com -c1  | grep ttl | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | uniq`
    create_egress_http_proxy
    wait_for_pod_running egress-http-proxy 1
    get_proxy_ip
    oc exec egress-http-proxy -- cat /etc/squid/squid.conf
    echo "

    "
    echo -e "$BBlue Can access youdao $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI www.youdao.com | grep 200"
    echo -e "$BPurple Cannot access baidu $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI www.baidu.com | grep 403"
    echo -e "$BBlue Can access youdao $NC"
    oc exec hello-pod -- bash -c "https_proxy=$proxy_ip:8080 curl --connect-timeout 5 -skI https://www.youdao.com | grep 200"
    echo -e "$BPurple Cannot access baidu $NC"
    oc exec hello-pod -- bash -c "https_proxy=$proxy_ip:8080 curl --connect-timeout 5 -skI https://www.baidu.com | grep 403"
    delete_egress_pod
    echo '


    '
}

function test_CIDR(){
    echo -e "$BGreen Test CIDR $NC"
    PROXY_DEST="10.66.140.0/23"
    create_egress_http_proxy
    wait_for_pod_running egress-http-proxy 1
    get_proxy_ip
    oc exec egress-http-proxy -- cat /etc/squid/squid.conf
    echo "

"
    echo -e "$BBlue Can access usersys $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -s fedorabmeng.usersys.redhat.com:8080 | grep login"
    echo -e "$BPurple Cannot access baidu $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI www.baidu.com | grep 403"
    echo -e "$BPurple Cannot access baidu $NC"
    oc exec hello-pod -- bash -c "https_proxy=$proxy_ip:8080 curl --connect-timeout 5 -skI https://www.baidu.com | grep 403"
    delete_egress_pod
    echo '


'
}

function test_hostname(){
    echo -e "$BGreen Test hostname $NC"
    PROXY_DEST="www.youdao.com\n        www.baidu.com"
    create_egress_http_proxy
    wait_for_pod_running egress-http-proxy 1
    get_proxy_ip
    oc exec egress-http-proxy -- cat /etc/squid/squid.conf
    echo "

"
    echo -e "$BPurple Cannot access usersys $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -s fedorabmeng.usersys.redhat.com:8080 | grep ACCESS_DENIED"
    echo -e "$BBlue Can access baidu $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI www.baidu.com | grep 200"
    echo -e "$BBlue Can access youdao $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI www.youdao.com | grep 200"
    echo -e "$BBlue Can access baidu $NC"
    oc exec hello-pod -- bash -c "https_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI https://www.baidu.com | grep 200"
    echo -e "$BBlue Can access youdao $NC"
    oc exec hello-pod -- bash -c "https_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI https://www.youdao.com | grep 200"
    delete_egress_pod
    echo '


'
}

function test_wildcard(){
    echo -e "$BGreen Test wildcard $NC"
    PROXY_DEST="*.youdao.com"
    create_egress_http_proxy
    wait_for_pod_running egress-http-proxy 1
    get_proxy_ip
    oc exec egress-http-proxy -- cat /etc/squid/squid.conf
    echo "

"
    echo -e "$BPurple Cannot access baidu $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI www.baidu.com | grep 403"
    echo -e "$BPurple Cannot access baidu $NC"
    oc exec hello-pod -- bash -c "https_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI https://www.baidu.com | grep 403"
    echo -e "$BBlue Can access youdao $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI dict.youdao.com | grep 200"
    echo -e "$BBlue Can access youdao $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI www.youdao.com | grep 200"
    delete_egress_pod
    echo "


"
}

function test_multiple_lines(){
    echo -e "$BGreen Test multiple lines $NC"
    PROXY_DEST="!www.youdao.com\n        ipecho.net\n        www.ip138.com\n        *"
    create_egress_http_proxy
    wait_for_pod_running egress-http-proxy 1
    oc exec egress-http-proxy -- cat /etc/squid/squid.conf
    get_proxy_ip
    echo "

"
    echo -e "$BPurple Cannot access youdao $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI www.youdao.com | grep 403"
    echo -e "$BPurple Cannot access youdao $NC"
    oc exec hello-pod -- bash -c "https_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI https://www.youdao.com | grep 403"
    echo -e "$BBlue Can access baidu $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI www.baidu.com | grep 200"
    echo -e "$BBlue Can access baidu $NC"
    oc exec hello-pod -- bash -c "https_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI https://www.baidu.com | grep 200"
    echo -e "$BBlue Can access ipecho $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI ipecho.net/plain | grep 200"
    echo -e "$BBlue Can access ip138 $NC"
    oc exec hello-pod -- bash -c "http_proxy=$proxy_ip:8080 curl --connect-timeout 5 -sI www.ip138.com | grep 200"
    delete_egress_pod
    echo "


"
}

function delete_egress_pod(){
    oc delete po egress-http-proxy
    until [ `oc get po | grep http-proxy | wc -l` -eq 0 ]
    do 
        echo -e "Waiting for pod to be deleted on server"
        sleep 5
    done
}

prepare_user
check_ip

create_pod_for_ping

test_single_ip
test_CIDR
test_hostname
test_wildcard
test_multiple_lines

oc delete project egresshttpproxy
