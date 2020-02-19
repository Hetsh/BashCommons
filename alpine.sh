#!/usr/bin/env bash


# Abort on any error
set -eu

# Load helpful functions
source libs/docker.sh

# Register information to query package updates
register_pkg_url_info() {
	_IMG_ARCH="$1"
	_IMG_BRANCH="$2"
}

# Check for base image update
update_image() {
	local ARCH="$1"
	local VERSION_REGEX="$2"

	local IMG="alpine"
	local CURRENT_VERSION=$(cat "Dockerfile" | grep -P -o "FROM $IMG:\K$VERSION_REGEX")
	local NEW_VERSION=$(curl -L -s "https://registry.hub.docker.com/v2/repositories/library/$IMG/tags" | jq '."results"[]["name"]' | grep -P -o "$VERSION_REGEX" | sort --version-sort | tail -n 1)
	register_pkg_url_info "$ARCH" "v${NEW_VERSION%.*}"

	if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
		prepare_update "$IMG" "Alpine" "$CURRENT_VERSION" "$NEW_VERSION"
		update_release
	fi
}

# Check for package update
update_pkg() {
	local PKG="$1"
	local NAME="$2"
	local MAIN="$3"
	local REPO="$4"
	local VERSION_REGEX="$5"

	local CURRENT_VERSION=$(cat "Dockerfile" | grep -P -o "$PKG=\K$VERSION_REGEX")
	local NEW_VERSION=$(curl -L -s "https://pkgs.alpinelinux.org/package/$_IMG_BRANCH/$REPO/$_IMG_ARCH/$PKG" | grep -m 1 -P -o "$VERSION_REGEX")

	if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
		prepare_update "$PKG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"

		if [ "$MAIN" = "true" ] && [ "${CURRENT_VERSION%-*}" != "${NEW_VERSION%-*}" ]; then
			update_version "$NEW_VERSION"
		else
			update_release
		fi
	fi
}