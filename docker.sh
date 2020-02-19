#!/usr/bin/env bash


# Abort on any error
set -eu

# Import current version
register_current_version() {
	_CURRENT_VERSION="$(git describe --tags --abbrev=0)"
	_NEXT_VERSION="$_CURRENT_VERSION"
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
