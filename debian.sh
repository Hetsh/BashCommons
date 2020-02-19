#!/usr/bin/env bash


# Abort on any error
set -eu

# Load helpful functions
source libs/docker.sh

# Register the url to query package updates
register_pkg_url() {
	local ARCH="$1"
	local CHANNEL="$2"
	_PKG_URL="https://packages.debian.org/$CHANNEL/$ARCH"
}

# Check for base image update
update_image() {
	local ARCH="$1"
	local VERSION_REGEX="$2"

	local IMG="debian"
	local CURRENT_VERSION=$(cat "Dockerfile" | grep -P -o "FROM $IMG:\K$VERSION_REGEX")
	local NEW_VERSION=$(curl -L -s "https://registry.hub.docker.com/v2/repositories/library/$IMG/tags?page_size=128" | jq '."results"[]["name"]' | grep -P -w "$VERSION_REGEX" | tr -d '"' | sort | tail -n 1)
	register_pkg_url "$ARCH" "${VERSION_REGEX%%-*}"

	if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
		prepare_update "$IMG" "Debian" "$CURRENT_VERSION" "$NEW_VERSION"
		update_release
	fi
}

# Check for package update
update_pkg() {
	local PKG="$1"
	local NAME="$2"
	local MAIN="$3"
	local VERSION_REGEX="$4"

	local CURRENT_VERSION=$(cat Dockerfile | grep -P -o "$PKG=\K$VERSION_REGEX")
	local NEW_VERSION=$(curl -L -s "$_PKG_URL/$PKG" | grep -P -o "$PKG \(\K$VERSION_REGEX")

	if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
		prepare_update "$PKG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"

		if [ "$MAIN" = "true" ] && [ "${CURRENT_VERSION%-*}" != "${NEW_VERSION%-*}" ]; then
			update_version "$NEW_VERSION"
		else
			update_release
		fi
	fi
}