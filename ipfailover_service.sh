#!/bin/bash
node1=ose-node1.bmeng.local
node2=ose-node2.bmeng.local
ip="10.66.140.105-106"

# check ips
for i in 105 106
do
ping -c1 10.66.140.$i
if [ $? -ne 1 ]
then
exit
fi
done

# add labels to node
oc label node $node1 ha-service=ha --overwrite
oc label node $node2 ha-service=ha --overwrite

# create router on each node
oc adm policy add-scc-to-user privileged -z default
oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/ha-network-service.json

# wait the routers are running
while [ `oc get pod | grep ha | grep Running | wc -l` -lt 2 ]
do
  sleep 5
done

oc patch svc ha-service -p '{"spec": {"ports": [{"port":9736,"targetPort":8080}]}}'
oc patch svc ha-service -p '{"spec": {"type":"NodePort"}}'

nodeport=`oc get svc ha-service -o jsonpath={.spec.ports[0].nodePort}`
# for i in $node1 $node2 ;do curl $i:9736 ; done

# create ipfailover for each router
oc adm policy add-scc-to-user privileged -z ipfailover
oc adm ipfailover ipf --create --selector=ha-service=ha --virtual-ips=${ip} --watch-port=${nodeport} --replicas=2 --service-account=ipfailover --interface=eth0

# wait the keepaliveds are running
while [ `oc get pod | grep ipf | grep -v deploy | grep Running | wc -l` -lt 2 ]
do
  sleep 5
done

for i in $node1 $node2 ;do curl $i:$nodeport ; done
