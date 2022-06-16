SHELL = /usr/bin/env bash

PROJECT_NAME := docker_cpp
BUILD_DIR ?= build
TESTS_DIR := tests
VCS_REF := $(shell git rev-parse HEAD)
BUILD_DATE := $(shell date --rfc-3339=date)
KEEP_CI_USER_SUDO ?= false
DOCKER_IMAGE_VERSION := 0.2.0
DOCKER_IMAGE_NAME := rudenkornk/$(PROJECT_NAME)
DOCKER_IMAGE_TAG := $(DOCKER_IMAGE_NAME):$(DOCKER_IMAGE_VERSION)
DOCKER_IMAGE := $(BUILD_DIR)/$(PROJECT_NAME)_image_$(DOCKER_IMAGE_VERSION)
DOCKER_CACHE_FROM ?=
DOCKER_CACHE_FROM := $(DOCKER_CACHE_FROM)
DOCKER_CONTAINER_NAME := $(PROJECT_NAME)_container
DOCKER_CONTAINER := $(BUILD_DIR)/$(DOCKER_CONTAINER_NAME)_$(DOCKER_IMAGE_VERSION)

DOCKER_DEPS :=
DOCKER_DEPS += Dockerfile
DOCKER_DEPS += install_gcc.sh
DOCKER_DEPS += install_llvm.sh
DOCKER_DEPS += install_cmake.sh
DOCKER_DEPS += install_python.sh
DOCKER_DEPS += install_conan.sh
DOCKER_DEPS += $(shell find conan -type f,l)
DOCKER_DEPS += config_conan.sh
DOCKER_DEPS += config_system.sh

HELLO_WORLD_DEPS := $(shell find $(TESTS_DIR) -type f,l)

.PHONY: $(DOCKER_IMAGE_NAME)
$(DOCKER_IMAGE_NAME): $(DOCKER_IMAGE)

.PHONY: docker_image_name
docker_image_name:
	$(info $(DOCKER_IMAGE_NAME))

.PHONY: docker_image_tag
docker_image_tag:
	$(info $(DOCKER_IMAGE_TAG))

.PHONY: docker_image_version
docker_image_version:
	$(info $(DOCKER_IMAGE_VERSION))

IF_DOCKERD_UP := command -v docker &> /dev/null && pidof dockerd &> /dev/null

DOCKER_IMAGE_ID := $(shell $(IF_DOCKERD_UP) && docker images --quiet $(DOCKER_IMAGE_TAG))
DOCKER_IMAGE_CREATE_STATUS := $(shell [[ -z "$(DOCKER_IMAGE_ID)" ]] && echo "$(DOCKER_IMAGE)_not_created")
DOCKER_CACHE_FROM_COMMAND := $(shell [[ ! -z "$(DOCKER_CACHE_FROM)" ]] && echo "--cache-from $(DOCKER_CACHE_FROM)")
.PHONY: $(DOCKER_IMAGE)_not_created
$(DOCKER_IMAGE): $(DOCKER_DEPS) $(DOCKER_IMAGE_CREATE_STATUS)
	docker build \
		$(DOCKER_CACHE_FROM_COMMAND) \
		--build-arg IMAGE_NAME="$(DOCKER_IMAGE_NAME)" \
		--build-arg VERSION="$(DOCKER_IMAGE_VERSION)" \
		--build-arg VCS_REF="$(VCS_REF)" \
		--build-arg BUILD_DATE="$(BUILD_DATE)" \
		--tag $(DOCKER_IMAGE_TAG) .
	mkdir --parents $(BUILD_DIR) && touch $@

.PHONY: $(DOCKER_CONTAINER_NAME)
$(DOCKER_CONTAINER_NAME): $(DOCKER_CONTAINER)

DOCKER_CONTAINER_ID := $(shell $(IF_DOCKERD_UP) && docker container ls --quiet --all --filter name=^/$(DOCKER_CONTAINER_NAME)$)
DOCKER_CONTAINER_STATE := $(shell $(IF_DOCKERD_UP) && docker container ls --format {{.State}} --all --filter name=^/$(DOCKER_CONTAINER_NAME)$)
DOCKER_CONTAINER_RUN_STATUS := $(shell [[ "$(DOCKER_CONTAINER_STATE)" != "running" ]] && echo "$(DOCKER_CONTAINER)_not_running")
.PHONY: $(DOCKER_CONTAINER)_not_running
$(DOCKER_CONTAINER): $(DOCKER_IMAGE) $(DOCKER_CONTAINER_RUN_STATUS)
ifneq ($(DOCKER_CONTAINER_ID),)
	docker container rename $(DOCKER_CONTAINER_NAME) $(DOCKER_CONTAINER_NAME)_$(DOCKER_CONTAINER_ID)
