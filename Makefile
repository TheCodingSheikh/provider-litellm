# ====================================================================================
# Setup Project

PROJECT_NAME ?= provider-litellm
PROJECT_REPO ?= github.com/thecodingsheikh/$(PROJECT_NAME)

# OpenTofu, not Terraform. HashiCorp relicensed Terraform under the BSL at 1.6,
# and this provider redistributes the binary inside its container image, so
# shipping 1.6+ is not permitted. OpenTofu is the MPL-2.0 fork and is CLI
# compatible, so upjet drives it unchanged -- it is installed as `terraform`
# because that is the executable name upjet invokes.
#
# It also unblocks write-only attributes (OpenTofu >= 1.11), which the upstream
# provider needs for litellm_jwt_key_mapping and litellm_key's key_wo.
export TERRAFORM_VERSION ?= 1.12.6
OPENTOFU_DOWNLOAD_URL ?= https://github.com/opentofu/opentofu/releases/download/v$(TERRAFORM_VERSION)/tofu_$(TERRAFORM_VERSION)_$(SAFEHOST_PLATFORM).zip

export TERRAFORM_PROVIDER_SOURCE ?= ncecere/litellm
export TERRAFORM_PROVIDER_REPO ?= https://github.com/ncecere/terraform-provider-litellm
# The provider is built from source at TERRAFORM_PROVIDER_REF rather than
# downloaded from GitHub releases, because it is patched: see hack/patches for
# the upstream fixes required by the observe-before-create model that upjet
# uses, and hack/build-terraform-provider.sh for how they are applied. REF may
# be a tag or a commit.
export TERRAFORM_PROVIDER_REF ?= v2.1.0
export TERRAFORM_PROVIDER_VERSION ?= 2.1.0
export TERRAFORM_PROVIDER_DOWNLOAD_NAME ?= terraform-provider-litellm
export TERRAFORM_NATIVE_PROVIDER_BINARY ?= terraform-provider-litellm_v$(TERRAFORM_PROVIDER_VERSION)
export TERRAFORM_DOCS_PATH ?= docs/resources
# The upstream docs are hand-written and carry none of the tfplugindocs
# frontmatter upjet's scraper requires, so pull-docs stages an annotated copy
# here and the scraper reads that instead. See hack/prepare-docs.sh.
export TERRAFORM_SCRAPE_DOCS_PATH ?= .scrape/resources


PLATFORMS ?= linux_amd64 linux_arm64

# -include will silently skip missing files, which allows us
# to load those files with a target in the Makefile. If only
# "include" was used, the make command would fail and refuse
# to run a target until the include commands succeeded.
-include build/makelib/common.mk

# ====================================================================================
# Setup Output

-include build/makelib/output.mk

# ====================================================================================
# Setup Go

# Set a sane default so that the nprocs calculation below is less noisy on the initial
# loading of this file
NPROCS ?= 1

# each of our test suites starts a kube-apiserver and running many test suites in
# parallel can lead to high CPU utilization. by default we reduce the parallelism
# to half the number of CPU cores.
GO_TEST_PARALLEL := $(shell echo $$(( $(NPROCS) / 2 )))

GO_REQUIRED_VERSION ?= 1.26
GOLANGCILINT_VERSION ?= 2.13.0
GO_STATIC_PACKAGES = $(GO_PROJECT)/cmd/provider $(GO_PROJECT)/cmd/generator
GO_LDFLAGS += -X $(GO_PROJECT)/internal/version.Version=$(VERSION)
GO_SUBDIRS += cmd internal apis
-include build/makelib/golang.mk

# ====================================================================================
# Setup Kubernetes tools

KIND_VERSION = v0.31.0
UPTEST_VERSION = v2.2.0
CRDDIFF_VERSION = v0.12.1
CROSSPLANE_CLI_VERSION = v2.2.1
# for e2e testing
CROSSPLANE_VERSION = 2.2.1
-include build/makelib/k8s_tools.mk

# ====================================================================================
# Setup Images

REGISTRY_ORGS ?= ghcr.io/thecodingsheikh
IMAGES = $(PROJECT_NAME)
-include build/makelib/imagelight.mk

# ====================================================================================
# Setup XPKG

XPKG_REG_ORGS ?= xpkg.upbound.io/thecodingsheikh
# NOTE(hasheddan): skip promoting on xpkg.crossplane.io as channel tags are
# inferred. The same applies to xpkg.upbound.io.
XPKG_REG_ORGS_NO_PROMOTE ?= xpkg.upbound.io/thecodingsheikh
XPKGS = $(PROJECT_NAME)
-include build/makelib/xpkg.mk

