export SHELL := $(shell env which bash)

# if PROG is not defined then set it to rexray
ifeq (,$(strip $(PROG)))
PROG := rexray
endif

# this makefile's default target is PROG
all: $(PROG)

# detect whether go and docker are available locally
GO := $(shell ! which go > /dev/null 2>&1 || echo 1)
DOCKER := $(shell ! docker version > /dev/null 2>&1 || echo 1)

# store the current directory
PWD := $(shell pwd)

# if GO_VERSION is not defined then parse it from the .travis.yml file
ifeq (,$(strip $(GO_VERSION)))
GO_VERSION := $(shell grep "go:" .travis.yml | awk '{print $$2}')
endif

# if GO_IMPORT_PATH is not defined then parse it from the .travis.yml file
ifeq (,$(strip $(GO_IMPORT_PATH)))
GO_IMPORT_PATH := $(shell grep "go_import_path:" .travis.yml | awk '{print $$2}')
endif


################################################################################
##                                BUILD                                       ##
################################################################################
ifneq (,$(strip $(DRIVER)))
BUILD_TAGS += $(DRIVER)
endif

ifneq (,$(strip $(TYPE)))
BUILD_TAGS += $(TYPE)
endif

GOBUILD := build
ifneq (,$(strip $(BUILD_TAGS)))
GOBUILD += -tags '$(BUILD_TAGS)'
endif

# if docker is avaialble then default to using it to build REX-Ray,
# otherwise check to see if go is available. if neither are
# available then print an error
$(PROG):
ifeq ($(XDOCKER)1,$(DOCKER))
	docker run -it -v "$(PWD)":"/go/src/$(GO_IMPORT_PATH)" golang:$(GO_VERSION) bash -c "cd \"src/$(GO_IMPORT_PATH)\" && go generate && go $(GOBUILD) -o \"$(PROG)\""
else
ifeq ($(XGO)1,$(GO))
	go generate && go $(GOBUILD) -o "$(PROG)"
else
	@echo "either docker or go is required to build REX-Ray"
	exit 1
endif
endif

clean-build:
	rm -f rexray rexray-client rexray-agent rexray-controller
clean: clean-build

.PHONY: clean-build


################################################################################
##                                SEMVER                                      ##
################################################################################
# the path to the semver.env file that all non-build targets use in
# order to ensure that they have access to the version-related data
# generated by `go generate`
SEMVER_MK := semver.mk

ifneq (true,$(TRAVIS))
$(SEMVER_MK): .git
endif

$(SEMVER_MK):
ifeq ($(XDOCKER)1,$(DOCKER))
	docker run -it -v "$(PWD)":"/go/src/$(GO_IMPORT_PATH)" golang:$(GO_VERSION) bash -c "cd \"src/$(GO_IMPORT_PATH)\" && go run core/semver/semver.go -f mk -o $@"
else
ifeq ($(XGO)1,$(GO))
	go run core/semver/semver.go -f mk -o $@
else
	@echo "either docker or go is required to build REX-Ray"
	exit 1
endif
endif

include $(SEMVER_MK)


################################################################################
##                                TGZ                                         ##
################################################################################
TGZ := $(PROG)-$(OS)-$(ARCH)-$(SEMVER).tar.gz
tgz: $(TGZ)
$(TGZ): $(PROG)
	tar -czf $@ $<
clean-tgz:
	rm -fr $(TGZ)
clean: clean-tgz
.PHONY: clean-tgz


################################################################################
##                                RPM                                         ##
################################################################################
RPMDIR := .rpm
RPM := $(PROG)-$(SEMVER_RPM)-1.$(ARCH).rpm
rpm: $(RPM)
$(RPM): $(PROG)
	rm -fr $(RPMDIR)
	mkdir -p $(RPMDIR)/BUILD \
			 $(RPMDIR)/RPMS \
			 $(RPMDIR)/SRPMS \
			 $(RPMDIR)/SPECS \
			 $(RPMDIR)/SOURCES \
			 $(RPMDIR)/tmp
	cp rpm.spec $(RPMDIR)/SPECS/$(<F).spec
	cd $(RPMDIR) && \
		setarch $(ARCH) rpmbuild -ba \
			-D "rpmbuild $(abspath $(RPMDIR))" \
			-D "v_semver $(SEMVER_RPM)" \
			-D "v_arch $(ARCH)" \
			-D "prog_name $(<F)" \
			-D "prog_path $(abspath $<)" \
			SPECS/$(<F).spec
	mv $(RPMDIR)/RPMS/$(ARCH)/$(RPM) $@
clean-rpm:
	rm -fr $(RPM)
clean: clean-rpm
.PHONY: clean-rpm


################################################################################
##                                DEB                                         ##
################################################################################
DEB := $(PROG)_$(SEMVER_RPM)-1_$(GOARCH).deb
deb: $(DEB)
$(DEB): $(RPM)
	fakeroot alien -k -c --bump=0 $<
