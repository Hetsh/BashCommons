#!/bin/bash

# Abort on any error
set -e -u -o pipefail

# Import version from git
_GIT_VERSION="$(git describe --tags --first-parent --abbrev=0)"

# Error codes
REQUEST_FAILED=1
SCRAPE_FAILED=2
PATTERN_NOT_FOUND=3
PATTERN_MALFORMED=4
IMAGE_MISSING=5

# Definitions
ASSIGNMENT_REGEX="[=:]"
EXPLICIT_UPDATE="explicit"
IMPLICIT_UPDATE="implicit"
HIDDEN_UPDATE="hidden"

# Output red message on stderr
echo_warning() {
	MESSAGE="$1"
	echo -e "\e[33m$MESSAGE\e[0m"
}

# Output red message on stderr
echo_error() {
	MESSAGE="$1"
	>&2 echo -e "\e[31m$MESSAGE\e[0m"
}

# Check for available updates
_UPDATES=()
updates_available() {
	test "${#_UPDATES[@]}" -gt 0
}

# Use SED with a regex pattern to check for file content
sed_search() {
	local PATTERN="$1"
	local TARGET="$2"

	# Can't use !{q123} to return 123 when the pattern is not found, because sed
	# will abort after the first line that does not match the pattern. Instead
	# using q123 to return 123 when the pattern was matched and then inverting the
	# result.
	local EXIT_CODE && EXIT_CODE=$(sed --quiet "\|$PATTERN|q123" "$TARGET"; echo "$?")
	if test "$EXIT_CODE" == "123"; then
		return
	elif test "$EXIT_CODE" == "0"; then
		return "$PATTERN_NOT_FOUND"
	else
		exit "$PATTERN_MALFORMED"
	fi
}

# Assert that a file contains the specified regex pattern
assert_search() {
	local PATTERN="$1"
	local TARGET="$2"
	local ERROR_MESSAGE="$3"

	if ! sed_search "$PATTERN" "$TARGET"; then
		echo_error "$ERROR_MESSAGE"
		return "$PATTERN_NOT_FOUND"
	fi
}

# Verify that sed actually found the pattern to replace
assert_replace() {
	local PATTERN="$1"
	local REPLACEMENT="$2"
	local TARGET="$3"
	local ERROR_MESSAGE="$4"

	assert_search "$PATTERN" "$TARGET" "$ERROR_MESSAGE"
	sed -i "s|$PATTERN|$REPLACEMENT|" "$TARGET"
}

# Verifies an item update is valid and tracks it
process_update() {
	local ITEM="$1"
	local CURRENT_VERSION="$2"
	local NEW_VERSION="$3"
	local PRETTY_NAME="${4-$ITEM}"
	local OLD_VALUE="${5-$CURRENT_VERSION}"
	local NEW_VALUE="${6-$NEW_VERSION}"

	if test -z "$ITEM"; then
		echo_warning "Skipping empty ITEM!"
		return
	fi

	if test -z "$CURRENT_VERSION"; then
		echo_error "Failed to scrape $ITEM current version!"
		return "$SCRAPE_FAILED"
	fi

	if test -z "$NEW_VERSION"; then
		echo_error "Failed to scrape $ITEM new version!"
		return "$SCRAPE_FAILED"
	fi

	if test "$CURRENT_VERSION" == "$NEW_VERSION"; then
		return
	fi

	_UPDATES+=("$ITEM" "$OLD_VALUE" "$NEW_VALUE")
	_CHANGELOG+="$PRETTY_NAME $CURRENT_VERSION -> $NEW_VERSION, "

	# An explicit update refers to an item (most probably a package)
	# that is explicitly installed in the Dockerfile with a pinned version.
	# All other updates are implicit, e.g. packages already installed in
	# the base image, explicitly installed packages without a pinned version,
	# or an implicitly installed dependency.
	if sed_search "$ITEM$ASSIGNMENT_REGEX" "Dockerfile"; then
		_UPDATES+=("$EXPLICIT_UPDATE")
	else
		_UPDATES+=("$IMPLICIT_UPDATE")
	fi

	echo "$PRETTY_NAME $NEW_VERSION is available!"
}

