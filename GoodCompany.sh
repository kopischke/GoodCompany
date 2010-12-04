#!/bin/bash

# GOODCOMPANY.SH - keeping your associations - a companion for FileVault
# reloads default handlers for UTI and URI bindings stored in LaunchServices.plist
# requires OS X 10.5 and duti 1.4 - http://duti.sourceforge.net/

# COPYRIGHT 2009 Martin Kopischke
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# application constants
readonly GC_BASENAME="GoodCompany"
readonly GC_LOG="[${GC_BASENAME}]"
readonly GC_DOMAIN="net.kopischke"
readonly GC_LSSAVED_NAME="${GC_BASENAME}.SavedState"
readonly GC_DUTICFG_NAME="${GC_BASENAME}.duti"
readonly GC_XSL_LEOPARD="${GC_BASENAME}.leopard.xsl"
readonly OSX_PLIST_SUFFIX="plist"
readonly OSX_LS_CONFIG="com.apple.LaunchServices"

# script version
readonly SCRIPT_VERSION=1.1.2

# minimum versions
readonly MIN_DUTI_VERSION=1.4
readonly MIN_BASH_VERSION=3

# exit codes
readonly E_OK=0
readonly E_RUNTIME_ERROR=1
readonly E_BAD_OS=70
readonly E_BAD_SHELL=71
readonly E_BAD_USER=72
readonly E_BAD_OPTION=73
readonly E_BAD_ARGUMENT=74
readonly E_BAD_CMD=75
readonly E_FILESYSTEM_ACCESS=80
readonly E_FILE_NOT_FOUND=81
readonly E_TIMED_OUT=90
readonly E_NOT_FV=91
readonly E_MISSING_CMD=127

if [[ $BASH_VERSION < $MIN_BASH_VERSION ]]; then
	echo "$GC_LOG Minimum Bash version required is ${MIN_BASH_VERSION}; aborting." >&2
	exit $E_BAD_SHELL
elif [[ ! "$OSTYPE" =~ darwin(9|10)\..* ]]; then
	echo "$GC_LOG Mac OS X 10.5 and 10.6 only; aborting." >&2
	exit $E_BAD_OS
fi

# check availability of all external commands
function gc_hash {
	func_exit_name=$FUNCNAME
	for needed in "$@"; do
		if ! hash $needed >/dev/null 2>&1; then
			echo "$GC_LOG Command not found in PATH -- $needed" >&2
			return $E_BAD_CMD
		fi
	done
	return $E_OK
}

# look for a named process in the process list and output result as 0 or 1 on stdout
# (used by wait for lsregister loop)
function gc_look_for {
	local cmd_exit cmd_out err_msg func_exit
	gc_hash ps grep
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	func_exit_name=$FUNCNAME

	cmd_out=$(ps -Aco comm 2>/dev/null | grep "$1" -c - 2>&1)
	cmd_exit=$?; if (( $cmd_exit > 1 )); then 
		echo "$GC_LOG Error looking for $1 process in process list -- 'grep' command returned $cmd_exit $cmd_out" >&2
		return $E_RUNTIME_ERROR
	fi

	echo $cmd_out
	return $E_OK
}

