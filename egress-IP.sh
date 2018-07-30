#!/bin/bash
source ./color.sh


function set_proxy() {
    export http_proxy=file.rdu.redhat.com:3128
    export https_proxy=file.rdu.redhat.com:3128
}

function check_ip() {
    #check ip
    for ip in $EGRESS_IP $EGRESS_IP2 $EGRESS_IP3
    do
      echo -e "$BBlue Check if the IP is in-use. $NC"
      ping -c1 $ip
      if [ $? -ne 1 ]
      then
        echo -e "$BRed EGRESS IP is being used $NC"
        exit 1
      fi
#      oc get hostsubnet --config admin.kubeconfig | grep $ip
#      if [ $? -ne 1 ]
#      then
#        echo -e "$BRed EGRESS IP is being used! $NC"
#        exit 1
#      fi
    done
}

function clean_node_egressIP() {
    nodes=(`oc get node --config admin.kubeconfig -o jsonpath='{.items[*].metadata.name}'`)
    for n in ${nodes[@]}
    do
      oc patch hostsubnet $n -p "{\"egressIPs\":[]}" --config admin.kubeconfig
      oc patch hostsubnet $n -p "{\"egressCIDRs\":[]}" --config admin.kubeconfig
    done
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
    oc login https://$MASTER_IP:8443 -u bmeng -p redhat --insecure-skip-tls-verify=true
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
    oc delete project project2
    echo -e "$BBlue Delete the project2 if already existed. $NC"
    until [ `oc get project | grep project2 | wc -l` -eq 0 ]
    do
      echo -e "Waiting for project2 to be deleted on server"
      sleep 5
    done
    sleep 10
    # create project
    create_project $PROJECT
}

function create_project(){
    local project=$1
    oc new-project $project
    if [ $? -ne 0 ]
    then
      echo -e "${BRed}Failed to create $project $NC"
      exit 1
    fi
}

