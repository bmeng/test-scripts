#!/bin/bash

master=$Master
master_port=$Master_Port
node=$Node
user="-u bmeng -p redhat"
version=`ssh root@$master "oc version | head -1 | cut -d ' ' -f2"`

function exit_on_fail() {
    if [ $? -ne 0 ]
    then
      exit 1
    fi
}

function login() {
    oc login https://${master}:${master_port} ${user} --insecure-skip-tls-verify=true
    exit_on_fail
}

function create_projects() {
    oc new-project bmengp1
    oc new-project bmengp2
}

function create_temp_upgrade_dir(){
    UPGRADE_DIR=/tmp/upgrade_$$
    mkdir $UPGRADE_DIR
}

function copy_admin_kubeconfig() {
    scp root@$master:/etc/origin/master/admin.kubeconfig $UPGRADE_DIR/admin.kubeconfig
    local CURR=`grep current-context $UPGRADE_DIR/admin.kubeconfig | cut -d: -f2-`
    local CONTEXTS=($(grep name\:\ default $UPGRADE_DIR/admin.kubeconfig | cut -d: -f2-))

    if [[ $CURR = ${CONTEXT[0]} ]]
    then
        sed -i "s#current-context:.*#current-context: ${CONTEXTS[1]}#g" $UPGRADE_DIR/admin.kubeconfig
    else
        sed -i "s#current-context:.*#current-context: ${CONTEXTS[0]}#g" $UPGRADE_DIR/admin.kubeconfig
    fi

    ADMIN="--config $UPGRADE_DIR/admin.kubeconfig"
}

function wait_running() {
    local POD=$1
    local NUM=$2
    local project=$3
    TRY=20
    COUNT=0
    while [ $COUNT -lt $TRY ]; do
      if [ `oc get po -n ${project} | grep $POD | grep Running | wc -l` -eq $NUM ]; then
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

function create_podsvc() {
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n bmengp1
    exit_on_fail
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/routing/list_for_caddy.json -n bmengp2
    exit_on_fail
    wait_running test 2 bmengp1
    wait_running caddy 2 bmengp2
}

function create_route() {
    oc expose svc test-service --name=http-route -n bmengp1
    exit_on_fail
    oc create route edge route-edge --service=test-service -n bmengp1
    exit_on_fail
    oc create route reencrypt route-reen --service=service-secure -n bmengp2
    exit_on_fail
    oc create route passthrough route-passthrough --service=service-secure -n bmengp2
    exit_on_fail
}

function create_egressfirewall() {
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egressnetworkpolicy/limit_policy.json -n bmengp1 $ADMIN
    exit_on_fail
}

function create_networkpolicy() {
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/networkpolicy/allow-local.yaml -n bmengp2
    exit_on_fail
}

function create_ingress() {
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/routing/ingress/test-ingress.json -n bmengp1 $ADMIN
    exit_on_fail
}

function create_ipfailover() {
    oc adm policy add-scc-to-user privileged -z ipfailover $ADMIN
    exit_on_fail
    oc adm ipfailover --images="registry.reg-aws.openshift.com:443/openshift3/ose-keepalived-ipfailover:${version}" --virtual-ips=40.40.40.40 $ADMIN
    exit_on_fail
}

function create_egressIP() {
    nodename=`oc get hostsubnet -o template --template="{{ (index .items 1).host }}" $ADMIN`
    oc patch hostsubnet $nodename -p '{"egressIPs":["10.10.10.10"]}' $ADMIN
    exit_on_fail
    oc patch netnamespace bmengp2 -p '{"egressIPs":["10.10.10.10"]}' $ADMIN
    exit_on_fail
}

function create_egressrouter() {
    oc adm policy add-scc-to-user privileged -z default -n bmengp1 $ADMIN
    exit_on_fail
    curl -s https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egress-ingress/egress-router/legacy-egress-router-list.json | sed "s/egress_ip/20.20.20.20/g;s/egress_gw/20.20.20.1/g;s/egress_dest/30.30.30.30/g;s/egress-router-image/registry.reg-aws.openshift.com:443\/openshift3\/ose-egress-router:${version}/g" | oc create -f - -n bmengp1 $ADMIN
    exit_on_fail
}

function dump_iptables() {
    ssh root@$node iptables-save > $UPGRADE_DIR/iptables.dump
    exit_on_fail
}

function dump_openflow() {
    ssh root@$node ovs-ofctl dump-flows br0 -O openflow13 > $UPGRADE_DIR/openflow.dump
    exit_on_fail
}

function dump_resources() {
    oc get po,svc,rc,route,ingress -o wide -n bmengp1 $ADMIN > $UPGRADE_DIR/p1_resource.yaml
    oc get po,svc,rc,route,ingress -o wide -n bmengp2 $ADMIN > $UPGRADE_DIR/p2_resource.yaml
    oc get egressnetworkpolicy -o yaml -n bmengp1 $ADMIN >> $UPGRADE_DIR/p1_resource.yaml
    oc get networkpolicy -o yaml -n bmengp2 $ADMIN >> $UPGRADE_DIR/p2_resource.yaml
    oc get clusternetwork,hostsubnet,netnamespaces $ADMIN > $UPGRADE_DIR/cluster.info
}


echo "Start pre upgrade!"
login
create_temp_upgrade_dir
create_projects
copy_admin_kubeconfig
create_podsvc
create_route
create_ingress
create_egressfirewall
create_networkpolicy
create_egressIP
create_ipfailover
create_egressrouter
dump_resources
dump_openflow
dump_iptables

echo "All steps finished!"
