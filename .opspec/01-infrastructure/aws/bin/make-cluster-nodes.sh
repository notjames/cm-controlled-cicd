#!/bin/bash

workers()
{
  aws ec2 describe-instances \
    --filters "Name=tag:cms_id,Values=${CLUSTER_ID}" "Name=tag:role,Values=worker" \
    --query 'Reservations[].Instances[].PublicIpAddress'
}

prep_for_new_key()
{
  if ! shred -z -n5 -u "${private_key}" 2>/dev/null
  then
    if [[ -f "${private_key}" ]]
    then
      if ! rm -rf "${private_key}" 2>/dev/null
      then
        echo >&2 "Unable to remove existing keyfile: ${private_key}"
        return 55
      fi
    fi
  fi

  if ! touch "${private_key}"; then
    echo >&2 "Unable to create (touch) new keyfile: ${private_key}"
    return 65
  else
    if ! chmod 0600 "${private_key}"; then
      echo >&2 "Unable to chmod 0600 ${private_key}"
      return 60
    fi
  fi
}

get_aws_key_fp()
{
  aws ec2 describe-key-pairs --key-name "${key_name}" \
                             --query "KeyPairs[].KeyFingerprint"
                             --output text
}

local_key_fp()
{
  openssl pkcs8 -in "${key_name}" -inform PEM -outform DER -topk8 \
                -nocrypt 2>/dev/null | \
                openssl sha1 -c | awk '{print $2}'
}

aws_delete_key()
{
  aws ec2 delete-key-pair --key-name "${key_name}"
}

create_new_key()
{
  if prep_for_new_key; then
    if  aws ec2 create-key-pair  \
        --key-name "${key_name}" \
        --query 'KeyMaterial'    \
        --output text >> "${private_key}"; then
      own "${private_key}"
    fi
  else
    return 60
  fi
}

aws_key_exists()
{
  local key_name
  key_name=$1

  [[ -z "${key_name}" ]] && \
    {
      echo >&2 "Usage: aws_key_exists(): requires the name of the key to check for in AWS."
      return 113
    }

  # shellcheck disable=SC2027,SC2086
  aws ec2 describe-key-pairs --query "KeyPairs[? KeyName == '"${key_name}"'] | length(@)"
}

own()
{
  [[ -z $1 ]] && return
  # shellcheck disable=SC2046
  chown $(stat -c '%u:%g' "$key_home") "$1"
}

get_key_material()
{
  local key_home public_key pk_base64
  declare -g key_name

  key_home="${KEY_HOME}"
  key_name="${CLUSTER_ID}Key"
  base_key_name="${key_home}/${key_name}"
  private_key="$base_key_name.pem"
  public_key="$base_key_name.pub"
  pk_base64="$base_key_name.b64"

  if [[ $(aws_key_exists "${key_name}") -gt 0 ]]; then
    aws_delete_key
  fi

  if [[ -s ${private_key} ]]; then
    ssh-keygen -t rsa -C "${key_name}" -yf "${private_key}" > "${public_key}"
    own "$public_key"

    if ! aws ec2 import-key-pair \
        --key-name "${key_name}" \
        --public-key-material file://"${public_key}"; then

      if ! create_new_key; then
        echo >&2 "Error creating/importing key material."
        return 1
      fi
    fi
  else
    if ! create_new_key; then
      echo >&2 "Error creating/importing key material."
      return 1
    fi
  fi

  if [[ ! -f $pk_base64 ]] || [[ ! -s $pk_base64 ]]; then
    < "$private_key" base64 | tr -d '\r\n' | tr -d ' ' > "$pk_base64"
    chmod 600 "$pk_base64" "$private_key"
    own "$pk_base64"
  fi

  CLUSTER_PRIVATE_KEY=$(< "$pk_base64")
  export CLUSTER_PRIVATE_KEY
}

chk_prereqs()
{
  [[ ! -x $(which jq) ]] && \
    {
      echo >&2 "Please install 'jq'. It is required for this script to work."
      return 25
    }

  [[ ! -x $(which aws) ]] && \
    {
      echo >&2 "Please install 'aws'. It is required for this script to work."
      return 25
    }

  if [ -z "${CLUSTER_ID}" ]; then
      echo "CLUSTER_ID must be set. Hint: export CLUSTER_ID=<cluster_id>"
      return 26
  fi

  if [ -z "${AVAILABILITY_ZONE}" ]; then
      echo "AVAILABILITY_ZONE must be set"
      return 27
  fi
}