# A cURL HTTP request with error handling
curl_request() {
	local RESPONSE_FILE && RESPONSE_FILE=$(mktemp)
	local HTTP_CODE && HTTP_CODE=$(curl \
		--netrc-optional \
		--silent \
		--show-error \
		--write-out "%{http_code}" \
		--output "$RESPONSE_FILE" \
		"$@")
	cat "$RESPONSE_FILE"
	rm "$RESPONSE_FILE"

	if test "$HTTP_CODE" -ge 300; then
		echo_error "Request failed: $HTTP_CODE"
		return "$REQUEST_FAILED"
	fi
}

# Applies updates to Dockerfile
save_changes() {
	local i=0
	while test $i -lt ${#_UPDATES[@]}; do
		local ID=${_UPDATES[((i++))]}
		local CURRENT_VALUE=${_UPDATES[((i++))]}
		local NEW_VALUE=${_UPDATES[((i++))]}
		local TYPE=${_UPDATES[((i++))]}

		if test "$TYPE" == "$IMPLICIT_UPDATE"; then
			continue
		fi

		local TARGET="Dockerfile"
		assert_replace "\($ID$ASSIGNMENT_REGEX\)$CURRENT_VALUE" "\1$NEW_VALUE" "$TARGET" "Item \"$ID $CURRENT_VALUE\" not found in \"$TARGET\""
	done
}

# Push changes and next tag to git
commit_changes() {
	local MAIN_ITEM="${1-}"

	# Any update will be tagged with an incremented release counter
	local CURRENT_RELEASE="${_GIT_VERSION##*-}"
	local NEXT_RELEASE="$((CURRENT_RELEASE + 1))"
	local NEXT_VERSION="${_GIT_VERSION%-*}-$NEXT_RELEASE"

	# But if the main item was updated, use the item version as tag
	if test -n "$MAIN_ITEM"; then
		local i=0
		while test $i -lt ${#_UPDATES[@]}; do
			local ID=${_UPDATES[((i++))]}
			local CURRENT_VALUE=${_UPDATES[((i++))]}
			local NEW_VALUE=${_UPDATES[((i++))]}
			local TYPE=${_UPDATES[((i++))]}

			if test "$ID" != "$MAIN_ITEM"; then
				continue
			fi

			# Skip the main item update if only the release counter was incremented
			local STRIPPED_CURRENT_VALUE="${CURRENT_VALUE%%-*}"
			local STRIPPED_NEW_VALUE="${NEW_VALUE%%-*}"
			if test "$STRIPPED_CURRENT_VALUE" != "$STRIPPED_NEW_VALUE"; then
				NEXT_VERSION="$STRIPPED_NEW_VALUE-1"
			fi
		done
	fi

	git add Dockerfile
	git commit -m "${_CHANGELOG%, }"
	git tag "$NEXT_VERSION"
	git push
	git push origin "$NEXT_VERSION"
}

# Check if tag in registry
image_exists() {
	local IMG="$1"

	local NAME && NAME=$(cut -f "1" -d ":" <<< "$1")
	local TAG && TAG=$(cut -f "2" -d ":" <<< "$1")
	if curl_request "https://registry.hub.docker.com/v2/repositories/$NAME/tags" | grep --only-matching "\"name\":\"$TAG\"" > /dev/null; then
		return 0
	else
		return "$IMAGE_MISSING"
	fi
}

# Check for base image update
update_image() {
	local IMG="$1"
	local IMG_ESCAPED="${IMG//+/\\+}"
	local VERSION_REGEX="$2"
	local PRETTY_NAME="${3-$IMG}"

	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=FROM $IMG_ESCAPED:)$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(curl_request "https://registry.hub.docker.com/v2/repositories/$IMG/tags?page_size=128" | jq --raw-output ".results[].name" | grep --only-matching --perl-regexp "^$VERSION_REGEX" | sort --version-sort | tail -n 1)
	process_update "$IMG" "$CURRENT_VERSION" "$NEW_VERSION" "$PRETTY_NAME"
}

# Check the provided Docker image for package updates with a package manager
update_packages() {
	local IMG="$1"
	local UPGRADE_COMMAND="$2"
	local UPGRADEABLE_PACKAGES_FUNCTION="$3"
	local PROCESS_LIST_FUNCTION="$4"

	local TARGET="Dockerfile"
	assert_search "$UPGRADE_COMMAND" "$TARGET" "No \"$UPGRADE_COMMAND\" found in \"$TARGET\"!"

	local CONTAINER_ID && CONTAINER_ID=$(docker run --quiet --rm --detach --entrypoint sleep "$IMG:$_GIT_VERSION" 60)
	local PKG_LIST && PKG_LIST=$("$UPGRADEABLE_PACKAGES_FUNCTION" "$CONTAINER_ID")
	docker stop --timeout 0 "$CONTAINER_ID" > /dev/null

	# Abort when no packages are available for upgrade, because mapfile can't
	# handle an empty PKG_LIST properly (or I don't know how to use it). It
	# would produce an array with one empty element, which breaks everything...
	if test -z "$PKG_LIST"; then
		return
	fi
	mapfile -t "PKG_LIST" <<< "$PKG_LIST"
	"$PROCESS_LIST_FUNCTION" "${PKG_LIST[@]}"

	# Append current date and time to the UPGRADE_KEYWORD without putting it in the
	# changelog to keep track of implicit updates.
	if updates_available; then
		_UPDATES+=("ARG LAST_UPGRADE" ".\+" "\"$(date --iso-8601=seconds)\"" "$HIDDEN_UPDATE")
	fi
}

# Get a list of upgradeable packages in an Alpine container
upgradeable_packages_apk() {
	local CONTAINER_ID="$1"

	docker exec --user root "$CONTAINER_ID" apk update > /dev/null
	docker exec --user root "$CONTAINER_ID" apk list --upgradeable
}

# Process the list of upgradeable packages from the Alpine Package Keeper
process_list_apk() {
	local PKG_LIST=("$@")

	for LINE in "${PKG_LIST[@]}"; do
		local FIRST_FIELD && FIRST_FIELD=$(awk '{print $1}' <<< "$LINE")
		local PKG && PKG=$(grep --only-matching --perl-regexp "^.+(?=-\d)" <<< "$FIRST_FIELD")
		local NEW_VERSION && NEW_VERSION=$(grep --only-matching --perl-regexp "(?<=-)\d+.+" <<< "$FIRST_FIELD")
		local LAST_FIELD && LAST_FIELD=$(awk '{print $NF}' <<< "$LINE")
		local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=-)\d+[^\]]+" <<< "$LAST_FIELD")
		process_update "$PKG" "$CURRENT_VERSION" "$NEW_VERSION"
	done
}

