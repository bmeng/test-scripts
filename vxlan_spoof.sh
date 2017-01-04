#!/bin/bash
project=u1p1
node_ip=10.66.140.165

oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/udp4789-pod.json -n $project

while [ `oc get po -n $project | grep udp4789-pod | grep Running | wc -l` -ne 1 ]
do
sleep 5
done

pod_ip=`oc get po udp4789-pod -n $project --template={{.status.podIP}}`
pod_mac=`oc exec udp4789-pod -n $project -- ip a s eth0 | grep ether | awk -F' ' '{print $2}'`

ip link add vxlan0 type vxlan id 0 dstport 4789 remote $node_ip

attacker_ip=`echo $pod_ip | sed 's/..$/15/g'`
ip addr add $attacker_ip/23 dev vxlan0

ip route

ip link set vxlan0 up

arp -s $pod_ip $pod_mac

sleep 10

(echo test) | nc -u $pod_ip 4789

oc logs udp4789-pod -n $project

ip link delete vxlan0
