SHELL := /bin/bash

ifneq ($(strip $(V)),)
  hide :=
else
  hide := @
endif

LATEST := $(shell cat latest)

DOCKER ?= docker
DOCKER_REPO := $(shell cat repo)
DOCKER_USER := $(shell $(DOCKER) info | awk '/^Username:/ { print $$2 }')
SUDO ?= sudo
MKIMAGE ?= mkimage.sh
MKIMAGE := $(shell readlink -f $(MKIMAGE))

DEBOOTSTRAP_VERSION := $(shell dpkg-query -W -f '$${Version}' debootstrap)
DEBOOTSTRAP_ARGS_COMMON := \
  $(if $(shell dpkg --compare-versions "$$debootstrapVersion" '>=' '1.0.69' && echo true),--force-check-gpg)

# $(1): relative directory path, e.g. "jessie/amd64"
# $(2): file name, e.g. suite
# $(3): default value
define get-part
$(shell if [ -f $(1)/$(2) ]; then cat $(1)/$(2); elif [ -f $(2) ]; then cat $(2); else echo "$(3)"; fi)
endef

# $(1): relative directory path, e.g. "jessie/amd64"
define target-name-from-path
$(subst /,-,$(1))
endef

# $(1): relative directory path, e.g. "jessie/amd64"
define suite-name-from-path
$(word 1,$(subst /, ,$(1)))
endef

# $(1): relative directory path, e.g. "jessie/amd64"
define arch-name-from-path
$(word 2,$(subst /, ,$(1)))
endef

# $(1): relative directory path, e.g. "jessie/amd64/curl"
define func-name-from-path
$(word 3,$(subst /, ,$(1)))
endef

# $(1): relative directory path, e.g. "jessie/amd64"
define base-image-from-path
$(shell cat $(1)/Dockerfile | grep ^FROM | awk '{print $$2}')
endef

# $(1): base image name, e.g. "foo/bar:tag"
define enumerate-build-dep-for-docker-build-inner
$(if $(filter $(DOCKER_USER)/$(DOCKER_REPO):%,$(1)),$(patsubst $(DOCKER_USER)/$(DOCKER_REPO):%,%,$(1)))
endef

# $(1): relative directory path, e.g. "jessie/amd64", "jessie/amd64/scm"
define enumerate-build-dep-for-docker-build
$(call enumerate-build-dep-for-docker-build-inner,$(call base-image-from-path,$(1)))
endef

# $(1): suite
# $(2): arch
# $(3): func
# $(4): version
define enumerate-additional-tags-for
$(if $(filter amd64,$(2)),$(1)$(if $(3),-$(3))) \
$(if $(filter $(LATEST),$(1)), \
  latest-$(2)$(if $(3),-$(3)) \
  $(if $(filter amd64,$(2)),latest$(if $(3),-$(3)))) \
$(4)-$(2)$(if $(3),-$(3)) \
$(if $(filter amd64,$(2)),$(4)$(if $(3),-$(3)))
endef

define do-rootfs-tarball
@echo "$@ <= building";
$(hide) args=( -d "$(@D)" debootstrap --arch="$(PRIVATE_ARCH)" ); \
$(if $(PRIVATE_VARIANT),args+=( --variant="$(PRIVATE_VARIANT)" );) \
$(if $(PRIVATE_COMPONENTS),args+=( --components="$(PRIVATE_COMPONENTS)" );) \
$(if $(PRIVATE_INCLUDE),args+=( --include="$(PRIVATE_INCLUDE)" );) \
$(if $(DEBOOTSTRAP_ARGS_COMMON),args+=( $(DEBOOTSTRAP_ARGS_COMMON) );) \
args+=( "$(PRIVATE_SUITE)" ); \
$(if $(PRIVATE_MIRROR), \
  args+=( "$(PRIVATE_MIRROR)" ); \
  $(if $(PRIVATE_SCRIPT),args+=( "$(PRIVATE_SCRIPT)" );)) \
$(SUDO) $(PRIVATE_ENVS) nice ionice -c 3 "$(MKIMAGE)" "$${args[@]}" 2>&1 | tee "$(@D)/build.log"; \
{ \
  echo "$$(basename "$(MKIMAGE)") $${args[*]/"$(@D)"/.}"; \
  echo; \
  echo 'https://github.com/docker/docker/blob/master/contrib/mkimage.sh'; \
} > $(@D)/build-command.txt;
$(hide) $(SUDO) $(PRIVATE_ENVS) chown -R "$$(id -u):$$(id -g)" "$(@D)";

endef

# $(1): relative directory path, e.g. "jessie/amd64", "jessie/amd64/scm"
# $(2): target name, e.g. jessie-amd64-scm
# $(3): suite name, e.g. jessie
# $(4): arch name, e.g. amd64
# $(5): func name, e.g. scm
define define-build-rootfs-tarball-target
$(2): $(1)/rootfs.tar.xz
$(1)/rootfs.tar.xz: PRIVATE_TARGET := $(2)
$(1)/rootfs.tar.xz: PRIVATE_PATH := $(1)
$(1)/rootfs.tar.xz: PRIVATE_SUITE := $(3)
$(1)/rootfs.tar.xz: PRIVATE_ARCH := $(4)
$(1)/rootfs.tar.xz: PRIVATE_VARIANT := $(call get-part,$(1),variant,minbase)
$(1)/rootfs.tar.xz: PRIVATE_COMPONENTS := $(call get-part,$(1),components,main)
$(1)/rootfs.tar.xz: PRIVATE_INCLUDE := $(call get-part,$(1),include)
$(1)/rootfs.tar.xz: PRIVATE_MIRROR := $(call get-part,$(1),mirror)
$(1)/rootfs.tar.xz: PRIVATE_SCRIPT := $(call get-part,$(1),script)
$(1)/rootfs.tar.xz: PRIVATE_ENVS := $(call get-part,$(1),envs)
$(1)/rootfs.tar.xz:
	$$(call do-rootfs-tarball)

