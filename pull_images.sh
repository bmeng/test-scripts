#/bin/bash
image_version=`curl -s $REPO_URL | grep -oE 'atomic-openshift-3.[0-9]{2}.[0-9]{1,3}[,-][0-9]{1,3}.[0-9]{1,3}.[0-9]' | cut -d- -f3- | uniq`
image_tag=v${image_version}.0
main_version=v$(echo $image_version | cut -d- -f1)
old_image_version=`cat /tmp/image_version`

if [[ $image_version != $old_image_version ]]
then 
    ssh bmeng@fedorabmeng.usersys.redhat.com "sudo docker rmi -f $(sudo docker images | grep "$main_version" |awk '{print $3}' | uniq)"
    ssh bmeng@fedorabmeng.usersys.redhat.com "sync_images $image_tag brew-pulp-docker01.web.prod.ext.phx2.redhat.com:8888/openshift3"
    touch /tmp/image_version
    echo -e $image_version > /tmp/image_version
fi
