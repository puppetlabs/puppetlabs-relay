#!/bin/bash

version=`puppet --version`

if [ -z "$version" ]; then
  PE_FILE_NAME=puppet-enterprise-2019.5.0-ubuntu-16.04-amd64
  #PE_FILE_NAME=puppet-enterprise-${PE_LATEST}-el-7-x86_64
  TAR_FILE=${PE_FILE_NAME}.tar
  DOWNLOAD_URL=https://artifactory.delivery.puppetlabs.net/artifactory/generic_enterprise__local/2019.5/release/ci-ready/${TAR_FILE}

  ## Download PE
  curl -o ${TAR_FILE} ${DOWNLOAD_URL}
  if [[ $? -ne 0 ]];then
    echo “Error: wget failed to download [${DOWNLOAD_URL}]”
    exit 2
  fi

  ## Install PE
  tar xvf ${TAR_FILE}
  if [[ $? -ne 0 ]];then
    echo “Error: Failed to untar [${TAR_FILE}]”
    exit 2
  fi

  cd ${PE_FILE_NAME}
  printf '1' | ./puppet-enterprise-installer
  if [[ $? -ne 0 ]];then
    echo “Error: Failed to install Puppet Enterprise. Please check the logs and call Bryan.x ”
    exit 2
  fi

  ## Finalize configuration
  echo “Finalize PE install”
  puppet agent -t

  puppet infra console_password --password=pie

  ## Create and configure Certs
  echo "autosign = true" >> /etc/puppetlabs/puppet/puppet.conf

  ## Setup the RBAC token
  echo 'pie' | puppet access login --lifetime 1y --username admin
fi

version=`puppet --version`

if [ -z "$version" ];  then
  echo 'puppet instaall failed'
  exit 1
fi
