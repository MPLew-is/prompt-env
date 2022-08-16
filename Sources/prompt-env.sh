#! /bin/sh
##
## Prompt user for variable values, outputting them in .env format (which is also shell-compatible).
##
## - Author: Mike Lewis <mike@mplew.is>
## - Date: 2020-07-05
##
## This script is useful to, for instance, request authentication information from a user during scripted setup of a project and output that information in a common format without the user having to manually edit files.
## Will also read the requested values from environment variables (with the same name as the variable name on the command-line), to minimize user prompting if already set in the user's profile, for instance.
##
## Each argument is interpreted as:
## 1. An optional prompt string, followed by a colon
## 2. A variable name to store the user-entered data in
##
## An optional `--secure` (or `-s`) flag is supported directly after an argument to hide the user input on the console for sensitive data such as passwords.
##
## Example usage:
## ```sh
## ./prompt-env.sh > .env \
##     "Prompt variable with input shown":PROMPT_VARIABLE \
##     "Prompt variable with input hidden":PROMPT_VARIABLE_SECURE --secure \
##     NO_PROMPT_VARIABLE \
##     NO_PROMPT_VARIABLE_SECURE --secure
## ```
##
## Printed to stderr:
## ```text
## Prompt variable with input shown: {User-entered value}
## Prompt variable with input hidden:
## NO_PROMPT_VARIABLE: {User-entered value}
## NO_PROMPT_VARIABLE_SECURE:
## ```
##
## Printed to stdout (or `.env` in the example above), waiting until after all variables are read so as to not interlace with stderr printing if output is not redirected:
## ```sh
## PROMPT_VARIABLE="{User-entered value}"
## PROMPT_VARIABLE_SECURE="{User-entered value}"
## NO_PROMPT_VARIABLE="{User-entered value}"
## NO_PROMPT_VARIABLE_SECURE="{User-entered value}"
## ```

# Wrap script contents in a function for cleanliness and partial execution prevention (executing only half of a shell script can be dangerous, if for instance the script was being streamed from `curl` to `sh` and the download was interrupted).
main() {
	# Create a temporary file for writing the partial variables, open two file descriptors for it, then unlink the file.
	# This hack ensures that the temporary file is always cleaned up, regardless of when or how the script exits.
	# `3` is the read descriptor and `4` is the write descriptor, mirroring `0` and `1` usage for stdin and stdout.
	envFile="$(mktemp 'prompt-env.env.XXXXXX')"
	# shellcheck disable=SC2094
	exec 3<"${envFile}" 4>"${envFile}"
	rm "${envFile}"

	# Parse each argument and prompt for value as specified.
	while [ "${#}" -gt 0 ]
	do
		# Remove the longest prefix (`##`) of any characters then a colon (`*:`) by shell parameter expansion, leaving just the variable name.
		# If there's no matching prefix the argument will be left unchanged, which is the desired behavior.
		variable="${1##*:}"
		# Remove the shortest suffix (`%`) of a colon then any characters, leaving just the prompt text.
		# If there's no matching suffix the argument will be left unchanged, which is the desired behavior.
		prompt="${1%:*}"
		shift


		# Initialize a variable for the command to call when reading input.
		readCommand='read'

		# Use the `-s` flag on the `read` invocation if the next argument is the secure flag, and shift that argument off.
		if [ "${1}" = '--secure' ] || [ "${1}" = '-s' ]
		then
			readCommand="${readCommand} -s"
			shift
		fi

		# Set `value` to the variable being prompted for if it's already defined via environment.
		# This indirection is necessary since we only have the name of the variable we want in another variable.
		# Also note that this only sets `value` if the variable is defined at all to preserve the difference between unset and an empty string below (an empty string may be a valid value for the variable, and we don't want to reject that).
		# Adapted from: https://stackoverflow.com/a/13864829/5737106
		eval "if [ ! -z \"\${${variable}+defined}\" ]; then value=\${${variable}}; fi;"

		# Prompt user for value if not defined (`-z` passes when its argument is empty, and `${variable+string}` returns nothing if the variable is completely unset and 'string' otherwise - including when the variable contains an empty string).
		# shellcheck disable=SC2154
		if [ -z "${value+defined}" ]
		then
			# Prompt the user for the input for this variable.
			${readCommand} -p "${prompt}: " "${variable}"

			# If the secure flag was set, print a newline after prompt, since `read` will not.
			# Use `-t` to detect a terminal on `stdin`, to mirror the behavior of `read`.
			if [ "${readCommand}" != 'read' ] && [ -t 0 ]
			then
				echo '' 1>&2
			fi

			# Read the variable value in via indirection again.
			# We can make this simpler this time since we've already eliminated environment variable effects.
			eval "value=\${${variable}}"
		fi

		# Print the variable name and value to the temporary file for later output.
		# Example: `USERNAME="mplewis"`
		echo "${variable}=\"${value}\"" 1>&4

		# Unset `value` for next iteration, to not clobber variable-set status detection.
		unset value
	done

	# Print "cached" env-format output to stdout.
	0<&3 cat
}

main "${@}"