cloudform()
{
  [[ ! -f "$CLUSTER_TEMPLATE" ]] && \
    {
      echo >&2 """
  The template '${CLUSTER_TEMPLATE}' does not exist in ${TMPL_PATH}.
  Please fix your '\$INSTANCE_OS_NAME' and/or '\$INSTANCE_OS_VER' env variables
  to match a template in ${BASEDIR}.
      """
      exit 21
    }

#  if ! aws s3 mb s3://${S3_BUCKET} > /dev/null 2>&1; then
#    aws s3 mb s3://${S3_BUCKET}
#  fi

#                               --s3-bucket "${S3_BUCKET}" \
  if ! aws cloudformation deploy --stack-name="${CLUSTER_ID}" \
                                 --template-file "${CLUSTER_TEMPLATE}" \
                                 --capabilities CAPABILITY_IAM \
                                 --parameter-overrides \
      CmsId="${CLUSTER_ID}"                   \
      KeyName="${key_name}"                   \
      username="${CLUSTER_USERNAME}"          \
      InstanceType="${INSTANCE_TYPE}"         \
      DiskSizeGb="${DISK_SIZE_GB}"            \
      AvailabilityZone="${AVAILABILITY_ZONE}" \
      SSHLocation="${SSH_LOCATION}"           \
      K8sNodeCapacity="${K8S_NODE_CAPACITY}" | tee "${CREATED}"; then
    return 1
  else
    while [[ "$(jq ". | length" <<< "$(workers)")" -lt "${K8S_NODE_CAPACITY}" ]]; do
      sleep "${S_TIME}"
      S_TIME=$((S_TIME * S_TIME))
    done
  fi
}

# courtesy of SO (/questions/630372/determine-the-path-of-the-executing-bash-script)
BASEDIR=$(cd -P -- "$(dirname -- "$0")" && cd ../ && pwd -P)
S3_BUCKET="${S3_BUCKET:-make-cluster-nodes}"
INSTANCE_TYPE=${INSTANCE_TYPE:-m4.large}
DISK_SIZE_GB=${DISK_SIZE_GB:-40}
SSH_LOCATION=${SSH_LOCATION:-0.0.0.0/0}
K8S_NODE_CAPACITY=${K8S_NODE_CAPACITY:-1}
INSTANCE_OS_NAME=${INSTANCE_OS_NAME:-centos}
CLUSTER_USERNAME=${CLUSTER_USERNAME:-$INSTANCE_OS_NAME}
INSTANCE_OS_VER=${INSTANCE_OS_VER:-7.4}
TMPL_PATH="$BASEDIR/templates"
CLUSTER_TEMPLATE="$TMPL_PATH/cluster-${INSTANCE_OS_NAME}-${INSTANCE_OS_VER}-cf.template"
CREATED=$(mktemp)
S_TIME=2

if [[ $USER == "root" ]]; then
  KEY_HOME="/root/.ssh"
else
  KEY_HOME="${KEY_HOME:-${HOME}/.ssh}"
fi

# Be opinionated about where CLUSTER_TYPE should be
# currently in the front. If it's in the end, remove it.
if echo "$CLUSTER_ID" | grep -Pq '[-_]manage[rd]$'; then
  CLUSTER_ID="$CLUSTER_TYPE-${CLUSTER_ID/[-_]manage[rd]$/}"
fi

# If CLUSTER_TYPE is not currently in the front, add it.
if ! echo "$CLUSTER_ID" | grep -Pq '^manage[rd]'; then
  CLUSTER_ID="${CLUSTER_TYPE}-${CLUSTER_ID}"
else
  # otherwise, if it's there, make sure it's correct
  CLUSTER_ID="${CLUSTER_ID/^manage[rd][-_]/${CLUSTER_TYPE}-}"
fi

if ! get_key_material; then
    echo >&2 """
  This script tries to use existing key material in ${KEY_HOME} based on the \$CLUSTER_ID.
  If key material doesn't exist, this script uses AWS to create new key material, which
  will be stored as ${private_key}. In some cases AWS may attempt to create a key that was
  neither able to be imported nor uniquely created. In these cases, you may need to run
  the following command and re-create the CF stack.

  To delete the AWS key use the command:
  aws ec2 delete-key-pair --key-name ${key_name}

    """

    exit 20
fi

if cloudform; then
  echo "Done"
fi
