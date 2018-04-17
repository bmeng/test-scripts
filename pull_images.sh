#/bin/bash
image_version=`curl -s $REPO_URL | grep -oE 'atomic-openshift-3.[0-9]{2}.[0-9]{1,3}[,-][0-9]{1,3}.[0-9]{1,3}.[0-9]' | cut -d- -f3- | uniq`
image_tag=v${image_version}.0
old_image_version=`cat /tmp/image_version`

if [[ $image_version != $old_image_version ]]
then 
    ssh bmeng@fedorabmeng.usersys.redhat.com "sync_images $image_tag brew-pulp-docker01.web.prod.ext.phx2.redhat.com:8888/openshift3"
    touch /tmp/image_version
    echo -e $image_version > /tmp/image_version
fi
