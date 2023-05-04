#!/usr/bin/env bash
#zerto_network_handler.sh


# chkconfig: 345 99 10
# description: Script to run a on start up and fix network scripts if needed

LOCKFILE=/var/lock/subsys/zerto_network_handler
PROCESS_LOG_FILE=-target-folder-network_handler.log
ONE_TIME_FILE=-target-folder-drctexecflag
ZERTO_TOOLS_FOLDER=/etc/ZertoTools
VC_FLAG=vc_flag
VC_FILE_FLAG=$ZERTO_TOOLS_FOLDER/$VC_FLAG
AZURE_FLAG=azure_flag
AZURE_FILE_FLAG=$ZERTO_TOOLS_FOLDER/$AZURE_FLAG
INDEX=0
NETWORK_SCRIPTS_FULL_PATH=/etc/sysconfig/network-scripts/

start(){
    # Touch our lock file so that stopping will work correctly
	touch ${LOCKFILE}
	echo $(date -u) 'Zerto Network Handler Service started'>> $PROCESS_LOG_FILE

	HV_RESPONSE=$(cat /sys/devices/virtual/dmi/id/sys_vendor | grep -i -E 'microsoft')
    echo $(date -u) 'Hypervisor detected is: '$HV_RESPONSE >> $PROCESS_LOG_FILE
	
    IS_RUN_WITHIN_VCENTER=${#HV_RESPONSE}
    if [ $IS_RUN_WITHIN_VCENTER -gt 0 ];
    then
		VC_VERIFIER=$(ls $ZERTO_TOOLS_FOLDER | grep $VC_FLAG)
				
		if [ ! -z $VC_VERIFIER ];
		then
			echo $(date -u)' We are in Azure for the 1st time, starting the network handler process' >> $PROCESS_LOG_FILE
			rm -rf $VC_FILE_FLAG
			touch $AZURE_FILE_FLAG
			
			echo $(date -u)' Creating network scripts backup' >> $PROCESS_LOG_FILE
			tar -zcvf $ZERTO_TOOLS_FOLDER/networkscripts.tar.gz $NETWORK_SCRIPTS_FULL_PATH
			tar -zcvf $ZERTO_TOOLS_FOLDER/rules.tar.gz /etc/udev/rules.d/
			tar -zcvf $ZERTO_TOOLS_FOLDER/network.tar.gz /etc/sysconfig/network    	
			
			echo $(date -u)' Verify that there are no persistent-net rules' >> $PROCESS_LOG_FILE
			if [ -f /etc/udev/rules.d/70-persistent-net.rules ];
			then
				rm -rf /etc/udev/rules.d/70-persistent-net.rules
				rm -rf /etc/udev/rules.d/75-persistent-net-generator.rules
				rm -rf /etc/udev/rules.d/80-net-name-slot-rules 
				
				echo $(date -u)" all interfaces before reload are: $(ls /sys/class/net/)" >> $PROCESS_LOG_FILE
				echo $(date -u)' Reload udev rules' >> $PROCESS_LOG_FILE
				
				# reload udev rules and reload hv_netvsc driver
				udevadm control --reload-rules && udevadm trigger
				modprobe -r hv_netvsc >> $PROCESS_LOG_FILE
				modprobe hv_netvsc >> $PROCESS_LOG_FILE										
								
				INTERFACES=$(ls /sys/class/net/)
				echo $(date -u)" all interfaces after reload are: " $INTERFACES >> $PROCESS_LOG_FILE				
				INTERFACES_RELOADED=$(echo $INTERFACES | grep eth0)
				
				if [ -z $INTERFACES_RELOADED ];
				then	
					echo $(date -u)" udev rules not reloaded. going to reboot." >> $PROCESS_LOG_FILE
					reboot
					exit 0
				fi
			fi  
		fi
		
		AZURE_VERIFIER=$(ls $ZERTO_TOOLS_FOLDER | grep $AZURE_FLAG)
		if [ ! -z $AZURE_VERIFIER ];
		then	
			rm -rf $AZURE_FILE_FLAG
			local is_nmcli_enabled=$(is_network_manager_enabled)
			local is_nmcli_active=$(is_network_manager_active)			
			
			if [ $is_nmcli_enabled == "false" ] && [ $is_nmcli_active == "false" ]
			then
				echo $(date -u)" NetworkManager is not active. Assuming network.service is enabled" >> $PROCESS_LOG_FILE
				echo $(date -u)" Fixing network scripts for network.service" >> $PROCESS_LOG_FILE
				fix_network_scripts
			else
				echo $(date -u)" Fixing connections for NetworkManager.service" >> $PROCESS_LOG_FILE
				systemctl start NetworkManager.service
				fix_network_manager_connections
			fi			
			
			rm -rf $VC_FILE
		fi
        echo $(date -u)" Done" >> $PROCESS_LOG_FILE
        echo $(date -u)" Removing Lock File" >> $PROCESS_LOG_FILE

    else
        echo $(date -u)" We're in VC. Suppressing all activity..." >> $PROCESS_LOG_FILE
		REIP_FLAG=$(ls $ZERTO_TOOLS_FOLDER | grep $VC_FLAG)
		if [ -z $REIP_FLAG ];
		then
			touch $VC_FILE_FLAG
		fi
    fi
    rm -rf ${LOCKFILE}
}

stop(){
# Remove our lock file
rm -rf ${LOCKFILE}
# Run that command that we wanted to run
echo $(date -u)" Zerto Network handler stopped" >> $PROCESS_LOG_FILE
}


function fix_network_scripts
{
# start with eth file - in case one of the original files is ethX we can overwrite it by accident (ens160->eth0,eth0->eth1)
	CONFIG_FILES_ETH=$(ls $NETWORK_SCRIPTS_FULL_PATH | grep "ifcfg-eth*" | sort)
	CONFIG_FILES=$(ls $NETWORK_SCRIPTS_FULL_PATH -I "ifcfg-lo" -I "ifcfg-eth*" | grep "ifcfg*")
	CONFIG_FILES=$CONFIG_FILES_ETH" "$CONFIG_FILES
	echo $(date -u)' Renaming all configuration not fits ethX standard' >> $PROCESS_LOG_FILE
	SOURCE_DATA_FILE_PATH=$ZERTO_TOOLS_FOLDER/dhcp.conf	
			
	for CONFIG_FILE in $CONFIG_FILES
	do
		echo $(date -u)' '$CONFIG_FILE >> $PROCESS_LOG_FILE
		SOURCE_PATH=$NETWORK_SCRIPTS_FULL_PATH$CONFIG_FILE
		TARGET_PATH=$NETWORK_SCRIPTS_FULL_PATH'ifcfg-eth'$INDEX
		echo $(date -u) ' Source file:'$SOURCE_PATH >> $PROCESS_LOG_FILE
		echo $(date -u) ' Target file:'$TARGET_PATH >> $PROCESS_LOG_FILE
	
		mv $SOURCE_PATH $TARGET_PATH
	
		cat $SOURCE_DATA_FILE_PATH > $TARGET_PATH
		INDEX=$((INDEX + 1))
	done			
	    
	echo $(date -u)' Zerto Network handler watchdog started' >> $PROCESS_LOG_FILE
	IS_NETWORK_RESTART_REQUIRED=""
	echo $(date -u)' We're not in VC. May be Azure. Let's give it a chance. Continue processing...' >> $PROCESS_LOG_FILE
	echo $(date -u)' Checking for static IP configuration' >> $PROCESS_LOG_FILE
	CONFIG_FILE_LIST=$(ls $NETWORK_SCRIPTS_FULL_PATH | grep "ifcfg-eth*")	
		
	COMMON_NETWORK_FILE=/etc/sysconfig/network
	echo $(date -u)' Processing GATEWAY section by removing it if exists' >> $PROCESS_LOG_FILE
	TMP=$(cat $COMMON_NETWORK_FILE | grep -v GATEWAY)
	echo $TMP > $COMMON_NETWORK_FILE
			
	for CONFIG_FILE in $CONFIG_FILE_LIST
	do
		CONFIG_FILE_PATH=$NETWORK_SCRIPTS_FULL_PATH$CONFIG_FILE
		echo $(date -u)' Starting test for file '$CONFIG_FILE_PATH >> $PROCESS_LOG_FILE
		IS_STATIC_IP=$(cat $CONFIG_FILE_PATH | grep -E  'BOOTPROTO=static|BOOTPROTO=none')
		echo $(date -u)' Static ip test returned '$IS_STATIC_IP >> $PROCESS_LOG_FILE
				
		echo $(date -u)" Processing "$CONFIG_FILE_PATH" file" >> $PROCESS_LOG_FILE
		INTERFACE_NAME=${CONFIG_FILE#"ifcfg-"}
		INTERFACE_NAME=${INTERFACE_NAME%"ifcfg-"}
		echo $(date -u)" Interface name "$INTERFACE_NAME" extracted" >> $PROCESS_LOG_FILE
				
		if [ ! -z $IS_STATIC_IP ];
		then
			echo $(date -u)" Static IP configuration discovered" >> $PROCESS_LOG_FILE

			# EDIT instead of replace
			echo $(date -u)" Updating configuration file" >> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing DEVICE section">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep DEVICE)
			NEW_VALUE='DEVICE="'$INTERFACE_NAME'"'
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing NAME section">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep NAME)
			NEW_VALUE='NAME="'$INTERFACE_NAME'"'
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing BOOTPROTO section">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep BOOTPROTO)
			NEW_VALUE='BOOTPROTO="dhcp"'
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing ONBOOT section">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep ONBOOT)
			NEW_VALUE='ONBOOT="yes"'
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing TYPE section">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep TYPE)
			NEW_VALUE='TYPE="Ethernet"'
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing USERCTL section">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep USERCTL)
			NEW_VALUE='USERCTL="yes"'
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing IPV6INIT section">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep IPV6INIT)
			NEW_VALUE='IPV6INIT="no"'
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing NM_CONTROLLED section">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep NM_CONTROLLED=yes)
			NEW_VALUE='NM_CONTROLLED=no"'
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing PERSISTENT_DHCLIENT section">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep PERSISTENT_DHCLIENT)
			NEW_VALUE='PERSISTENT_DHCLIENT="1"'
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing GATEWAY section by removing it if exists">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep GATEWAY)
			NEW_VALUE=''
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing HWADDR section by editing it if exists">> $PROCESS_LOG_FILE
			resolve_hw_addr $CONFIG_FILE_PATH $INTERFACE_NAME 
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
					
			echo $(date -u)" Processing BROADCAST section by removing it if exists">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep BROADCAST)
			NEW_VALUE=''
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing IPADDR section by removing it if exists">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep IPADDR)
			NEW_VALUE=''
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing NETMASK section by removing it if exists">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep NETMASK)
			NEW_VALUE=''
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing NETWORK section by removing it if exists">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep NETWORK)
			NEW_VALUE=''
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing DNS1 section by removing it if exists">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep DNS1)
			NEW_VALUE=''
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			
			echo $(date -u)" Processing DNS2 section by removing it if exists">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep DNS2)
			NEW_VALUE=''
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing IPV4_FAILURE_FATAL section by removing it if exists">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep IPV4_FAILURE_FATAL)
			NEW_VALUE=''
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing DEFROUTE section by removing it if exists">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep DEFROUTE)
			NEW_VALUE=''
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Processing PREFIX section by removing it if exists">> $PROCESS_LOG_FILE
			OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep PREFIX)
			NEW_VALUE=''
			if [ ! -z $OLD_VALUE ];
			then
				sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
			fi
			cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE
			
			echo $(date -u)" Clean up empty lines">> $PROCESS_LOG_FILE
			sed -i '/^$/d' $CONFIG_FILE_PATH
					
			IS_NETWORK_RESTART_REQUIRED="True"
		else
			echo $(date -u)" IP set to DHCP "$IS_STATIC_IP >> $PROCESS_LOG_FILE
			resolve_hw_addr $CONFIG_FILE_PATH $INTERFACE_NAME
		fi
		done
		
	if [ ! -z $IS_NETWORK_RESTART_REQUIRED ];
	then
		echo $(date -u)" Restarting network" >> $PROCESS_LOG_FILE
		service network restart
		echo $(date -u)" Preparing to reboot" >> $PROCESS_LOG_FILE
		rm -rf $VC_FILE
		reboot
	fi
}

