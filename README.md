
# For AWS infrastructure

* During development, this is the way to start the two stacks in AWS Cloudformation using `optct` (preferred):
** In the following cases, CLUSTER_ID was set as an environment variable.
  1. `for cluster_type in manager managed; do
        (opctl run -a uid=$(id -u) -a gid=$(id -g) -a cluster_id=$CLUSTER_ID -a cluster_private_key=~/.ssh/${cluster_type}Key.b64 -a cluster_type=$cluster_type 01-infrastructure/aws &)
      done`

* Or one can run the script manually. Note the following will create two cluster sets (manager and managed) in a subshell in parallel:
  1. `cd .opspec/01-infrastructure/aws/bin`
  1. `for cluster_type in manager managed; do
        CLUSTER_ID=<some_cluster_name> \
        OS_TYPE=centos \
        CLUSTER_TYPE=$CLUSTER_TYPE \
        AWS_DEFAULT_REGION=us-west-2 \
        AVAILABILITY_ZONE=us-west-2b \
        INSTANCE_TYPE=c4.large \
        $(./export_aws_creds) && \
        CLUSTER_PRIVATE_KEY=$(< ~/.ssh/${CLUSTER_ID}Key.b64 2>/dev/null)
        (./make-cluster-nodes.sh &)
      done`

