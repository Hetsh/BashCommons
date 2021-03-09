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

# Extracts a variable from another script
extract_var() {
	local VAR_NAME="$1"
	local SCRIPT="$2"
	local REGEX="${3:-.*}"

	local -n VAR="$VAR_NAME"
	VAR=$(cat "$SCRIPT" | grep -P -o "(?<=$VAR_NAME=)$REGEX")
}
