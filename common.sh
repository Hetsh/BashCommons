#!/bin/bash


# Cheat-Sheet for POSIX Parameter Expansion
#
# +--------------------+----------------------+-----------------+-----------------+
# |   Expression       |       parameter      |     parameter   |    parameter    |
# |   in script:       |   Set and Not Null   |   Set But Null  |      Unset      |
# +--------------------+----------------------+-----------------+-----------------+
# | ${parameter:-word} | substitute parameter | substitute word | substitute word |
# | ${parameter-word}  | substitute parameter | substitute null | substitute word |
# | ${parameter:=word} | substitute parameter | assign word     | assign word     |
# | ${parameter=word}  | substitute parameter | substitute null | assign word     |
# | ${parameter:?word} | substitute parameter | error, exit     | error, exit     |
# | ${parameter?word}  | substitute parameter | substitute null | error, exit     |
# | ${parameter:+word} | substitute word      | substitute null | substitute null |
# | ${parameter+word}  | substitute word      | substitute word | substitute null |
# +--------------------+----------------------+-----------------+-----------------+

# Append snippet to a trap
append_trap() {
	local SIGNAL="$1"
	local SNIPPET="$2"

	local TRAP_HISTORY=$(trap -p $SIGNAL)
	if [ -z "${TRAP_HISTORY-unset}" ]; then
		trap "$SNIPPET" "$SIGNAL"
	else
		extract_3rd_argument() { echo "$3"; }
		EXISTING_SNIPPET=$(eval "extract_3rd_argument $TRAP_HISTORY")
		trap "$EXISTING_SNIPPET; $SNIPPET" "$SIGNAL"
	fi
}

# Print message with details on error
report_unexpected_error() {
	local RETVAL="$1"
	local LINE="$2"
	local FILE="$3"
	local COMMAND="$4"
	>&2 echo -e "\e[31mLine $LINE ($FILE): Command $COMMAND failed with exit code $RETVAL!\e[0m"
}
append_trap ERR 'report_unexpected_error "$?" "$LINENO" "$BASH_SOURCE" "$BASH_COMMAND"'

# Append cleanup step
add_cleanup_step() {
	local STEP="$1"

	local SIGNAL="EXIT"
	if [ -z "${_CLEANUP_BOILERPLATE_SET+unset}" ]; then
		append_trap $SIGNAL 'echo "Cleaning up ..."'
		append_trap $SIGNAL "set +e +u"
		_CLEANUP_BOILERPLATE_SET="true"
	fi

	append_trap $SIGNAL "$STEP"
}

# Ensure depending programs exist
assert_dependency() {
	if ! [ -x "$(command -v $1)" ]; then
		echo "\"$1\" is required but not installed!"
		exit $(false)
	fi
}

# Run script as specific user
force_user() {
	local REQUIRED_USER="$1"
	if [ "$(whoami)" != "$REQUIRED_USER" ]; then
		echo "Must be executed as user \"$REQUIRED_USER\"!"
		exit $(false)
	fi
}

# Ask user if action should be performed
confirm_action() {
	local MESSAGE="$1"
	read -p "$MESSAGE [y/n]" -n 1 -r && echo
	if [ "$REPLY" != "y" ]; then
		return $(false)
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

# Read password from cli
read_pass() {
	local VAR_PASSWORD="$1"

	local VAL_PASSWORD
	local VERIFICATION
	while true; do
		read -s -p "Enter $VAR_PASSWORD: " VAL_PASSWORD && echo ""
		read -s -p "Confirm $VAR_PASSWORD: " VERIFICATION && echo ""
		if [ "$VAL_PASSWORD" = "$VERIFICATION" ]; then
			break
		else
			echo "Passwords mismatch, try again!"
		fi
	done

	export_var "$VAR_PASSWORD" "$VAL_PASSWORD"
}

# Read username and password from cli
read_creds() {
	local VAR_USERNAME="$1"
	local VAR_PASSWORD="$2"

	local VAL_USERNAME
	read -p "Enter $VAR_USERNAME name: " VAL_USERNAME
	export_var "$VAR_USERNAME" "$VAL_USERNAME"

	read_pass "$VAR_PASSWORD"
}