# get script path and parse into components
function gc_script_init {
	if (( $GC_SCRIPT_INITED == 1 )); then return $E_OK; fi

	local cmd_exit cmd_out err_msg func_exit
	gc_hash basename dirname
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	func_exit_name=$FUNCNAME
	
 	# make sure we catch source inclusions (which have $0 <> ${BASH_SOURCE[0]})
	local -r GC_SOURCE=${BASH_SOURCE[0]}

	# get script directory; use dirname as it always resolves to something usable (like '.')
	cmd_out=$(dirname "$GC_SOURCE" 2>&1)
	cmd_exit=$?; if (( $cmd_exit > 0 )); then
		echo "$GC_LOG Unable to retrieve script directory from Bash source $GC_SOURCE -- 'dirname' command returned $cmd_exit $cmd_out" >&2
		return $E_RUNTIME_ERROR
	fi	
	readonly GC_DIR=$(cd "$cmd_out"; pwd -P; cd "$OLDPWD")/
	
	# get script file name (including suffix); see above for rationale of using basename
	cmd_out=$(basename "$GC_SOURCE" 2>&1)
	cmd_exit=$?; if (( $cmd_exit > 0 )); then
		echo "$GC_LOG Unable to retrieve script file name from Bash source $GC_SOURCE -- 'basename' command returned $cmd_exit $cmd_out" >&2
		return $E_RUNTIME_ERROR
	fi
	readonly GC_SCRIPT=$cmd_out
 	readonly GC_SCRIPT_SUFFIX=${GC_SCRIPT##*.}
 
	# get full script path
 	readonly GC_SCRIPT_PATH=${GC_DIR}${GC_SCRIPT}
	if [[ ! -f "$GC_SCRIPT_PATH" ]]; then
		echo "$GC_LOG Invalid script file path -- $GC_SCRIPT_PATH" >&2
		return $E_FILE_NOT_FOUND
	fi

	GC_SCRIPT_INITED=1
 	return $E_OK
}

# validate the user context the script runs in, allowing for root calls via sudo etc.
# also check if the account is FileVault protected or not
function gc_validate_user {
	if (( GC_USER_VALIDATED == 1 )); then return $E_OK; fi
	
	local cmd_exit cmd_out err_msg func_exit
	gc_hash grep id who
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	func_exit_name=$FUNCNAME
	
	# always get the user currently logged on to the console, and note if we are root
	# this should return the current user even with multiple users logged on	
	cmd_out=$(who -m 2>&1)
	cmd_exit=$?; if [[ -z "$cmd_out" || (( $cmd_exit > 0 )) ]]; then
		$err_msg=" Unable to retrieve user name"
		if (( $cmd_exit > 0 )); then 
			err_msg="$err_msg -- 'who' command returned $cmd_exit $cmd_out"
		fi
		echo "$GC_LOG $err_msg" >&2
		return $E_RUNTIME_ERROR
	fi	
	local -r WHOM=${cmd_out%%' '*}
	local -r GREP="${WHOM}[[:space:]]+console"
	cmd_out=$(who 2>&1 | grep "$GREP" -Ec - 2>&1)
	cmd_exit=$?; if (( $cmd_exit > 1 || $cmd_out == 0 )); then
		$err_msg=" Unable to locate user $WHOM on console"
		if (( $cmd_exit > 0 )); then 
			err_msg="$err_msg -- 'grep' command returned $cmd_exit $cmd_out"
		fi
		echo "$GC_LOG $err_msg" >&2
		return $E_RUNTIME_ERROR
	fi
	readonly GC_USER=$WHOM
	
	# check if the user is a regular account (i.e. ID 501 and above)
	cmd_out=$(id -u $GC_USER 2>&1)
	cmd_exit=$?; if [[ -z "$cmd_out" || (( $cmd_exit > 0 )) ]]; then
		err_msg="Unable to retrieve user ID for user $GC_USER"
		if [[ -n "$cmd_out" ]]; then
			err_msg="$err_msg -- 'id' command returned $cmd_exit $cmd_out"
		fi
		echo "$GC_LOG $err_msg" >&2
		return $E_RUNTIME_ERROR
	fi
	local -r GC_USER_ID=$cmd_out
	if (( $GC_USER_ID < 501 )); then
		echo "$GC_LOG Not a local user -- $GC_USER (${GC_USER_ID})" >&2
		return $E_BAD_USER
	fi
	if (( GC_VERBOSE == 1 )); then echo "Apply actions to domain of user $GC_USER (${GC_USER_ID})"; fi

	# make sure we are either the user logged onto the console, or root
	cmd_out=$(id -u 2>&1)
	cmd_exit=$?; if [[ -z "$cmd_out" || (( $cmd_exit > 0 )) ]]; then
		$err_msg=" Unable to retrieve ID of calling user"
		if (( $cmd_exit > 0 )); then 
			err_msg="$err_msg -- 'id' command returned $cmd_exit $cmd_out"
		fi
		echo "$GC_LOG $err_msg" >&2
		return $E_RUNTIME_ERROR
	fi
	local -r GC_CALLER_ID=$cmd_out
	if [[ "$GC_CALLER_ID" != "$GC_USER_ID" ]]; then
		if (( $GC_CALLER_ID == 0 )); then
			# use sudo -u $GC_USER on all commands in the user's domain if root
			gc_hash sudo
			func_exit=$?; if (( $func_exit > 0 )); then
				echo "$GC_LOG 'sudo' command needed to execute as root -- command missing" >&2
				return $E_BAD_CMD
			fi
			readonly GC_ROOT=1
			readonly GC_EXEC="sudo -u $GC_USER"
			# 1.1 NEW test for working of sudo
			local -r SUDO_BUG="http://support.apple.com/kb/TA25121"
			if [[ "$($GC_EXEC echo "$SUDO_BUG" 2>/dev/null)" != "$SUDO_BUG" ]]; then
				echo "$GC_LOG 'sudo' command needed to excute as root -- command does not execute, possibly because of bug $SUDO_BUG"
				return $E_RUNTIME_ERROR
			fi
			# 1.1 NEW end
			if (( $GC_VERBOSE == 1 )); then echo "Executing as root"; fi
		else
			echo "$GC_LOG Calling user must be logged on console, or be root -- $(id -un $GC_CALLER_ID)" >&2
			return $E_BAD_USER
		fi
	else
		readonly GC_ROOT=0
		readonly GC_EXEC=''
	fi

	GC_USER_VALIDATED=1
	return $E_OK
}

# check if user account is FileVault protected
function gc_validate_fv {	
	if (( GC_FV_VALIDATED == 1 )); then return $E_OK; fi

	local cmd_exit cmd_out err_msg func_exit
	gc_hash dscl
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	func_exit_name=$FUNCNAME

	# check if user account runs FileVault if required
	if (( $GC_FV_ONLY == 1 )); then
		cmd_out=$(dscl . -read "/Users/$GC_USER" HomeDirectory 2>&1)
		cmd_exit=$?; if (( $cmd_exit > 0 )); then
			echo "$GC_LOG Error retrieving HomeDirectory node for $GC_USER -- 'dscl' command returned $cmd_exit $cmd_out" >&2
			return $E_RUNTIME_ERROR
		fi
		local -r HOMEDIR_NODE="$cmd_out"
 		if [[ "$HOMEDIR_NODE" != *.sparsebundle* && "$HOMEDIR_NODE" != *.sparseimage* ]]; then
			echo "$GC_LOG Not a FileVault protected account -- $C_USER" >&2
			return $E_NOT_FV
		fi
		if (( GC_VERBOSE == 1 )); then echo "FileVault protected account, proceeding"; fi
	fi
	
	GC_FV_VALIDATED=1
	return $E_OK
}

# initialise variables for setup functions
function gc_setup_init {
	if (( $GC_SETUP_INITED == 1 )); then return $E_OK; fi
	
	local cmd_exit cmd_out err_msg func_exit
	gc_hash osascript
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	gc_validate_user
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	gc_validate_fv
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	func_exit_name=$FUNCNAME
	
	# get user Library directory, make sure it is writable
	local -r OSASCRIPT="POSIX path of (path to library folder from user domain)"
	cmd_out=$($GC_EXEC osascript -e "$OSASCRIPT" 2>&1)
	cmd_exit=$?; if [[ -z "$cmd_out" || (( $cmd_exit > 0 )) ]]; then
		err_msg="No Library directory found in domain of user $GC_USER"
		if (( $cmd_exit > 0 )); then
			err_msg="$err_msg -- 'osascript' command returned $cmd_exit $cmd_out"
		fi
		echo "$GC_LOG $err_msg" >&2
		return $E_FILE_NOT_FOUND
	fi
	readonly LIBRARY_DIR=$cmd_out
	if [[ ! -w "$LIBRARY_DIR" ]]; then
		echo "$GC_LOG Library directory is not user writable -- $LIBRARY_DIR" >&2
		return $E_FILESYSTEM_ACCESS	
	fi
	
	# get user LaunchAgents directory (OK if not present yet); make sure it is writable if it exists
	readonly AGENTS_DIR="${LIBRARY_DIR}LaunchAgents/"
	if [[ -d "$AGENTS_DIR" && ! -w "$AGENTS_DIR" ]]; then
		echo "$GC_LOG LaunchAgents directory is not user writable -- $AGENTS_DIR" >&2
		return $E_FILESYSTEM_ACCESS
	fi
	
	# Name of the LaunchAgent (we check the file proper when we need it)
	readonly GC_AGENT_NAME="${GC_DOMAIN}.${GC_BASENAME}.${OSX_PLIST_SUFFIX}"

	GC_SETUP_INITED=1
	return $E_OK
}

# install Launch Agent
function gc_setup_enable {
	local cmd_exit cmd_out err_msg func_exit
	gc_hash cp defaults
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	gc_setup_init
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	func_exit_name=$FUNCNAME

	# create LaunchAgents directory if it doesn't exist yet
	if [[ ! -d  "$AGENTS_DIR" ]]; then
		gc_hash mkdir
		func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
		if (( $GC_VERBOSE == 1)); then echo "Creating LaunchAgents directory:"; fi
		cmd_out=$(mkdir -pv "$AGENTS_DIR" 2>&1)
		cmd_exit=$?; if (( $cmd_exit > 0 )); then
			echo "$GC_LOG Unable to create LaunchAgents directory $AGENTS_DIR -- 'mkdir' command returned $cmd_exit $cmd_out" >&2
			return $E_RUNTIME_ERROR	
		fi
		if (( $GC_VERBOSE == 1 )); then printf "%s\n" "$cmd_out"; fi
	fi
	
	# get Launch Agent file in script directory
	local -r GC_AGENT_SOURCE=${GC_DIR}${GC_AGENT_NAME}
	if [[ ! -f "$GC_AGENT_SOURCE" ]]; then
		echo "$GC_LOG $GC_BASENAME Launch Agent not found -- $GC_AGENT_SOURCE" >&2 
		return $E_FILE_NOT_FOUND	
	fi
	
	# copy Launch Agent into LaunchAgents directory
	if (( $GC_VERBOSE == 1 )); then echo "Copying $GC_BASENAME Launch Agent to LaunchAgents directory:"; fi
	local -r GC_AGENT_TARGET="${AGENTS_DIR}${GC_AGENT_NAME}"
	cmd_out=$(cp -fv "$GC_AGENT_SOURCE" "$GC_AGENT_TARGET" 2>&1)
	cmd_exit=$?; if [[ ! -f "$GC_AGENT_TARGET" || (( $cmd_exit > 0 )) ]]; then
		err_msg="Unable to copy $GC_AGENT_SOURCE to LaunchAgents directory $AGENTS_DIR"
		if (( $cmd_exit > 0 )); then
			err_msg="$err_msg -- 'cp' command returned $cmd_exit $cmd_out"
			cmd_exit=$E_RUNTIME_ERROR
		else
			cmd_exit=$E_FILE_NOT_FOUND
		fi
		echo "$GC_LOG $err_msg" >&2
		return $cmd_exit
	fi
	if (( $GC_VERBOSE == 1 )); then printf "%s\n" "$cmd_out"; fi

	# set path to script in Launch Agent
	if (( $GC_VERBOSE == 1 )); then echo "Setting path to $GC_SCRIPT in Launch Agent:"; fi
	local -r KEY="ProgramArguments"
	cmd_out=$($GC_EXEC defaults write "${GC_AGENT_TARGET%.*}" "$KEY" -array 'sh' "$GC_SCRIPT_PATH" '-x' 'restore' 2>&1)
	cmd_exit=$?; if (( $cmd_exit > 0 )) ; then
		echo "$GC_LOG Unable to set Launch Argument key to $GC_SCRIPT_PATH -- 'defaults' command returned $cmd_exit $cmd_out" >&2
		return $E_RUNTIME_ERROR
	fi
	if (( $GC_VERBOSE == 1 )); then echo $GC_SCRIPT_PATH; fi
	
	return $E_OK
}

# deinstall Launch Agent
function gc_setup_disable {
	local cmd_exit cmd_out err_msg func_exit
	gc_hash rm
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	gc_setup_init
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	func_exit_name=$FUNCNAME

	#  get active Launch Agent
	local -r GC_AGENT_ACTIVE=${AGENTS_DIR}${GC_AGENT_NAME}

	# return if no file exists
	if (( $GC_VERBOSE == 1 )); then echo "Removing active $GC_BASENAME Launch Agent:"; fi
	if [[ ! -f "$GC_AGENT_ACTIVE" ]]; then
		if (( $GC_VERBOSE == 1 )); then
			echo "No active $GC_BASENAME Launch Agent to disable -- $GC_AGENT_ACTIVE"
		fi
		return $E_OK
	fi
	
	# remove active Launch Agent
	cmd_out=$(rm -fv "$GC_AGENT_ACTIVE" 2>&1)
	cmd_exit=$?; if (( $cmd_exit > 0 )) ; then
		echo "$GC_LOG $GC_BASENAME Launch Agent could not be deleted -- 'rm' command returned $cmd_exit $cmd_out" >&2
		return $E_RUNTIME_ERROR
	fi
	if (( $GC_VERBOSE == 1 )); then printf "%s\n" "$cmd_out"; fi

	return $E_OK
}

# uninstall (including script dir if in user domain, or in local domain if runnign as root)
function gc_setup_uninstall {
	local cmd_exit cmd_out err_msg
	
	# clear and disable
	if (( GC_VERBOSE == 1 )); then echo "Uninstalling $GC_BASENAME":; fi
	gc_hash osascript rm	
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	gc_do_clear
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	gc_setup_disable
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	
	# get user home directory
	local -r OSASCRIPT="POSIX path of (path to home folder from user domain)"
	cmd_out=$($GC_EXEC osascript -e "$OSASCRIPT" 2>&1)
	cmd_exit=$?; if [[ -z "$cmd_out" || (( $cmd_exit > 0 )) ]]; then
		err_msg="No Home directory found for user $GC_USER"
		if (( $cmd_exit > 0 )); then
			err_msg="$err_msg -- 'osascript' command returned $cmd_exit $cmd_out"
		fi
		echo "$GC_LOG $err_msg" >&2
		return $E_FILE_NOT_FOUND
	fi
	local -r USER_HOMEDIR=$cmd_out
	
	# check if either running as root or if install dir of script is inside user domain
	# 1.1 ADD || (( $GC_ROOT == 1 ))
	if [[ "$GC_DIR" == "$USER_HOMEDIR"* ]] || (( $GC_ROOT == 1 )); then
		if (( GC_VERBOSE == 1 )); then echo "Removing $GC_BASENAME install directory:"; fi	
		cmd_out=$(rm -fRv "$GC_DIR" 2>&1)
		cmd_exit=$?; if [[ -d "$GC_DIR" || (( $cmd_exit > 0 )) ]]; then
			err_msg="Unable to remove $GC_BASENAME directory $GC_DIR"
			if (( $cmd_exit > 0 )); then
				err_msg="$err_msg -- 'rm' command returned $cmd_exit $cmd_out"
			fi
			echo "$GC_LOG $err_msg" >&2
			return $E_RUNTIME_ERROR
		fi
	elif (( GC_VERBOSE == 1 )); then
		# 1.1 MOD "... needs to run as root to uninstall outside domain of user ..."
		echo "Leaving $GC_BASENAME directory alone: needs to run as root to uninstall outside domain of user $GC_USER -- $GC_DIR"
	fi
	# 1.1 ADD output result depending on user status
	if (( GC_VERBOSE == 1 )); then
		echo $cmd_out
		local out_msg="Uninstall complete"
		if (( $GC_ROOT == 0 )); then out_msg="$out_msg for user $GC_USER"; fi
		echo $out_msg
	fi
	return $E_OK
}

# initialise variables for restore and save functions
function gc_do_init {
	if (( $GC_DO_INITED == 1 )); then return $E_OK; fi

	local cmd_exit cmd_out err_msg func_exit
	gc_hash plutil osascript
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	gc_validate_user
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	gc_validate_fv
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	func_exit_name=$FUNCNAME

	# get prefs dir, make sure it is readable
	local -r OSASCRIPT="POSIX path of (path to preferences from user domain)"
	cmd_out=$($GC_EXEC osascript -e "$OSASCRIPT" 2>&1)
	cmd_exit=$?; if [[ -z "$cmd_out" || (( $cmd_exit > 0 )) ]]; then
		err_msg="No preferences directory found in domain of user $GC_USER"
		if (( $cmd_exit > 0 )); then
			err_msg="$err_msg -- 'osascript' command returend $cmd_exit $cmd_out"
		fi
		echo "$GC_LOG $err_msg" >&2
		return $E_RUNTIME_ERROR
	fi
	readonly PREFS_DIR=$cmd_out
	if [[ ! -d "$PREFS_DIR" ]]; then
		echo "$GC_LOG Invalid user Preferences directory -- $PREFS_DIR" >&2
		return $E_FILE_NOT_FOUND
	elif [[ ! -r "$PREFS_DIR" ]]; then
		echo "$GC_LOG User Preferences directory not user readable -- $PREFS_DIR" >&2
		return $E_FILESYSTEM_ACCESS
	fi

	# get launch Services plist, make sure it is readable and valid
	readonly LS_PLIST="${PREFS_DIR}${OSX_LS_CONFIG}.${OSX_PLIST_SUFFIX}"
	if [[ "$GC_ACTION" == "restore" || "$GC_ACTION" == "save" ]]; then
		if [[ ! -f "$LS_PLIST" ]]; then
			echo "$GC_LOG Launch Services plist not found or not a file -- $LS_PLIST" >&2
			return $E_FILE_NOT_FOUND
		elif [[ ! -r  "$LS_PLIST" ]]; then
			echo "$GC_LOG Launch Services plist not user readable -- $LS_PLIST" >&2
			return $E_FILESYSTEM_ACCESS
		fi
		if (( GC_VERBOSE == 1 )); then echo "Validating Launch Services plist:"; fi
		cmd_out=$(plutil "$LS_PLIST" 2>&1)
		cmd_exit=$?; if (( $cmd_exit > 0 )); then
			echo "$GC_LOG Unable to validate Launch Services plist -- 'plutil' command returned $cmd_exit $cmd_out" >&2
			return $E_RUNTIME_ERROR
		fi
		if (( $GC_VERBOSE == 1 )); then printf "%s\n" "$cmd_out"; fi
	fi
	
	# set saved Launch Services state file name (OK if not present yet)
	readonly LS_SAVED="${GC_LSSAVED_NAME}.${OSX_PLIST_SUFFIX}"

	GC_DO_INITED=1
	return $E_OK
}

# restore bindings from Launch Services plist (or plist.save if present)
function gc_do_restore {
	local cmd_exit cmd_out err_msg func_exit
	gc_hash plutil rm sleep xsltproc
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	gc_do_init
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	func_exit_name=$FUNCNAME

	# get duti configuration file directory
	local -r DUTI_CFG_DIR="$TMPDIR"
	if [[ ! -d "$DUTI_CFG_DIR" ]]; then
		echo "$GC_LOG duti configuration file directory not found -- $DUTI_CFG_DIR" >&2 
		return $E_FILE_NOT_FOUND
	elif [[ ! -w "$DUTI_CFG_DIR" ]]; then
		echo "$GC_LOG duti configuration file directory is not user writable -- $DUTI_CFG_DIR" >&2 
		return $E_FILESYSTEM_ACCESS
	fi
	
	# set duti configuration file name
	local -r DUTI_CFG="${DUTI_CFG_DIR}${GC_DUTICFG_NAME}.${OSX_PLIST_SUFFIX}"

	# get XSL stylesheet
	case "$OSTYPE" in
		darwin9.*) local -r XSL="${GC_DIR}${GC_XSL_LEOPARD}" ;;
	esac
	if [[ ! -f "$XSL" ]]; then
		echo "$GC_LOG XSL stylesheet not found -- $XSL" >&2
		return $E_FILE_NOT_FOUND
	elif [[ ! -r "$XSL" ]]; then
		echo "$GC_LOG XSL stylesheet not user readable -- $XSL" >&2
		return $E_FILESYSTEM_ACCESS
	fi
	
	# use saved state if available and valid and not indicated otherwise by -s mode
	local LS_FILE="$LS_PLIST"
	if [[ -r "$LS_SAVED" && $GC_USE_SAVED != "ignore" ]]; then
		if (( $GC_VERBOSE == 1 )); then echo "Validating saved Launch Services state plist:"; fi
		cmd_out=$(plutil "$LS_SAVED" 2>&1)
		cmd_exit=$?; if (( $cmd_exit > 0 )); then
			echo "$GC_LOG Unable to validate saved Launch Services state plist -- 'plutil' command returned $cmd_exit $cmd_out" >&2
			return $E_RUNTIME_ERROR 
		fi
		if (( $GC_VERBOSE == 1 )); then printf "%s\n" "$cmd_out"; fi
		LS_FILE="$LS_SAVED"
	# if file is not present or readable, cancel if required by -f mode, else use LS plist
	elif [[ ! -f "$LS_SAVED"  || ! -w  "$LS_SAVED" ]]; then
		err_msg="Saved Launch Services state plist"
		if [[ ! -f "$LS_SAVED" ]]; then
			err_msg="$err_msg not found"
		else
			err_msg="$err_msg not user readable"
		fi
		if [[ "$GC_USE_SAVED" == "force" ]]; then
			echo "$GC_LOG ${err_msg}, saved state required by -f option -- $LS_SAVED" >&2
			return $E_FILE_NOT_FOUND
		fi
		echo "$GC_LOG ${err_msg}, falling back on Launch Services plist -- $LS_SAVED" >&2
	fi

	# get duti (looking for version in script dir first, then in PATH)
	local -r DUTI_LOCAL="${GC_DIR}duti"
	if [[ -x "$DUTI_LOCAL" ]]; then
		hash -p "$DUTI_LOCAL" duti >/dev/null 2>&1
	else
		gc_hash duti
		func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	fi
	if (( $GC_VERBOSE == 1 )); then echo "Using $(hash -t duti)"; fi
	local -r DUTI_VERSION=$(duti -V)
	if [[ $DUTI_VERSION < $MIN_DUTI_VERSION ]]; then
		echo "$GC_LOG $(hash -t duti) version $DUTI_VERSION too low; needs at least $MIN_DUTI_VERSION" >&2
		return $E_BAD_CMD
	fi

	# remove old duti configuration; if failed, try to create uniquely named configuration file
	if (( $GC_VERBOSE == 1 )); then echo "Removing old duti plist:"; fi
	if [[ -f "$DUTI_CFG" ]]; then
		cmd_out=$(rm -fv "$DUTI_CFG" 2>&1)
		cmd_exit=$?; while [[ -f "$DUTI_CFG" ]]; do
			if (( $cmd_exit> 0 )); then
				echo "$GC_LOG Error removing duti plist $DUTI_CFG -- 'rm' command returned $cmd_exit $cmd_out" >&2
			fi
			if (( $GC_VERBOSE == 1)); then echo $cmd_out; fi
			DUTI_CFG="${DUTI_CFG_DIR}${GC_DUTICFG_NAME}.${RANDOM}.${OSX_PLIST_SUFFIX}"
			echo "$GC_LOG duti plist set to new name -- $DUTI_CFG" >&2
		done
		if (( $GC_VERBOSE == 1 )); then printf "%s\n" "$cmd_out"; fi
	else
		if (( $GC_VERBOSE == 1 )); then echo "No old duti plist to remove -- $DUTI_CFG"; fi
	fi
	
	# transform Launch Services plist into duti configuration plist
	if (( $GC_VERBOSE == 1 )); then echo "Converting Launch Services plist into duti plist:"; fi
	cmd_out=$(plutil -convert xml1 -o - "$LS_FILE" 2>/dev/null | xsltproc --nonet -o "$DUTI_CFG" "$XSL" - 2>&1)
	cmd_exit=$?; if (( $cmd_exit > 0 )); then
		echo "$GC_LOG Error while converting Launch Services plist into duti plist -- 'xsltproc' command returned $cmd_exit $cmd_out" >&2
		return $E_RUNTIME_ERROR
	fi
	if (( $GC_VERBOSE == 1 )); then printf "%s\n" "$cmd_out"; fi

	# check for, and validate, created duti configuration plist
	if [[ -f "$DUTI_CFG" ]]; then
		if (( $GC_VERBOSE == 1 )); then echo "Validating saved Launch Services state plist:"; fi
		cmd_out=$(plutil "$DUTI_CFG" 2>&1)
		cmd_exit=$?; if (( $cmd_exit > 0 )); then
			echo "$GC_LOG Error validating duti plist -- 'plutil' command returned $cmd_exit $cmd_out" >&2
			return $E_RUNTIME_ERROR 
		fi
		if (( $GC_VERBOSE == 1 )); then printf "%s\n" "$cmd_out"; fi
	else
		echo "$GC_LOG duti plist file not found -- $DUTI_CFG" >&2
		return $E_FILE_NOT_FOUND
	fi

	# wait for lsregister instances to terminate for max GC_TIMEOUT seconds
	if (( $GC_VERBOSE == 1 )); then echo "Waiting for lsregister to terminate"; fi
	local -r WAIT_FOR=5
	local slept_for=0
	local lsregister_running=$(gc_look_for 'lsregister')
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	while (( $lsregister_running > 0 )); do
		# sleep
		cmd_out=$(sleep $WAIT_FOR 2>&1)
		cmd_exit=$?; if (( $cmd_exit > 0 )); then
			echo "$GC_LOG Error waiting for lsregister process -- 'sleep' command returned $cmd_exit $cmd_out" >&2
			return $E_RUNTIME_ERROR;
		fi
		# check for timeout
		(( slept_for+=$WAIT_FOR ))
		if (( $slept_for > $GC_TIMEOUT )); then
			echo "$GC_LOG Wait for lsregister timed out after $GC_TIMEOUT seconds." >&2
			return $E_TIMED_OUT
		fi
		local lsregister_running=$(gc_look_for 'lsregister')
		func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	done
	if (( $GC_VERBOSE == 1 )); then echo "Proceeding after $slept_for seconds wait"; fi

	# register Launch Services UTI and URI binding through duti
	if (( $GC_VERBOSE == 1 )); then echo "Registering UTI and URI user bindings:"; fi
	cmd_out=$($GC_EXEC duti -v "$DUTI_CFG" 2>&1)
	cmd_exit=$?; if (( $cmd_exit > 0 )); then
		echo "$GC_LOG Error while registering UTI and URI user bindings -- 'duti' command returned $cmd_exit $cmd_out" >&2
		return $E_RUNTIME_ERROR
	fi
	if (( $GC_VERBOSE == 1 )); then printf "%s\n" "$cmd_out"; fi

	return $E_OK
}