clean-deb:
	rm -fr $(DEB)
clean: clean-deb
.PHONY: clean-deb


################################################################################
##                              BINTRAY                                      ##
################################################################################
BINTRAY_FILES := $(foreach r,unstable staged stable,bintray-$r.json)
ifeq (,$(strip $(BINTRAY_SUBJ)))
BINTRAY_SUBJ := emccode
endif

define BINTRAY_GENERATED_JSON
{
   "package": {
        "name":     "$${REPO}",
        "repo":     "$(PROG)",
        "subject":  "$(BINTRAY_SUBJ)"
    },
    "version": {
        "name":     "$(SEMVER)",
        "desc":     "$(SEMVER).Sha.$(SHA32)",
        "released": "$(RELEASE_DATE)",
        "vcs_tag":  "v$(SEMVER)",
        "gpgSign":  false
    },
    "files": [{
        "includePattern": "./($(PROG).*?\.(?:gz|rpm|deb))",
        "excludePattern": "./.*/.*",
        "uploadPattern":  "$${REPO}/$(SEMVER)/$1"
    }],
    "publish": true
}
endef
export BINTRAY_GENERATED_JSON

bintray: $(BINTRAY_FILES)
$(BINTRAY_FILES):
	@echo generating $@
	@echo "$$BINTRAY_GENERATED_JSON" | \
	sed -e 's/$${REPO}/$(@F:bintray-%.json=%)/g' > $@

clean-bintray:
	rm -f $(BINTRAY_FILES)
clean: clean-bintray

.PHONY: clean-bintray


################################################################################
##                                   TEST                                     ##
################################################################################
test:
	$(MAKE) -C libstorage test

.PHONY: test


################################################################################
##                                  COVERAGE                                  ##
################################################################################
COVERAGE_IMPORTS := github.com/onsi/gomega \
  github.com/onsi/ginkgo \
  golang.org/x/tools/cmd/cover

COVERAGE_IMPORTS_PATHS := $(addprefix $(GOPATH)/src/,$(COVERAGE_IMPORTS))

$(COVERAGE_IMPORTS_PATHS):
	go get $(subst $(GOPATH)/src/,,$@)

coverage.out:
	printf "mode: set\n" > coverage.out
	for f in $$(find libstorage -name "*.test.out" -type f); do \
	  grep -v "mode :set" $$f >> coverage.out; \
	done

cover: coverage.out | $(COVERAGE_IMPORTS_PATHS)
	curl -sSL https://codecov.io/bash | bash -s -- -f $<

.PHONY: coverage.out cover


################################################################################
##                                  DOCKER                                    ##
################################################################################
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
SPACE6 := $(SPACE)$(SPACE)$(SPACE)$(SPACE)$(SPACE)$(SPACE)
SPACE8 := $(SPACE6)$(SPACE)$(SPACE)

DOCKER_SEMVER := $(subst +,-,$(SEMVER))
DOCKER_DRIVER := $(DRIVER)

ifeq (undefined,$(origin DOCKER_PLUGIN_ROOT))
DOCKER_PLUGIN_ROOT := $(PROG)
endif
DOCKER_PLUGIN_NAME := $(DOCKER_PLUGIN_ROOT)/$(DOCKER_DRIVER):$(DOCKER_SEMVER)
DOCKER_PLUGIN_NAME_UNSTABLE := $(DOCKER_PLUGIN_ROOT)/$(DOCKER_DRIVER):edge
DOCKER_PLUGIN_NAME_STAGED := $(DOCKER_PLUGIN_NAME)
DOCKER_PLUGIN_NAME_STABLE := $(DOCKER_PLUGIN_ROOT)/$(DOCKER_DRIVER):latest

DOCKER_PLUGIN_BUILD_PATH := .docker/plugins/$(DOCKER_DRIVER)

DOCKER_PLUGIN_DOCKERFILE := $(DOCKER_PLUGIN_BUILD_PATH)/.Dockerfile
ifeq (,$(strip $(wildcard $(DOCKER_PLUGIN_DOCKERFILE))))
DOCKER_PLUGIN_DOCKERFILE := .docker/plugins/Dockerfile
endif
DOCKER_PLUGIN_DOCKERFILE_TGT := $(DOCKER_PLUGIN_BUILD_PATH)/Dockerfile
$(DOCKER_PLUGIN_DOCKERFILE_TGT): $(DOCKER_PLUGIN_DOCKERFILE)
	cp -f $? $@

DOCKER_PLUGIN_ENTRYPOINT := $(DOCKER_PLUGIN_BUILD_PATH)/.rexray.sh
ifeq (,$(strip $(wildcard $(DOCKER_PLUGIN_ENTRYPOINT))))
DOCKER_PLUGIN_ENTRYPOINT := .docker/plugins/rexray.sh
endif
DOCKER_PLUGIN_ENTRYPOINT_TGT := $(DOCKER_PLUGIN_BUILD_PATH)/$(PROG).sh
$(DOCKER_PLUGIN_ENTRYPOINT_TGT): $(DOCKER_PLUGIN_ENTRYPOINT)
	cp -f $? $@

