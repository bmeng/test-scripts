#!/bin/bash
source ./color.sh

MASTER=$MASTER_IP
NODE1=$NODE_IP_1
NODE2=$NODE_IP_2

function get_current_plugin() {
    local plugin_length=`ssh root@$MASTER "grep ovs /etc/origin/master/master-config.yaml | wc -m"`
    if [ $plugin_length -eq 54 ]
    then
      plugin_type=multitenant
      echo "Plugin is multitenant"
    elif [ $plugin_length -eq 49 ]
    then
      plugin_type=subnet
      echo "Plugin is subnet"
    else
      plugin_type=networkpolicy
      echo "Plugin is networkpolicy"
    fi
}

function switch_to_multitenant() {
    ssh root@$MASTER "sed -i 's#networkPluginName:.*#networkPluginName: redhat/openshift-ovs-multitenant#g' /etc/origin/master/master-config.yaml"
    ssh root@$MASTER "systemctl restart atomic-openshift-master"
    sleep 10
    for i in $NODE1 $NODE2
    do
      ssh root@$i "sed -i 's#networkPluginName:.*#networkPluginName: redhat/openshift-ovs-multitenant#g' /etc/origin/node/node-config.yaml"
      ssh root@$i "systemctl restart atomic-openshift-node"
    done
}

function switch_to_subnet() {
    ssh root@$MASTER "sed -i 's#networkPluginName:.*#networkPluginName: redhat/openshift-ovs-subnet#g' /etc/origin/master/master-config.yaml"
    ssh root@$MASTER "systemctl restart atomic-openshift-master"
    sleep 10
    for i in $NODE1 $NODE2
    do
      ssh root@$i "sed -i 's#networkPluginName:.*#networkPluginName: redhat/openshift-ovs-subnet#g' /etc/origin/node/node-config.yaml"
      ssh root@$i "systemctl restart atomic-openshift-node"
      sleep 5
    done

    sleep 60
}

function wait_for_pod_running() {
    local POD=$1
    local NUM=$2
    local PROJ=$3
    TRY=20
    COUNT=0
    while [ $COUNT -lt $TRY ]; do
        if [ `oc get po -n $PROJ | grep $POD | grep Running | wc -l` -eq $NUM ]; then
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

function create_pods() {
    oc login https://$MASTER:8443 -u bmeng -p redhat
    oc new-project u1p1
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n u1p1
    wait_for_pod_running test-rc 2 u1p1
    p1pod1=`oc get po -o wide -n u1p1 | grep test-rc | head -1 | awk '{print \$1}'`
    p1ip1=`oc get po -o wide -n u1p1 | grep test-rc | head -1 | awk '{print \$6}'`
    p1ip2=`oc get po -o wide -n u1p1 | grep test-rc | tail -1 | awk '{print \$6}'`
    p1svc=`oc get svc -n u1p1 | grep test-service | awk '{print \$2}'`

    oc new-project u1p2
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n u1p2
    wait_for_pod_running test-rc 2 u1p2
    p2pod1=`oc get po -o wide -n u1p2 | grep test-rc| head -1 | awk '{print \$1}'`
    p2ip1=`oc get po -o wide -n u1p2 | grep test-rc| head -1 | awk '{print \$6}'`
    p2ip2=`oc get po -o wide -n u1p2 | grep test-rc| tail -1 | awk '{print \$6}'`
    p2svc=`oc get svc -n u1p2 | grep test-service | awk '{print \$2}'`
}


function access_pod_svc() {
    oc project u1p1
    #p1pod access p1pod
    oc exec $p1pod1 -- curl --connect-timeout 2 -s $p1ip2:8080
    #p1pod access p1svc
    oc exec $p1pod1 -- curl --connect-timeout 2 -s $p1svc:27017
    #p1pod access p2pod
    oc exec $p1pod1 -- curl --connect-timeout 2 -s $p2ip2:8080
    #p1pod access p2svc
    oc exec $p1pod1 -- curl --connect-timeout 2 -s $p2svc:27017
    
    oc project u1p2
    #p2pod access p2pod
    oc exec $p2pod1 -- curl --connect-timeout 2 -s $p2ip1:8080
    #p2pod access p2svc
    oc exec $p2pod1 -- curl --connect-timeout 2 -s $p2svc:27017
    #p2pod access p1pod
    oc exec $p2pod1 -- curl --connect-timeout 2 -s $p1ip1:8080
    #p2pod access p1svc
    oc exec $p2pod1 -- curl --connect-timeout 2 -s $p1svc:27017
}

function clean_up(){
    oc delete project u1p1
    oc delete project u1p2
    sleep 5
}



get_current_plugin

if [ $plugin_type = multitenant ]
then
  create_pods
  access_pod_svc
  switch_to_subnet
  access_pod_svc
  switch_to_multitenant
  access_pod_svc
elif [ $plugin_type = subnet ]
then
  create_pods
  access_pod_svc
  switch_to_multitenant
  access_pod_svc
  switch_to_subnet
  access_pod_svc
else
  echo "Plugin type not supported"
  exit 1
fi
clean_up