# save Launch Services plist to saved state plist
function gc_do_save {
	local cmd_exit cmd_out err_msg func_exit
	gc_hash cp
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	gc_do_init
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	func_exit_name=$FUNCNAME

	# make sure preferences directory is user writable
	if [[ ! -w "$PREFS_DIR" ]]; then
		echo "$GC_LOG User Preferences directory not user writable -- $PREFS_DIR" >&2
		return $E_FILESYSTEM_ACCESS
	fi

	# copy Launch Services plist to saved state plist
	if (( $GC_VERBOSE == 1 )); then echo "Copying Launch Services plist to saved state plist:"; fi
	cmd_out=$($GC_EXEC cp -fv "$LS_PLIST" "$LS_SAVED" 2>&1)
	cmd_exit=$?; if (( $cmd_exit > 0 )); then
		echo "$GC_LOG Unable to save copy of Launch Services plist $LS_PLIST to $LS_SAVED -- 'cp' command returned $cmd_exit $cmd_out" >&2
		return $E_RUNTIME_ERROR
	fi
	if (( $GC_VERBOSE == 1 )); then printf "%s\n" "$cmd_out"; fi
	
	return $E_OK
}

# delete existing saved Launch Services state plist
function gc_do_clear {
	local cmd_exit cmd_out err_msg func_exit
	gc_hash rm
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	gc_do_init
	func_exit=$?; if (( $func_exit > 0 )); then return $func_exit; fi
	func_exit_name=$FUNCNAME

	if (( $GC_VERBOSE == 1 )); then echo "Deleting saved Launch Services state plist:"; fi
	if [[ -f "$LS_SAVED" ]]; then
		cmd_out=$(rm -fv "$LS_SAVED" 2>&1)
		cmd_exit=$?; if (( $cmd_exit > 0 )); then
			echo "$GC_LOG Unable to delete saved Launch Services state plist $LS_SAVED -- 'rm' command returned $cmd_exit $cmd_out" >&2
			return $E_RUNTIME_ERROR
		fi
		if (( $GC_VERBOSE == 1 )); then printf "%s\n" "$cmd_out"; fi
	elif (( $GC_VERBOSE == 1 )); then
		echo "No saved Launch Services state plist to remove -- $LS_SAVED"
	fi
	
	return $E_OK
}

