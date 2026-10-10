#!/usr/bin/env bash
# Shared validation for immutable R2 release namespaces.
navis_r2_valid_tag() {
  local tag="$1" channel="$2"
  [[ "${channel}" =~ ^(stable|dev|staging)$ ]] || return 1
  [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
  [[ "${channel}" != stable && "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-(dev|staging)\.[1-9][0-9]*$ ]]
}
