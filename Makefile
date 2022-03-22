SHELL=/bin/bash -o pipefail

REGISTRY ?= kubedb
BIN      := proxysql
IMAGE    := $(REGISTRY)/$(BIN)
TAG      := v2.0.4

.PHONY: push
push: container
	docker push $(IMAGE):$(TAG)


.PHONY: container
container:
	wget -qO tini https://github.com/kubedb/tini/releases/download/v0.20.0/tini-static
	chmod +x tini
	docker build --pull -t $(IMAGE):$(TAG) .
	rm tini

# make and load docker image to kind cluster
.PHONY: push-to-kind
push-to-kind: container
	@echo "Loading docker image into kind cluster...."
	@kind load docker-image $(IMAGE):$(TAG) --name second
	@echo "Image has been pushed successfully into kind cluster."