# print usage statement
function gc_usage {
	local -r GC_ARGS_ACTION='[ -Fv ] -x action [ -s mode ] [ -t timeout ]'
	local -r GC_ARGS_INFO='-V | -h | -D [ bundle ]'
	echo "usage: sh $GC_SCRIPT $GC_ARGS_ACTION"
	echo "       sh $GC_SCRIPT $GC_ARGS_INFO"
	echo "       see documentation ('sh $GC_SCRIPT -D') for further reference"
}

# show docs
function gc_showdoc {
	local cmd_exit cmd_out err_msg func_exit
	gc_hash open
	func_exit=$?; if (( $func_exit > 0 )); then exit $func_exit; fi
	func_exit_name=$FUNCNAME

	# get documentation file
	local -r GC_DOC="${GC_DIR}${GC_BASENAME}.html"
	if [[ ! -f "$GC_DOC" ]]; then
		echo "$GC_BASENAME documentation not found or not a file -- $GC_DOC"
		return $E_FILE_NOT_FOUND
	elif [[ ! -r "$GC_DOC" ]]; then
		echo "$GC_BASENAME documentation not user readable to user $GC_USER -- $GC_DOC"
		return $E_FILESYTEM_ACCESS
	fi
	# open documentation file
	cmd_out=$(open -b "$GC_DOC_VIEWER" "$GC_DOC" 2>&1)
	cmd_exit=$?; if (( $cmd_exit > 0 )); then
		echo "Error opening $GC_BASENAME documentation -- 'open' command returned $cmd_exit $cmd_out"
		return $E_RUNTIME_ERROR
	fi
	
	return $E_OK
}

