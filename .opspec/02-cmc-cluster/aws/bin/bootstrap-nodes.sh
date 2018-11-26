#!/bin/bash

usage()
{
  echo """
  Usage: $0 --cluster-type|-ct <manager|managed> --node-type|-nt <master|worker>
            [--help|-h]

  """
}

copy_to_host()
{
  local priv_key things_to_copy ip_addr

  priv_key="$1";shift
  ip_addr="$1";shift
  things_to_copy="$*"

  # shellcheck disable=SC2086
  scp -i "$priv_key" $SSH_OPTIONS $things_to_copy "$OS_TYPE"@"$ip_addr":
}

run_ssh_commands_master()
{
  local priv_key ip_addr JOIN_STRING

  priv_key="$1"
  ip_addr="$2"
  JOIN_STRING="$3"

  # shellcheck disable=SC2086,SC2029
  ssh -i "$priv_key" $SSH_OPTIONS $OS_TYPE@$ip_addr \
    "bash -x install_master.sh && grep -Po 'kubeadm join.*' /var/log/startup.log | tail -n 1 > $JOIN_STRING"

  # grab "kubeadm join string
  # shellcheck disable=SC2086
  scp -i "$priv_key" $SSH_OPTIONS "$OS_TYPE"@"$ctrl_manager_ipaddr":$JOIN_STRING .
}

run_ssh_commands_node()
{
  local priv_key ip_addr join_string

  priv_key="$1"
  ip_addr="$2"
  join_string="$3"

  # shellcheck disable=SC2086,SC2029
  ssh -i "$priv_key" $SSH_OPTIONS $OS_TYPE@$ip_addr "bash -x install_worker.sh $join_string"
}

manager_master_bootstrap()
{
  local host_ipaddr join_string things_to_copy

  # obtain IP address of manager controller node
  host_ipaddr=$(./generate-cmc-yaml.sh --get manager | jq -Mr '.manager_controllers[0].address')

  # scp common_functions to remote host
  things_to_copy=(scripts/install_master.sh scripts/common_functions.sh)
  copy_to_host "$KEYFILE" "$host_ipaddr" "${things_to_copy[@]}"

  # if manager master, run master bits
  #   grab token string
  run_ssh_commands_master "$KEYFILE" "$ctrl_manager_ipaddr" "$join_string"
}

manager_node_bootstrap()
{
  local host_ipaddr join_string things_to_copy

  join_string=$1

  # obtain IP address of manager controller node
  host_ipaddr=$(./generate-cmc-yaml.sh --get manager | jq -Mr '.manager_nodes[0].address')

  # scp common_functions to remote host
  things_to_copy=(scripts/install_worker.sh scripts/common_functions.sh $JOIN_STRING)
  copy_to_host "$KEYFILE" "$host_ipaddr" "${things_to_copy[@]}"

  run_ssh_commands_node "$KEYFILE" "$host_ipaddr" "$join_string"
}

main()
{
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      --cluster-type|-ct)
        shift
        cluster_type=$1
      ;;
      --node-type|-nt)
        shift
        node_type=$1
      ;;
      --help|-h)
        usage
        return 0
      ;;
      *)
        echo >&2 "Unknown argument: $1"
        usage
        return 1
      ;;
    esac

    shift
  done

  if ! [[ $cluster_type =~ ^manage[rd]$ ]]; then
    echo >&2 "Invalid cluster type: '$cluster_type'. Must be 'manager' or 'managed'"
    usage
    return 1
  fi

  if ! [[ $node_type =~ ^(master|worker)$ ]]; then
    echo >&2 "Invalid node type: '$node_type'. Must be 'master' or 'worker'"
    usage
    return 1
  fi

  if [[ $cluster_type != "manager" ]]; then
    echo >&2 "This script should only be used to provision manager cluster machines."
    return 1
  fi

  if [[ $node_type == "master" ]]; then
    if manager_master_bootstrap; then
      return 0
    else
      echo >&2 "Bootstrap failed for manager master."
      return 1
    fi
  fi

  manager_node_bootstrap "$JOIN_STRING"
}

# private key path
KEYFILE=~/.ssh/manager-${CLUSTER_ID}Key.pem

# join_string
JOIN_STRING="join_string.txt"

# ssh options
# turn off host checking and ignore the hosts file since this will be non-interactive.
SSH_OPTIONS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "

if ! main "$@"; then
  exit 50
fi

