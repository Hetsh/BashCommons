#!/usr/bin/env bash


# Abort on any error
set -eu

# Load helpful functions
source libs/docker.sh

# Check for base image update
update_image() {
	local IMG="$1"
	local NAME="$2"
	local VERSION_REGEX="$3"

	local CURRENT_VERSION=$(cat "Dockerfile" | grep -P -o "FROM $IMG:\K$VERSION_REGEX")
	local NEW_VERSION=$(curl -L -s "https://registry.hub.docker.com/v2/repositories/$IMG/tags" | jq '."results"[]["name"]' | grep -P -w "$VERSION_REGEX" | tr -d '"' | sort | tail -n 1)

	if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
		prepare_update "$IMG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
		update_release
	fi
}