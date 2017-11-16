#!/bin/bash
source ./color.sh

MASTER_IP=$MASTER_IP
NODE1=$NODE_NAME_1
NODE2=$NODE_NAME_2
VIPS=$VIPS
PROJECT=ipf


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
    oadm policy add-scc-to-user privileged system:serviceaccount:$PROJECT:default --config admin.kubeconfig
    if [ $? -ne 0 ]
        then
        echo -e "${BRed}Failed to grant privileged permission${NC}"
        exit 1
    fi
}

function expand_ipv4_range(){
    expandedset=()
    local ip1=$(echo "$1" | awk '{print $1}' FS='-')
    local ip2=$(echo "$1" | awk '{print $2}' FS='-')
    local n

    if [ -z "$ip2" ]; then
      expandedset=(${expandedset[@]} "$ip1")
    else
      local base=$(echo "$ip1" | cut -f 1-3 -d '.')
      local start=$(echo "$ip1" | awk '{print $NF}' FS='.')
      local end=$(echo "$ip2" | awk '{print $NF}' FS='.')
      for n in `seq $start $end`; do
        expandedset=(${expandedset[@]} "${base}.$n")
      done
    fi
}

function check_ips(){
    expand_ipv4_range $VIPS
    for i in ${expandedset[@]}
    do ping -c 1 $i
      if [ $? -ne 1 ]
      then
        exit
      fi
    done
    VIP_1="${expandedset[0]},${expandedset[1]}"
    VIP_2="${expandedset[2]},${expandedset[3]}"
    echo $VIP_1
    echo $VIP_2
}

function test_offset(){
    echo -e "$BGreen Test ipfailover with vrrp_id_offset $NC"
    # add labels to node
    oc label node $NODE1 ha=red --overwrite --config admin.kubeconfig
    oc label node $NODE2 ha=blue --overwrite --config admin.kubeconfig

    # create router on each node
    oadm policy add-scc-to-user hostnetwork -z router --config admin.kubeconfig
    oadm router router-red --selector=ha=red --config admin.kubeconfig --images=openshift3/ose-haproxy-router:$VERSION
    oadm router router-blue --selector=ha=blue --config admin.kubeconfig --images=openshift3/ose-haproxy-router:$VERSION

    # wait the routers are running
    while [ `oc get pod --config admin.kubeconfig | grep -v deploy| grep router | grep Running | wc -l` -lt 2 ]
    do
      sleep 5
    done

    echo -e "$BBlue Create ipfailover $NC"
    # create ipfailover for each router
    oadm policy add-scc-to-user privileged -z ipfailover --config admin.kubeconfig
    oadm ipfailover ipf-red --create --selector=ha=red --virtual-ips=${VIP_1} --watch-port=80 --replicas=1 --service-account=ipfailover  --config admin.kubeconfig --images=openshift3/ose-keepalived-ipfailover:$VERSION
    oadm ipfailover ipf-blue --create --selector=ha=blue --virtual-ips=${VIP_2} --watch-port=80 --replicas=1 --service-account=ipfailover --vrrp-id-offset=50 --config admin.kubeconfig --images=openshift3/ose-keepalived-ipfailover:$VERSION

    # wait the keepaliveds are running
    while [ `oc get pod --config admin.kubeconfig | grep -v deploy | grep ipf | grep Running | wc -l` -lt 2 ]
    do
      sleep 5
    done

    echo -e "$BBlue Check the value in keepalived.conf $NC"
    oc exec `oc get po --config admin.kubeconfig | grep ipf-red |grep -v deploy| cut -d " " -f1` --config admin.kubeconfig -- grep -i id /etc/keepalived/keepalived.conf
    oc exec `oc get po --config admin.kubeconfig | grep ipf-blue | grep -v deploy | cut -d " " -f1` --config admin.kubeconfig -- grep -i id /etc/keepalived/keepalived.conf

    echo -e "$BBlue Create pod svc route for test $NC"
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/routing/unsecure/list_for_unsecure.json
    while [ `oc get pod | grep caddy | grep Running | wc -l` -lt 2 ]
    do
      sleep 5
    done

    echo -e "$BBlue Access the ipfailover via port $NC"
    for i in ${expandedset[@]}
    do
      set -x
      curl -s --resolve unsecure.example.com:80:$i http://unsecure.example.com/
      set +x
    done
}

function test_svc(){
    echo -e "$BGreen Test ipfailover for ha service $NC"
    # add labels to node
    oc label node $NODE1 ha-service=ha --overwrite --config admin.kubeconfig
    oc label node $NODE2 ha-service=ha --overwrite --config admin.kubeconfig

    echo -e "$BBlue Create ha service $NC"
    # create ha service on each node
    oadm policy add-scc-to-user privileged -z default -n $PROJECT --config admin.kubeconfig
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/ha-network-service.json

    # wait the endpoints are running
    while [ `oc get pod | grep ha | grep Running | wc -l` -lt 2 ]
    do
      sleep 5
    done

    # patch the service
    oc patch svc ha-service -p '{"spec": {"ports": [{"port":9736,"targetPort":8080}]}}'
    oc patch svc ha-service -p '{"spec": {"type":"NodePort"}}'
    local nodeport=`oc get svc ha-service -o jsonpath={.spec.ports[0].nodePort}`

    echo -e "$BBlue Create ipfailover $NC"
    # create ipfailover
    oadm ipfailover ipf --create --selector=ha-service=ha --virtual-ips=${VIP_1} --watch-port=${nodeport} --replicas=2 --service-account=ipfailover --config admin.kubeconfig --images=openshift3/ose-keepalived-ipfailover:$VERSION

    # wait the keepaliveds are running
    while [ `oc get pod --config admin.kubeconfig | grep ipf | grep -v deploy | grep Running | wc -l` -lt 2 ]
    do
      sleep 5
    done

    echo -e "$BBlue Access the ipfailover via port $NC"
    # access the svc
    for i in ${expandedset[@]:0:2}
    do
      set -x
      curl -s $i:$nodeport
      set +x
    done
}


function clean_up(){
    echo -e "$BGreen Clean up the pods $NC"
    oc delete dc,svc router-red --config admin.kubeconfig
    oc delete dc,svc router-blue --config admin.kubeconfig
    oc delete dc ipf-red --config admin.kubeconfig
    oc delete dc ipf-blue --config admin.kubeconfig
    oc delete dc ipf  --config admin.kubeconfig
    oc delete all --all
    sleep 15
}

prepare_user
check_ips
test_offset
clean_up
test_svc
clean_up

oc delete project ipf
