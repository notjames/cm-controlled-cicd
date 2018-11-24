#!/bin/bash
# shellcheck disable=SC2046,SC2140

err()
{
  echo >&2 "$*"
}

say()
{
  echo "$*"
}

get_managed_nodes()
{
  local cluster_id

  cluster_id=$1

  [[ -z ${cluster_id} ]] && \
  {
    err "Usage: get_managed_nodes(cluster_id)"
    return 50
  }

  q="Reservations[].Instances[]."
  q+="{"
  q+="  name:    Tags[? Key == 'Name'].Value | [0],"
  q+="  address: PublicIpAddress"
  q+="} | [? contains(name,'$cluster_id')] | "
  q+="{"
  q+="  manager_controllers: [? contains(name, 'managed') && contains(name,'control')],"
  q+="  manager_nodes: [? contains(name, 'managed') && contains(name, 'work')]"
  q+="}"

  aws ec2 describe-instances \
    --filter Name=instance-state-name,Values="running" \
    --query "$q"
}

get_manager_nodes()
{
  local cluster_id

  cluster_id=$1

  [[ -z ${cluster_id} ]] && \
  {
    err "Usage: get_managed_nodes(cluster_id)"
    return 50
  }

  q="Reservations[].Instances[]."
  q+="{"
  q+="  name:    Tags[? Key == 'Name'].Value | [0],"
  q+="  address: PublicIpAddress"
  q+="} | [? contains(name,'$cluster_id')] | "
  q+="{"
  q+="  manager_controllers: [? contains(name, 'manager') && contains(name,'control')],"
  q+="  manager_nodes: [? contains(name, 'manager') && contains(name, 'work')]"
  q+="}"

  aws ec2 describe-instances \
    --filter Name=instance-state-name,Values="running" \
    --query "$q"
}

#  {
#    "manager_controllers": [
#        {
#            "name": "control-manager-jimconn-test",
#            "address": "34.222.114.181"
#        }
#    ],
#    "manager_nodes": [
#        {
#            "name": "worker-manager-jimconn-test",
#            "address": "35.167.223.114"
#        }
#    ]
#  }

jo_control_planes()
{
  local nodes hostname

  nodes="$*"
  echo "$nodes"
  exit
  hostname=$(jq '.manager_controllers[].name' <<< "$nodes")

  jo username="$CLUSTER_USERNAME" port=22 password="" \
    labels=$(jo -a $(jo name=Name value="$hostname"))
}

jo_worker_nodes()
{
  local nodes hostname

  nodes="$*"
  echo "$nodes"
  exit
  hostname=$(jq '.worker_nodes[].name' <<< "$nodes")

  jo username="$CLUSTER_USERNAME" host="" port=22 password="" \
    labels=$(jo -a $(jo name=Name value="$hostname"))
}

create_worker_cluster_manifest()
{
  [[ -z "$*" ]] && \
    {
      echo >&2 "Requires nodes! Maybe none exist right now?"
      return 25
    }

  # jo -a $(jo username="centos" host=10.1.1.1 port=22 password="" labels=$(jo -a $(jo name=Name value="some_name"))) | jq --argjson m '{"managed_workers": [{"name": "managed-worker-jimconn-centos2","address": "34.210.121.198"}]}' '. | {"manager_nodes":$m[]}'

  #  jo -a $(jo manager_nodes=null username="centos" host=10.1.1.1 port=22 password="" labels=$(jo -a $(jo name=Name value="some_name"))) | jq --argjson m '[{"name": "managed-worker-jimconn-centos2","address": "34.210.121.198"}]' '.[].manager_nodes |= $m'

  # jq -n --arg 'CLUSTER_ID' 'test' --arg KUBELET_VERSION 1.10.6 --arg CLUSTER_PRIVATE_KEY "redacted" -f ../templates/main_jq.tmpl
  # jq -n --arg node_types "managed-master" --argjson labels '[{"Key":"nothing","Key2":"nothing"}]' --arg username centos --arg ipaddr 10.10.10.10 --arg password "" --arg port 22 -f ../templates/nodes_jq.tmpl

  jo name="$CLUSTER_ID" \
     k8s_version="$KUBELET_VERSION" \
     high_availability=true \
     network_fabric=flannel \
     api_endpont="" \
     private_key="$CLUSTER_PRIVATE_KEY" \
     control_plane_nodes=$(jo_control_planes "$nodes")\
     worker_nodes=$(jo_worker_nodes "$nodes") | \
     sed 's/null/""/g' | json2yaml -
}

check_reqs()
{
  pass=0

  for req in "${REQS[@]}"; do
    if ! which "$req" >/dev/null 2>&1; then
      err "pre-requisite: $req does not exist or is not in your PATH. Please fix then re-run."
    else
      ((pass++))
    fi
  done

  [[ $pass -ne "${#REQS[*]}" ]] && return 15
  return 0
}

usage()
{
  echo """
Usage: $0 <--get <manager|managed>> [--create-manifest|-c] [--help|-h]

  """
}


[[ -z $CLUSTER_ID ]] && \
  {
    echo >&2 "\$CLUSTER_ID env variable must be set."
    exit 16
  }

BASEDIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
OUTDIR=${BASEDIR}/out
KUBELET_VERSION=${KUBELET_VERSION:-1.10.6}
REQS=(aws yaml2json json2yaml jo jq)
create_manifest=0

create_cluster_yaml="$OUTDIR/create-$CLUSTER_ID.yaml"

[[ $# == 0 ]] && usage && exit 11

while [[ "$#" -gt 0 ]]; do
  arg=$1

  case $arg in
    --create-manifest|-c)
      create_manifest=1
      shift
    ;;
    --get|-g)
      shift
      what_to_get=$1
    ;;
    --help|-h)
      usage
      exit 12
    ;;
    *) echo "Do not understand argument: $arg"
       usage
       exit 10
    ;;
  esac
  shift
done

if ! check_reqs; then
  exit 40
fi

case "$what_to_get" in
  manager) get_nodes=get_manager_nodes;;
  managed) get_nodes=get_managed_nodes;;
  *)
    echo >&2 "Do not understand how to get '$what_to_get'"
    usage
    exit 36
  ;;
esac

if nodes=$($get_nodes "$CLUSTER_ID") 2>/dev/null; then
  if [[ $create_manifest == 1 ]]; then
    mkdir -p "$OUTDIR" 2>/dev/null

    if [[ "$what_to_get" == "managed" ]]; then
      if [[ $(echo "$nodes" | jq '.manager_controllers | length') == 0 ]]; then
        echo >&2 "There are currently no managed nodes deployed. Cannot continue."
        exit 59
      fi

      if ! create_worker_cluster_manifest "$nodes" > "$create_cluster_yaml"; then
        exit 60
      fi
    else
      echo "Since manager clusters do not yet need a manifest, I don't know how to make one."
      exit 61
    fi
  else
    if [[ -z "$nodes" ]]; then
      echo "No nodes exist for $what_to_get"
    else
      echo "$nodes"
    fi
  fi
fi
