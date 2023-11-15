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
	local ITEM && ITEM="$1"
	local NAME && NAME="$2"
	local OLD_VERSION && OLD_VERSION="$3"
	local NEW_VERSION && NEW_VERSION="$4"
	local OLD_VALUE && OLD_VALUE=${5-$OLD_VERSION}
	local NEW_VALUE && NEW_VALUE=${6-$NEW_VERSION}

	echo "$NAME $NEW_VERSION is available!"
	_UPDATES+=("$ITEM" "$OLD_VALUE" "$NEW_VALUE")
	_CHANGELOG+="$NAME $OLD_VERSION -> $NEW_VERSION, "
}

# Remove the trailing release number from semantic versions
strip_release() {
	local VERSION && VERSION="$1"
	# Bash's variable substitution is not regex compatible
	# shellcheck disable=SC2001
	echo "$VERSION" | sed 's|-r\?[0-9]\+$||'
}

# Set version number, indicating major application update
update_version() {
	local VERSION_WITH_RELEASE && VERSION_WITH_RELEASE="$1"
	local VERSION_NO_RELEASE && VERSION_NO_RELEASE=$(strip_release "$VERSION_WITH_RELEASE")
	_NEXT_VERSION="$VERSION_NO_RELEASE-1"
}

# Increase release counter, indicating a minor package update
update_release() {
	# Prevent overriding major update changes
	if ! updates_available; then
		local CURRENT_VERSION_NO_RELEASE && CURRENT_VERSION_NO_RELEASE=$(strip_release "$_CURRENT_VERSION")
		local CURRENT_RELEASE && CURRENT_RELEASE=$(echo "$_CURRENT_VERSION" | grep --only-matching --perl-regexp "\d+$")
		local NEXT_RELEASE && NEXT_RELEASE="$((CURRENT_RELEASE+1))"
		_NEXT_VERSION="$CURRENT_VERSION_NO_RELEASE-$NEXT_RELEASE"
	fi
}

# Check for available updates
updates_available() {
	if test "$_CURRENT_VERSION" != "$_NEXT_VERSION"; then
		return 0
	else
		return 1
	fi
}

# Check for base image update
update_image() {
	local IMG && IMG="$1"
	local IMG_ESCAPED && IMG_ESCAPED="${IMG/+/\\+}"
	local NAME && NAME="$2"
	local MAIN && MAIN="$3"
	local VERSION_REGEX && VERSION_REGEX="$4"
	local ARCH && ARCH="${5:-amd64}"

	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "FROM $IMG_ESCAPED:\K$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(curl --silent --location "https://registry.hub.docker.com/v2/repositories/$IMG/tags?page_size=128" | jq ".results | select(.[].images[].architecture == \"$ARCH\") | sort_by(.last_updated) | .[].name" | tr -d '"' | grep --only-matching --perl-regexp "^$VERSION_REGEX$" | tail -n 1)

	if test -z "$CURRENT_VERSION" || test -z "$NEW_VERSION"; then
		echo_stderr "Failed to scrape $NAME version!"
		return 2
	fi

	if test "$CURRENT_VERSION" = "$NEW_VERSION"; then
		return 0
	fi

	prepare_update "$IMG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	if test "$MAIN" = "true" && test "$(strip_release "$CURRENT_VERSION")" != "$(strip_release "$NEW_VERSION")"; then
		update_version "$NEW_VERSION"
	else
		update_release
	fi
}

# Check for package update
update_pkg() {
	local PKG && PKG="$1"
	local PKG_ESCAPED && PKG_ESCAPED="${PKG/+/\\+}"
	local NAME && NAME="$2"
	local MAIN && MAIN="$3"
	local URL && URL="$4"
	local VERSION_REGEX && VERSION_REGEX="$5"

	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "\s+$PKG_ESCAPED=\K$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(curl --silent --location "$URL/$PKG" | grep --only-matching --perl-regexp "$VERSION_REGEX" | head -n 1)

	if test -z "$CURRENT_VERSION" || test -z "$NEW_VERSION"; then
		echo_stderr "Failed to scrape $NAME version!"
		return 4
	fi

	if test "$CURRENT_VERSION" = "$NEW_VERSION"; then
		return 0
	fi

	prepare_update "$PKG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	if test "$MAIN" = "true" && test "$(strip_release "$CURRENT_VERSION")" != "$(strip_release "$NEW_VERSION")"; then
		update_version "$NEW_VERSION"
	else
		update_release
	fi
}

