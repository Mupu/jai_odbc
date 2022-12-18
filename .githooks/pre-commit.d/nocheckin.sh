#!/bin/bash
# Author: xezrunner (github.com/xezrunner)
# Credit: DustinGadal on r/Jai

# Required programs/utilities for default behavior (as-is):
# git, grep, xargs

# This pre-commit hook/script checks for the existence of the word "$SEARCH_TARGET"
# in your *staged* source files, then aborts the commit if any matches were found.
# It also shows you where you have them inside the file.

SEARCH_TARGET="nocheckin"

CL_RED='\e[31m'
CL_BRED='\e[1;31m'
CL_NONE='\e[0m'

MESSAGE_0="${CL_BRED}Error:${CL_NONE} $SEARCH_TARGET(s) were found in "
MESSAGE_1="file(s) - ${CL_BRED}ignoring commit:${CL_NONE}"

SEARCH_CMD="git diff --staged -i --diff-filter=d --name-only -G $SEARCH_TARGET --relative $PWD"
GREP_CMD="grep -H $SEARCH_TARGET -n --color=always" # <filename>:line******

# Get the amount of files that we found the search target in:
# NOTE: I use 'wc -l' (line count of command output) for this.
# If you use a custom $SEARCH_CMD, either make sure it returns an output
# that favors this, or modify the following to your liking:
STATUS=$($SEARCH_CMD | grep -v README  | grep -v pre-commit | wc -l)

if ((STATUS > 0)); then
	echo -e $MESSAGE_0 $STATUS $MESSAGE_1;
	($SEARCH_CMD | xargs $GREP_CMD);
	exit 1;
fi
