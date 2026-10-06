# c4-ha-system — everything lives in mise tasks: the common-only contract
# (prose/license/shell/workflow lint) plus pinned tools come from the shared
# toolchain submodule at .mise/, selected in the root mise.toml; tasks.toml
# carries the Lua-specific tasks (stylua fmt, selene lint) and the canonical
# fmt/lint/build/test gates over scripts/build.sh and scripts/test.sh.
# This Makefile is only the thin forwarding shim — `make <task>` == `mise run <task>`.
include .mise/common/include.mk
