#!/usr/bin/env bash


# Abort on any error
set -eu

# Import current version
register_current_version() {
	_CURRENT_VERSION="$(git describe --tags --abbrev=0)"
	_NEXT_VERSION="$_CURRENT_VERSION"
}

# Registers information for retrieving alpine packages
register_alpine_pkg_query() {
	_IMG_ARCH="$1"
	_ALPINE_BRANCH="v${2%.*}"
}

# Registers information for retrieving debian packages
register_debian_pkg_query() {
	_IMG_ARCH="$1"
	_DEBIAN_CHANNEL="$2"
}

# Pushes updated packages into a list and prepares the changelog
prepare_update() {
	local ITEM="$1"
	local NAME="$2"
	local CURRENT_VERSION="$3"
	local NEW_VERSION="$4"

	echo "$NAME $NEW_VERSION is available!"
	_UPDATES+=("$ITEM" "$CURRENT_VERSION" "$NEW_VERSION")
	_CHANGELOG+="$NAME $CURRENT_VERSION -> $NEW_VERSION, "
}

# Set version number, indicating major application update
update_version() {
	_NEXT_VERSION="${1%-*}-1"
}

# Increase release counter, indicating a minor package update
update_release() {
	# Prevent overriding major update changes
	if ! updates_available; then
		_CURRENT_RELEASE="${_CURRENT_VERSION#*-}"
		_NEXT_VERSION="${_CURRENT_VERSION%-*}-$((_CURRENT_RELEASE+1))"
	fi
}

# Check for available updates
updates_available() {
	if [ "$_CURRENT_VERSION" = "$_NEXT_VERSION" ]; then
		return 1
	else
		return 0
	fi
}

# Check for updates of the base image
update_alpine_image() {
	local ARCH="$1"
	local VERSION_REGEX="$2"

	local IMG="alpine"
	local CURRENT_VERSION=$(cat "Dockerfile" | grep -P -o "FROM $IMG:\K$VERSION_REGEX")
	local NEW_VERSION=$(curl -L -s "https://registry.hub.docker.com/v2/repositories/library/$IMG/tags" | jq '."results"[]["name"]' | grep -P -o "$VERSION_REGEX" | sort --version-sort | tail -n 1)
	register_alpine_pkg_query "$ARCH" "$NEW_VERSION"

	if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
		prepare_update "$IMG" "Alpine" "$CURRENT_VERSION" "$NEW_VERSION"
		update_release
	fi
}

# Check for updates of alpine packages
update_alpine_pkg() {
	local PKG="$1"
	local NAME="$2"
	local MAIN="$3"
	local REPO="$4"
	local VERSION_REGEX="$5"

	local CURRENT_VERSION=$(cat "Dockerfile" | grep -P -o "$PKG=\K$VERSION_REGEX")
	local NEW_VERSION=$(curl -L -s "https://pkgs.alpinelinux.org/package/$_ALPINE_BRANCH/$REPO/$_IMG_ARCH/$PKG" | grep -m 1 -P -o "$VERSION_REGEX")

	if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
		prepare_update "$PKG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"

		if [ "$MAIN" = "true" ] && [ "${CURRENT_VERSION%-*}" != "${NEW_VERSION%-*}" ]; then
			update_version "$NEW_VERSION"
		else
			update_release
		fi
	fi
}

# Check for updates of the base image
update_debian_image() {
	local ARCH="$1"
	local VERSION_REGEX="$2"

	local IMG="debian"
	local CURRENT_VERSION=$(cat "Dockerfile" | grep -P -o "FROM $IMG:\K$VERSION_REGEX")
	local NEW_VERSION=$(curl -L -s "https://registry.hub.docker.com/v2/repositories/library/$IMG/tags?page_size=128" | jq '."results"[]["name"]' | grep -P -w "$VERSION_REGEX" | tr -d '"' | sort | tail -n 1)
	register_debian_pkg_query "$ARCH" "${VERSION_REGEX%%-*}"

	if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
		prepare_update "$IMG" "Debian" "$CURRENT_VERSION" "$NEW_VERSION"
		update_release
	fi
}

# Check for updates of alpine packages
update_debian_pkg() {
	local PKG="$1"
	local NAME="$2"
	local MAIN="$3"
	local VERSION_REGEX="$4"

	local CURRENT_VERSION=$(cat Dockerfile | grep -P -o "$PKG=\K$VERSION_REGEX")
	local NEW_VERSION=$(curl -L -s "https://packages.debian.org/$_DEBIAN_CHANNEL/$_IMG_ARCH/$PKG" | grep -P -o "$PKG \(\K$VERSION_REGEX")

	if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
		prepare_update "$PKG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"

		if [ "$MAIN" = "true" ] && [ "${CURRENT_VERSION%-*}" != "${NEW_VERSION%-*}" ]; then
			update_version "$NEW_VERSION"
		else
			update_release
		fi
	fi
}

# Applies updates to Dockerfile
save_changes() {
	local i=0
	while [ $i -lt ${#_UPDATES[@]} ]; do
		local PKG=${_UPDATES[((i++))]}
		local CURRENT_VERSION=${_UPDATES[((i++))]}
		local NEW_VERSION=${_UPDATES[((i++))]}

		sed -i "s|$PKG\([=:]\)$CURRENT_VERSION|$PKG\1$NEW_VERSION|" Dockerfile
	done
}

# Push changes to git
commit_changes() {
	git add Dockerfile
	git commit -m "${_CHANGELOG%,*}"
	git push
	git tag "$_NEXT_VERSION"
	git push origin "$_NEXT_VERSION"
}
