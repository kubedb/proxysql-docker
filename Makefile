SHELL=/bin/bash -o pipefail

REGISTRY ?= kubedb
BIN      := proxysql
IMAGE    := $(REGISTRY)/$(BIN)
TAG      := 2.0.4

.PHONY: push
push: container
	docker push $(IMAGE):$(TAG)

.PHONY: container
container:
	docker build --pull -t $(IMAGE):$(TAG) .