# ====================================================================================
# Fallthrough

# run `make help` to see the targets and options

# We want submodules to be set up the first time `make` is run.
# We manage the build/ folder and its Makefiles as a submodule.
# The first time `make` is run, the includes of build/*.mk files will
# all fail, and this target will be run. The next time, the default as defined
# by the includes will be run instead.
fallthrough: submodules
	@echo Initial setup complete. Running make again . . .
	@make

# NOTE(hasheddan): we force image building to happen prior to xpkg build so that
# we ensure image is present in daemon.
xpkg.build.provider-litellm: do.build.images

# NOTE(hasheddan): we ensure up is installed prior to running platform-specific
# build steps in parallel to avoid encountering an installation race condition.
build.init: $(UP) $(CROSSPLANE_CLI) check-terraform-version

# ====================================================================================
# Setup Terraform for fetching provider schema
TERRAFORM := $(TOOLS_HOST_DIR)/terraform-$(TERRAFORM_VERSION)
TERRAFORM_WORKDIR := $(WORK_DIR)/terraform
TERRAFORM_PROVIDER_SCHEMA := config/schema.json
export TERRAFORM_PROVIDER_SRC := $(WORK_DIR)/tf-provider-src
export TERRAFORM_PROVIDER_MIRROR := $(WORK_DIR)/tf-mirror

# Retained as a build.init hook; the BSL ceiling no longer applies because the
# binary is OpenTofu rather than Terraform.
check-terraform-version:
	@:

$(TERRAFORM): check-terraform-version
	@$(INFO) installing opentofu $(TERRAFORM_VERSION) $(HOSTOS)-$(HOSTARCH)
	@mkdir -p $(TOOLS_HOST_DIR)/tmp-terraform
	@curl -fsSL $(OPENTOFU_DOWNLOAD_URL) -o $(TOOLS_HOST_DIR)/tmp-terraform/tofu.zip
	@unzip -q $(TOOLS_HOST_DIR)/tmp-terraform/tofu.zip -d $(TOOLS_HOST_DIR)/tmp-terraform
	@# upjet invokes an executable named `terraform`.
	@mv $(TOOLS_HOST_DIR)/tmp-terraform/tofu $(TERRAFORM)
	@chmod +x $(TERRAFORM)
	@rm -fr $(TOOLS_HOST_DIR)/tmp-terraform
	@$(OK) installing opentofu $(TERRAFORM_VERSION) $(HOSTOS)-$(HOSTARCH)

# Build the upstream provider from source for every platform the image needs
# plus the host, so schema generation and the runtime image share one mirror.
TERRAFORM_PROVIDER_HOST_PLATFORM := $(HOSTOS)_$(patsubst x86_64,amd64,$(patsubst aarch64,arm64,$(HOSTARCH)))
terraform-provider: 
	@$(INFO) building $(TERRAFORM_PROVIDER_SOURCE) from $(TERRAFORM_PROVIDER_REF)
	@./hack/build-terraform-provider.sh \
		"$(TERRAFORM_PROVIDER_REPO)" "$(TERRAFORM_PROVIDER_REF)" "$(TERRAFORM_PROVIDER_VERSION)" \
		"$(TERRAFORM_PROVIDER_SRC)" "$(TERRAFORM_PROVIDER_MIRROR)" \
		$(TERRAFORM_PROVIDER_HOST_PLATFORM) $(filter-out $(TERRAFORM_PROVIDER_HOST_PLATFORM),$(filter linux_%,$(PLATFORMS))) || $(FAIL)
	@$(OK) building $(TERRAFORM_PROVIDER_SOURCE) from $(TERRAFORM_PROVIDER_REF)

# Exercise the focused regression test embedded in the Crossplane compatibility
# patch. The provider wrapper's normal unit tests do not run tests from the
# Terraform provider source that the runtime image embeds.
.PHONY: test-terraform-provider-patch
test-terraform-provider-patch:
	@./hack/build-terraform-provider.sh \
		"$(TERRAFORM_PROVIDER_REPO)" "$(TERRAFORM_PROVIDER_REF)" "$(TERRAFORM_PROVIDER_VERSION)" \
		"$(TERRAFORM_PROVIDER_SRC)" "$(TERRAFORM_PROVIDER_MIRROR)" linux_amd64 || $(FAIL)
	@cd "$(TERRAFORM_PROVIDER_SRC)" && grep -Fq 'func TestReadKeyClearsOrganizationIDWhenAPIOmitsIt(' internal/provider/resource_key_test.go && grep -Fq 'func TestKeyWriteOnlyCrossplaneUpdateRetainsPlannedValueProtocol(' internal/provider/key_wo_crossplane_protocol_test.go && go test ./internal/provider -run 'TestReadKeyClearsOrganizationIDWhenAPIOmitsIt|TestKeyWriteOnlyCrossplane(Create|Update)RetainsPlannedValueProtocol' -count=1 || $(FAIL)