# exit statement and code
function gc_exit {
	local cmd_exit cmd_out err_msg func_exit
	local -r GC_EXIT_CODE=${1:-0}
	if (( $GC_EXIT_CODE > 0 )); then
		err_msg="script aborted"
		if [[ -n "$func_exit_name" ]]; then
			err_msg="${err_msg}: $func_exit_name returned $GC_EXIT_CODE"
		else
			err_msg="${err_msg} with code $GC_EXIT_CODE"
		fi
		echo "$GC_LOG $err_msg" >&2
	elif (( $GC_VERBOSE == 1 )); then
		echo "$GC_BASENAME terminated successfully on $(date)"
	fi
	exit $GC_EXIT_CODE
}

# MAIN SCRIPT BODY (cont.)
# get script file data
declare -i GC_SCRIPT_INITED=0 GC_SETUP_INITED=0 GC_DO_INITED=0
declare -i GC_FV_VALIDATED=0 GC_USER_VALIDATED=0
gc_script_init
func_exit=$?; if (( $func_exit > 0 )); then gc_exit $func_exit; fi
func_exit_name=''

# get options and arguments
declare -i GC_FV_ONLY=0 GC_TIMEOUT=300 GC_VERBOSE=0
declare GC_ACTION='' GC_DOC_VIEWER="com.apple.Safari" GC_USE_SAVED=''

