#!/bin/bash


# Import current version
_CURRENT_VERSION="$(git describe --tags --abbrev=0)"
_NEXT_VERSION="$_CURRENT_VERSION"

# Output red message on stderr
echo_stderr() {
	MESSAGE="$1"
	>&2 echo -e "\e[31m$MESSAGE\e[0m"
}

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
	local VERSION_NO_RELEASE=$(echo "$1" | sed 's|-r\?[0-9]\+$||')
	_NEXT_VERSION="$VERSION_NO_RELEASE-1"
}

# Increase release counter, indicating a minor package update
update_release() {
	# Prevent overriding major update changes
	if ! updates_available; then
		local VERSION_NO_RELEASE=$(echo "$_CURRENT_VERSION" | sed 's|-r\?[0-9]\+$||')
		local CURRENT_RELEASE=$(echo "$_CURRENT_VERSION" | grep --only-matching --perl-regexp "\d+$")
		local NEXT_RELEASE="$((CURRENT_RELEASE+1))"
		_NEXT_VERSION="$VERSION_NO_RELEASE-$NEXT_RELEASE"
	fi
}

# Check for available updates
updates_available() {
	if [ "$_CURRENT_VERSION" != "$_NEXT_VERSION" ]; then
		return $(true)
	else
		return $(false)
	fi
}

# Check for base image update
update_image() {
	local IMG="$1"
	local IMG_ESCAPED=$(echo "$IMG" | sed 's|+|\\+|g')
	local NAME="$2"
	local MAIN="$3"
	local VERSION_REGEX="$4"
	local ARCH="${5:-amd64}"

	local CURRENT_VERSION=$(cat Dockerfile | grep --only-matching --perl-regexp "FROM $IMG_ESCAPED:\K$VERSION_REGEX")
	local NEW_VERSION=$(curl --silent --location "https://registry.hub.docker.com/v2/repositories/$IMG/tags?page_size=128" | jq ".results | select(.[].images[].architecture == \"$ARCH\") | sort_by(.last_updated) | .[].name" | tr -d '"' | grep --only-matching --perl-regexp "^$VERSION_REGEX$" | tail -n 1)

	if [ -z "$CURRENT_VERSION" ] || [ -z "$NEW_VERSION" ]; then
		echo_stderr "Failed to scrape $NAME version!"
		return $(false)
	fi

	if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
		return $(true)
	fi

	prepare_update "$IMG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	if [ "$MAIN" = "true" ] && [ "${CURRENT_VERSION%-*}" != "${NEW_VERSION%-*}" ]; then
		update_version "$NEW_VERSION"
	else
		update_release
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

	local CURRENT_VERSION=$(cat Dockerfile | grep --only-matching --perl-regexp "\s+$PKG_ESCAPED=\K$VERSION_REGEX")
	local NEW_VERSION=$(curl --silent --location "$URL/$PKG" | grep --only-matching --perl-regexp "$VERSION_REGEX" | head -n 1)

	if [ -z "$CURRENT_VERSION" ] || [ -z "$NEW_VERSION" ]; then
		echo_stderr "Failed to scrape $NAME version!"
		return $(false)
	fi

	if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
		return $(true)
	fi

	prepare_update "$PKG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	if [ "$MAIN" = "true" ] && [ "${CURRENT_VERSION%-*}" != "${NEW_VERSION%-*}" ]; then
		update_version "$NEW_VERSION"
	else
		update_release
	fi
}

# Check for Debian package updates
update_pkg_debian() {
	local PKG="$1"
	local NAME="$2"
	local MAIN="$3"
	local ARCH="${4:-amd64}"
	local SUITE="${5:-stable}"

	local CURRENT_VERSION=$(cat Dockerfile | grep --only-matching --perl-regexp "(?<=${PKG//+/\\+}=)[^ ]+")
	local NEW_VERSION=$(curl --silent --location "https://qa.debian.org/madison.php?package=$PKG&a=$ARCH,all&s=$SUITE&text=on#" | tr -d ' ' | cut -d '|' -f 2)

	if [ -z "$CURRENT_VERSION" ] || [ -z "$NEW_VERSION" ]; then
		echo_stderr "Failed to scrape $NAME version!"
		return $(false)
	fi

	if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
		return $(true)
	fi

	prepare_update "$PKG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	if [ "$MAIN" = "true" ] && [ "${CURRENT_VERSION%-*}" != "${NEW_VERSION%-*}" ]; then
		update_version "$NEW_VERSION"
	else
		update_release
	fi
}