function wait_for_pod_running() {
    local POD=$1
    local NUM=$2
    local project=$3
    TRY=20
    COUNT=0
    while [ $COUNT -lt $TRY ]; do
      if [ `oc get po -n ${project:-$PROJECT} | grep $POD | grep Running | wc -l` -eq $NUM ]; then
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

function step_pass(){
    if [ $? -ne 0 ]
    then
      echo -e "$BRed FAILED! $NC"
    else
      echo -e "$BGreen PASS! $NC"
    fi
}

function step_fail(){
    if [ $? -ne 0 ]
    then
      echo -e "$BGreen PASS! $NC"
    else
      echo -e "$BRed FAILED! $NC"
    fi
}

function elect_egress_node(){
    EGRESS_NODE=`oc get node -l node-role.kubernetes.io/compute=true --config admin.kubeconfig -o jsonpath='{.items[*].metadata.name}' | xargs shuf -n1 -e`
}

function clean_up_egressIPs(){
    echo -e "$BBlue Clean up the egressIP on both hostnetwork and netns $NC"
    oc patch hostsubnet $EGRESS_NODE -p "{\"egressIPs\":[]}" --config admin.kubeconfig
    oc patch netnamespaces $PROJECT -p "{\"egressIPs\":[]}" --config admin.kubeconfig
}

function assign_egressIP_to_node(){
    elect_egress_node
    echo -e "$BBlue Assign egress IP to the elected node $NC"
    oc patch hostsubnet $EGRESS_NODE -p "{\"egressIPs\":[\"$EGRESS_IP\"]}" --config admin.kubeconfig
}

function assign_egressCIDR_to_node(){
    elect_egress_node
    local egresscidr=$1
    echo -e "$BBlue Assign egress IP to the elected node $NC"
    set -x
    oc patch hostsubnet $EGRESS_NODE -p "{\"egressCIDRs\":[\"${egresscidr:-$EGRESS_CIDR}\"]}" --config admin.kubeconfig
    set +x
}

function assign_egressIP_to_netns(){
    echo -e "$BBlue Assign egress IP to the project netnamespace $NC"
    local netns=$1
    local egressip=$2
    oc patch netnamespace $netns -p "{\"egressIPs\":[\"${egressip:-$EGRESS_IP}\"]}" --config admin.kubeconfig
}

function access_external_network(){
    echo -e "$BBlue Access external network $NC"
    local pod=$1
    local project=$2
    oc exec $pod -n $project -- curl -sS --connect-timeout 10 $external_service
}

function test_only_cluster_admin_can_modify(){
    echo -e "$BBlue Test OCP-15465/15466 Only cluster admin can manipulate egressIP. $NC"
    elect_egress_node
    oc project $PROJECT
    oc patch hostsubnet $EGRESS_NODE -p "{\"egressIPs\":[]}"
    step_fail
    oc patch netnamespaces $PROJECT -p "{\"egressIPs\":[]}"
    step_fail
    clean_up_egressIPs
    sleep 5
}

function test_egressip_to_multi_netns(){
    echo -e "$BBlue Test OCP-15467 Pods will lose external access if the same egressIP is set to multiple netnamespaces and error logs in master. $NC"
    elect_egress_node
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    create_project project2
    assign_egressIP_to_node
    assign_egressIP_to_netns $PROJECT
    assign_egressIP_to_netns project2
    echo -e "$BBlue Check the node log $NC"
    ssh root@$EGRESS_NODE journalctl -l -u atomic-openshift-node --since \"1 min ago\" | grep -E E[0-9]{4}
    # sleep sometime to make sure the egressIP ready
    sleep 10
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_fail
      access_external_network $p $PROJECT
      step_fail
    done
    echo -e "$BRed Bug 1520363 $NC"
    clean_up_egressIPs
    oc delete project project2
    oc delete all --all -n $PROJECT
    sleep 10
}

function test_no_node_with_egressip(){
    echo -e "$BBlue Test OCP-15469 Pods will lose external access if there is no node can host the egress IP which admin assigned to the netns. $NC"
#    assign_egressIP_to_node
    assign_egressIP_to_netns $PROJECT
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_fail
      access_external_network $p $PROJECT
      step_fail
    done
    clean_up_egressIPs
    oc delete all --all -n $PROJECT
    sleep 10
}

function test_pods_through_egressip(){
    echo -e "$BBlue Test OCP-15471 All the pods egress connection will get out through the egress IP if the egress IP is set to netns and egress node can host the IP $NC"
    echo -e "$BRed Needs update for multiple projects $NC"
    assign_egressIP_to_node
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    assign_egressIP_to_netns $PROJECT
    oc scale rc test-rc --replicas=4 -n $PROJECT
    wait_for_pod_running test-rc 4
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    for p in ${pod}
    do
      access_external_network $p $PROJECT 
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP
      step_pass
    done
    clean_up_egressIPs
    oc delete all --all -n $PROJECT
    sleep 15
}

function test_node_nic(){
    echo -e "$BBlue Test OCP-15472 The egressIPs will be added to the node's primary NIC when it gets set on hostsubnet and will be removed after gets unset $NC"
    assign_egressIP_to_netns $PROJECT
    assign_egressIP_to_node
    ssh root@$EGRESS_NODE "ip a s | grep $EGRESS_IP"
    step_pass
    clean_up_egressIPs
    ssh root@$EGRESS_NODE "ip a s | grep $EGRESS_IP"
    step_fail
    sleep 10
}

function test_iptables_openflow_rules(){
    echo -e "$BBlue Test OCP-15473 iptables/openflow rules add/remove $NC"
    assign_egressIP_to_node
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    assign_egressIP_to_netns $PROJECT
    OTHER_NODE=`oc get node -l node-role.kubernetes.io/compute=true --config admin.kubeconfig -o jsonpath='{.items[*].metadata.name}' | sed "s/$EGRESS_NODE//" | cut -d " " -f2 | tr -d " "`
    ssh root@$EGRESS_NODE "iptables -S OPENSHIFT-FIREWALL-ALLOW | grep $EGRESS_IP"
    step_pass
    ssh root@$EGRESS_NODE "iptables -t nat -S OPENSHIFT-MASQUERADE | grep $EGRESS_IP"
    step_pass
    ssh root@$EGRESS_NODE 'id=$(docker ps | grep openvswitch | awk -F " " "{print \$1}") ; docker exec -t $id ovs-ofctl dump-flows br0 -O openflow13 | grep table=100'
    echo -e "\n"
    ssh root@$OTHER_NODE 'id=$(docker ps | grep openvswitch | awk -F " " "{print \$1}") ; docker exec -t $id ovs-ofctl dump-flows br0 -O openflow13 | grep table=100'
    echo -e "\n"
    clean_up_egressIPs
    ssh root@$EGRESS_NODE "iptables -S OPENSHIFT-FIREWALL-ALLOW | grep $EGRESS_IP"
    step_fail
    ssh root@$EGRESS_NODE "iptables -t nat -S OPENSHIFT-MASQUERADE | grep $EGRESS_IP"
    step_fail
    ssh root@$EGRESS_NODE 'id=$(docker ps | grep openvswitch | awk -F " " "{print \$1}") ; docker exec -t $id ovs-ofctl dump-flows br0 -O openflow13 | grep table=100' 
    echo -e "\n"
    ssh root@$OTHER_NODE 'id=$(docker ps | grep openvswitch | awk -F " " "{print \$1}") ; docker exec -t $id ovs-ofctl dump-flows br0 -O openflow13 | grep table=100'
    echo -e "\n"
    oc delete all --all -n $PROJECT
    sleep 10
}

function test_multi_egressip(){
    echo -e "$BBlue Test OCP-15474 Only the first element of the EgressIPs array in netNamespace will take effect. $NC"
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    elect_egress_node
    oc patch hostsubnet $EGRESS_NODE -p "{\"egressIPs\":[\"$EGRESS_IP\",\"$EGRESS_IP2\"]}" --config admin.kubeconfig
    oc patch netnamespace $PROJECT -p "{\"egressIPs\":[\"$EGRESS_IP\",\"$EGRESS_IP2\"]}" --config admin.kubeconfig
    # sleep sometime to make sure the egressIP ready
    sleep 15
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    for p in ${pod}
    do
      access_external_network $p $PROJECT | grep $EGRESS_IP
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP
      step_pass
    done
    oc delete all --all -n $PROJECT
    clean_up_egressIPs
    sleep 10
}

function test_egressip_to_multi_host(){
    echo -e "$BBlue Test OCP-15987 The egressIP will be unavailable if it was set to multiple hostsubnets. $NC"
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    OTHER_NODE=`oc get node -l node-role.kubernetes.io/compute=true --config admin.kubeconfig -o jsonpath='{.items[*].metadata.name}' | sed "s/$EGRESS_NODE//" | cut -d " " -f2 | tr -d " "`
    oc patch hostsubnet $OTHER_NODE -p "{\"egressIPs\":[\"$EGRESS_IP\"]}" --config admin.kubeconfig
    # sleep sometime to make sure the egressIP ready
    sleep 10
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP
      step_fail
    done
    clean_up_egressIPs
    sleep 10
}

function test_pods_in_other_project(){
    echo -e "$BBlue Test OCP-15989 Pods will not be affected by the egressIP set on other netnamespace. $NC"
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    assign_egressIP_to_node
    assign_egressIP_to_netns $PROJECT
    create_project project2
    oc project project2
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n project2
    wait_for_pod_running test-rc 2 project2
    pod=$(oc get po -n project2 | grep Running | cut -d' ' -f1)
    for p in ${pod}
    do
      access_external_network $p project2
      step_pass
      access_external_network $p project2 | grep $EGRESS_IP
      step_fail
    done
    clean_up_egressIPs
    oc delete project project2
    oc delete all --all -n $PROJECT
    sleep 10
}

function test_egressnetworkpolicy_with_egressip(){
    echo -e "$BBlue Test OCP-15992 EgressNetworkPolicy works well with egressIP. $NC"
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    assign_egressIP_to_node
    assign_egressIP_to_netns $PROJECT
    cat << EOF | oc create -f - --config admin.kubeconfig -n $PROJECT
{
    "kind": "EgressNetworkPolicy",
    "apiVersion": "v1",
    "metadata": {
        "name": "default"
    },
    "spec": {
        "egress": [
            {
                "type": "Deny",
                "to": {
                    "cidrSelector": "10.66.140.0/23"
                }
            },
            {
                "type": "Deny",
                "to": {
                    "cidrSelector": "10.72.12.0/22"
                }
            }
        ]
    }
}
EOF
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_fail
      access_external_network $p $PROJECT
      step_fail
    done
    oc patch egressnetworkpolicy default -p '{"spec":{"egress":[{"to":{"cidrSelector":"10.66.144.0/23"},"type":"Deny"}]}}' -n $PROJECT --config admin.kubeconfig
    # sleep sometime to make sure the egressIP ready
    sleep 15
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP
      step_pass
    done
    clean_up_egressIPs
    sleep 10
}

function test_access_egressip(){
    echo -e "$BBlue Test OCP-15996 Should not be able to access node via egressIP. $NC"

    assign_egressIP_to_node
    assign_egressIP_to_netns $PROJECT
    ssh root@$EGRESS_NODE "hostname"
    step_pass
    ssh root@$EGRESS_IP "hostname"
    step_fail
    clean_up_egressIPs
    sleep 10
}

function test_negative_values(){
    echo -e "$BBlue Test OCP-Negative values in egressIP. $NC"
    elect_egress_node
    oc patch hostsubnet $EGRESS_NODE --config admin.kubeconfig -p '{"egressIPs":["abcd"]}'
    step_fail
    oc patch hostsubnet $EGRESS_NODE --config admin.kubeconfig -p '{"egressIPs":["fe80::5054:ff:fedd:3698"]}'
    step_fail
    oc patch hostsubnet $EGRESS_NODE --config admin.kubeconfig -p '{"egressIPs":["a.b.c.d"]}'
    step_fail
    oc patch hostsubnet $EGRESS_NODE --config admin.kubeconfig -p '{"egressIPs":["256.256.256.256"]}'
    step_fail
    oc patch hostsubnet $EGRESS_NODE --config admin.kubeconfig -p '{"egressIPs":["10.66.140.100/32"]}'
    step_fail
    oc patch hostsubnet $EGRESS_NODE --config admin.kubeconfig -p '{"egressIPs":["8.8.8.-1"]}'
    step_fail
}

function test_add_remove_egressip(){
    echo -e "$BBlue Test OCP-18315 [bz1547899] Add the removed egressIP back to the netnamespace would work well. $NC"
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    assign_egressIP_to_node
    assign_egressIP_to_netns $PROJECT
    # remove the egressIP on netnamespace
    echo -e "$BBlue Remove the egressIP from the netnamespace $NC"
    oc patch netnamespace $PROJECT -p "{\"egressIPs\":[]}" --config admin.kubeconfig
    # sleep some time to wait for the egressIP ready
    sleep 15
    for p in ${pod}
    do
      access_external_network $p $PROJECT | grep $EGRESS_IP
      step_fail
      access_external_network $p $PROJECT 
      step_pass
    done
    # add the egressIP back
    echo -e "$BBlue Add the egressIP back to the netnamespace $NC"
    assign_egressIP_to_netns $PROJECT
    # sleep some time to wait for the egressIP ready
    sleep 15
    for p in ${pod}
    do
      access_external_network $p $PROJECT 
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP
      step_pass
    done
    clean_up_egressIPs
    oc delete all --all -n $PROJECT
    sleep 15
}

function test_switch_egressip(){
    echo -e "$BBlue Test OCP-18434 [bz1553297] Should be able to change the egressIP of the project when there are multiple egressIPs set to nodes. $NC"
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    elect_egress_node
    echo -e "$BBlue Add multiple egressIP to different node $NC"
    oc patch hostsubnet $EGRESS_NODE -p "{\"egressIPs\":[\"$EGRESS_IP\",\"$EGRESS_IP2\"]}" --config admin.kubeconfig
    OTHER_NODE=`oc get node -l node-role.kubernetes.io/compute=true --config admin.kubeconfig -o jsonpath='{.items[*].metadata.name}' | sed "s/$EGRESS_NODE//" | cut -d " " -f2 | tr -d " "`
    oc patch hostsubnet $OTHER_NODE -p "{\"egressIPs\":[\"$EGRESS_IP3\"]}" --config admin.kubeconfig
    assign_egressIP_to_netns $PROJECT
    sleep 15
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP
      step_pass
    done
    assign_egressIP_to_netns $PROJECT $EGRESS_IP2
    sleep 15
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP2
      step_pass
    done
    assign_egressIP_to_netns $PROJECT $EGRESS_IP3
    sleep 15
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP3
      step_pass
    done
    clean_up_egressIPs
    oc delete all --all -n $PROJECT
    sleep 15
}

function test_reuse_egressip(){
    echo -e "$BBlue Test OCP-18316 [bz1543786] The egressIPs should work well when re-using the egressIP which is holding by a deleted project. $NC"
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    assign_egressIP_to_node
    assign_egressIP_to_netns $PROJECT
    sleep 15
    # delete the project
    echo -e "$BBlue Delete the project $NC"
    oc delete project $PROJECT
    
    until [ `oc get project | grep $PROJECT | wc -l` -eq 0 ]
    do
      echo -e "Waiting for project to be deleted on server"
      sleep 5
    done
    echo -e "$BBlue Remove the egressIP from node $NC"
    oc patch hostsubnet $EGRESS_NODE -p "{\"egressIPs\":[]}" --config admin.kubeconfig
    NEWPROJECT=newegress
    create_project $NEWPROJECT
    oc project $NEWPROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $NEWPROJECT
    wait_for_pod_running test-rc 2 $NEWPROJECT
    pod=$(oc get po -n $NEWPROJECT | grep Running | cut -d' ' -f1)
    assign_egressIP_to_node
    sleep 15
    for p in ${pod}
    do
      access_external_network $p $NEWPROJECT
      step_pass
      access_external_network $p $NEWPROJECT
      step_pass
    done
    echo -e "$BBlue Delete the project for the 2nd time $NC"
    oc delete project $NEWPROJECT
    until [ `oc get project | grep $NEWPROJECT | wc -l` -eq 0 ]
    do
      echo -e "Waiting for project to be deleted on server"
      sleep 5
    done
    echo -e "$BBlue Remove the egressIP from node 2nd time $NC"
    oc patch hostsubnet $EGRESS_NODE -p "{\"egressIPs\":[]}" --config admin.kubeconfig
    create_project $PROJECT
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    assign_egressIP_to_node
    assign_egressIP_to_netns $PROJECT
    sleep 15
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP
      step_pass
    done
    clean_up_egressIPs
    oc delete all --all -n $PROJECT
    sleep 15
}

function test_single_egressCIDR() {
    echo -e "$BBlue Test OCP-18581 The egressIP could be assigned to project automatically once it is defined in hostsubnet egressCIDR. $NC"
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    assign_egressCIDR_to_node
    assign_egressIP_to_netns $PROJECT
    sleep 15
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP
      step_pass
    done
    assign_egressIP_to_netns $PROJECT $EGRESS_IP2
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP2
      step_pass
    done
    assign_egressIP_to_netns $PROJECT $EGRESS_IP3
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP3
      step_pass
    done
    EGRESS_IP_OOR=10.1.1.100
    assign_egressIP_to_netns $PROJECT $EGRESS_IP_OOR
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_fail
    done
    clean_up_egressIPs
    oc delete all --all -n $PROJECT
    sleep 15
}

function test_multiple_egressCIDRs() {
    echo -e "$BBlue Test OCP-20011 The egressIP could be assigned to project automatically when the hostsubnet has multiple egressCIDRs specified. $NC"
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    assign_egressCIDR_to_node "10.66.140.96/28\",\"10.66.140.200/29\",\"10.66.141.250/32"
    assign_egressIP_to_netns $PROJECT
    sleep 15
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP
      step_pass
    done
    assign_egressIP_to_netns $PROJECT $EGRESS_IP2
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP2
      step_pass
    done
    assign_egressIP_to_netns $PROJECT $EGRESS_IP3
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_pass
      access_external_network $p $PROJECT | grep $EGRESS_IP3
      step_pass
    done
    EGRESS_IP_OOR=10.66.140.180
    assign_egressIP_to_netns $PROJECT $EGRESS_IP_OOR
    for p in ${pod}
    do
      access_external_network $p $PROJECT
      step_fail
    done
    clean_up_egressIPs
    oc delete all --all -n $PROJECT
    sleep 15
}

function clean_up_resource(){
    echo -e "$BBlue Delete all resources in project $NC"
    oc delete all --all -n $PROJECT ; sleep 20
}

if [ -z $USE_PROXY ]
    then
    set_proxy
fi

PROJECT=newegressproject
LOCAL_SERVER=`ping fedorabmeng.usersys.redhat.com -c1  | grep ttl | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'`
external_service=$EXTERNAL_SERVICE

prepare_user
clean_node_egressIP
check_ip

oc version

if ( $OCP15465 ); then
test_only_cluster_admin_can_modify
fi
echo -e "\n\n\n\n"
if ( $OCP15467 ); then
test_egressip_to_multi_netns
fi
echo -e "\n\n\n\n"
if ( $OCP15469 ); then
test_no_node_with_egressip
fi
echo -e "\n\n\n\n"
if ( $OCP15471 ); then
test_pods_through_egressip
fi
echo -e "\n\n\n\n"
if ( $OCP15472 ); then
test_node_nic
fi
echo -e "\n\n\n\n"
if ( $OCP15473 ); then
test_iptables_openflow_rules
fi
echo -e "\n\n\n\n"
if ( $OCP15474 ); then
test_multi_egressip
fi
echo -e "\n\n\n\n"
if ( $OCP15987 ); then
test_egressip_to_multi_host
fi
echo -e "\n\n\n\n"
if ( $OCP15989 ); then
test_pods_in_other_project
fi
echo -e "\n\n\n\n"
if ( $OCP15996 ); then
test_access_egressip
fi
echo -e "\n\n\n\n"
if ( $OCP15998 ); then
test_negative_values
fi
echo -e "\n\n\n\n"
if ( $OCP15992 ); then
test_egressnetworkpolicy_with_egressip
fi
echo -e "\n\n\n\n"
if ( $OCP18315 ); then
test_add_remove_egressip
fi
echo -e "\n\n\n\n"
if ( $OCP18434 ); then
test_switch_egressip
fi
echo -e "\n\n\n\n"
if ( $OCP18316 ); then
test_reuse_egressip
fi
echo -e "\n\n\n\n"
if ( $egressCIDR ); then
  test_single_egressCIDR
  test_multiple_egressCIDRs
fi
echo -e "\n\n\n\n"

# clean all in the end
oc delete project $PROJECT || true
oc delete project project2 || true
oc delete egressnetworkpolicy default -n default --config admin.kubeconfig || true
