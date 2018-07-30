#!/bin/bash
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
    oc delete project $NEWPROJECT
    echo -e "$BBlue Delete the $NEWPROJECT if already existed. $NC"
    until [ `oc get project | grep $NEWPROJECT | wc -l` -eq 0 ]
    do
      echo -e "Waiting for project2 to be deleted on server"
      sleep 5
    done
    sleep 10
    # create project
    create_project $PROJECT
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

function access_external_network(){
    echo -e "$BBlue Access external network $NC"
    local pod=$1
    local project=$2
    oc exec $pod -n $project -- curl -sS --connect-timeout 10 $external_service
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

function test_first_available_item() {
    echo -e "$BBlue Test OCP-19961 The first egressIP in the netnamespace list which is claimed by node will take effect. $NC"
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    elect_egress_node
    # Add multiple egressIP to project and the 2nd one will be claimed by node
    oc patch netnamespace $PROJECT -p "{\"egressIPs\":[\"$NS_EGRESS_IP\",\"$NS_EGRESS_IP2\"]}" --config admin.kubeconfig
    # Add multiple egressIP to node 
    oc patch hostsubnet $EGRESS_NODE -p "{\"egressIPs\":[\"$HOST_EGRESS_IP\",\"$HOST_EGRESS_IP2\"]}" --config admin.kubeconfig
    # sleep sometime to make sure the egressIP ready
    sleep 15
    # Try to access outside with the source IP on the 2nd place
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    for p in ${pod}
    do
      access_external_network $p $PROJECT | grep $NS_EGRESS_IP2
      step_pass
      access_external_network $p $PROJECT | grep $NS_EGRESS_IP2
      step_pass
    done
    # Try to addnew egressIPs to new node, which claimed the 1st item in project egressIP array
    SECOND_NODE=`oc get node --config admin.kubeconfig -o jsonpath='{.items[*].metadata.name}' | sed "s/$EGRESS_NODE//" | cut -d " " -f1 | tr -d " "`
    oc patch hostsubnet ${SECOND_NODE} -p "{\"egressIPs\":[\"$HOST_EGRESS_IP3\",\"$HOST_EGRESS_IP4\"]}" --config admin.kubeconfig
    # Try to access outside and the 1st egressIP will take effect
    for p in ${pod}
    do
      access_external_network $p $PROJECT | grep $NS_EGRESS_IP
      step_pass
      access_external_network $p $PROJECT | grep $NS_EGRESS_IP
      step_pass
    done
    oc delete all --all -n $PROJECT
    clean_up_egressIPs
    sleep 10
}


function test_egressip_not_in_first_place_being_used_by_other_project() {
    echo -e "$BBlue Test OCP-19964 The traffic on the project will be dropped if any of the egressIPs is being used in another project. $NC"
    oc project $PROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $PROJECT
    wait_for_pod_running test-rc 2
    # Add multiple egressIP to project
    oc patch netnamespace $PROJECT -p "{\"egressIPs\":[\"$NS_EGRESS_IP\",\"$NS_EGRESS_IP2\",\"$NS_EGRESS_IP3\"]}" --config admin.kubeconfig
    # Add the egress IP to host which claiming the 1st ip
    elect_egress_node
    oc patch hostsubnet $EGRESS_NODE -p "{\"egressIPs\":[\"$HOST_EGRESS_IP\"]}" --config admin.kubeconfig
    sleep 15
    # Try to access outside
    pod=$(oc get po -n $PROJECT | grep Running | cut -d' ' -f1)
    for p in ${pod}
    do
      access_external_network $p $PROJECT | grep $NS_EGRESS_IP
      step_pass
      access_external_network $p $PROJECT | grep $NS_EGRESS_IP
      step_pass
    done
    # Add egress to another project which is the same as the one in project1's secondary egressIP
    oc project $NEWPROJECT
    oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/list_for_pods.json -n $NEWPROJECT
    wait_for_pod_running test-rc 2
    oc patch netnamespace $NEWPROJECT -p "{\"egressIPs\":[\"$NS_EGRESS_IP2\"]}" --config admin.kubeconfig
    # Try to access outside with both project
    for p in ${pod}
    do
      access_external_network $p $PROJECT 
      step_fail
      access_external_network $p $PROJECT 
      step_fail
    done
    for p in ${pod}
    do
      access_external_network $p $NEWPROJECT 
      step_fail
      access_external_network $p $NEWPROJECT 
      step_fail
    done
    # Update the 2nd project to use the 3rd egressIP of project 1
    oc patch netnamespace $NEWPROJECT -p "{\"egressIPs\":[\"$NS_EGRESS_IP3\"]}" --config admin.kubeconfig
    # Try to access outside with both project
    for p in ${pod}
    do
      access_external_network $p $PROJECT 
      step_fail
      access_external_network $p $PROJECT 
      step_fail
    done
    for p in ${pod}
    do
      access_external_network $p $NEWPROJECT 
      step_fail
      access_external_network $p $NEWPROJECT 
      step_fail
    done
    oc delete all --all -n $PROJECT
    oc delete project $NEWPROJECT
    clean_up_egressIPs
    sleep 10
}

function test_egressip_change_node() {

}

function test_keep_using_same_egressip() {

}

PROJECT=haegress
NEWPROJECT=newhaegress

test_first_available_item
test_egressip_not_in_first_place_being_used_by_other_project
