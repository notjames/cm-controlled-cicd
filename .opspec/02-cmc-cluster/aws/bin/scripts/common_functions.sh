
install_docker()
{
  local docker_service
  docker_service='/usr/lib/systemd/system/docker.service'

  # Our current kubeadm doesn't work right with docker-ce 18.3 provided
  # by our currently used AMI. Also, we want to know we're getting the
  # stock provided docker for the system on the pod everytime. So we'll just
  # remove and reinstall docker every time we install.

  if docker_rpms="$(rpm -qa 'docker*')"; then
    sudo yum remove -y "$docker_rpms"
  fi

  sudo yum install -y docker

  if [[ ! -f "$docker_service" ]]; then
    echo >&2 'Cannot update docker.service file. "$docker_service" does not exist.'
    return 1
  fi

  if [[ $(grep -c "native.cgroupdriver=systemd" "$docker_service" 2>/dev/null) == 0 ]]; then
    if ! sudo sed -r -i 's#^(ExecStart=/usr/bin/dockerd)#\1 --exec-opt native.cgroupdriver=systemd --exec-opt runtime-cgroups=/systemd/system.slice --exec-opt kubelet-cgroups=/systemd/system.slice --exec-opt MountFlags=private#' \
         "$docker_service"; then
      echo >&2 "Unable to update '$docker_service' with proper cgroupdriver."
      return 1
    fi
  else
    echo >&2 "WARNING: Looks like '$docker_service' was already updated. Skipping."
  fi

  if sudo cp /dev/stdin /etc/sysconfig/docker <<< 'DOCKER_OPTS="--iptables=false --ip-masq=false"'; then
    [[ -z ${USER+x} ]] && USER=$(whoami)
    sudo usermod -a -G docker "$USER"
    sudo chmod 640 /etc/sysconfig/docker
  else
    echo >&2 "Unable to update /etc/sysconfig/docker."
    return 1
  fi

  if ! sudo systemctl enable --now docker;then
    echo >&2 "Unable to 'systemctl enable docker'. Quitting."
    return 1
  fi

  if ! sudo systemctl daemon-reload; then
    echo >&2 "Unable to reload systemctl daemon."
    return 1
  fi

  if sudo systemctl restart docker.service; then
    echo "docker is installed successfully."
  fi
}

prune_kubeadm_env()
{
  local kubeadmenv_dir kubeadmenv_file

  kubeadmenv_dir="/var/lib/kubelet"
  kubeadmenv_file="$kubeadmenv_dir/kubeadm-flags.env"

  # See https://samsung-cnct.atlassian.net/browse/CMS-391
  # If the file exists, grok it first (preserving current settings)
  if [[ -d $kubeadmenv_dir ]]; then
    if [[ -f "$kubeadmenv_file" ]]; then
      source "$kubeadmenv_file"

      # change the one we want to change
      if [[ -n $KUBELET_KUBEADM ]]; then
        if [[ $(echo "$KUBELET_KUBEADM_ARGS" | grep -c "--cgroup-driver=systemd") == 0 ]]; then
          if ! sudo sed -r -i."$(date +%Y%m%dT%H%M%s)" 's/"(.*)"/"\1 --cgroup-driver-systemd"/' "$kubeadmenv_file"; then
            echo >&2 "FATAL: Unable to fix cgroupfs driver in $kubeadmenv_file"
            return 1
          fi
        else
          if ! echo "KUBELET_KUBEADM_ARGS=--cgroup-driver=systemd" | sudo tee "$kubeadmenv_file"; then
            echo >&2 "Unable to create $kubeadmenv_file!"
            return 1
          fi
        fi
      fi
    else
      sudo cp /dev/stdin "$kubeadmenv_file" <<< \
      "KUBELET_KUBEADM_ARGS=--cgroup-driver=systemd"
      sudo chmod 644 "$kubeadmenv_file"
    fi
  fi
}

fix_kubelet_config()
{
  config="/var/lib/kubelet/config.yaml"
  sudo sed -r -i 's#cgroupDriver: cgroupfs#cgroupDriver: systemd#' $config
}

