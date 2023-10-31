# Makefile is self-documenting, comments starting with '##' are extracted as help text.
help: ## Print this help message.
	@echo; echo = Targets =
	@grep -E '^\w+:.*##' Makefile | sed 's/:.*##\s*/#/' | column -s'#' -t
	@echo; echo  = Variables =
	@grep -E '^## [A-Z_]+: ' Makefile | sed 's/^## \([A-Z_]*\): \(.*\)/\1#\2/' | column -s'#' -t

# The following variables can be overridden by environment variables or on the `make` command line

## VERSION: semantic version for releases, based on "git describe" for work in development (not semver).
VERSION?=$(or $(shell git describe 2>/dev/null | cut -d- -f1,2 | sed 's/-/_dev_/'),$(file <$(VERSION_TXT)))
## IMG: Name of image to build or deploy, without version tag.
IMG?=quay.io/korrel8r/korrel8r
## TAG: Image tag, defaults to $(VERSION)
TAG?=$(VERSION)
## OVERLAY: Name of kustomize directory in config/overlays to use for `make deploy`.
OVERLAY?=dev
## IMGTOOL: May be podman or docker.
IMGTOOL?=$(shell which podman || which docker)

all: generate lint test install _site ## Run all build and test targets, except: image deploy

clean: # Warning: runs `git clean -dfx` and removes checked-in generated files.
	rm -vrf _site docs/zz_*.adoc pkg/api/docs /cmd/korrel8r/version.txt
	git clean -dfx

tools: ## Install tools for `make generate` and `make lint` locally.
	go install github.com/go-swagger/go-swagger/cmd/swagger@latest
	go install github.com/swaggo/swag/cmd/swag@latest
	go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest

VERSION_TXT=cmd/korrel8r/version.txt

ifneq ($(VERSION),$(file <$(VERSION_TXT)))
.PHONY: $(VERSION_TXT) # Force update if VERSION_TXT does not match VERSION
endif
$(VERSION_TXT):
	echo $(VERSION) > $@

generate: $(VERSION_TXT) pkg/api/docs ## Generate code.
	hack/copyright.sh
	go mod tidy

pkg/api/docs: $(PKG_GO)
	@mkdir -p $(dir $@)
	swag init -q -g pkg/api/api.go -o $@
	swag fmt pkg/api
	@touch $@

lint: ## Run the linter to find and fix code style problems.
	golangci-lint run --fix

install: $(VERSION_TXT) ## Build and install the korrel8r binary locally in $GOBIN.
	go install -tags netgo ./cmd/korrel8r

test: ## Run all tests, requires a cluster.
	TEST_NO_SKIP=1 go test -timeout=1m -race ./...

cover: ## Run tests and show code coverage in browser.
	go test -coverprofile=test.cov ./...
	go tool cover --html test.cov; sleep 2 # Sleep required to let browser start up.

CONFIG=etc/korrel8r/korrel8r.yaml
run: $(VERSION_TXT) ## Run `korrel8r web` from source using configuration in ./etc.
	go run ./cmd/korrel8r/ web -c $(CONFIG)

IMAGE=$(IMG):$(TAG)
image: $(VERSION_TXT) ## Build and push image. IMG must be set to a writable image repository.
	$(IMGTOOL) build -q --tag=$(IMAGE) .
	$(IMGTOOL) push -q $(IMAGE)
	@echo $(IMAGE)

image-name: ## Print the full image name and tag.
	@echo $(IMAGE)

IMAGE_KUSTOMIZATION=config/overlays/$(OVERLAY)/kustomization.yaml
.PHONY: $(IMAGE_KUSTOMIZATION)
$(IMAGE_KUSTOMIZATION):
	mkdir -p $(dir $@)
	hack/replace-image.sh "quay.io/korrel8r/korrel8r" $(IMG) $(TAG) > $@

WATCH=kubectl get events -A --watch-only& trap "kill %%" EXIT;

deploy: image $(IMAGE_KUSTOMIZATION)	## Deploy to a cluster using kustomize. IMG must be set to a *public* image repository.
	$(WATCH) kubectl apply -k config/overlays/$(OVERLAY)
	$(WATCH) kubectl wait -n korrel8r --for=condition=available --timeout=60s deployment.apps/korrel8r

route:				## Create a route to access korrel8r service from outside the cluster, requires openshift.
	oc delete route/korrel8r --ignore-not-found
	mkdir -p tmp
	oc extract --confirm -n korrel8r configmap/openshift-service-ca.crt secret/korrel8r --to=tmp
	oc create route reencrypt -n korrel8r --service=korrel8r --cert=tmp/tls.crt --key=tmp/tls.key --dest-ca-cert=tmp/service-ca.crt --ca-cert=tmp/service-ca.crt
	$(MAKE) --no-print-directory url

url:				## Print the URL of the external route.
	@oc get route/korrel8r -o template='https://{{.spec.host}}/'

# Public site is generated by .github/workflows/asciidoctor-ghpages.yml
ADOC_RUN=$(IMGTOOL) run -iq -v./docs:/src:z -v./_site:/dst:z quay.io/rhdevdocs/devspaces-documentation
ADOC_ARGS=-a revnumber=$(VERSION) -a stylesheet=fedora.css -D/dst /src/index.adoc
SITE_DEPS?=$(wildcard docs/*.adoc) docs/zz_domains.adoc docs/zz_rest_api.adoc Makefile
_site: $(SITE_DEPS)
	@mkdir -p $@
	$(ADOC_RUN) asciidoctor $(ADOC_ARGS)
	$(ADOC_RUN) asciidoctor-pdf -a allow-uri-read -o ebook.pdf $(ADOC_ARGS)
	@touch $@
docs/zz_domains.adoc: $(shell find cmd/korrel8r-doc pkg -name '*.go')
	go run ./cmd/korrel8r-doc pkg/domains/* > $@
# Note docs/templates/markdown overrides the swagger markdown templates to generate asciidoc
docs/zz_rest_api.adoc: pkg/api/docs docs/templates/markdown/docs.gotmpl $(shell find pkg -name '*.go')
	swagger -q generate markdown -T docs/templates -f $</swagger.json --output $@

release: ## Create a local release tag and commit. TAG must be set to vX.Y.Z.
	$(CHECK_RELEASE)
	@test -z "$(shell git status --porcelain)" || { git status -s; echo Workspace is not clean; exit 1; }
	$(MAKE) all
	hack/changelog.sh $(VERSION) > CHANGELOG.md	# Update change log
	git commit -q -a -m "Release $(VERSION)"
	git tag $(VERSION) -a -m "Release $(VERSION)"
	@echo -e "To push the release commit and images: \n   make release-push"

release-push: ## Push release tag and image.
	$(CHECK_RELEASE)
	git push origin main --follow-tags
	$(MAKE) --no-print-directory image
	$(IMGTOOL) push -q "$(IMAGE)" "$(IMG):latest"

CHECK_RELEASE=@echo "$(VERSION)" | grep -qE "^v[0-9]+\.[0-9]+\.[0-9]+$$" || { echo "VERSION=$(VERSION) must be semantic version like vX.Y.Z"; exit 1; }
