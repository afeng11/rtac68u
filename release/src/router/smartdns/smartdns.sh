#! /bin/sh

SMARTDNS_BIN=/usr/sbin/smartdns
SMARTDNS_CONF=/etc/smartdns/smartdns.conf
DNSMASQ_CONF="/etc/dnsmasq.conf"
SMARTDNS_PID=/var/run/smartdns.pid
SMARTDNS_PORT=5353
SMARTDNS_OPT=/etc/smartdns/smartdns-opt.conf
# workmode 
# 0: run as port only
# 1: redirect port
# 2: replace 
SMARTDNS_WORKMODE="1"

if [ -f "$SMARTDNS_OPT" ]; then
. $SMARTDNS_OPT
fi


set_iptable()
{
	local redirect_tcp

	redirect_tcp=0;

	grep ^bind-tcp $SMARTDNS_CONF > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		redirect_tcp=1;
	fi

	IPS="`ifconfig | grep "inet addr" | grep -v ":127" | grep "Bcast" | awk '{print $2}' | awk -F: '{print $2}'`"
	for IP in $IPS
	do
		if [ $redirect_tcp -eq 1 ]; then
			iptables -t nat -A PREROUTING -p tcp -d $IP --dport 53 -j REDIRECT --to-ports $SMARTDNS_PORT > /dev/null 2>&1
		fi
		iptables -t nat -A PREROUTING -p udp -d $IP --dport 53 -j REDIRECT --to-ports $SMARTDNS_PORT > /dev/null 2>&1
	done

}

clear_iptable()
{
	IPS="`ifconfig | grep "inet addr" | grep -v ":127" | grep "Bcast" | awk '{print $2}' | awk -F: '{print $2}'`"
	for IP in $IPS
	do
		iptables -t nat -D PREROUTING -p tcp -d $IP --dport 53 -j REDIRECT --to-ports $SMARTDNS_PORT > /dev/null 2>&1
		iptables -t nat -D PREROUTING -p udp -d $IP --dport 53 -j REDIRECT --to-ports $SMARTDNS_PORT > /dev/null 2>&1
	done
	
}

restart_dnsmasq()
{
	CMD="`ps | grep "  dnsmasq" | grep -v grep 2>/dev/null`"
	if [ -z "$CMD" ]; then
		CMD="`ps | grep "/usr/sbin/dnsmasq" | grep -v grep 2>/dev/null`"
		if [ -z "$CMD" ]; then
			CMD="`ps ax | grep "  dnsmasq" | grep -v grep 2>/dev/null`"
			if [ -z "$CMD" ]; then
				CMD="`ps ax | grep /usr/sbin/dnsmasq | grep -v grep 2>/dev/null`"
			fi	
		fi	
	fi

	if [ -z "$CMD" ]; then
		echo "cannot find dnsmasq"
		return 1
	fi

	PID=`echo "$CMD" | awk '{print $1}'`
	if [ ! -d "/proc/$PID" ]; then
		echo "dnsmasq is not running"
		return 1
	fi

	kill -9 $PID

	DNSMASQ_CMD="`echo $CMD | awk '{for(i=5; i<=NF;i++)printf \$i " "}'`"

	$DNSMASQ_CMD
}

get_server_ip()
{
	CONF_FILE=$1
	IPS="`ifconfig | grep "inet addr" | grep -v ":127" | grep "Bcast" | awk '{print $2}' | awk -F: '{print $2}'`"
	LOCAL_SERVER_IP=""
	for IP in $IPS
	do
		N=3
		while [ $N -gt 0 ]
		do
			ADDR=`echo $IP | awk -F. "{for(i=1;i<=$N;i++)printf \\$i\".\"}"`
			grep "dhcp-range=" $CONF_FILE | grep $ADDR >/dev/null 2>&1
			if [ $? -eq 0 ]; then
					SERVER_TAG="`grep "^dhcp-range *=" $CONF_FILE | grep $ADDR | awk -F= '{print $2}' | awk -F, '{print $1}'`"
					LOCAL_SERVER_IP="$IP"
					return 0
			fi
			N="`expr $N - 1`"
		done
	done

	return 1
}

set_dnsmasq_conf()
{
	local LOCAL_SERVER_IP=""
	local SERVER_TAG=""
	local CONF_FILE=$1

	get_server_ip $CONF_FILE
	if [ "$LOCAL_SERVER_IP" ] && [ "$SERVER_TAG" ]; then
		grep "dhcp-option *=" $CONF_FILE | grep "$SERVER_TAG,6,$LOCAL_SERVER_IP" > /dev/null 2>&1
		if [ $? -ne 0 ]; then
			sed -i "/^dhcp-option *=$SERVER_TAG,6,/d" $CONF_FILE
			echo "dhcp-option=$SERVER_TAG,6,$LOCAL_SERVER_IP" >> $CONF_FILE
			RESTART_DNSMASQ=1
		fi
	fi

	grep "^port *=0" $CONF_FILE > /dev/null 2>&1
	if [ $? -ne 0 ]; then
		sed -i "/^port *=/d" $CONF_FILE
		echo "port=0" >> $CONF_FILE
		RESTART_DNSMASQ=1
	fi
}

