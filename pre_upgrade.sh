#!/bin/bash

source ./color.sh

master=$MASTER
master_port=$MASTER_PORT
node=$NODE
version=$VERSION


if [ -n $CREDENTIAL ]
then
  if [[ $CRED =~ .*:.* ]]
  then
    username=`echo $CREDENTIAL | cut -d: -f1`
    passwd=`echo $CREDENTIAL | cut -d: -f2`
    user="-u $username -p $passwd"
  else
    user="--token $CREDENTIAL"
  fi
else
  echo -e "$BRed No user spcified! $NC"
  exit 1
fi


function exit_on_fail() {
    if [ $? -ne 0 ]
    then
      exit 1
      echo -e "$BRed Step failed!! $NC"
    fi
}

function login() {
    echo -e "$BBlue Login to the openshift master. $NC"
    oc login https://${master}:${master_port} ${user} --insecure-skip-tls-verify=true
    exit_on_fail
}

function create_projects() {
    echo -e "$BBlue Create projects $NC"
    oc new-project bmengp1
    exit_on_fail
    oc new-project bmengp2
    exit_on_fail
}

function create_temp_upgrade_dir(){
    UPGRADE_DIR=/tmp/upgrade_$$
    mkdir $UPGRADE_DIR
}

function copy_admin_kubeconfig() {
    echo -e "$BBlue Copy the admin.kubeconfig from master and change context. $NC"
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
      echo -e "Waiting for pods ready..."
      let COUNT=$COUNT+1
    done
    if [ $COUNT -eq 20 ]
    then
      echo -e "$BRed Pod creation failed! $NC"
      exit 1
    fi

}

function create_podsvc() {
    echo -e "$BBlue Create pod and svc in user projects. $NC"
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n bmengp1
    exit_on_fail
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/routing/list_for_caddy.json -n bmengp2
    exit_on_fail
    wait_running test 2 bmengp1
    wait_running caddy 2 bmengp2
}

function create_route() {
    echo -e "$BBlue Create different types of route in user projects. $NC"
    oc expose svc test-service --name=http-route -n bmengp1
    exit_on_fail
    oc create route edge route-edge --service=test-service -n bmengp1
    exit_on_fail
    oc create route reencrypt route-reen --service=service-secure --hostname=reen-route.example.com -n bmengp2
    exit_on_fail
    oc create route passthrough route-passthrough --service=service-secure --hostname=pass-route.example.com -n bmengp2
    exit_on_fail
}

function create_egressfirewall() {
    echo -e "$BBlue Create egress firewall in project 1 via admin. $NC"
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egressnetworkpolicy/limit_policy.json -n bmengp1 $ADMIN
}

function create_networkpolicy() {
    echo -e "$BBlue Create network policy in project 2 via admin. $NC"
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/networkpolicy/allow-local.yaml -n bmengp2
}

function create_ingress() {
    echo -e "$BBlue Create ingress in project 1 via admin. $NC"
    oc env dc/router ROUTER_ENABLE_INGRESS=true $ADMIN
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/routing/ingress/test-ingress.json -n bmengp1 $ADMIN
}

function create_ipfailover() {
    echo -e "$BBlue Create ipfailover in default project via admin. $NC"
    oc adm policy add-scc-to-user privileged -z ipfailover $ADMIN
    oc adm ipfailover --images="registry.reg-aws.openshift.com:443/openshift3/ose-keepalived-ipfailover:${version}" --virtual-ips=40.40.40.40 $ADMIN
}

function create_egressIP() {
    echo -e "$BBlue Add egressIP to hostsubnet and netnamespace via admin. $NC"
    nodename=`oc get hostsubnet -o template --template="{{ (index .items 1).host }}" $ADMIN`
    oc patch hostsubnet $nodename -p '{"egressIPs":["10.10.10.10"]}' $ADMIN
    oc patch netnamespace bmengp2 -p '{"egressIPs":["10.10.10.10"]}' $ADMIN
}

function create_egressrouter() {
    echo -e "$BBlue Create egress router in project1 via admin. $NC"
    oc adm policy add-scc-to-user privileged -z default -n bmengp1 $ADMIN
    curl -s https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egress-ingress/egress-router/legacy-egress-router-list.json | sed "s/egress_ip/20.20.20.20/g;s/egress_gw/20.20.20.1/g;s/egress_dest/30.30.30.30/g;s/egress-router-image/registry.reg-aws.openshift.com:443\/openshift3\/ose-egress-router:${version}/g" | oc create -f - -n bmengp1 $ADMIN
}

function create_hostsubnet(){
    echo -e "$BBlue Create f5 hostsubnet via admin. $NC"
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/f5-hostsubnet.json $ADMIN
}

function dump_iptables() {
    echo -e "$BBlue Dump iptables rules into $UPGRADE_DIR. $NC"
    ssh root@$node iptables-save > $UPGRADE_DIR/iptables.dump
    exit_on_fail
}

function dump_openflow() {
    echo -e "$BBlue Dump openflow rules into $UPGRADE_DIR. $NC"
    id=`ssh root@$node "docker ps | grep openvswitch | cut -d ' ' -f1"`
    ssh root@$node "docker exec -t $id ovs-ofctl dump-flows br0 -O openflow13 2>/dev/null" > $UPGRADE_DIR/openflow.dump
    exit_on_fail
    ssh root@$node "docker exec -t $id ovs-vsctl --version 2>/dev/null" > $UPGRADE_DIR/ovs.version
    exit_on_fail
}

function dump_resources() {
    echo -e "$BBlue Dump created resource into $UPGRADE_DIR. $NC"
    oc get po,svc,rc,route,ingress -o wide -n bmengp1 $ADMIN > $UPGRADE_DIR/p1_resource.yaml
    oc get po,svc,rc,route,ingress -o wide -n bmengp2 $ADMIN > $UPGRADE_DIR/p2_resource.yaml
    oc get egressnetworkpolicy -o yaml -n bmengp1 $ADMIN >> $UPGRADE_DIR/p1_resource.yaml
    oc get networkpolicy -o yaml -n bmengp2 $ADMIN >> $UPGRADE_DIR/p2_resource.yaml
    oc get clusternetwork,hostsubnet,netnamespaces $ADMIN > $UPGRADE_DIR/cluster.info
}

rm -rf /tmp/upgrade*

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
create_hostsubnet
dump_resources
dump_openflow
dump_iptables

echo "All steps finished!"