docker-build-$(2): $(1)/rootfs.tar.xz

endef

define do-docker-build
@echo "$@ <= docker building $(PRIVATE_PATH)";
$(hide) if [ -n "$(FORCE)" -o -z "$$($(DOCKER) inspect $(DOCKER_USER)/$(DOCKER_REPO):$(PRIVATE_TARGET) 2>/dev/null | grep Created)" ]; then \
  $(DOCKER) build -t $(DOCKER_USER)/$(DOCKER_REPO):$(PRIVATE_TARGET) $(PRIVATE_PATH); \
  $(DOCKER) run --rm "$(DOCKER_USER)/$(DOCKER_REPO):$(PRIVATE_TARGET)" bash -xc ' \
    cat /etc/apt/sources.list; \
    echo; \
    cat /etc/os-release 2>/dev/null; \
    echo; \
    cat /etc/lsb-release 2>/dev/null; \
    echo; \
    cat /etc/debian_version 2>/dev/null; \
    true; \
  '; \
  $(DOCKER) run --rm "$(DOCKER_USER)/$(DOCKER_REPO):$(PRIVATE_TARGET)" dpkg-query -f '$${Package}\t$${Version}\n' -W > "$(PRIVATE_PATH)/build.manifest"; \
fi

endef

# $(1): relative directory path, e.g. "jessie/amd64", "jessie/amd64/scm"
# $(2): target name, e.g. jessie-amd64-scm
# $(3): suite name, e.g. jessie
# $(4): arch name, e.g. amd64
# $(5): func name, e.g. scm
define define-docker-build-target
.PHONY: docker-build-$(2)
$(2): docker-build-$(2)
docker-build-$(2): PRIVATE_TARGET := $(2)
docker-build-$(2): PRIVATE_PATH := $(1)
docker-build-$(2): $(call enumerate-build-dep-for-docker-build,$(1))
	$$(call do-docker-build)

endef

define do-docker-tag
@echo "$@ <= docker tagging $(PRIVATE_PATH)";
$(hide) for tag in $(PRIVATE_TAGS); do \
  $(DOCKER) tag -f $(DOCKER_USER)/$(DOCKER_REPO):$(PRIVATE_TARGET) $(DOCKER_USER)/$(DOCKER_REPO):$${tag}; \
done

endef

# $(1): relative directory path, e.g. "jessie/amd64", "jessie/amd64/scm"
# $(2): target name, e.g. jessie-amd64-scm
# $(3): suite name, e.g. jessie
# $(4): arch name, e.g. amd64
# $(5): func name, e.g. scm
# $(6): version, e.g. 15.04
define define-docker-tag-target
.PHONY: docker-tag-$(2)
$(2): docker-tag-$(2)
docker-tag-$(2): PRIVATE_TARGET := $(2)
docker-tag-$(2): PRIVATE_PATH := $(1)
docker-tag-$(2): PRIVATE_TAGS := $(call enumerate-additional-tags-for,$(3),$(4),$(5),$(6))
docker-tag-$(2): docker-build-$(2)
	$$(call do-docker-tag)

endef

# $(1): relative directory path, e.g. "jessie/amd64", "jessie/amd64/scm"
define define-target-from-path
$(eval target := $(call target-name-from-path,$(1)))
$(eval suite := $(call suite-name-from-path,$(1)))
$(eval arch := $(call arch-name-from-path,$(1)))
$(eval func := $(call func-name-from-path,$(1)))
$(eval version := $(shell cat $(suite)/version))

.PHONY: $(target) $(suite) $(arch) $(func)
all: $(target)
$(suite): $(target)
$(arch): $(target)
$(if $(func),$(func): $(target))
$(target):
	@echo "$$@ done"

$(if $(filter scratch,$(call base-image-from-path,$(1))), \
  $(call define-build-rootfs-tarball-target,$(1),$(target),$(suite),$(arch),$(func)))
$(call define-docker-build-target,$(1),$(target),$(suite),$(arch),$(func))
$(if $(strip $(call enumerate-additional-tags-for,$(suite),$(arch),$(func),$(version))), \
  $(call define-docker-tag-target,$(1),$(target),$(suite),$(arch),$(func),$(version)))

endef

all:
	@echo "Build $(DOCKER_USER)/$(DOCKER_REPO) done"

$(foreach f,$(shell find . -type f -name Dockerfile | cut -d/ -f2-), \
  $(eval path := $(patsubst %/Dockerfile,%,$(f))) \
  $(if $(wildcard $(path)/skip), \
    $(info Skipping $(path): $(shell cat $(path)/skip)), \
    $(eval $(call define-target-from-path,$(path))) \
  ) \
)

.PHONY: debian ubuntu
debian: squeeze wheezy jessie stretch sid
ubuntu: precise trusty vivid wily