set_dnsmasq()
{
	local RESTART_DNSMASQ=0

	for conf in $DNSMASQ_CONF
	do
		if [ ! -e "$conf" ]; then
			continue
		fi

		set_dnsmasq_conf $conf
	done
	
	if [ $RESTART_DNSMASQ -ne 0 ]; then
		restart_dnsmasq	
	fi
}

clear_dnsmasq_conf()
{
	local LOCAL_SERVER_IP=""
	local SERVER_TAG=""
	local CONF_FILE=$1
	
	get_server_ip $CONF_FILE
	if [ "$LOCAL_SERVER_IP" ] && [ "$SERVER_TAG" ]; then
		grep "dhcp-option *=" $CONF_FILE | grep "$SERVER_TAG,6,$LOCAL_SERVER_IP" > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			sed -i "/^dhcp-option *=$SERVER_TAG,6,/d" $CONF_FILE
			RESTART_DNSMASQ=1
		fi
	fi

	grep "^port *=" $CONF_FILE > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		sed -i "/^port *=/d" $CONF_FILE
		RESTART_DNSMASQ=1
	fi
}

clear_dnsmasq()
{
	local RESTART_DNSMASQ=0

	for conf in $DNSMASQ_CONF
	do
		if [ ! -e "$conf" ]; then
			continue
		fi

		clear_dnsmasq_conf $conf
	done

	if [ $RESTART_DNSMASQ -ne 0 ]; then
		restart_dnsmasq	
	fi
}

set_smartdns_port()
{
	if [ "$SMARTDNS_WORKMODE" = "0" ]; then
		return 0
	elif [ "$SMARTDNS_WORKMODE" = "1" ]; then
		sed -i "s/^\(bind .*\):53 *\(.*\)\$/\1:$SMARTDNS_PORT \2/g" $SMARTDNS_CONF
    	sed -i "s/^\(bind-tcp .*\):53 *\(.*\)\$/\1:$SMARTDNS_PORT \2/g" $SMARTDNS_CONF
	elif [ "$SMARTDNS_WORKMODE" = "2" ]; then
		sed -i "s/^\(bind .*\):$SMARTDNS_PORT *\(.*\)\$/\1:53 \2/g" $SMARTDNS_CONF
    	sed -i "s/^\(bind-tcp .*\):$SMARTDNS_PORT *\(.*\)\$/\1:53 \2/g" $SMARTDNS_CONF
	else
		return 1
	fi	

	return 0
}

set_rule()
{
	if [ "$SMARTDNS_WORKMODE" = "0" ]; then
		return 0
	elif [ "$SMARTDNS_WORKMODE" = "1" ]; then
		set_iptable
		return $?
	elif [ "$SMARTDNS_WORKMODE" = "2" ]; then
		set_dnsmasq
		return $?
	else
		return 1
	fi
}

clear_rule()
{
	if [ "$SMARTDNS_WORKMODE" = "0" ]; then
		return 0
	elif [ "$SMARTDNS_WORKMODE" = "1" ]; then
		clear_iptable
		return $?
	elif [ "$SMARTDNS_WORKMODE" = "2" ]; then
		clear_dnsmasq
		return $?
	else
		return 1
	fi
}

get_tz()
{
	if [ -e "/etc/localtime" ]; then
		return 
	fi
	
	for tzfile in /etc/TZ /var/etc/TZ
	do
		if [ ! -e "$tzfile" ]; then
			continue
		fi
		
		tz="`cat $tzfile 2>/dev/null`"
	done
	
	if [ -z "$tz" ]; then
		return	
	fi
	
	export TZ=$tz
}

case "$1" in
	start)
	set_rule
	if [ $? -ne 0 ]; then
		exit 1
	fi

	set_smartdns_port
	get_tz
	$SMARTDNS_BIN -c $SMARTDNS_CONF -p $SMARTDNS_PID
	if [ $? -ne 0 ]; then
		clear_rule
	fi
	;;
	status)
	pid="`cat $SMARTDNS_PID |head -n 1 2>/dev/null`"
	if [ -z "$pid" ]; then
		echo "smartdns not running."
		return 0
	fi

	if [ -d "/proc/$pid" ]; then
		echo "smartdns running"
		return 0;
	fi
	echo "smartdns not running."
	return 0;
	;;
	stop)
	clear_rule
	pid="`cat $SMARTDNS_PID | head -n 1 2>/dev/null`"
	if [ -z "$pid" ]; then
		echo "smartdns not running."
		return 0
	fi

	if [ ! -d "/proc/$pid" ]; then
		return 0;
	fi

	kill -9 $pid 2>/dev/null
	;;
	restart)
	$0 stop
	$0 start
	;;
	enable)
	nvram set apps_state_enable=2
	nvram set apps_state_error=0
	nvram set apps_state_install=5
	nvram set apps_state_action=install
	nvram set apps_u2ec_ex=2
	;;
	firewall-start|reload|force-reload|reconfigure)
	$0 restart
	;;
	*)
	;;
esac

