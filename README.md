
# For AWS infrastructure
## Creating AWS instances for testing:
* Requirements:
** You must already have valid AWS credentials set up and saved in your `$HOME/.aws/credentials`.
** In a couple of the examples below, a variable is created by reading a private base64 encoded key. YOU DO NOT NEED TO CREATE THE KEY! If an error occurs because the key does not exist, you can safely ignore the error. The cloudformation stack create script will create a key based off the `$CLUSTER_ID`. In the event that you've created a stack with the same `$CLUSTER_ID`, the script will import that key to AWS. If the key doesn't exist, the script will have AWS create one and import it locally. Then the script will create a base64 encoded key from that private key minding proper permissions.

### Using [optctl](https://opctl.io/docs/getting-started/opctl.html)
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

### Run the script from Docker
* This would be the preferred method of runtime if running on a Darwin environment and `opctl` was not installed. Note: do not worry if CLUSTER_PRIVATE_KEY fails with an error.
  1. `cd .opspec/01-infrastructure/aws/build/cfstack`
  1. `docker build -t cm-cf-createstack:latest .`
  1. `cd ../..`
  1. `export CLUSTER_ID=<cluster_id> CLUSTER_PRIVATE_KEY=$(< $HOME/.ssh/${CLUSTER_ID}-Key.b64) `
  1. `for cluster_type in manager managed; do
        (docker run -v $PWD:/root \
                   -v $HOME/.ssh:/root/.ssh \
              $(echo " OS_TYPE=centos
                       CLUSTER_ID=$CLUSTER_ID
                       AWS_DEFAULT_REGION=us-west-2
                       AVAILABILITY_ZONE=us-west-2b
                       CLUSTER_USERNAME=centos
                       INSTANCE_TYPE=c4.large
                       CLUSTER_TYPE=$cluster_type
                       $(bin/export_aws_creds)" | \
                sed 's# \+# -e #g' \
                      -i cm-cf-createstack:latest &)
      done`

### Use the script free from containerization
* Note the following will create two cluster sets (manager and managed) in a subshell in parallel:
  1. `cd .opspec/01-infrastructure/aws/bin`
  1. `export CLUSTER_ID=<some_cluster_name> \
        OS_TYPE=centos \
        AWS_DEFAULT_REGION=us-west-2 \
        AVAILABILITY_ZONE=us-west-2b \
        INSTANCE_TYPE=c4.large \
        $(./export_aws_creds) && \
        CLUSTER_PRIVATE_KEY=$(< $HOME/.ssh/${CLUSTER_ID}-Key.b64)`
  1. `for cluster_type in manager managed; do
        CLUSTER_TYPE=$cluster_type
        (./make-cluster-nodes.sh &)
      done`

## Bootrapping controller instances in preparation for testing CMS
* So there are now four instances; 2 manager instances and 2 managed instances. These machines are vanilla installations so far. They still need all the Kubernetes bits and stuff installed. The following *manual* steps will cover that. An opctl thingy is still forthcoming.

### Bootstrap the manager controller (master)
  1. `cd .opspec/02-cmc-cluster/aws/bin`
  1. `./bootstrap-nodes.sh -ct manager -nt master`
    * This command will automatically determine the public IP for the master and it will bootstrap the master control instance and start Kubernetes. The script will capture the kubeadm join string for worker nodes.

### Bootstrap the manager worker
  1. `./bootstrap-nodes.sh -ct manager -nt worker`
    * This command will bootstrap the worker and join it to the master
    * It  will then install helm
    * It tries to install the cmc stuff, but that currently does not yet work due to restrictions on repos among other things.
