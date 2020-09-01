#!/usr/bin/env bash
set -e
set -x

# BDD test specific part
export BDD_NAME="bdd-ghe"

# the gitops repository template to use
export GITOPS_TEMPLATE_PROJECT="jx3-gitops-repositories/jx3-gke-terraform-vault"

# to enable spring / gradle...
#export RUN_TEST="bddjx -ginkgo.focus=spring-boot-http-gradle -test.v"


# lets default to using github enterprise
export JX_ADMIN_CREATE_ARGS="--git-name ghe --git-server https://github.beescloud.com --env-git-owner dev1"


`dirname "$0"`/../ci.sh
