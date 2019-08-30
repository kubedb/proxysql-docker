#!/bin/bash
set -xeou pipefail

GOPATH=$(go env GOPATH)
REPO_ROOT=$GOPATH/src/kubedb.dev/proxysql

DOCKER_REGISTRY=${DOCKER_REGISTRY:-kubedb}

IMG="proxysql"

DB_VERSION="5.7"
TAG="$DB_VERSION"

build() {
  pushd "$REPO_ROOT/hack/docker/proxysql/$DB_VERSION"

  local cmd="docker build --pull -t $DOCKER_REGISTRY/$IMG:$TAG ."
  echo $cmd
  $cmd

  popd
}

push() {
  pushd "$REPO_ROOT/hack/docker/proxysql/$DB_VERSION"

  local cmd="docker push $DOCKER_REGISTRY/$IMG:$TAG"
  echo $cmd
  $cmd

  popd
}

"$@"