install_k8s_w_yum()
{
  if [[ -z $KUBELET_VERSION ]]; then
    echo >&2 "FATAL: \$KUBELET_VERSION is nil! Cannot continue."
    return 1
  fi

  sudo yum install -y createrepo

  # Set SELinux in permissive mode (effectively disabling it)
  sudo setenforce 0
  sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config]

  # copy rpms from tools container
  toolsImage=$(sudo docker create quay.io/samsung_cnct/cm-vmware-bootstrap)
  sudo docker cp ${toolsImage}:/resources/rpms/ /var/log/rpms
  sudo docker cp ${toolsImage}:/resources/yaml/kube-flannel.yml /var/log/kube-flannel.yml

  # setup yum repositories
  sudo createrepo /var/log/rpms/1.10.6
  sudo createrepo /var/log/rpms/1.11.2

  sudo cp /dev/stdin /etc/yum.repos.d/kubernetes-old.repo <<< "[kubernetes-old]
    name=Kubernetes-old
    baseurl=file:///var/log/rpms/1.10.6
    enabled=1
    gpgcheck=0
    repo_gpgcheck=0"

  sudo cp /dev/stdin /etc/yum.repos.d/kubernetes-new.repo <<< "[kubernetes-new]
    name=Kubernetes-new
    baseurl=file:///var/log/rpms/1.11.2
    enabled=1
    gpgcheck=0
    repo_gpgcheck=0"

  sudo sed -r -i 's#^\ +##g' /etc/yum.repos.d/kubernetes-{old,new}.repo
  sudo yum clean all

  # TODO: kubernetes-new is hardcoded with 1.11.2
  # TODO: kubernetes-old is hardcoded with 1.10.6
  sudo yum --disablerepo='*' --enablerepo=kubernetes-old -y install kubelet
  sudo yum --disablerepo='*' --enablerepo=kubernetes-old -y install kubectl
  sudo yum --disablerepo='*' --enablerepo=kubernetes-old -y install kubeadm

  # prune arg we want to change
  prune_kubeadm_env

  sudo systemctl enable kubelet && sudo systemctl start kubelet
}

# This function should only be used by install_k8s_w_curl(). Yum already
# handles all this stuff.
bootstrap_k8s_systemd()
{
  sudo cp /dev/stdin /etc/systemd/system/kubelet.service <<< '[Unit]
    Description=kubelet: The Kubernetes Node Agent
    Documentation=https://kubernetes.io/docs/

    [Service]
    ExecStart=/usr/bin/kubelet
    Restart=always
    StartLimitInterval=0
    RestartSec=10

    [Install]
    WantedBy=multi-user.target' | \

    sudo sed -r -i 's#^\ +##g' /etc/systemd/system/kubelet.service

  sudo mkdir -p /etc/systemd/system/kubelet.service.d
  sudo cp /dev/stdin /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<< '[Service]
    Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
    Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
    # This is a file that "kubeadm init" and "kubeadm join" generates at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
    EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
    # This is a file that the user can use for overrides of the kubelet args as a last resort. Preferably, the user should use
    # the .NodeRegistration.KubeletExtraArgs object in the configuration files instead. KUBELET_EXTRA_ARGS should be sourced from this file.
    EnvironmentFile=-/etc/sysconfig/kubelet
    ExecStart=
    ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS' | \

    sudo sed -r -i 's#^\ +##g' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
}

yum_upgrade_master()
{

  # TODO: kubernetes-new is hardcoded with 1.11.2
  sudo yum --disablerepo='*' --enablerepo=kubernetes-new -y install kubelet
  sudo yum --disablerepo='*' --enablerepo=kubernetes-new -y install kubectl
  sudo yum --disablerepo='*' --enablerepo=kubernetes-new -y install kubeadm

  if ! fix_kubelet_config; then
    return 1
  fi

  sudo systemctl daemon-reload
  sudo systemctl restart kubelet
}

yum_upgrade_node()
{
  p="/usr/bin/kubeadm"
  CONTROL_PLANE_VERSION=${CONTROL_PLANE_VERSION:-$KUBELET_VERSION}
  app_url="https://storage.googleapis.com/kubernetes-release/release/v${CONTROL_PLANE_VERSION}/bin/linux/amd64/kubeadm"

  # TODO: kubernetes-new is hardcoded with 1.11.2
  sudo yum --disablerepo='*' --enablerepo=kubernetes-new -y install kubelet
  sudo yum --disablerepo='*' --enablerepo=kubernetes-new -y install kubectl
  sudo yum --disablerepo='*' --enablerepo=kubernetes-new -y install kubeadm

  # The purpose of this is that for some reason, ytbd, it seems the CMC pushes
  # or causes a download of the most recent version of kubeadm. This forces
  # getting the correct binary until we figure out what's going on.
  if status=$(sudo curl -sL "$app_url" -o $p -w '{"status":"%{http_code}"}'); then
    if [[ "$status" =~ 200 ]]; then
      sudo chmod 755 /usr/bin/kubeadm
    else
      return 1
    fi
  else
    return 1
  fi

  # https://github.com/kubernetes/kubernetes/issues/65863
  # Issue exists where when upgrading to >= 1.11.x, the /var/lib/kubelet/config.yaml
  # missing causes kubelet not to restart, which causes the node to not start/join
  # after an upgrade. One other fun-fact to note is that the config.yaml changes the
  # the cgroupfs driver back to cgroupfs when we use systemd.

  sudo kubeadm upgrade node config --kubelet-version $(kubelet --version | cut -d ' ' -f 2)

  # if this fails, it might be because the upgrade ^^^ failed.
  if ! fix_kubelet_config; then
    echo >&2 "Unable to fixup /var/l"
    return 1
  fi

  sudo systemctl daemon-reload
  sudo systemctl restart kubelet
}