DOCKER_PLUGIN_CONFIGFILE := $(DOCKER_PLUGIN_BUILD_PATH)/.rexray.yml
DOCKER_PLUGIN_CONFIGFILE_TGT := $(DOCKER_PLUGIN_BUILD_PATH)/$(PROG).yml
ifeq (,$(strip $(wildcard $(DOCKER_PLUGIN_CONFIGFILE))))
DOCKER_PLUGIN_CONFIGFILE := .docker/plugins/rexray.yml
$(DOCKER_PLUGIN_CONFIGFILE_TGT): $(DOCKER_PLUGIN_CONFIGFILE)
	sed -e 's/$${DRIVER}/$(DRIVER)/g' $? > $@
else
$(DOCKER_PLUGIN_CONFIGFILE_TGT): $(DOCKER_PLUGIN_CONFIGFILE)
	cp -f $? $@
endif

DOCKER_PLUGIN_REXRAYFILE := $(PROG)
DOCKER_PLUGIN_REXRAYFILE_TGT := $(DOCKER_PLUGIN_BUILD_PATH)/$(PROG)
$(DOCKER_PLUGIN_REXRAYFILE_TGT): $(DOCKER_PLUGIN_REXRAYFILE)
	cp -f $? $@

DOCKER_PLUGIN_CONFIGJSON_TGT := $(DOCKER_PLUGIN_BUILD_PATH)/config.json

DOCKER_PLUGIN_ENTRYPOINT_ROOTFS_TGT := $(DOCKER_PLUGIN_BUILD_PATH)/rootfs/$(PROG).sh
docker-build-plugin: build-docker-plugin
build-docker-plugin: $(DOCKER_PLUGIN_ENTRYPOINT_ROOTFS_TGT)
$(DOCKER_PLUGIN_ENTRYPOINT_ROOTFS_TGT): $(DOCKER_PLUGIN_CONFIGJSON_TGT) \
										$(DOCKER_PLUGIN_DOCKERFILE_TGT) \
										$(DOCKER_PLUGIN_ENTRYPOINT_TGT) \
										$(DOCKER_PLUGIN_CONFIGFILE_TGT) \
										$(DOCKER_PLUGIN_REXRAYFILE_TGT)
	docker plugin rm $(DOCKER_PLUGIN_NAME) 2> /dev/null || true
	sudo rm -fr $(@D)
	docker build \
	  --label `driver="$(DRIVER)"` \
	  --label `semver="$(SEMVER)"` \
	  -t rootfsimage $(<D) && \
	  id=$$(docker create rootfsimage true) && \
	  sudo mkdir -p $(@D) && \
	  sudo docker export "$$id" | sudo tar -x -C $(@D) && \
	  docker rm -vf "$$id" && \
	  docker rmi rootfsimage
	sudo docker plugin create $(DOCKER_PLUGIN_NAME) $(<D)
	docker plugin ls

push-docker-plugin:
ifeq (1,$(DOCKER_PLUGIN_$(DOCKER_DRIVER)_NOPUSH))
	echo "docker plugin push disabled"
else
	@docker login -u $(DOCKER_USER) -p $(DOCKER_PASS)
ifeq (unstable,$(DOCKER_PLUGIN_TYPE))
	sudo docker plugin create $(DOCKER_PLUGIN_NAME_UNSTABLE) $(DOCKER_PLUGIN_BUILD_PATH)
	docker plugin push $(DOCKER_PLUGIN_NAME_UNSTABLE)
endif
ifeq (staged,$(DOCKER_PLUGIN_TYPE))
	docker plugin push $(DOCKER_PLUGIN_NAME_STAGED)
endif
ifeq (stable,$(DOCKER_PLUGIN_TYPE))
	docker plugin push $(DOCKER_PLUGIN_NAME)
	sudo docker plugin create $(DOCKER_PLUGIN_NAME_UNSTABLE) $(DOCKER_PLUGIN_BUILD_PATH)
	docker plugin push $(DOCKER_PLUGIN_NAME_UNSTABLE)
	sudo docker plugin create $(DOCKER_PLUGIN_NAME_STABLE) $(DOCKER_PLUGIN_BUILD_PATH)
	docker plugin push $(DOCKER_PLUGIN_NAME_STABLE)
endif
ifeq (,$(DOCKER_PLUGIN_TYPE))
	docker plugin push $(DOCKER_PLUGIN_NAME)
endif
endif

.PHONY: docker-build-plugin build-docker-plugin push-docker-plugin


################################################################################
##                                   CLEAN                                    ##
################################################################################
clean:

.PHONY: all clean
