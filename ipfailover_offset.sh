#!/bin/bash
node1=ose-node1.bmeng.local
node2=ose-node2.bmeng.local
ip1="10.66.140.100-101"
ip2="10.66.140.102-103"

# check ips
for i in 100 101 102 103
do
ping -c 1 10.66.140.$i
if [ $? -ne 1 ]
then
exit
fi
done

# add labels to node
oc label node $node1 ha=red --overwrite
oc label node $node2 ha=blue --overwrite

# create router on each node
oadm policy add-scc-to-user hostnetwork -z router
oadm router router-red --selector=ha=red
oadm router router-blue --selector=ha=blue

# wait the routers are running
while [ `oc get pod | grep -v deploy| grep Running | wc -l` -lt 2 ]
do
sleep 5
done

# create ipfailover for each router
oadm policy add-scc-to-user privileged -z ipfailover
oadm ipfailover ipf-red --create --selector=ha=red --virtual-ips=${ip1} --watch-port=80 --replicas=1 --service-account=ipfailover 
oadm ipfailover ipf-blue --create --selector=ha=blue --virtual-ips=${ip2} --watch-port=80 --replicas=1 --service-account=ipfailover --vrrp-id-offset=50

# wait the keepaliveds are running
while [ `oc get pod | grep -v deploy | grep ipf | grep Running | wc -l` -lt 2 ]
do
sleep 5
done
