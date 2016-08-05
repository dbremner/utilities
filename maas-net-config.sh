#!/bin/bash

cat >/dev/tty <<-EOT

	# This scipt will check network config of a MAAS Controller node.
	# It should be ran on a MAAS Controller Node.
	# Follow the advises, if any.
	# Run again until no advises shown.

EOT

eth0='' # 'eno1'	# external
eth1='' # 'enp12s0f2'	# internal

ntp_host='ntp.ubuntu.com'

interfaces='/etc/network/interfaces'
sysctl='/etc/sysctl.conf'

all_ok='yes'

error () {
	local -i rc=$1
	shift
	all_ok='no'
	echo "ERROR: $@" >&2
	exit $rc
}

warn () {
	all_ok='no'
	echo "WARNING: $@" >&1
}

intf_list () {
	ifconfig -s | awk 'NR>1{print $1;}'
}

intf_addrs () {
	local intf="$1"
	ip addr show dev "$intf" \
	| grep -o 'inet [0-9.]\+' \
	| cut -d' ' -f2
}

intf_list_long () {
	local i='' a=''

	while read i; do
		a=$(intf_addrs "$i")
		echo -e "$i ($a)"
	done < <(intf_list)
}

select_except () {
	# read words (lines) from stdin
	# make selection of words
	# except given on command line
	local -a words=()
	local w='' t='' x='' ok=''
	while read w t; do
		ok='yes'
		for x in "$@"; do
			if [ "$w" = "$x" ]; then
				ok='no'
				break
			fi
		done
		if [ "$ok" = 'yes' ]; then
			words[${#words[*]}]="$w $t"
		fi
	done
	select w in "${words[@]}"; do
		if [ -z "$w" ]; then
			read -p 'Terminate? ' w </dev/tty
			case "$w" in
			yes)	error 0 "Terminated.";;
			*)	echo "ok">&2; continue;;
			esac
		fi
		echo "$w" | cut -d' ' -f1
		return
	done </dev/tty
}

intf_ok () {
	local intf="$1"

	[ -z "$intf" ] && return 1
	intf_list | grep -wq "^$intf\$"
}

quote_all_words () {
	sed -e "1,\$s/[^ ]\+/'&'/g"
}

output_has_word () {
	local word="$1"
	local mesg="$2"
	shift 2

	if $@ | grep -q '[[:space:]]\+'$word'[[:space:]]\+'; then
		echo "# It looks like $mesg for '$word' is ok."
	else
		warn "No '$word' in $mesg."
		return 1
	fi
}

[ -f "$interfaces" ] || error 1 "No '$interfaces' - wrong distriution."

#

if [ -w /etc/passwd ]; then
	SUDO=''
else
	SUDO='sudo'
	echo "# Using '$SUDO'..." >&2
	$SUDO -v
	echo
fi

if ! intf_ok "$eth0"; then
	echo "# Please, select _external_ interface:" >&2
	eth0=$(intf_list_long | select_except $eth0 $eth1)
	intf_ok "$eth0" || error 1 "No external interface '$eth0'."
fi

if ! intf_ok "$eth1"; then
	echo "# Please, select _internal_ interface:" >&2
	eth1=$(intf_list_long | select_except $eth0 $eth1)
	intf_ok "$eth1" || error 1 "No external interface '$eth1'."
fi

echo "# External link via '$eth0':"
/sbin/ifconfig "$eth0" || error $? "No link '$eth0'."

echo "# Internal link via '$eth1':"
/sbin/ifconfig "$eth1" || error $? "No link '$eth1'."

echo "# System-wide interface config ($interfaces):"
eth0_found='no'
eth1_found='no'

check_ifconfig () {
	local interfaces="$1"
	local k='' a='' t=''

	while read k a t; do
		if [ "$k" = 'source' ]; then
			for t in $a; do
				[ -r "$t" ] && check_ifconfig "$t"
			done
		elif [ "$k" = 'auto' ]; then
			case "$a" in
			"$eth0")	eth0_found='yes'
					echo "0=$a"
					echo -e "0|\t$k $a $t"
					[ "$eth1_found" = 'no' ] || eth1_found='x'
					continue;;
			"$eth1")	eth1_found='yes'
					echo "1=$a"
					echo -e "1|\t$k $a $t"
					[ "$eth0_found" = 'no' ] || eth0_found='x'
					continue;;
			*)		[ "$eth0_found" = 'no' ] || eth0_found='z'
					[ "$eth1_found" = 'no' ] || eth1_found='z'
					continue;;
			esac
		fi
		if [ "$eth0_found" = 'yes' ]; then
			echo -e "0|\t$k $a $t"
		elif [ "$eth1_found" = 'yes' ]; then
			echo -e "1|\t$k $a $t"
		else
			: echo "x>$k|$a|$t<"
		fi
	done < <(grep -v '#' "$interfaces" | grep -v '^[ ]*$')
}

check_ifconfig "$interfaces"

[ "$eth0_found" = 'no' ] && error 1 "No config for external '$eth0'."
[ "$eth1_found" = 'no' ] && error 1 "No config for internal '$eth1'."
echo "# Interfaces '$eth0' (external) and '$eth1' (internal) somehow configured."
echo

echo "# Local routing:"
route -n
route -n | grep -q "[[:space:]]\+$eth0\$" || error 1 "Interface '$eth0' is never used."
route -n | grep -q "[[:space:]]\+$eth1\$" || error 1 "Interface '$eth1' is never used."
echo "# Both interfaces are in use. Good."
echo

echo "# Local NAT config:"
W=''
$SUDO /sbin/iptables -S -t nat
output_has_word "$eth0" 'NAT config' "$SUDO /sbin/iptables -S -t nat" || W='yes'
if [ "$W" = 'yes' ]; then
	cat >&2 <<-EOT
		# Consider adding these rules:
		# -t nat -A POSTROUTING -o $eth0 -j MASQUERADE
EOT
fi
$SUDO /sbin/iptables -t nat -S POSTROUTING | grep -qw MASQUERADE \
	|| error 1 "No MASQUERADE rule in POSTROUTING chain (table 'nat')."
echo

echo "# Kernel support for NAT:"
n=$($SUDO find /sys/module/ -name '*_nat*' -exec ls -ld {} \; | grep -v /holders/ | wc -l)
(( $n == 0 )) && error 1 "No NAT kernel support found." || echo "# Kernel has modules, good."

lsmod | grep nat_ && echo "# NAT modules loaded." || warn "No NAT kernel modules loaded."
echo

echo "# Local forwarding policy:"
W=''
$SUDO /sbin/iptables -S FORWARD
output_has_word "$eth0" 'routing' "$SUDO /sbin/iptables -S FORWARD" || W='yes'
output_has_word "$eth1" 'routing' "$SUDO /sbin/iptables -S FORWARD" || W='yes'
if [ "$W" = 'yes' ]; then
	cat >&2 <<-EOT
		# Consider adding these rules:
		# -A FORWARD -i $eth0 -o $eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT
		# -A FORWARD -i $eth1 -o $eth0 -j ACCEPT
EOT
fi
echo

grep -Hn 'net.ipv4.ip_forward[[:space:]]*=[[:space:]]*1' "$sysctl" \
	|| error 1 "You must add 'net.ipv4.ip_forward=1' to '$sysctl'."
grep -q '#[[:space:]]*net.ipv4.ip_forward[[:space:]]*=[[:space:]]*1' "$sysctl" \
	&& error 1 "You must uncomment the line and reload with '$SUDO sysctl -p'."

echo
[ "$all_ok" = 'yes' ] && echo "# Congrats! It looks like everything is fine!"
# EOF #