fix_etc_hosts()
{
  local add new_entry hosts
  declare -a hosts

  # chk and fix /etc/hosts
  hosts=(quay.io gcr.io k8s.gcr.io registry-1.docker.io docker.io packages.cloud.google.com)
  new_entry="$current_entry"
  add=0

  for h in "${hosts[@]}"; do
    if ! echo "$new_entry" | grep -q "$h"; then
      ((add++))
      new_entry+=" $h"
    fi
  done

  if [[ $add ]]; then
    # this next line comments out the current entry
    if ! sed -r -i "s/^($current_entry)/#\1/" /etc/hosts; then
      # put the original back
      echo >&2 "Unable to correctly in-line edit /etc/hosts. Restoring from backup."

      if ! mv "$bu_etc_hosts_file" /etc/hosts; then
        echo >&2 "Unable to restore backup $bu_etc_hosts_file -> /etc/hosts"
      fi

      return 1
    fi

    # append new entry to /etc/hosts
    echo "$new_entry" >> /etc/hosts
    rc=$?

    if [[ "$rc" -gt 0 ]]; then
      echo >&2 "Unable to append new entry into /etc/hosts."
      return 1
    fi
  fi
}

prips()
{
  cidr=$1

  # range is bounded by network (-n) & broadcast (-b) addresses.
  # the following uses `read` with a here-statement to assign the output of
  # ipcalc -bn into two variables; $hi and $lo the output of which is cut and then
  # delimited by a ":". Read uses $IFS to automatically split on that delimiter.
  IFS=':' read -r hi lo <<< "$(ipcalc -bn "$cidr" | cut -f 2 -d = | sed -r 'N;s/\n/:/')"

  # similar to above only this is splitting on '.'.
  IFS='.' read -r a b c d <<< "$lo"
  IFS='.' read -r e f g h <<< "$hi"

  # kubeadm uses 10th IP as DNS server
  eval "echo {$a..$e}.{$b..$f}.{$c..$g}.{$d..$h}" | awk '{print $11}'
}

configure_kubelet_systemd()
{
  # configure kubelet
  sudo cp /dev/stdin /etc/systemd/system/kubelet.service.d/20-kubelet.conf <<< "[Service]
Environment='KUBELET_DNS_ARGS=--cluster-dns=${CLUSTER_DNS_SERVER} --cluster-domain=${CLUSTER_DNS_DOMAIN}'"
  sudo chmod 644 /etc/systemd/system/kubelet.service.d/20-kubelet.conf
  sudo systemctl enable --now kubelet
}

configure_kubeadm()
{
  sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
  sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1
  sudo sysctl -p

  if [[ $(systemctl is-active firewalld.service) == "active" ]]; then
     sudo systemctl disable --now firewalld
  fi

  # configure kubeadm
  sudo cp /dev/stdin /etc/kubernetes/kubeadm_config.yaml <<< "---
  apiVersion: kubeadm.k8s.io/v1alpha1
  kind: MasterConfiguration
  api:
    advertiseAddress: ${MASTER_IP}
    bindPort: 443
  etcd:
    local:
      dataDir: /var/lib/etcd
      image:
  kubernetesVersion: v${KUBELET_VERSION}
  token: ${TOKEN}
  kubeProxy:
    config:
      clusterCIDR: ${POD_CIDR}
  networking:
    dnsDomain: ${CLUSTER_DNS_DOMAIN}
    podSubnet: ${POD_CIDR}
    serviceSubnet: ${SERVICE_CIDR}
  "

  # YAML is whitespace picky. So, need to fix kubeadm_config
  sudo sed -r -i 's#^[[:blank:]]{2}##' /etc/kubernetes/kubeadm_config.yaml

  # Create and set bridge-nf-call-iptables to 1 to pass the kubeadm preflight check.
  # Workaround was found here:
  # http://zeeshanali.com/sysadmin/fixed-sysctl-cannot-stat-procsysnetbridgebridge-nf-call-iptables/
  if [[ $(sudo lsmod | grep br_netfilter -c) == 0 ]];then
    sudo modprobe br_netfilter
  fi

  # Allowing swap may not be reliable:
  # https://github.com/kubernetes/kubernetes/issues/53533
  sudo swapoff -a
}

