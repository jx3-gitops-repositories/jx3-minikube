FETCH_DIR := build/base
TMP_TEMPLATE_DIR := build/tmp
OUTPUT_DIR := config-root

VAULT_ADDR ?= https://vault.secret-infra:8200

.PHONY: clean
clean:
	rm -rf build $(OUTPUT_DIR)

init:
	mkdir -p $(FETCH_DIR)
	mkdir -p $(TMP_TEMPLATE_DIR)
	mkdir -p $(OUTPUT_DIR)/namespaces/jx
	cp -r src/* build
	mkdir -p $(FETCH_DIR)/cluster/crds
	#mkdir -p $(FETCH_DIR)/namespaces/nginx
	#mkdir -p $(FETCH_DIR)/namespaces/jx-cli:0.0.330


.PHONY: fetch
fetch: init
	# lets configure the cluster gitops repository URL on the requirements if its missing
	jx gitops repository --source-dir $(OUTPUT_DIR)/namespaces

	# lets resolve chart versions and values from the version stream
	jx gitops helmfile resolve

	# lets make sure we are using the latest jx-cli in the git operator Job
	jx gitops image -s .jx/git-operator

	# not sure why we need this but it avoids issues...
	helm repo add jx http://chartmuseum.jenkins-x.io

	# generate the yaml from the charts in helmfile.yaml
	helmfile --debug template  -args="--include-crds --values=jx-values.yaml --values=src/fake-secrets.yaml.gotmpl" --output-dir $(TMP_TEMPLATE_DIR)

	# split the files into one file per resource
	jx gitops split --dir $(TMP_TEMPLATE_DIR)

	# move the templated files to correct cluster or namespace folder
	# setting the namespace on namespaced resources
	jx gitops helmfile move --dir $(TMP_TEMPLATE_DIR) --output-dir $(OUTPUT_DIR)

	# convert k8s Secrets => ExternalSecret resources using secret mapping + schemas
	# see: https://github.com/jenkins-x/jx-secret#mappings
	jx secret convert --dir $(OUTPUT_DIR)

	# old approach
	#jx gitops jx-apps template --template-values src/fake-secrets.yaml.txt -o $(OUTPUT_DIR)/namespaces
	#jx gitops namespace --dir-mode --dir $(OUTPUT_DIR)/namespaces

	# disable cert manager validation of webhooks due to cert issues
	#jx gitops label --kind Namespace cert-manager.io/disable-validation=true

.PHONY: build
# uncomment this line to enable kustomize
#build: build-kustomise
build: build-nokustomise

.PHONY: build-kustomise
build-kustomise: kustomize post-build

.PHONY: build-nokustomise
build-nokustomise: copy-resources post-build


.PHONY: pre-build
pre-build:

.PHONY: post-build
post-build:
	jx gitops scheduler -d config-root/namespaces/jx -o src/base/namespaces/jx/lighthouse-config
	# TODO do we need this?
	#jx gitops ingress
	jx gitops label --dir $(OUTPUT_DIR) gitops.jenkins-x.io/pipeline=environment
	jx gitops annotate --dir  $(OUTPUT_DIR)/namespaces --kind Deployment wave.pusher.com/update-on-config-change=true

	# lets force a rolling upgrade of lighthouse pods whenever we update the lighthouse config...
	jx gitops hash -s config-root/namespaces/jx/lighthouse-config/config-cm.yaml -s config-root/namespaces/jx/lighthouse-config/plugins-cm.yaml -d config-root/namespaces/jx/lighthouse

.PHONY: kustomize
kustomize: pre-build
	kustomize build ./build  -o $(OUTPUT_DIR)/namespaces

.PHONY: copy-resources
copy-resources: pre-build
	cp -r ./build/base/* $(OUTPUT_DIR)
	rm $(OUTPUT_DIR)/kustomization.yaml

.PHONY: lint
lint:

.PHONY: verify-ingress
verify-ingress:
	jx verify ingress -b

.PHONY: verify-ingress-ignore
verify-ingress-ignore:
	-jx verify ingress -b

.PHONY: verify-install
verify-install:
	# TODO lets disable errors for now
	# as some pods stick around even though they are failed causing errors
	-jx verify install --pod-wait-time=2m

.PHONY: verify
verify: verify-ingress
	jx verify env
	jx verify webhooks --verbose --warn-on-fail

.PHONY: verify-ignore
verify-ignore: verify-ingress-ignore

.PHONY: secrets-populate
secrets-populate:
	# lets populate any missing secrets we have a generator defined for in the `.jx/gitops/secret-schema.yaml` file
	# they can be modified/regenerated at any time via `jx secret edit`
	-VAULT_ADDR=$(VAULT_ADDR) jx secret populate

.PHONY: secrets-wait
secrets-wait:
	# lets wait for the ExternalSecrets service to populate the mandatory Secret resources
	VAULT_ADDR=$(VAULT_ADDR) jx secret wait

.PHONY: git-setup
git-setup:
	jx gitops git setup
	git pull

.PHONY: regen-check
regen-check:
	jx gitops condition --last-commit-msg-prefix '!Merge pull request' -- make git-setup resolve-metadata all double-apply verify-ingress-ignore commit push

	# lets run this twice to ensure that ingress is setup after applying nginx if not using a custom domain yet
	jx gitops condition --last-commit-msg-prefix '!Merge pull request' -- make verify-ingress-ignore all verify-ignore secrets-populate commit push secrets-wait

.PHONY: apply
apply: regen-check
	kubectl apply --prune -l=gitops.jenkins-x.io/pipeline=environment -R -f $(OUTPUT_DIR)
	-jx verify env
	-jx verify webhooks --verbose --warn-on-fail

.PHONY: double-apply
double-apply: 
	# TODO has a hack lets do this twice as the first time fails due to CRDs
	-kubectl apply --prune -l=gitops.jenkins-x.io/pipeline=environment -R -f $(OUTPUT_DIR)
	kubectl apply --prune -l=gitops.jenkins-x.io/pipeline=environment -R -f $(OUTPUT_DIR)

.PHONY: resolve-metadata
resolve-metadata:
	# lets merge in any output from Terraform in the ConfigMap default/terraform-jx-requirements if it exists
	jx gitops requirements merge

	# lets resolve any requirements
	jx gitops requirements resolve -n

.PHONY: commit
commit:
	-git add *
	-git status
	# lets ignore commit errors in case there's no changes and to stop pipelines failing
	-git commit -m "chore: regenerated"

.PHONY: all
all: clean fetch build lint


.PHONY: pr
pr: all commit push-pr-branch

.PHONY: push-pr-branch
push-pr-branch:
	jx gitops pr push

.PHONY: push
push:
	git push

.PHONY: release
release: lint