# Check the provided Docker image for package updates by using the Alpine Package Keeper (apk)
update_packages_apk() {
	local IMG="$1"

	update_packages "$IMG" "apk upgrade" "upgradeable_packages_apk" "process_list_apk"
}

# Get a list of upgradeable packages in a Debian container
upgradeable_packages_apt() {
	local CONTAINER_ID="$1"

	docker exec --user root "$CONTAINER_ID" apt-get update > /dev/null
	docker exec --user root "$CONTAINER_ID" apt-get -o "APT::Get::Show-User-Simulation-Note=false" --simulate full-upgrade | { grep ^Inst || true; }
}

# Process the list of upgradeable packages from the Advanced Package Tool
process_list_apt() {
	local PKG_LIST=("$@")

	for LINE in "${PKG_LIST[@]}"; do
		local PKG && PKG=$(cut --only-delimited --delimiter " " --field 2 <<< "$LINE")
		local CURRENT_VERSION && CURRENT_VERSION=$(cut --only-delimited --delimiter " " --field 3 <<< "$LINE" | tr -d "[]")
		local NEW_VERSION && NEW_VERSION=$(cut --only-delimited --delimiter " " --field 4 <<< "$LINE" | tr -d "(")
		process_update "$PKG" "$CURRENT_VERSION" "$NEW_VERSION"
	done
}

# Check the provided Docker image for package updates by using the Advanced Package Tool (apt)
update_packages_apt() {
	local IMG="$1"
	update_packages "$IMG" "apt full-upgrade" "upgradeable_packages_apt" "process_list_apt"
}

