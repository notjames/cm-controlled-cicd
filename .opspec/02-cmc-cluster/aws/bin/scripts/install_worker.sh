#!/usr/bin/env bash

JOIN_STR_FILE="$1"
SERVICE_CIDR=10.96.0.0/12
POD_CIDR=10.24.0.0/16
CLUSTER_DNS_DOMAIN=cluster.local
KUBELET_VERSION=1.10.6
OUTPUT_LOG="/var/log/startup.log"
HELM_VERSION="2.11.0"

export JOIN_STR_FILE KUBELET_VERSION SERVICE_CIDR POD_CIDR \
       MASTER_IP CLUSTER_DNS_DOMAIN HELM_VERSION

if [[ -z $JOIN_STR_FILE ]];  then
  echo >&2 "Cannot continue. The \$JOIN_STR was not supplied."
  exit 13
else
  if JOIN_STR=$(< "$JOIN_STR_FILE"); then
    MASTER_IP=$(echo "$JOIN_STR" | grep -Po '(\d{1,3}\.){3}\d{1,3}')
  else
    echo >&2 "Unable to read file '$JOIN_STR_FILE'."
    exit  14
  fi
fi

if ! source common_functions.sh; then
  echo >&2 "Unable to source functions script."
  exit 15
fi

if ! install_docker | sudo tee -a $OUTPUT_LOG; then
  echo >&2 "Unable to install docker."
  exit 16
fi

if ! install_k8s_w_yum | sudo tee -a $OUTPUT_LOG; then
  echo >&2 "Unable to install yum."
  exit 17
fi

if ! configure_kubeadm | sudo tee -a $OUTPUT_LOG; then
  echo >&2 "Unable to configure kubeadm."
  exit 18
fi

if ! configure_kubelet_systemd | sudo tee -a $OUTPUT_LOG; then
  echo >&2 "Unable to configure kubelet systemd."
  exit 19
fi

if ! run_kubeadm_join "$JOIN_STR" | sudo tee -a $OUTPUT_LOG; then
  echo >&2 "Unable to join kubeadm master."
  exit 20
fi

## XXX the following two expressions don't work 100% yet - jconner
if ! install_helm $HELM_VERSION | sudo tee -a $OUTPUT_LOG; then
  echo >&2 "Unable to install helm."
  exit 22
fi

if ! install_cma_charts | sudo tee -a $OUTPUT_LOG; then
  echo >&2 "Charts installation failed."
  exit 23
fi

#   generate machine.yaml and then
#   curl POST machine.yaml