# Check for Debian package updates
update_pkg_madison() {
	local PKG && PKG="$1"
	local NAME && NAME="$2"
	local MAIN && MAIN="$3"
	local URL && URL="$4"
	local SUITE && SUITE="${5:-stable}"
	local ARCH && ARCH="${6:-amd64}"

	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=\s${PKG//+/\\+}=)[^\s]+" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(curl --silent --location --data-urlencode "text=on" --data-urlencode "package=$PKG" --data-urlencode "a=$ARCH,all" --data-urlencode "s=$SUITE" "$URL" | tail -n 1 | tr -d '[:space:]' | cut -d '|' -f 2)

	if test -z "$CURRENT_VERSION" || test -z "$NEW_VERSION"; then
		echo_stderr "Failed to scrape $NAME version!"
		return 5
	fi

	if test "$CURRENT_VERSION" = "$NEW_VERSION"; then
		return 0
	fi

	prepare_update "$PKG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	if test "$MAIN" = "true" && test "$(strip_release "$CURRENT_VERSION")" != "$(strip_release "$NEW_VERSION")"; then
		update_version "$NEW_VERSION"
	else
		update_release
	fi
}

# Check for steam depot update
update_depot() {
	local APP_ID && APP_ID="$1"
	local DEPOT_ID && DEPOT_ID="$2"
	local MANIFEST_NAME && MANIFEST_NAME="$3"
	local NAME && NAME="$4"
	local MAIN && MAIN="$5"

	local MANIFEST_REGEX && MANIFEST_REGEX="\d{16,19}"
	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=$MANIFEST_NAME=)$MANIFEST_REGEX" "Dockerfile")
	local APP_INFO && APP_INFO=$(docker run --rm --mount type=bind,source=/etc/localtime,target=/etc/localtime,readonly hetsh/steamapi steamcmd.sh +login anonymous +app_info_print "$APP_ID" +quit)
	local NEW_VERSION && NEW_VERSION=$(echo "$APP_INFO" | sed -e "1,/$DEPOT_ID/d" -e '1,/manifests/d' -e '/maxsize/,$d' | grep --perl-regexp --only "public\"\h+\"\K$MANIFEST_REGEX")

	if test -z "$CURRENT_VERSION" || test -z "$NEW_VERSION"; then
		echo_stderr "Failed to scrape $NAME version!"
		return 6
	fi

	if test "$CURRENT_VERSION" = "$NEW_VERSION"; then
		return 0
	fi

	prepare_update "$MANIFEST_NAME" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	if test "$MAIN" = "true"; then
		update_version "$NEW_VERSION"
	else
		update_release
	fi
}

# Check for steam mod update
update_mod() {
	local MOD_ID && MOD_ID="$1"
	local NAME && NAME="$2"
	local VERSION_ID && VERSION_ID="$3"

	local VERSION_REGEX && VERSION_REGEX="\d{1,2} .{3}(, \d{4})? @ \d{1,2}:\d{1,2}(am|pm)"
	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=$VERSION_ID=\")$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(curl --silent --location "https://steamcommunity.com/sharedfiles/filedetails/changelog/$MOD_ID" | grep --only-matching --perl-regexp "(?<=Update: )$VERSION_REGEX" | head -n 1)

	if test -z "$CURRENT_VERSION" || test -z "$NEW_VERSION"; then
		echo_stderr "Failed to scrape $NAME version!"
		return 7
	fi

	if test "$CURRENT_VERSION" = "$NEW_VERSION"; then
		return 0
	fi

	prepare_update "$VERSION_ID" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	update_release
}

# Check for update on GitHub
update_github() {
	local REPO && REPO="$1"
	local NAME && NAME="$2"
	local VERSION_ID && VERSION_ID="$3"
	local VERSION_REGEX && VERSION_REGEX="$4"

	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=$VERSION_ID=)$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(curl --silent --location "https://api.github.com/repos/$REPO/releases/latest" | jq -r ".tag_name" | sed "s/^v//")
	if test -z "$CURRENT_VERSION" || test -z "$NEW_VERSION"; then
		echo_stderr "Failed to scrape $NAME version!"
		return 8
	fi

	if test "$CURRENT_VERSION" = "$NEW_VERSION"; then
		return 0
	fi

	prepare_update "$VERSION_ID" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	update_version "$NEW_VERSION"
}