while getopts ':Fvx:s:t:VhD:' gc_option; do
	case $gc_option in
		F)	GC_FV_ONLY=1
			;;
		v)	GC_VERBOSE=1
			;;
		x)	GC_ACTION="$OPTARG"
			;;
		s)	if [[ "$OPTARG" == "ignore" || "$OPTARG" == "force" ]]; then
				GC_USE_SAVED=$OPTARGS
			elif [[ -n "$OPTARG" ]]; then
				echo "$GC_LOG Illegal argument for -f option -- $OPTARG" >&2
				exit $E_BAD_ARGUMENT
			else
				echo "$GC_LOG Missing argument to option -- $OPTARG" >&2
				gc_usage
				func_exit=$?; if (( $func_exit > 0 )); then gc_exit $func_exit; fi
				exit $E_BAD_ARGUMENT
			fi
			;;
		t)	gc_hash grep
			func_exit=$?; if (( $func_exit > 0 )); then gc_exit $func_exit; fi
			cmd_out=$(echo $OPTARG 2>/dev/null | grep '^[0-9]+$' -E - 2>&1)
			cmd_exit=$?; if [[ -z "$cmd_out" || (( $cmd_exit > 1 )) ]]; then
				err_msg="Could not process timeout value argument $OPTARG"
				if (( $cmd_exit > 0 )); then
					err_msg="$err_msg -- 'grep' command returned $cmd_exit $cmd_out"
				fi
				echo "${err_msg}"\n"Falling back on default value -- $GC_TIMEOUT" >&2
			elif [[ -n $GC_TIMEOUT_ARG ]]; then 
				GC_TIMEOUT=$GC_TIMEOUT_ARG
			fi
			;;
		V)	echo $SCRIPT_VERSION
			gc_exit $E_OK
			;;
		h)	gc_usage
			func_exit=$?; if (( $func_exit > 0 )); then gc_exit $func_exit; fi
			gc_exit $E_OK
			;;
		D)	GC_DOC_VIEWER="$OPTARG"
			gc_showdoc
			gc_exit $?
			;;
		:)	case $OPTARG in
				# catch optional arguments
				D)	gc_showdoc
					gc_exit $?
					;;
				*)	echo "$GC_LOG Missing argument to option -- $OPTARG" >&2
					gc_usage
					func_exit=$?; if (( $func_exit > 0 )); then gc_exit $func_exit; fi
					exit $E_BAD_ARGUMENT
					;;
			esac
			;;
		\?)	echo "$GC_LOG Illegal option -- $OPTARG" >&2
			gc_usage
			func_exit=$?; if (( $func_exit > 0 )); then gc_exit $func_exit; fi
			exit $E_BAD_OPTION
			;;
		*)	echo "$GC_LOG Runtime error while processing options." >&2
			exit $E_RUNTIME_ERROR
			;;
	esac
done

# action switch
case "$GC_ACTION" in
	clear)
		gc_do_clear
		gc_exit $?
		;;
	enable)
		gc_setup_enable
		gc_exit $?
		;;
	disable)
		gc_setup_disable
		gc_exit $?
		;;
	restore)
		gc_do_restore
		gc_exit $?
		;;
	save)
		gc_do_save
		gc_exit $?
		;;
	uninstall)
		gc_setup_uninstall
		gc_exit $?
		;;
	*)  # also covers all missing options scenario
		if [[ -z "$GC_ACTION" ]]; then
			gc_usage
			gc_exit $E_OK
		else
			echo "$GC_LOG Bad action argument -- $GC_ACTION" >&2
			gc_usage
			gc_exit $BAD_ARGUMENT
		fi
		;;
esac