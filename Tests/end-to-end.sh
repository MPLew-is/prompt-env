#! /bin/sh
##
## Test the end-to-end functionality of `prompt-env` using `shunit2`, ensuring correct prompting and variable parsing behavior.
##
## @author [Mike Lewis](mailto:mike@mplew.is)
## @date 2020-07-13
##
## Usage:
## ```sh
## shunit2 end-to-end.sh
## ```

# Create a per-test-case temporary directory inside the script-level one (created by `shunit2`) to isolate test cases from each other.
# This is probably overkill since the helper functions below clean up the individual files they create, but this provides a strong guarantee of isolation even on failure or for future parallelization.
# This function is called automatically by `shunit2` before each test case is run.
setUp() {
	testTemporaryDirectory="$(mktemp -d "${SHUNIT_TMPDIR}/XXXXXX")"
}

# Clean up the temporary directory for the just-finished test case.
# This function is called automatically by `shunit2` after each test case completes.
tearDown() {
	# Explicitly unset the per-test temporary directory, to ensure it doesn't leak into the next test.
	# The directory itself will be cleaned by `shunit2`, so there's no need to do anything else.
	unset testTemporaryDirectory
}

# Declare some dummy functions to prevent strange interactions between `bashcov` and `shunit2` when a function is being dynamically looked up and exists only in `shunit2`.
# It seems that `shunit2`'s lookup functionality breaks `bashcov`'s instrumentation redirection, leading to that output being printed to the console and not picked to indicate a hit line for coverage.
# By defining dummy functions, the coverage issues go away and `shunit2` seems to perform exactly the same.
oneTimeSetUp() {
	true
}
oneTimeTearDown() {
	true
}
# The fact that this does not cause issues running the tests is probably a bug, as `shunit2` says defining this will override its built-in test-function detection.
suite() {
	true
}


# Get the name of the command that invoked this script, so that the script under test can be invoked the same way.
# This is needed because the shell code coverage tools are tightly coupled to `bash` introspection features and `source`ing the script while under test seems to produce strange errors.
# Explicitly using the same shell as this test script was called with allows the actual source script to keep its `/bin/sh` shebang while still being able to be tested under `bash`.
invokingShell="$(ps -p "${$}" -ocomm=)"

# Extract the path to the repository root from the current working directory from the arguments, as this script is invoked with `shunit2 {script path}.`
rootDirectory="$(dirname "$(dirname "${1}")")"

# Store the path to the script under test, for centralization purposes.
promptEnvPath="${rootDirectory}/Sources/prompt-env.sh"

# Call `prompt-env` without mocking an interactive TTY, just feeding the script input directly over `stdin`.
# This will produce the correct env-file output, but `read -p` will not display a prompt when not reading from (what it thinks is) a terminal.
promptEnv() {
	# Call `prompt-env` directly without a wrapper (other than the invoking shell).
	"${invokingShell}" "${promptEnvPath}" "${@}"
}

# Call `prompt-env` via an `expect` wrapper to mock an interactive TTY, allowing testing both the env-file output and the prompts the user sees.
# This is necessary since `read -p` (used in `prompt-env`) will not show the prompt unless it thinks it's reading from a terminal.
# This might seem like overkill, but since the prompts to the user are a part of the contract provided by `prompt-env`, they should be tested.
promptEnvInteractive() {
	# We want to return the exit status of the `expect` wrapper, so a pipe must be manually created.
	expectPipe="${testTemporaryDirectory}/expect.txt"
	mkfifo "${expectPipe}"

	# Invoke `tr` in the background to strip control characters added by `expect` when output is produced later.
	# We shouldn't have to resort to this hackery, but it's a quick solution to be able to diff between expected and actual output.
	0<"${expectPipe}" tr -d '\r' &
	trProcessId="${!}"

	# Run `prompt-env` via an `expect` wrapper to emulate a terminal (`read` behaves differently when being fed input from a prompt vs a TTY).
	"${rootDirectory}/Tests/read-prompt.exp" "${invokingShell}" "${promptEnvPath}" "${@}" 1>"${expectPipe}"
	status="${?}"

	# Make sure the background process completes and is cleaned up.
	wait "${trProcessId}"

	# Exit with the status from the `expect` wrapper.
	return "${status}"
}

