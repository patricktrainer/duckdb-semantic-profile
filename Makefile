.PHONY: clean clean_all

PROJ_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

EXTENSION_NAME=semantic_profile

# Build against the stable V1 C API. DuckDB 2.x refuses unstable-API binaries that
# lack the _init_c_api_v2 entrypoint, which the `duckdb` crate cannot emit (only
# `duckdb-neo` can). The stable ABI loads into 1.5.6 and 2.0.0 alike (both tested).
USE_UNSTABLE_C_API=0

# With the stable ABI this is the C API version requested, not a DuckDB release.
# It is read at macro expansion: after changing it, touch src/lib.rs.
TARGET_DUCKDB_VERSION=v1.2.0

all: configure debug

# Include makefiles from DuckDB
include extension-ci-tools/makefiles/c_api_extensions/base.Makefile
include extension-ci-tools/makefiles/c_api_extensions/rust.Makefile

configure: venv platform extension_version

debug: build_extension_library_debug build_extension_with_metadata_debug
release: build_extension_library_release build_extension_with_metadata_release

# Locally, depend on the build: testing a stale binary against a fixture built by
# a fresh one fails as a confusing cache miss rather than "you forgot to rebuild".
#
# Not in CI. There the build phase has already run, and on linux_amd64 it runs
# inside a container that leaves target/ owned by root -- a rebuild from the test
# phase, which runs outside the container, dies on .cargo-build-lock (EACCES).
ifndef CI
test_debug: debug
test_release: release
endif

test: test_debug
test_debug: test_extension_debug
test_release: test_extension_release

clean: clean_build clean_rust
clean_all: clean_configure clean