function fix_network_manager_connections
{
	for i in {1..10}
	do
		if [[ $(nmcli device) ]];
		then
			DEVICES=$(nmcli device)		
			echo $(date -u)" Declared devices: $DEVICES" >> $PROCESS_LOG_FILE
			break
		fi
		sleep 5
		echo $(date -u)" Service slept for 5 seconds while waiting for devices to show" >> $PROCESS_LOG_FILE 
	done
		
	INTERFACES_NAMES=$(ls /sys/class/net/ | grep '^eth')
	for INTERFACE in $INTERFACES_NAMES
	do
		echo $(date -u)" checking if need to declare connection to $INTERFACE" >> $PROCESS_LOG_FILE
		DEVICE_EXIST=$(nmcli device | awk '$1 == "'"${INTERFACE}"'" && $3 == "connected" {print $1}')
		if [ -z $DEVICE_EXIST ];
		then
			echo $(date -u)" Add connection to $INTERFACE" >> $PROCESS_LOG_FILE
			nmcli con add type ethernet con-name "$INTERFACE" ifname "$INTERFACE"
		fi
	done
}

function resolve_hw_addr
{
	CONFIG_FILE_PATH=$1
	INTERFACE_NAME=$2
	echo $(date -u)" Processing HWADDR section by removing it if exists">> $PROCESS_LOG_FILE
	OLD_VALUE=$(cat $CONFIG_FILE_PATH | grep HWADDR)
	echo $(date -u)" all addresses: $(cat /sys/class/net/*/address)" >> $PROCESS_LOG_FILE
	echo $(date -u)" all interfaces are: $(ls /sys/class/net/)" >> $PROCESS_LOG_FILE
	HW_ADDR=$(cat /sys/class/net/$INTERFACE_NAME/address)	
	echo $(date -u)" HW_ADDR is: $HW_ADDR , interface name is: $INTERFACE_NAME">> $PROCESS_LOG_FILE
	NEW_VALUE='HWADDR="'$HW_ADDR'"'
	if [ ! -z $OLD_VALUE ];
	then
		sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" $CONFIG_FILE_PATH
	else
		echo -e "\n"$NEW_VALUE >> $CONFIG_FILE_PATH
	fi
	cat $CONFIG_FILE_PATH>> $PROCESS_LOG_FILE	
}

function is_network_manager_enabled
{
	if [ -e "/usr/sbin/NetworkManager" ]
	then
		local network_manager_enabled=`systemctl is-enabled NetworkManager`
		
		if [ "$network_manager_enabled" == "enabled" ]
		then
			echo true
			return
		fi
	fi
	
	echo false
}

function is_network_manager_active
{
	local network_manager_active=`systemctl is-active NetworkManager`
  
	if [ "$network_manager_active" == "active" ] || [ "$network_manager_active" == "activating" ]
	then
		echo true
		return
	fi
  
	echo false
}

case "$1" in
    start) start;;
    stop) stop;;
    *)
        echo $"Usage: $0 {start|stop}"
        exit 1
esac
exit 0