# Diff between two input files, expected/old on `stdin` and actual/new as the first argument.
# Prints the diff in unified format to `stderr`, with the entire file printed as context (instead of just a few lines).
# Also returns with the `diff` exit status to allow easy failure analysis.
diff() {
	# Extract arguments into named variables for clarity.
	actualFile="${1}"

	# In order to provide the entire "expected" file as context, we need to count the number of lines; however, the input file can be a pipe, so we can't just read it twice.
	# Instead, use `tee` to duplicate the file to a temporary buffer and consume the original to count the lines.
	expectedBuffer="${testTemporaryDirectory}/buffer.txt"
	lines="$(tee "${expectedBuffer}" | wc -l | awk '{ print $1 }')"

	# A unified diff will print some unnecessary header information that includes the path to the file (which in this case is a garbage temporary path), so strip that header (the first 3 lines).
	# We have to manually create a new pipe here since we want to return the exit status from the `diff` call, which would otherwise be the first element in the pipeline and thus have its exit status ignored.
	diffPipe="${testTemporaryDirectory}/output.diff"
	mkfifo "${diffPipe}"
	# Named pipes block until both ends are open, so invoke `tail` in the background.
	# We also want the `diff` output to go to the user's `stderr` rather than `stdout`, so redirect that too.
	0<"${diffPipe}" tail -n +3 1>&2 &
	tailProcessId="${!}"

	# Diff between the files with full-file context, writing to the pipe being read by `tail`.
	colordiff --unified="${lines}" "${expectedBuffer}" "${actualFile}" 1>"${diffPipe}"
	status="${?}"

	# Make sure the background process we created finishes and is cleaned up.
	wait "${tailProcessId}"

	# Exit with the status from the `diff` call.
	return "${status}"
}

# Pass `stdin` to `prompt-env` and diff the output with the contents of file descriptor 3, returning an error on either `prompt-env` or `diff` failure.
# Calls `prompt-env` with an input function/command name as the first argument, using the remainder as arguments to the function.
# We want to have the same diff behavior for the interactive and non-interactive test flavors, so this function centralizes that logic and allows a different function for `prompt-env` to be dropped in as needed.
promptEnvDiff() {
	# If the `--interactive` flag is provided, switch to using the `expect` wrapper.
	if [ "${1}" = '--interactive' ]
	then
		promptEnvFunction='promptEnvInteractive'
		shift

	# Otherwise, just use the normal call.
	else
		promptEnvFunction='promptEnv'
	fi

	# Create a named pipes for the actual file (the expected is on file descriptor 3).
	# `diff` can only be told to read from stdin, so we need something with an actual name for one of the arguments.
	actualPipe="${testTemporaryDirectory}/actual.txt"
	mkfifo "${actualPipe}"

	# Spawn a background `diff` process comparing the actual and expected outputs, and store its process ID for later cleanup.
	# The reader of the pipe must always be spawned first or the writer will crash with an error.
	0<&3 diff "${actualPipe}" &
	diffProcessId="${!}"

	# Pass `stdin` to `prompt-env` (dynamically, with function name selected based on input) and write its output to the actual pipe.
	"${promptEnvFunction}" "${@}" 1>"${actualPipe}"
	promptEnvStatus="${?}"

	# Wait for the diff invocation to finish and store its return code.
	wait "${diffProcessId}"
	diffStatus="${?}"

	# Exit with the sum of statuses from the diff and `prompt-env` invocations, so that a failure code is returned if either invocation fails.
	# In general, this will likely be just the `diff` exit code, but if both return a failure code the value of the individual components will probably not be immediately obvious.
	return "$((diffStatus + promptEnvStatus))"
}

