
# For AWS infrastructure
* Requirements:
** You must already have valid AWS credentials set up and saved in your `$HOME/.aws/credentials`.

## Using [optctl](https://opctl.io/docs/getting-started/opctl.html)
* `optctl` is currently the preferred method for creating these CF stacks. *NOTE* In the following example, `$CLUSTER_ID` was set as an environment variable:
  1. `envsubst '$HOME' < .opspec/args.yml-in > .opspec/args.yml`
  ** this was necessary because currently `opctl` does not know how to interpolate environment variables in `inputs`.
  1. `for cluster_type in manager managed; do
        (opctl run -a uid=$(id -u) \
                   -a gid=$(id -g) \
                   -a cluster_id=$CLUSTER_ID \
                   -a cluster_private_key=~/.ssh/${CLUSTER_ID}-Key.b64 \
                   -a cluster_type=$cluster_type 01-infrastructure/aws &)
      done`

## Run the script from Docker
* This would be the preferred method of runtime if running on a Darwin environment and `opctl` was not installed. Note: do not worry if CLUSTER_PRIVATE_KEY fails with an error.
  1. `cd .opspec/01-infrastructure/aws/build/cfstack`
  1. `docker build -t cm-cf-createstack:latest .`
  1. `cd ../..`
  1. `export CLUSTER_ID=<cluster_id> CLUSTER_PRIVATE_KEY=$(< $HOME/.ssh/${CLUSTER_ID}-Key.b64) `
  1. `for cluster_type in manager managed; do
        (docker run -v $PWD:/root \
                   -v $HOME/.ssh:/root/.ssh \
              $(echo " OS_TYPE=centos CLUSTER_ID=$CLUSTER_ID AWS_DEFAULT_REGION=us-west-2 AVAILABILITY_ZONE=us-west-2b CLUSTER_USERNAME=centos INSTANCE_TYPE=c4.large CLUSTER_TYPE=$cluster_type $(bin/export_aws_creds)" | \
                sed 's# # -e #g') \
                      -it cm-cf-createstack:latest &)
      done`

## Use the script free from containerization
* Note the following will create two cluster sets (manager and managed) in a subshell in parallel:
  1. `cd .opspec/01-infrastructure/aws/bin`
  1. `for cluster_type in manager managed; do
        CLUSTER_ID=<some_cluster_name> \
        OS_TYPE=centos \
        CLUSTER_TYPE=$cluster_type \
        AWS_DEFAULT_REGION=us-west-2 \
        AVAILABILITY_ZONE=us-west-2b \
        INSTANCE_TYPE=c4.large \
        $(./export_aws_creds) && \
        CLUSTER_PRIVATE_KEY=$(< $HOME/.ssh/${CLUSTER_ID}-Key.b64 2>/dev/null)
        (./make-cluster-nodes.sh &)
      done`