# Check for steam depot update
update_depot() {
	local APP_ID="$1"
	local DEPOT_ID="$2"
	local MANIFEST_NAME="$3"
	local NAME="$4"
	local MAIN="$5"

	local MANIFEST_REGEX="\d{16,19}"
	local CURRENT_VERSION=$(cat Dockerfile | grep --only-matching --perl-regexp "(?<=$MANIFEST_NAME=)$MANIFEST_REGEX")
	local APP_INFO=$(docker run --rm --mount type=bind,source=/etc/localtime,target=/etc/localtime,readonly hetsh/steamapi steamcmd.sh +login anonymous +app_info_print $APP_ID +quit)
	local NEW_VERSION=$(echo "$APP_INFO" | sed -e "1,/$DEPOT_ID/d" -e '1,/manifests/d' -e '/maxsize/,$d' | grep --perl-regexp --only "public\"\h+\"\K$MANIFEST_REGEX")

	if [ -z "$CURRENT_VERSION" ] || [ -z "$NEW_VERSION" ]; then
		echo_stderr "Failed to scrape $NAME version!"
		return $(false)
	fi

	if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
		return $(true)
	fi

	prepare_update "$MANIFEST_NAME" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	if [ "$MAIN" = "true" ]; then
		update_version "$NEW_VERSION"
	else
		update_release
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

	if [ -z "$CURRENT_VERSION" ] || [ -z "$NEW_VERSION" ]; then
		echo_stderr "Failed to scrape $NAME version!"
		return $(false)
	fi

	if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
		return $(true)
	fi

	prepare_update "$VERSION_ID" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	update_release
}

# Check for update on GitHub
update_github() {
	local REPO="$1"
	local NAME="$2"
	local VERSION_ID="$3"
	local VERSION_REGEX="$4"

	local CURRENT_VERSION=$(cat Dockerfile | grep --only-matching --perl-regexp "(?<=$VERSION_ID=)$VERSION_REGEX")
	local NEW_VERSION=$(curl --silent --location "https://api.github.com/repos/$REPO/releases/latest" | jq -r ".tag_name" | sed "s/^v//")
	if [ -z "$CURRENT_VERSION" ] || [ -z "$NEW_VERSION" ]; then
		echo_stderr "Failed to scrape $NAME version!"
		return $(false)
	fi

	if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
		return $(true)
	fi

	prepare_update "$VERSION_ID" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	update_version "$NEW_VERSION"
}

# Check for update on webpage
update_web() {
	local VAR="$1"
	local NAME="$2"
	local MAIN="$3"
	local MADISON_URL="$4"
	local VAL_REGEX="$5"

	local CURRENT_VAR=$(cat "Dockerfile" | grep --only-matching --perl-regexp "(?<=$VAR=)$VAL_REGEX")
	local NEW_VAR=$(curl --silent --location "$MADISON_URL" | grep --only-matching --perl-regexp "$VAL_REGEX" | sort --version-sort | tail -n 1)

	if [ -z "$CURRENT_VAR" ] || [ -z "$NEW_VAR" ]; then
		echo_stderr "Failed to get $NAME info!"
		return $(false)
	fi

	if [ "$CURRENT_VAR" = "$NEW_VAR" ]; then
		return $(true)
	fi

	prepare_update "$VAR" "$NAME" "$CURRENT_VAR" "$NEW_VAR"
	if [ "$MAIN" = "true" ]; then
		update_version "$NEW_VAR"
	else
		update_release
	fi
}

# Check for update on pypi
update_pypi() {
	local PKG="$1"
	local NAME="$2"
	local MAIN="$3"
	local VERSION_REGEX="$4"

	local CURRENT_VERSION=$(cat Dockerfile | grep --only-matching --perl-regexp "(?<=$PKG==)$VERSION_REGEX")
	local NEW_VERSION=$(curl --silent --location "https://pypi.org/pypi/$PKG/json" | jq -r ".info.version")

	if [ -z "$CURRENT_VERSION" ] || [ -z "$NEW_VERSION" ]; then
		echo_stderr "Failed to scrape $NAME version!"
		return $(false)
	fi

	if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
		return $(true)
	fi

	prepare_update "$PKG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	if [ "$MAIN" = "true" ] && [ "${CURRENT_VERSION%-*}" != "${NEW_VERSION%-*}" ]; then
		update_version "$NEW_VERSION"
	else
		update_release
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
		return $(true)
	else
		return $(false)
	fi
}