$(TERRAFORM_PROVIDER_SCHEMA): $(TERRAFORM) terraform-provider
	@$(INFO) generating provider schema for $(TERRAFORM_PROVIDER_SOURCE) $(TERRAFORM_PROVIDER_VERSION)
	@# Start clean: the lock file pins the previous version, and the version
	@# moves whenever TERRAFORM_PROVIDER_REF does.
	@rm -rf $(TERRAFORM_WORKDIR)
	@mkdir -p $(TERRAFORM_WORKDIR)
	@echo '{"terraform":[{"required_providers":[{"provider":{"source":"'"$(TERRAFORM_PROVIDER_SOURCE)"'","version":"'"$(TERRAFORM_PROVIDER_VERSION)"'"}}],"required_version":"'"$(TERRAFORM_VERSION)"'"}]}' > $(TERRAFORM_WORKDIR)/main.tf.json
	@TF_CLI_CONFIG_FILE=$(TERRAFORM_PROVIDER_MIRROR)/terraformrc $(TERRAFORM) -chdir=$(TERRAFORM_WORKDIR) init > $(TERRAFORM_WORKDIR)/terraform-logs.txt 2>&1
	@TF_CLI_CONFIG_FILE=$(TERRAFORM_PROVIDER_MIRROR)/terraformrc $(TERRAFORM) -chdir=$(TERRAFORM_WORKDIR) providers schema -json=true > $(TERRAFORM_PROVIDER_SCHEMA) 2>> $(TERRAFORM_WORKDIR)/terraform-logs.txt
	@$(OK) generating provider schema for $(TERRAFORM_PROVIDER_SOURCE) $(TERRAFORM_PROVIDER_VERSION)

# Docs come from the same checkout the binary was built from, so they always
# describe exactly the schema that was generated.
pull-docs: terraform-provider
	@./hack/prepare-docs.sh "$(TERRAFORM_PROVIDER_SRC)/$(TERRAFORM_DOCS_PATH)" "$(TERRAFORM_PROVIDER_SRC)/$(TERRAFORM_SCRAPE_DOCS_PATH)" "$(shell echo $(TERRAFORM_PROVIDER_DOWNLOAD_NAME) | sed 's/^terraform-provider-//')"

generate.init: $(TERRAFORM_PROVIDER_SCHEMA) pull-docs

.PHONY: $(TERRAFORM_PROVIDER_SCHEMA) pull-docs check-terraform-version terraform-provider
# ====================================================================================
# Targets

# NOTE: the build submodule currently overrides XDG_CACHE_HOME in order to
# force the Helm 3 to use the .work/helm directory. This causes Go on Linux
# machines to use that directory as the build cache as well. We should adjust
# this behavior in the build submodule because it is also causing Linux users
# to duplicate their build cache, but for now we just make it easier to identify
# its location in CI so that we cache between builds.
go.cachedir:
	@go env GOCACHE

go.mod.cachedir:
	@go env GOMODCACHE

# Generate a coverage report for cobertura applying exclusions on
# - generated file
cobertura:
	@cat $(GO_TEST_OUTPUT)/coverage.txt | \
		grep -v zz_ | \
		$(GOCOVER_COBERTURA) > $(GO_TEST_OUTPUT)/cobertura-coverage.xml

# Update the submodules, such as the common build scripts.
submodules:
	@git submodule sync
	@git submodule update --init --recursive

# This is for running out-of-cluster locally, and is for convenience. Running
# this make target will print out the command which was used. For more control,
# try running the binary directly with different arguments.
run: go.build
	@$(INFO) Running Crossplane locally out-of-cluster . . .
	@# To see other arguments that can be provided, run the command with --help instead
	$(GO_OUT_DIR)/provider --debug

# ====================================================================================
# End to End Testing
CROSSPLANE_NAMESPACE = crossplane-system
-include build/makelib/local.xpkg.mk
-include build/makelib/controlplane.mk

