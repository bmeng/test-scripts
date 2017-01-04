#!/bin/bash
egress_ip=10.66.140.100
egress_gw=10.66.141.254
egress_dest=10.3.11.3
project=u1p1
admin=admin.kubeconfig

#get version
version=`oc version | head -1 | cut -d' ' -f2 | cut -c -9`
egress_router_image="openshift3/ose-egress-router:$version"

#check ip
ping -c1 $egress_ip
if [ $? -ne 1 ]
then 
exit
fi

oc new-project $project
#add privileged scc to user
oadm policy add-scc-to-user privileged system:serviceaccount:$project:default --config=$admin

#create egress router pod with svc
curl -s https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/egress-ingress/egress-router-list.json | sed "s#egress-router-image#$egress_router_image#g;s#egress_ip#$egress_ip#g;s#egress_gw#$egress_gw#g;s#egress_dest#$egress_dest#g" | oc create -f - -n $project

while [ `oc get po -n $project | grep egress | grep Running | wc -l ` -ne 1 ]
do
sleep 10
done

egress_svc=`oc get svc egress-svc --template={{.spec.clusterIP}}`
egress_node=`oc get po -l name=egress-router -o wide | grep Running | awk -F' ' '{print $7}'`

#create pod for access the router
oc create -f https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/networking/pod-for-ping.json

while [ `oc get po -n $project | grep hello-pod | grep Running | wc -l ` -ne 1 ]
do
sleep 10
done

#access the router
oc exec hello-pod -- curl -sS $egress_svc:2015

#move the egress router to another node
while [ `oc get po -l name=egress-router -o wide | grep Running | awk -F' ' '{print $7}'` = $egress_node ]
do
oc delete po -l name=egress-router
sleep 20
done

while [ `oc get po -n $project | grep egress | grep Running | wc -l ` -ne 1 ]
do
sleep 10
done

#access the router again
oc exec hello-pod -- curl -sS $egress_svc:2015

#connect the node via the egress ip
telnet $egress_ip 22
