## Run checks and tests for the `prompt-env.sh` script, including dependency management.
##
## - Author: Mike Lewis <mike@mplew.is>
## - Date: 2021-02-19
##
## The intent of this file is to be a "zero-configuration" automation script, where any setup or dependency installation that needs to be done is taken care of by this script.
## While there may be issues to be solved along the way, the desired end result is to able to perform the following steps:
## 1. Clone this repository
## 2. `make checks`
## and then have all tests and code checks run for the project, without needing to manually install or configure dependencies.
##
## Pursuant to the above, we make the assumption that you either have [Homebrew](https://brew.sh} installed, or are willing to have it installed for you, as that is the way that dependency management is performed for this automation script.
##
## This file is primarily a convenience for interactive usage, and as such does not have a public API for integrating with other scripts.
## However, the current targets and their functions are provided below:
## - setup                  : install all needed dependecies for running checks
## - test                   : run all tests of the `prompt-env.sh` script
## - coverage-json, coverage: generate the JSON coverage report, exiting with a failure code if not 100% covered
## - coverage-html          : generate the HTML coverage report and open it with the system-registered program
## - lint                   : run all lint checks of the `prompt-env.sh` script
## - clean, clean-all       : remove all generated files

# Don't do anything by default, as there's nothing to "build" here.
.PHONY: default
default: ;

# Instead of silencing each command (which makes the code less readable and hinders debugging), make use of the special `.SILENT` target to prevent printing of commands unless the `VERBOSE` flag is set.
ifndef VERBOSE
    .SILENT:
endif


# Set some variables for centralization purposes.
HOMEBREW                  = $(shell which brew || echo '/usr/local/bin/brew')
BUILD_DIRECTORY          := .build
GEM_INSTALLATION_RECEIPT := ${BUILD_DIRECTORY}/Gemfile.lock

# Install Homebrew if not already present.
${HOMEBREW}:
	/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"

# Install or update dependencies from stored bundle file.
Brewfile.lock.json: Brewfile | ${HOMEBREW}
	brew update
	brew bundle

# Create the build artifacts directory.
${BUILD_DIRECTORY}:
	mkdir -p '${@}'

# Install dependencies from stored version and bundle files and create an installation "receipt" file.
# This file is separate from `Gemfile.lock` to force dependency installation at least once; otherwise, on a fresh clone of the repository the timestamps may all be the same and `make` will think everything is up to date.
# The content of this file is unimportant (only its existence and timestamp), but by reusing the contents of `Gemfile.lock` there's at least some evidence of what its purpose is.
${GEM_INSTALLATION_RECEIPT}: Gemfile.lock .ruby-version Gemfile Brewfile.lock.json | ${BUILD_DIRECTORY}
	rbenv install --skip-existing
	"$$(rbenv which bundle)" install
	cp -f '${<}' '${@}'
	touch '${@}'

# Provide a shortcut target for installing dependencies.
.PHONY: setup
setup: Brewfile.lock.json ${GEM_INSTALLATION_RECEIPT}


# Dynamically find the files run in the coverage report instead of hardcoding them.
SOURCE_FILES                       = $(shell find Sources -name '*.sh')
TEST_FILES                         = $(shell find Tests -name '*.sh') $(shell find Tests -name '*.exp')


# Run all test cases, ensuring dependencies are installed and up-to-date first.
.PHONY: test
test: ${TEST_FILES} Brewfile.lock.json
	shunit2 '${<}'


# Set some variables for centralization purposes.
COVERAGE_DIRECTORY                := .coverage
COVERAGE_REPORT_JSON              := ${COVERAGE_DIRECTORY}/coverage.json
COVERAGE_REPORT_JSON_INTERMEDIATE := ${COVERAGE_DIRECTORY}/.coverage.json
COVERAGE_REPORT_HTML              := ${COVERAGE_DIRECTORY}/index.html

# Dynamically calculate whether an HTML coverage report is requested based on the target being generated.
# This checks to see if `${COVERAGE_REPORT_HTML}` matches the target name and sets the variable to `1` if so; otherwise, set the variable to `0`.
# Note that this is only computed when requested, so it always gets the current value for the current target.
SIMPLECOV_HTML                     = $(if $(filter ${COVERAGE_REPORT_HTML},${@}),1,0)

# Generate either the (intermediate) JSON or HTML coverage report, depending on which target is requested.
# This complexity is used to allow unified rule and dependency definitions for the two reports (which effectively only differ in "formatting").
${COVERAGE_REPORT_JSON_INTERMEDIATE} ${COVERAGE_REPORT_HTML}: ${TEST_FILES} ${SOURCE_FILES} .simplecov Makefile Brewfile.lock.json ${GEM_INSTALLATION_RECEIPT}
	SIMPLECOV_HTML=${SIMPLECOV_HTML} "$$(rbenv which bundle)" exec bashcov --bash-path="$$(brew --prefix)/bin/bash" shunit2 '${<}'

# Post-process the intermediate JSON report to strip absolute path references and pretty-print (otherwise the data is all on one line).
${COVERAGE_REPORT_JSON}: ${COVERAGE_REPORT_JSON_INTERMEDIATE} Brewfile.lock.json
	0<'${<}' jq --tab '.files[].filename |= sub("${CURDIR}/"; "")' 1>'${@}'


# Provide some shortcut targets for generating the JSON coverage report.
.PHONY: coverage
coverage: coverage-json

# Print coverage summary and fail if not 100% covered, even if reusing result from previous run.
.PHONY: coverage-json
coverage-json: ${COVERAGE_REPORT_JSON} Brewfile.lock.json
    # Extract the number and percentage of covered lines from the JSON report.
	0<'${<}' jq --raw-output '.metrics | "\(.covered_lines)/\(.total_lines) (\(.covered_percent)%) covered"'
    # Exit with failure status if not 100% covered
	0<'${<}' jq --exit-status '.metrics | .covered_lines == .total_lines' 1>/dev/null

# Provide a shortcut target for generating (and opening) the HTML coverage report.
.PHONY: coverage-html
coverage-html: ${COVERAGE_REPORT_HTML}
	open '${<}'


# Get a list of all the shell-file dependencies of the current target.
SHELL_DEPENDENCIES = $(filter %.sh,${^})

# Run linting tools against the source and test files.
.PHONY: lint
lint: ${SOURCE_FILES} ${TEST_FILES} Brewfile.lock.json
	shellcheck ${SHELL_DEPENDENCIES}
	checkbashisms --posix ${SHELL_DEPENDENCIES}


# Provide a shortcut target for running all checks.
.PHONY: checks
checks: test coverage lint


# Clean up generated files.
# Use a stub for `clean-all` for now, just so the various subprojects all have the same API.
.PHONY: clean clean-all
clean clean-all:
	rm -f Brewfile.lock.json
	rm -rf '${BUILD_DIRECTORY}'
	rm -rf '${COVERAGE_DIRECTORY}'