# Check for update on webpage
update_web() {
	local VAR && VAR="$1"
	local NAME && NAME="$2"
	local MAIN && MAIN="$3"
	local URL && URL="$4"
	local VAL_REGEX && VAL_REGEX="$5"

	local CURRENT_VAR && CURRENT_VAR=$(grep --only-matching --perl-regexp "(?<=$VAR=)$VAL_REGEX" "Dockerfile")
	local NEW_VAR && NEW_VAR=$(curl --silent --location "$URL" | grep --only-matching --perl-regexp "$VAL_REGEX" | sort --version-sort | tail -n 1)

	if test -z "$CURRENT_VAR" || test -z "$NEW_VAR"; then
		echo_stderr "Failed to get $NAME info!"
		return 9
	fi

	if test "$CURRENT_VAR" = "$NEW_VAR"; then
		return 0
	fi

	prepare_update "$VAR" "$NAME" "$CURRENT_VAR" "$NEW_VAR"
	if test "$MAIN" = "true"; then
		update_version "$NEW_VAR"
	else
		update_release
	fi
}

# Check for update on http file server
update_fileserver() {
	local VAR && VAR="$1"
	local NAME && NAME="$2"
	local MAIN && MAIN="$3"
	local URL && URL="$4"
	local VAL_REGEX && VAL_REGEX="$5"

	local CURRENT_VAL && CURRENT_VAL=$(grep --only-matching --perl-regexp "(?<=$VAR=)$VAL_REGEX" Dockerfile)
	local NEW_VAL && NEW_VAL=$(curl --silent --location "$URL" | grep --only-matching --perl-regexp "$VAL_REGEX(?=/)" | sort --version-sort | tail -n 1)

	if test -z "$CURRENT_VAL" || test -z "$NEW_VAL"; then
		echo_stderr "Failed to get $NAME info!"
		return 10
	fi

	if test "$CURRENT_VAL" = "$NEW_VAL"; then
		return 0
	fi

	prepare_update "$VAR" "$NAME" "$CURRENT_VAL" "$NEW_VAL"
	if test "$MAIN" = "true"; then
		update_version "$NEW_VAL"
	else
		update_release
	fi
}

# Check for update on pypi
update_pypi() {
	local PKG && PKG="$1"
	local NAME && NAME="$2"
	local MAIN && MAIN="$3"
	local VERSION_REGEX && VERSION_REGEX="$4"

	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=$PKG==)$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(curl --silent --location "https://pypi.org/pypi/$PKG/json" | jq -r ".info.version")

	if test -z "$CURRENT_VERSION" || test -z "$NEW_VERSION"; then
		echo_stderr "Failed to scrape $NAME version!"
		return 11
	fi

	if test "$CURRENT_VERSION" = "$NEW_VERSION"; then
		return 0
	fi

	prepare_update "$PKG" "$NAME" "$CURRENT_VERSION" "$NEW_VERSION"
	if test "$MAIN" = "true" && test "$(strip_release "$CURRENT_VERSION")" != "$(strip_release "$NEW_VERSION")"; then
		update_version "$NEW_VERSION"
	else
		update_release
	fi
}

# Applies updates to Dockerfile
save_changes() {
	local i && i=0
	while test $i -lt ${#_UPDATES[@]}; do
		local PKG && PKG=${_UPDATES[((i++))]}
		local CURRENT_VERSION && CURRENT_VERSION=${_UPDATES[((i++))]}
		local NEW_VERSION && NEW_VERSION=${_UPDATES[((i++))]}

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
	local IMG && IMG="$1"

	local EXISTS && EXISTS=$(curl --silent --location "https://registry.hub.docker.com/v2/repositories/$IMG/tags" | jq --arg VERSION "$_NEXT_VERSION" '[."results"[]["name"] == $VERSION] | any')
	if test "$EXISTS" != "true"; then
		return 12
	else
		return 0
	fi
}