# All of the below test cases are in the format:
# ```sh
# 0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff {arguments}
#     {some input value}
# INPUT
#     {some expected value}
# EXPECTED
# ```
#
# This formatting is probably a little esoteric, so here's the general overview:
# - `{number}<<`: create [a here-doc](https://tldp.org/LDP/abs/html/here-docs.html) on the file descriptor given by `{number}`, allowing us to specify raw input directly at this command instead of having to deal with storing multi-line strings in a variable and then echoing them.
# - `{number}<<-`: create a here-doc as above that ignores leading spacing so that the contents can be indented for code-formmating purposes.
# - `{number}<<-'STRING'`: use 'STRING' as the delimiter for the end of the heredoc, and do not attempt to expand variables or other shell commands found in its contents (strictly treat the here-doc as text).
#
# Thus, anything between the command and `INPUT` is what's fed over file descriptor 0 (`stdin`) to `prompt-env`, and anything between `INPUT` and `EXPECTED` is what's fed over file descriptor 3 as the 'expected' output from `prompt-env` to the given input and arguments.
# Additionally, by making the diff invocation the last command in the function, its status is automatically returned as the output of the function so that `shunit2` can correctly show failures; if more complex test cases are needed, that status will need to be stored and explicitly `return`ed.
# All functions (such as the ones below) that start with `test` are considered test cases by `shunit2`; simply add new functions matching that format to add new tests.

# Test that a non-interactive no-variable prompt succeeds and has no output.
testNoOp() {
	0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff
	INPUT
	EXPECTED
}

# Test that an interactive no-variable prompt succeeds and has no output.
testNoOpInteractive() {
	0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff --interactive
	INPUT
	EXPECTED
}

# Test that a single-variable, non-secure, non-interactive prompt succeeds and matches expected env-file output.
testSingleVariable() {
	0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff FOO
		bar
	INPUT
		FOO="bar"
	EXPECTED
}

# Test that a single-variable, non-secure, interactive prompt succeeds and matches expected output for both the user-facing prompts and the output env file.
testSingleVariableInteractive() {
	0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff --interactive FOO
		bar
	INPUT
		FOO: bar
		FOO="bar"
	EXPECTED
}

# Test that a single-variable, non-secure, non-interactive prompt with custom text succeeds and matches expected env-file output.
testSingleVariableCustomPrompt() {
	0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff "Your foo":FOO
		bar
	INPUT
		FOO="bar"
	EXPECTED
}

# Test that a single-variable, non-secure, interactive prompt with custom text succeeds and matches expected output for both the user-facing prompts and the output env file.
testSingleVariableCustomPromptInteractive() {
	0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff --interactive "Your foo":FOO
		bar
	INPUT
		Your foo: bar
		FOO="bar"
	EXPECTED
}

# Test that a single-variable, secure, non-interactive prompt succeeds and matches expected env-file output.
testSingleSecureVariable() {
	0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff FOO --secure
		bar
	INPUT
		FOO="bar"
	EXPECTED
}

# Test that a single-variable, secure, interactive prompt succeeds and matches expected env-file output.
# The backslash is used below to prevent the trailing space from being removed by overzealous text editors.
testSingleSecureVariableInteractive() {
	0<<-'INPUT' 3<<-EXPECTED promptEnvDiff --interactive FOO --secure
		bar
	INPUT
		FOO: \

		FOO="bar"
	EXPECTED
}

# Test that a multi-variable, non-secure, non-interactive prompt succeeds and matches expected env-file output.
testMultipleVariables() {
	0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff FOO BAZ
		bar
		qux
	INPUT
		FOO="bar"
		BAZ="qux"
	EXPECTED
}

