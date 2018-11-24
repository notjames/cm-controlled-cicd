#!/bin/bash

# obtain IP addresses nodes
# scp common_functions to remote host
# source functions
# if manager master, run master bits
#   grab token string

# if manager worker, run worker bits
#   join with token string
#   install helm
#   install cma
#   do the other things
#   helm install cma-vmare
#   git clone cluster-api-provider-ssh
#     generate manifests
#     install clusterapi-apiserver and provider-components

#   generate machine.yaml using
#   curl POST machine.yaml
