#!/usr/bin/env bash


# Print message on error
print_error() {
	echo -e "\e[31mLine $BASH_LINENO: Command $BASH_COMMAND failed with exit code $?!\e[0m"
}
trap "print_error" ERR


# Use traps for cleanup steps
add_cleanup() {
	_CLEANUP_TRAPS="$1; ${_CLEANUP_TRAPS-}"
	trap "set +e +u; echo 'Cleaning up ...'; $_CLEANUP_TRAPS echo 'done!'" EXIT
}

# Ensure depending programs exist
assert_dependency() {
	if ! [ -x "$(command -v $1)" ]; then
		echo "\"$1\" is required but not installed!"
		exit -1
	fi
}

# Run script as specific user
force_user() {
	local REQUIRED_USER="$1"
	if [ "$(whoami)" != "$REQUIRED_USER" ]; then
		echo "Must be executed as user \"$REQUIRED_USER\"!"
		exit -2
	fi
}

# Ask user if action should be performed
confirm_action() {
	local MESSAGE="$1"
	read -p "$MESSAGE [y/n]" -n 1 -r && echo
	if [ "$REPLY" != "y" ]; then
		return -1
	fi
}

# Make variable accessible to calling script
export_var() {
	local NAME="$1"
	local VALUE="$2"

	local -n EXPORT="$NAME"
	EXPORT="$VALUE"
}

# Extracts a variable from another script
extract_var() {
	local VAR_NAME="$1"
	local SCRIPT="$2"
	local REGEX="${3:-.*}"

	export_var "$VAR_NAME" $(cat "$SCRIPT" | grep -P -o "(?<=$VAR_NAME=)$REGEX")
}

# Read username and password from cli
read_creds() {
	local VAR_USERNAME="$1"
	local VAR_PASSWORD="$2"

	local VAL_USERNAME
	local VAL_PASSWORD
	local VERIFICATION
	read -p "Enter $VAR_USERNAME name: " VAL_USERNAME
	read -s -p "Enter $VAR_PASSWORD: " VAL_PASSWORD && echo ""
	read -s -p "Confirm $VAR_PASSWORD: " VERIFICATION && echo ""
	if [ "$VAL_PASSWORD" != "$VERIFICATION" ]; then
		echo "Passwords mismatch!"
		return -1
	fi

	export_var "$VAR_USERNAME" "$VAL_USERNAME"
	export_var "$VAR_PASSWORD" "$VAL_PASSWORD"
}