# Check for steam depot update
update_depot() {
	local APP_ID="$1"
	local DEPOT_ID="$2"
	local MANIFEST_NAME="$3"
	local PRETTY_NAME="$4"

	local MANIFEST_REGEX && MANIFEST_REGEX="\d{16,19}"
	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=$MANIFEST_NAME=)$MANIFEST_REGEX" "Dockerfile")
	local APP_INFO && APP_INFO=$(docker run --rm --mount type=bind,source=/etc/localtime,target=/etc/localtime,readonly hetsh/steamapi steamcmd.sh +login anonymous +app_info_print "$APP_ID" +quit)
	local NEW_VERSION && NEW_VERSION=$(echo "$APP_INFO" | sed -e "1,/$DEPOT_ID/d" -e '1,/manifests/d' -e '/maxsize/,$d' | grep --perl-regexp --only "public\"\h+\"\K$MANIFEST_REGEX")
	process_update "$MANIFEST_NAME" "$CURRENT_VERSION" "$NEW_VERSION" "$PRETTY_NAME"
}

# Check for steam mod update
update_mod() {
	local MOD_ID="$1"
	local VERSION_ID="$2"
	local PRETTY_NAME="$3"

	local VERSION_REGEX && VERSION_REGEX="\d{1,2} .{3}(, \d{4})? @ \d{1,2}:\d{1,2}(am|pm)"
	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=$VERSION_ID=\")$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(curl_request "https://steamcommunity.com/sharedfiles/filedetails/changelog/$MOD_ID" | grep --only-matching --perl-regexp "(?<=Update: )$VERSION_REGEX" | head -n 1)
	process_update "$VERSION_ID" "$CURRENT_VERSION" "$NEW_VERSION" "$PRETTY_NAME"
}

# Check for update on GitHub
update_github() {
	local REPO="$1"
	local VERSION_ID="$2"
	local VERSION_REGEX="$3"
	local PRETTY_NAME="${4-$VERSION_ID}"

	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=$VERSION_ID=)$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(curl_request "https://api.github.com/repos/$REPO/releases/latest" | jq -r ".tag_name" | sed "s|^v||")
	process_update "$VERSION_ID" "$CURRENT_VERSION" "$NEW_VERSION" "$PRETTY_NAME"
}

# Check for new tag in git repository
update_git() {
	local URL="$1"
	local VERSION_ID="$2"
	local VERSION_REGEX="$3"
	local PRETTY_NAME="${4-$VERSION_ID}"

	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=$VERSION_ID=)$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(git ls-remote --tags "$URL" | cut --only-delimited --field 2 | grep --only-matching --perl-regexp "(?<=refs/tags/)$VERSION_REGEX" | sort --version-sort | tail -n 1)
	process_update "$VERSION_ID" "$CURRENT_VERSION" "$NEW_VERSION" "$PRETTY_NAME"
}

# Check for update on webpage
update_web() {
	local VAR="$1"
	local URL="$2"
	local VAL_REGEX="$3"
	local PRETTY_NAME="${4-$VAR}"

	local CURRENT_VAR && CURRENT_VAR=$(grep --only-matching --perl-regexp "(?<=$VAR=)$VAL_REGEX" "Dockerfile")
	local NEW_VAR && NEW_VAR=$(curl_request "$URL" | grep --only-matching --perl-regexp "$VAL_REGEX" | sort --version-sort | tail -n 1)
	process_update "$VAR" "$CURRENT_VAR" "$NEW_VAR" "$PRETTY_NAME"
}

# Check for update on http file server
update_fileserver() {
	local VAR="$1"
	local URL="$2"
	local VAL_REGEX="$3"
	local PRETTY_NAME="${4-$VAR}"

	local CURRENT_VAL && CURRENT_VAL=$(grep --only-matching --perl-regexp "(?<=$VAR=)$VAL_REGEX" Dockerfile)
	local NEW_VAL && NEW_VAL=$(curl_request "$URL" | grep --only-matching --perl-regexp "$VAL_REGEX(?=/)" | sort --version-sort | tail -n 1)
	process_update "$VAR" "$CURRENT_VAL" "$NEW_VAL" "$PRETTY_NAME"
}

# Check for update on pypi
update_pypi() {
	local PKG="$1"
	local VERSION_REGEX="$2"

	local CURRENT_VERSION && CURRENT_VERSION=$(grep --only-matching --perl-regexp "(?<=$PKG==)$VERSION_REGEX" "Dockerfile")
	local NEW_VERSION && NEW_VERSION=$(curl_request "https://pypi.org/pypi/$PKG/json" | jq -r ".info.version")
	process_update "$PKG" "$CURRENT_VERSION" "$NEW_VERSION"
}
