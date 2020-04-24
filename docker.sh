#!/usr/bin/env bash


# Import current version
_CURRENT_VERSION="$(git describe --tags --abbrev=0)"
_NEXT_VERSION="$_CURRENT_VERSION"

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

# Check for base image update
update_image() {
	local IMG="$1"
	local IMG_ESCAPED=$(echo "$IMG" | sed 's|+|\\+|g')
	local NAME="$2"
	local MAIN="$3"
	local VERSION_REGEX="$4"

	local CURRENT_VERSION=$(cat Dockerfile | grep -P -o "FROM $IMG_ESCAPED:\K$VERSION_REGEX")
	local NEW_VERSION=$(curl -L -s "https://registry.hub.docker.com/v2/repositories/$IMG/tags" | jq '."results"[]["name"]' | grep -P -o "$VERSION_REGEX" | sort --version-sort | tail -n 1)

	if [ -z "$CURRENT_VERSION" ] || [ -z "$NEW_VERSION" ];then
		echo -e "\e[31mFailed to scrape $NAME version!\e[0m"
		return
	fi

	if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
		prepare_update "$IMG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"

		if [ "$MAIN" = "true" ] && [ "${CURRENT_VERSION%-*}" != "${NEW_VERSION%-*}" ]; then
			update_version "$NEW_VERSION"
		else
			update_release
		fi
	fi
}

# Check for package update
update_pkg() {
	local PKG="$1"
	local PKG_ESCAPED=$(echo "$PKG" | sed 's|+|\\+|g')
	local NAME="$2"
	local MAIN="$3"
	local URL="$4"
	local VERSION_REGEX="$5"

	local CURRENT_VERSION=$(cat Dockerfile | grep -P -o "$PKG_ESCAPED=\K$VERSION_REGEX")
	local NEW_VERSION=$(curl -L -s "$URL/$PKG" | grep -P -o "$VERSION_REGEX" | head -n 1)

	if [ -z "$CURRENT_VERSION" ] || [ -z "$NEW_VERSION" ];then
		echo -e "\e[31mFailed to scrape $NAME version!\e[0m"
		return
	fi

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
	git tag "$_NEXT_VERSION"
	git push
	git push origin "$_NEXT_VERSION"
}