run_kubeadm_master()
{
  if ! sudo kubeadm init --config /etc/kubernetes/kubeadm_config.yaml; then
    echo >&2 "Unable to start kubeadm."
    return 1
  fi

  for (( i = 0; i < 60; i++ )); do
    sudo kubectl --kubeconfig /etc/kubernetes/kubelet.conf annotate --overwrite node "$(hostname)" machine="${MACHINE}" && break
    sleep 1
  done

  # By default, use flannel for container network plugin, should make this configurable.
  sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f https://raw.githubusercontent.com/coreos/flannel/v0.10.0/Documentation/kube-flannel.yml
}

run_kubeadm_join()
{
  #sudo kubeadm join --token "${TOKEN}" "${MASTER}" --ignore-preflight-errors=all --discovery-token-unsafe-skip-ca-verification

  IFS=" " read -r g g ipaddr targ token darg sha <<< "$*"
  sudo kubeadm join "$targ" "$token" "$ipaddr" --ignore-preflight-errors=all "$darg" "$sha"

  mkdir -p "$HOME"/.kube
  sudo cp /etc/kubernetes/kubelet.conf "$HOME"/.kube/config
  sudo chown -R "$(stat -c '%u:%g' "$HOME")" "$HOME"/.kube

  for (( i = 0; i < 60; i++ )); do
    sudo kubectl --kubeconfig /etc/kubernetes/kubelet.conf annotate --overwrite node $(hostname) machine=${MACHINE} && break
    sleep 1
  done
}

drain()
{
  sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf drain $(hostname) --delete-local-data --ignore-daemonsets && \
  sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf delete node $(hostname)
}

teardown()
{
  error_occurred=0

  if ! sudo kubeadm reset --force; then
    echo >&2 "kubeadm version doesn't have 'reset --force' yet probably...trying without."
    if ! sudo kubeadm reset; then
      echo >&2 "Hmm, can't kubeadm reset..."
      ((error_occurred++))
    fi
  fi

  all_dockers=($(rpm -qa 'docker*'))
  sudo yum remove -y kubeadm kubectl kubelet kubernetes-cni "${all_dockers[@]}"

  RM_RF_DIRS="/etc/cni \
              /etc/docker \
              /etc/sysconfig/docker \
              /etc/ethertypes \
              /etc/kubernetes \
              /etc/systemd/system/kubelet.service.d \
              /var/lib/cni \
              /var/lib/docker \
              /var/lib/dockershim \
              /var/lib/etcd \
              /var/lib/etcd2 \
              /var/lib/kubelet"

  # sort doesn't need to be a for-loop, but leaving alone for now.
  for d in ${RM_RF_DIRS}; do
    # Note that an attempt to remove /var/lib/docker may fail
    # with some AMIs as /var/lib/docker is a mounted EBS.
    # As a result of the above, let's just try and remove everything in the
    # directory before removing the directory so that for those
    # directories that can't be force removed, at least we know
    # the stuff in them will be.
    sudo rm -rf "$d"
  done

  sudo yum -y clean all
  sudo rm -rf /var/cache/yum
}

install_helm()
{
  local helm_version
  helm_version=$1

  curl -sL https://storage.googleapis.com/kubernetes-helm/helm-v${helm_version}-linux-amd64.tar.gz | \
    tar zxf - linux-amd64/helm && sudo mv linux*/helm /usr/local/bin/helm
}

# XXX FIXME
# problem - vmware repo is private and cms-bootstrap quay repo is old.
install_cma_charts()
{
  __dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  helm init

  CMA_NAMESPACE=${CMA_NAMESPACE:-cma}

  if ! git clone https://github.com/samsung-cnct/vmware; then
    echo >&2 "Unable to clone vmware repo."
    return 1
  fi

  if cd vmware; then
    # Create namespace
    kubectl create ns ${CMA_NAMESPACE}

    # Install cluster api
    kubectl -n default -f ${__dir}/k8s/cma/clusterapi-apiserver.yaml
    #kubectl -n default -f ${__dir}/k8s/cma/provider-components.yaml

    # Install cma
    helm --name cma-operator --namespace ${CMA_NAMESPACE} install ${__dir}/../charts/cma-operator
    helm --name cma-vmware --namespace ${CMA_NAMESPACE} install ${__dir}/../charts/cma-vmware
    helm --name cma --namespace ${CMA_NAMESPACE} install ${__dir}/../charts/cluster-manager-api
  else
    echo >&2 "Unable to chdir to cloned vmware repo."
    return 1
  fi

  kubectl get all -n ${CMA_NAMESPACE}
}

install_provider_components()
{
  cd $HOME

  if ! git clone https://github.com/samsung-cnct/cluster-api-provider-ssh; then
    echo >&2 "Unable to clone cluster-api-provider-ssh"
    return 1
  fi

  if ! cd cluster-api-provider-ssh/clusterctl/example/ssh; then
    echo >&2 "Unable to chdir to generate provider-components.yaml"
    return 1
  fi

  if ./generate-yaml.sh; then
    kubectl -n default create -f provider-components.yaml
  fi
}
