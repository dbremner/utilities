#!/bin/bash

# script to recoursively list package dependencies to any given depth

declare -i max_depth=0
indent_step='   '
show_all='no'
expand_args='no'
show_status='no'
seen_list=$(mktemp -p /var/tmp -t depdeb.XXXXXXXXXX)

cleanup () {
	stats
	cp "$seen_list" /tmp/sl.txt
	rm -f "$seen_list"
}

trap cleanup EXIT

error () {
	local -i rc=$1
	shift
	echo "/$@" | cut -d/ -f2- >&2
	exit $rc
}

check_bin () {
	local man="$1"
	local bin="$2"

	type -p "$bin" >/dev/null 2>&1 || error 1 "No $bin($man) here."
}

check_bin 1 dpkg
check_bin 8 apt-cache

stats () {
	local -i nseen=$(wc -l < $seen_list)

	echo "# Total packages seen: $nseen"
	if [ "$show_status" = 'yes' ]; then
		local -i ninst=$(grep ':ok' "$seen_list" | wc -l)
		local -i nnins=$(grep ':no' "$seen_list" | wc -l)
		local -i nunkn=$(grep ':u ' "$seen_list" | wc -l)

		echo "#           installed: $ninst"
		echo "#       not installed: $nnins"
		echo "#        other states: $nunkn"
	fi
}

seen () {
	grep -q "^$1:.\*\$" "$seen_list"
}

mark_seen () {
	echo "$@" >> "$seen_list"
}

wantees () {
	apt-cache depends "$@" \
	| grep '^[[:space:]]*Depends:' \
	| cut -d: -f2- \
	| sed -e '1,$s/([^)]\+),\?//g' \
	| tr -d ',|<>' \
	| tr -s '[:space:]' '\012' \
	| cut -d: -f1 \
	| sort -u | grep -v '^$'
}

pkg_status () {
	[ "$show_status" = 'no' ] && return

	local pkg="$1"
	local status=$(dpkg -s "$pkg" 2>/dev/null | grep '^Status:' | sed -e '1,$s/^Status:[ \t]\+//')
	local result="u ($status)"

	if [ -z "$status" ]; then
		echo "no"
		return
	fi

	case "$status" in
	'install ok installed')	result='ok';;
	esac
	echo "$result"
}

indent () {
	local -i level=$1
	local -i i=0

	for ((i=0; i<level; i++)); do
		echo -n "$indent_step"
	done
}

hidden () {
	case "$1" in
	lib*|debconf*)	return 0;;
	esac
	return 1
}

say () {
	local -i level=$1
	local c=$2
	local st=$3
	local pkg=$4

	if [ "$show_all" = 'yes' ] || ! hidden "$pkg"; then
		indent $level
		echo "$pkg$c $st"
	fi
}

list_dep () {
	local -i level=$1 ; shift
	local pkg='' st=''

	if [ -z "$1" ]; then
		return
	fi

	for pkg in "$@"; do
		st=$(pkg_status "$pkg")
		if seen "$pkg"; then
			say $level '<' "$st" "$pkg"
			continue
		fi
		mark_seen "$pkg:$st"
		if hidden "$pkg"; then
			say $level '.' "$st" "$pkg"
		elif (( level > max_depth )); then
			say $level '/' "$st" "$pkg"
		else
			say $level ':' "$st" "$pkg"
			list_dep $((level + 1)) $(wantees "$pkg")
		fi
	done
}

help () {
	cat <<-EOT
	$(basename $1) [option...] [--] [package...]

	Options:
	-h, --help -- this help
	-a, --show-all -- show "hidden" packages ($show_all)
	-d, --max-depth <N> -- set max depth to <N> ($max_depth)
	-x, --expand-args -- expand arguments into package names ($expand_args)
	-s, --show-status -- show installation status for packages ($show_status)

	Legend:
	suffix	means
	  .	"hidden"
	  <	already listed above
	  :	depends on the following
	  /	too deep to expand
EOT
}

while [ -n "$1" ]; do
	[[ "$1" == -* ]] || break
	case "$1" in
	-h|--help)	help "$0"; exit;;
	-d|--max-depth)	max_depth=$2; shift;;
	-a|--show-all)	show_all='yes';;
	-x|--expand)	expand_args='yes';;
	-s|--show-status)	show_status='yes';;
	--)	shift; break;;
	*)	error 1 "What's '$1'?";;
	esac
	shift
done

if [ "$expand_args" = 'yes' ]; then
	declare -a args=()
	while (( $# > 0 )); do
		arg="$1"
		shift
		for xarg in $(apt-cache pkgnames | grep "$arg"); do
			args[${#args[@]}]="$xarg"
		done
	done
	list_dep 0 ${args[*]}
else
	list_dep 0 "$@"
fi

# EOF #
