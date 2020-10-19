#!/usr/bin/env bash


# Import current version
_CURRENT_VERSION="$(git describe --tags --abbrev=0)"
_NEXT_VERSION="$_CURRENT_VERSION"

# Pushes updated packages into a list and prepares the changelog
prepare_update() {
	local ITEM="$1"
	local NAME="$2"
	local OLD_VERSION="$3"
	local NEW_VERSION="$4"
	local OLD_VALUE=${5-$OLD_VERSION}
	local NEW_VALUE=${6-$NEW_VERSION}

	echo "$NAME $NEW_VERSION is available!"
	_UPDATES+=("$ITEM" "$OLD_VALUE" "$NEW_VALUE")
	_CHANGELOG+="$NAME $OLD_VERSION -> $NEW_VERSION, "
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
	if [ "$_CURRENT_VERSION" != "$_NEXT_VERSION" ]; then
		return 0
	else
		return 1
	fi
}

# Check for base image update
update_image() {
	local IMG="$1"
	local IMG_ESCAPED=$(echo "$IMG" | sed 's|+|\\+|g')
	local NAME="$2"
	local MAIN="$3"
	local VERSION_REGEX="$4"

	local CURRENT_VERSION=$(cat Dockerfile | grep --only-matching --perl-regexp "FROM $IMG_ESCAPED:\K$VERSION_REGEX")
	local NEW_VERSION=$(curl --silent --location "https://registry.hub.docker.com/v2/repositories/$IMG/tags?page_size=128" | jq '.results | sort_by(.last_updated) | .[].name' | tr -d '"' | grep --only-matching --perl-regexp "^$VERSION_REGEX$" | tail -n 1)

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

	local CURRENT_VERSION=$(cat Dockerfile | grep --only-matching --perl-regexp "$PKG_ESCAPED(@testing)?=\K$VERSION_REGEX")
	local NEW_VERSION=$(curl --silent --location "$URL/$PKG" | grep --only-matching --perl-regexp "$VERSION_REGEX" | head -n 1)

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

# Check for steam mod update
update_mod() {
	local MOD_ID="$1"
	local NAME="$2"
	local VERSION_ID="$3"

	local VERSION_REGEX="\d{1,2} .{3}(, \d{4})? @ \d{1,2}:\d{1,2}(am|pm)"
	local CURRENT_VERSION=$(cat Dockerfile | grep --only-matching --perl-regexp "(?<=$VERSION_ID=\")$VERSION_REGEX")
	local NEW_VERSION=$(curl --silent --location "https://steamcommunity.com/sharedfiles/filedetails/changelog/$MOD_ID" | grep --only-matching --perl-regexp "(?<=Update: )$VERSION_REGEX" | head -n 1)

	if [ -z "$CURRENT_VERSION" ] || [ -z "$NEW_VERSION" ];then
		echo -e "\e[31mFailed to scrape $NAME version!\e[0m"
		return
	fi

	if [ "$CURRENT_VERSION" != "$NEW_VERSION" ]; then
		prepare_update "$VERSION_ID" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
		update_release
	fi
}

# Check for url update
update_url() {
	local URL_ID="$1"
	local NAME="$2"
	local MAIN="$3"
	local MIRROR="$4"
	local URL_REGEX="$5"
	local VERSION_REGEX="$6"

	local CURRENT_URL=$(cat Dockerfile | grep --only-matching --perl-regexp "(?<=$URL_ID=\").*(?=\")")
	local NEW_URL=$(curl --silent --location "$MIRROR" | grep --only-matching --perl-regexp "(?<=href=(\"|'))$URL_REGEX(?=(\"|'))" | sort --version-sort | tail -n 1)
	if [ -z "$CURRENT_URL" ] || [ -z "$NEW_URL" ];then
		echo -e "\e[31mFailed to scrape $NAME URL!\e[0m"
		return
	fi
	# Convert relative reference to uri
	if [ "$NEW_URL" != *'://'* ]; then
		NEW_URL="$MIRROR/$NEW_URL"
	fi

	local CURRENT_VERSION=$(echo "$CURRENT_URL" | grep --only-matching --perl-regexp "$VERSION_REGEX")
	local NEW_VERSION=$(echo "$NEW_URL" | grep --only-matching --perl-regexp "$VERSION_REGEX")
	if [ -z "$CURRENT_VERSION" ] || [ -z "$NEW_VERSION" ];then
		echo -e "\e[31mFailed to scrape $NAME version!\e[0m"
		return
	fi

	if [ "$CURRENT_URL" != "$NEW_URL" ]; then
		prepare_update "$URL_ID" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION" "$CURRENT_URL" "$NEW_URL"

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

		# Images assigned by :
		# Packages assigned by =
		# Variables assigned by ="
		sed -i "s|$PKG\([:=\"]\+\)$CURRENT_VERSION|$PKG\1$NEW_VERSION|" Dockerfile
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

# Check if tag in registry
tag_exists() {
	local IMG="$1"

	local EXISTS=$(curl --silent --location "https://registry.hub.docker.com/v2/repositories/$IMG/tags" | jq --arg VERSION "$_NEXT_VERSION" '[."results"[]["name"] == $VERSION] | any')
	if [ "$EXISTS" = "true" ]; then
		return 0
	else
		return 1
	fi
}