# This target requires the following environment variables to be set:
# - UPTEST_EXAMPLE_LIST, a comma-separated list of examples to test
#   To ensure the proper functioning of the end-to-end test resource pre-deletion hook, it is crucial to arrange your resources appropriately.
#   You can check the basic implementation here: https://github.com/crossplane/uptest/blob/main/internal/templates/03-delete.yaml.tmpl.
# - UPTEST_CLOUD_CREDENTIALS (optional), multiple sets of AWS IAM User credentials specified as key=value pairs.
#   The support keys are currently `DEFAULT` and `PEER`. So, an example for the value of this env. variable is:
#   DEFAULT='[default]
#   aws_access_key_id = REDACTED
#   aws_secret_access_key = REDACTED'
#   PEER='[default]
#   aws_access_key_id = REDACTED
#   aws_secret_access_key = REDACTED'
#   The associated `ProviderConfig`s will be named as `default` and `peer`.
# - UPTEST_DATASOURCE_PATH (optional), please see https://github.com/crossplane/uptest#injecting-dynamic-values-and-datasource
uptest: $(UPTEST) $(KUBECTL) $(CHAINSAW) $(CROSSPLANE_CLI)
	@$(INFO) running automated tests
	@KUBECTL=$(KUBECTL) CHAINSAW=$(CHAINSAW) CROSSPLANE_CLI=$(CROSSPLANE_CLI) CROSSPLANE_NAMESPACE=$(CROSSPLANE_NAMESPACE) $(UPTEST) e2e "${UPTEST_EXAMPLE_LIST}" --data-source="${UPTEST_DATASOURCE_PATH}" --setup-script=cluster/test/setup.sh --default-conditions="Test" || $(FAIL)
	@$(OK) running automated tests

local-deploy: build controlplane.up local.xpkg.deploy.provider.$(PROJECT_NAME)
	@$(INFO) running locally built provider
	@$(KUBECTL) wait provider.pkg $(PROJECT_NAME) --for condition=Healthy --timeout 5m
	@$(KUBECTL) -n crossplane-system wait --for=condition=Available deployment --all --timeout=5m
	@$(OK) running locally built provider

e2e: local-deploy uptest

crddiff: $(UPTEST)
	@$(INFO) Checking breaking CRD schema changes
	@for crd in $${MODIFIED_CRD_LIST}; do \
		if ! git cat-file -e "$${GITHUB_BASE_REF}:$${crd}" 2>/dev/null; then \
			echo "CRD $${crd} does not exist in the $${GITHUB_BASE_REF} branch. Skipping..." ; \
			continue ; \
		fi ; \
		echo "Checking $${crd} for breaking API changes..." ; \
		changes_detected=$$(go run github.com/crossplane/uptest/cmd/crddiff@$(CRDDIFF_VERSION) revision --enable-upjet-extensions <(git cat-file -p "$${GITHUB_BASE_REF}:$${crd}") "$${crd}" 2>&1) ; \
		if [[ $$? != 0 ]] ; then \
			printf "\033[31m"; echo "Breaking change detected!"; printf "\033[0m" ; \
			echo "$${changes_detected}" ; \
			echo ; \
		fi ; \
	done
	@$(OK) Checking breaking CRD schema changes

schema-version-diff:
	@$(INFO) Checking for native state schema version changes
	@export PREV_PROVIDER_VERSION=$$(git cat-file -p "${GITHUB_BASE_REF}:Makefile" | sed -nr 's/^export[[:space:]]*TERRAFORM_PROVIDER_VERSION[[:space:]]*:=[[:space:]]*(.+)/\1/p'); \
	echo Detected previous Terraform provider version: $${PREV_PROVIDER_VERSION}; \
	echo Current Terraform provider version: $${TERRAFORM_PROVIDER_VERSION}; \
	mkdir -p $(WORK_DIR); \
	git cat-file -p "$${GITHUB_BASE_REF}:config/schema.json" > "$(WORK_DIR)/schema.json.$${PREV_PROVIDER_VERSION}"; \
	./scripts/version_diff.py config/generated.lst "$(WORK_DIR)/schema.json.$${PREV_PROVIDER_VERSION}" config/schema.json
	@$(OK) Checking for native state schema version changes

.PHONY: cobertura submodules fallthrough run crds.clean

# ====================================================================================
# Special Targets

define CROSSPLANE_MAKE_HELP
Crossplane Targets:
    cobertura             Generate a coverage report for cobertura applying exclusions on generated files.
    submodules            Update the submodules, such as the common build scripts.
    run                   Run crossplane locally, out-of-cluster. Useful for development.

endef
# The reason CROSSPLANE_MAKE_HELP is used instead of CROSSPLANE_HELP is because the crossplane
# binary will try to use CROSSPLANE_HELP if it is set, and this is for something different.
export CROSSPLANE_MAKE_HELP

crossplane.help:
	@echo "$$CROSSPLANE_MAKE_HELP"

help-special: crossplane.help

.PHONY: crossplane.help help-special

# TODO(negz): Update CI to use these targets.
vendor: modules.download
vendor.check: modules.check
