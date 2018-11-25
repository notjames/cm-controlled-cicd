#!/usr/bin/env bash

# https://github.com/samsung-cnct/cluster-api-provider-ssh/blob/master/cloud/ssh/actuators/machine/setupconfigs_metadata.go
#KUBELET_VERSION={{ .Machine.Spec.Versions.Kubelet }}
#VERSION=v${KUBELET_VERSION}
#NAMESPACE={{ .Machine.ObjectMeta.Namespace }}
#MACHINE_NAME={{ .Machine.ObjectMeta.Name }}
#MACHINE=$NAMESPACE
#MACHINE+="/"
#MACHINE+=$MACHINE_NAME
#CONTROL_PLANE_VERSION={{ .Machine.Spec.Versions.ControlPlane }}
#CLUSTER_DNS_DOMAIN={{ .Cluster.Spec.ClusterNetwork.ServiceDomain }}
#POD_CIDR={{ .PodCIDR }}
#SERVICE_CIDR={{ .ServiceCIDR }}
#MASTER_IP={{ .MasterIP }}

SERVICE_CIDR=10.96.0.0/12
POD_CIDR=10.24.0.0/16
MASTER_IP="$(curl -s http://169.254.169.254/2018-09-24/meta-data/public-ipv4)"
CLUSTER_DNS_DOMAIN=cluster.local
KUBELET_VERSION=1.10.6
OUTPUT_LOG="/var/log/startup.log"

export KUBELET_VERSION SERVICE_CIDR POD_CIDR MASTER_IP CLUSTER_DNS_DOMAIN

# shellcheck disable=SC1091
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

if ! run_kubeadm_master | sudo tee -a $OUTPUT_LOG; then
  echo >&2 "Unable to start kubeadm master."
  exit 20
fi