# Test that a multi-variable, non-secure, interactive prompt succeeds and matches expected output for both the user-facing prompts and the output env file.
testMultipleVariablesInteractive() {
	0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff --interactive FOO BAZ
		bar
		qux
	INPUT
		FOO: bar
		BAZ: qux
		FOO="bar"
		BAZ="qux"
	EXPECTED
}

# Test that a multi-variable, secure, non-interactive prompt succeeds and matches expected env-file output.
testMultipleSecureVariables() {
	0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff FOO --secure BAZ --secure
		bar
		qux
	INPUT
		FOO="bar"
		BAZ="qux"
	EXPECTED
}

# Test that a multi-variable, secure, interactive prompt succeeds and matches expected output for both the user-facing prompts and the output env file.
# The backslashes are used below to prevent the trailing space from being removed by overzealous text editors.
testMultipleSecureVariablesInteractive() {
	0<<-'INPUT' 3<<-EXPECTED promptEnvDiff --interactive FOO --secure BAZ --secure
		bar
		qux
	INPUT
		FOO: \

		BAZ: \

		FOO="bar"
		BAZ="qux"
	EXPECTED
}

# Test that a secure variable followed by a non-secure one in a non-interactive prompt succeeds and matches expected env-file output.
testSecureThenNonSecureVariable() {
	0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff FOO --secure BAZ
		bar
		qux
	INPUT
		FOO="bar"
		BAZ="qux"
	EXPECTED
}

# Test that a secure variable followed by a non-secure one in an interactive prompt succeeds and matches expected output for both the user-facing prompts and the output env file.
# The backslash is used below to prevent the trailing space from being removed by overzealous text editors.
testSecureThenNonSecureVariableInteractive() {
	0<<-'INPUT' 3<<-EXPECTED promptEnvDiff --interactive FOO --secure BAZ
		bar
		qux
	INPUT
		FOO: \

		BAZ: qux
		FOO="bar"
		BAZ="qux"
	EXPECTED
}

# Test that a non-secure variable followed by a secure one in a non-interactive prompt succeeds and matches expected env-file output.
testNonSecureThenSecureVariable() {
	0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff FOO BAZ --secure
		bar
		qux
	INPUT
		FOO="bar"
		BAZ="qux"
	EXPECTED
}

# Test that a non-secure variable followed by a secure one in an interactive prompt succeeds and matches expected output for both the user-facing prompts and the output env file.
# The backslash is used below to prevent the trailing space from being removed by overzealous text editors.
testNonSecureThenSecureVariableInteractive() {
	0<<-'INPUT' 3<<-EXPECTED promptEnvDiff --interactive FOO BAZ --secure
		bar
		qux
	INPUT
		FOO: bar
		BAZ: \

		FOO="bar"
		BAZ="qux"
	EXPECTED
}

# Test that a single-variable, non-secure, non-interactive prompt successfully reads a value from an environment variable when given no input.
testEnvironmentVariableExtraction() {
	FOO=bar 0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff FOO
	INPUT
		FOO="bar"
	EXPECTED
}

# Test that a single-variable, non-secure, interactive prompt successfully reads a value from an environment variable when given no input.
testEnvironmentVariableExtractionInteractive() {
	FOO=bar 0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff --interactive FOO
	INPUT
		FOO="bar"
	EXPECTED
}

# Test that a single-variable, non-secure, non-interactive prompt successfully reads a value from an environment variable when given some input.
testEnvironmentVariableExtractionIgnoreInput() {
	FOO=bar 0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff FOO
		baz
	INPUT
		FOO="bar"
	EXPECTED
}

# Test that a single-variable, non-secure, interactive prompt successfully reads a value from an environment variable when given some input.
testEnvironmentVariableExtractionIgnoreInputInteractive() {
	FOO=bar 0<<-'INPUT' 3<<-'EXPECTED' promptEnvDiff --interactive FOO
		baz
	INPUT
		FOO="bar"
	EXPECTED
}