endif
	docker run --interactive --tty --detach \
		--user ci_user \
		--env KEEP_CI_USER_SUDO=$(KEEP_CI_USER_SUDO) \
		--env CI_UID="$$(id --user)" --env CI_GID="$$(id --group)" \
		--env "TERM=xterm-256color" \
		--name $(DOCKER_CONTAINER_NAME) \
		--mount type=bind,source="$$(pwd)",target=/home/repo \
		$(DOCKER_IMAGE_TAG)
	sleep 1
	mkdir --parents $(BUILD_DIR) && touch $@


$(BUILD_DIR)/gcc/hello_world: $(DOCKER_CONTAINER) $(HELLO_WORLD_DEPS)
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c "gcc --version" | grep --perl-regexp --quiet "12\.\d+\.\d+"
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c "g++ --version" | grep --perl-regexp --quiet "12\.\d+\.\d+"
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c " \
		conan install \
		--profile:host gcc \
		--profile:host sanitize.jinja \
		--settings build_type=Release \
		--build missing \
		--install-folder $(BUILD_DIR)/gcc $(TESTS_DIR) \
		"
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c "conan build --build-folder $(BUILD_DIR)/gcc $(TESTS_DIR)"
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c "./$(BUILD_DIR)/gcc/hello_world" | grep --quiet "Hello world!"
	grep --quiet "g++" $(BUILD_DIR)/gcc/compile_commands.json
	touch $@

$(BUILD_DIR)/llvm/hello_world: $(DOCKER_CONTAINER) $(HELLO_WORLD_DEPS)
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c "clang --version" | grep --perl-regexp --quiet "14\.\d+\.\d+"
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c "clang++ --version" | grep --perl-regexp --quiet "14\.\d+\.\d+"
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c " \
		conan install \
		--profile:host llvm \
		--profile:host sanitize.jinja \
		--settings build_type=Release \
		--build missing \
		--install-folder $(BUILD_DIR)/llvm $(TESTS_DIR) \
		"
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c "conan build --build-folder $(BUILD_DIR)/llvm $(TESTS_DIR)"
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c "./$(BUILD_DIR)/llvm/hello_world" | grep --quiet "Hello world!"
	grep --quiet "clang++" $(BUILD_DIR)/llvm/compile_commands.json
	touch $@

$(BUILD_DIR)/valgrind_test: $(BUILD_DIR)/gcc/hello_world $(BUILD_DIR)/llvm/hello_world
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c " \
		valgrind $(BUILD_DIR)/gcc/hello_world && \
		valgrind $(BUILD_DIR)/llvm/hello_world && \
		: "
	touch $@

$(BUILD_DIR)/gdb_test: $(BUILD_DIR)/gcc/hello_world $(BUILD_DIR)/llvm/hello_world
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c " \
		gdb -ex run -ex quit ./build/gcc/hello_world && \
		gdb -ex run -ex quit ./build/llvm/hello_world && \
		: "
	touch $@

$(BUILD_DIR)/clang_tidy_test: $(BUILD_DIR)/gcc/hello_world $(BUILD_DIR)/llvm/hello_world
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c "clang-tidy --version" | grep --perl-regexp --quiet "14\.\d+\.\d+"
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c " \
		clang-tidy -p $(BUILD_DIR)/gcc $(TESTS_DIR)/hello_world.cpp && \
		clang-tidy -p $(BUILD_DIR)/llvm $(TESTS_DIR)/hello_world.cpp && \
		: "
	touch $@

$(BUILD_DIR)/clang_format_test: $(DOCKER_CONTAINER)
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c "clang-format --version" | grep --perl-regexp --quiet "14\.\d+\.\d+"
	touch $@

$(BUILD_DIR)/lit_test: $(DOCKER_CONTAINER)
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c "lit --version" | grep --perl-regexp --quiet "14\.\d+\.\d+"
	touch $@

$(BUILD_DIR)/filecheck_test: $(DOCKER_CONTAINER)
	docker exec $(DOCKER_CONTAINER_NAME) \
		bash -c "FileCheck --version" | grep --perl-regexp --quiet "14\.\d+\.\d+"
	touch $@

.PHONY: check
check: \
	$(BUILD_DIR)/gcc/hello_world \
	$(BUILD_DIR)/llvm/hello_world \
	$(BUILD_DIR)/clang_tidy_test \
	$(BUILD_DIR)/gdb_test \
	$(BUILD_DIR)/valgrind_test \
	$(BUILD_DIR)/lit_test \
	$(BUILD_DIR)/filecheck_test \

.PHONY: clean
clean:
	docker container ls --quiet --filter name=$(DOCKER_CONTAINER_NAME)_ | \
		ifne xargs docker stop
	docker container ls --quiet --filter name=$(DOCKER_CONTAINER_NAME)_ --all | \
		ifne xargs docker rm
