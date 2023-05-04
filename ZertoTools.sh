#!/bin/sh
LOGS_FOLDER=/etc/ZertoTools/
WORKING_DIRECTORY=$(pwd)
INSTALLATION_LOG=$WORKING_DIRECTORY/installation.log
HANDLER_NAME='zerto_network_handler.sh'
CONF_FILE_NAME='dhcp.conf'
NETWORK_HANDLER_PATH=$LOGS_FOLDER$HANDLER_NAME
CONF_FILE_PATH=$LOGS_FOLDER$CONF_FILE_NAME
DRIVERS="hv_vmbus hv_netvsc hv_storvsc mptbase mptscsih mptspi scsi_transport_fc scsi_transport_iscsi scsi_transport_srp scsi_transport_sas scsi_transport_spi"
GRUB_OPTIONS=" rootdelay=300 console=ttyS0 console=tty0 earlyprintk=ttyS0"
ZERTO_TOOLS_VERSION="2.00"
FSTAB_PATH=/etc/fstab
YELLOW='\033[1;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
VERSION_FILE=$LOGS_FOLDER/version.txt
enable_serial_console=1

fstab_verifier()
{
FSTAB_PATH_NOT_SUPPORTED=$(grep "/dev/s" $FSTAB_PATH)
echo $(date -u) "fstab record: $FSTAB_PATH_NOT_SUPPORTED is not supported">>$INSTALLATION_LOG
if [[ "$FSTAB_PATH_NOT_SUPPORTED" == "/dev/s"* ]]
then
    echo -e "${YELLOW}WARNING: Your fstab contains a direct path to a disk and may cause issues when booting in Azure. Consider changing the $FSTAB_PATH_NOT_SUPPORTED to the UUID of the disk and add nofail flag.${NC}" |& tee -a $INSTALLATION_LOG
fi
}


add_drivers_to_dracut()
{
drivers_to_dracut_verifier

OLD_VALUE='#add_drivers+=""'
NEW_VALUE='add_drivers+=" -DRIVERS- "'
echo $(date -u) "Verify that $DRIVERS drivers are included in the dracut configuration">>$INSTALLATION_LOG

is_hv_drivers_exists

if [ ${#IS_HV_EXISTS} -eq 0 ];
then
    echo $(date -u)" drivers Definition not found. Adding hv drivers" >> $INSTALLATION_LOG	
	
	if [[ $VERSION_ABOVE_8 == 'true' ]]
	then
		echo $NEW_VALUE > /etc/dracut.conf.d/hv.conf
		sed -i -e "s|-DRIVERS-|$DRIVERS|" /etc/dracut.conf.d/hv.conf
		echo $(date -u)" Drivers added to /etc/dracut.conf.d/hv.conf " >> $INSTALLATION_LOG
	else	
		sed -i -e "s|$OLD_VALUE|$NEW_VALUE|" /etc/dracut.conf
		sed -i -e "s|-DRIVERS-|$DRIVERS|" /etc/dracut.conf
		echo $(date -u)" Drivers added to /etc/dracut.conf " >> $INSTALLATION_LOG
	fi
	
	echo $(date -u)" Verify all the expected drivers are added to the dracut configuration" >> $INSTALLATION_LOG
	
	is_hv_drivers_exists
	if [ ${#IS_HV_EXISTS} -ne 0 ];
	then
        echo $(date -u)" All the expected drivers: $DRIVERS, were added successfully to the dracut configuration" >> $INSTALLATION_LOG
	fi

	echo $(date -u)" backup initramfs before running dracut" >> $INSTALLATION_LOG
	cp -p /boot/initramfs-$(uname -r).img /boot/initramfs-$(uname -r).img.zertotools.bak

	echo $(date -u) " Running dracut tool and saving the output">>$INSTALLATION_LOG		
	
	RUNNING_KERNEL=$(uname -a)
	RUNNING_KERNEL_VERSION=$(echo $RUNNING_KERNEL | cut -d' ' -f 3)
	echo $(date -u) " running kernel version $RUNNING_KERNEL_VERSION">>$INSTALLATION_LOG

	INSTALLED_KERNEL=$(grubby --default-kernel)
	INSTALLED_KERNEL_VERSION=$(echo $INSTALLED_KERNEL |  sed 's/\/boot\/vmlinuz-//g' )

	echo $(date -u) " installed kernel version $INSTALLED_KERNEL_VERSION">>$INSTALLATION_LOG
	
	DRACUT_COMMAND=$(echo dracut -f -v /boot/initramfs-$INSTALLED_KERNEL_VERSION.img  $INSTALLED_KERNEL_VERSION)		
	
	DRACUT_OUTPUT=$LOGS_FOLDER'dracut.output'
    $DRACUT_COMMAND |& tee -a $INSTALLATION_LOG $DRACUT_OUTPUT >/dev/null
	DRACUT_VERIFY=$(grep -i 'Failed to install' $DRACUT_OUTPUT)
	if [ ${#DRACUT_VERIFY} -ne 0 ];
	then
		echo -e "${RED}There is an error with the dracut: " $DRACUT_VERIFY " Do not continue with the Failover operation${NC}" |& tee -a $INSTALLATION_LOG
		exit 0
	fi
fi
}


calculate_version_above_8()
{
if [[ $VERSION == 8* ]] || [[ $VERSION == 9* ]]
then
	VERSION_ABOVE_8='true'
else
	VERSION_ABOVE_8='false'
fi
}

calculate_version_above_7()
{
if [[ $VERSION == 7* ]] || [[ $VERSION_ABOVE_8 == 'true' ]]
then
	VERSION_ABOVE_7='true'
else
	VERSION_ABOVE_7='false'
fi
}


is_hv_drivers_exists()
{

DRACUT_ABOVE_8_CONF=/etc/dracut.conf.d/hv.conf

if [[ $VERSION_ABOVE_8 == 'true' ]] && [[ -f "$DRACUT_ABOVE_8_CONF" ]]
then
	IS_HV_EXISTS=$(cat $DRACUT_ABOVE_8_CONF | grep "$DRIVERS")
else
	IS_HV_EXISTS=$(cat /etc/dracut.conf | grep "$DRIVERS")
fi
}


drivers_to_dracut_verifier() 
{
for DRIVER in $DRIVERS
do
    echo $(date -u) " Verifying driver $DRIVER is in the OS modules list" >> $INSTALLATION_LOG 
	MODULE_VERIFIER=$(modinfo $DRIVER 2>modinfo_err | head -1)
	echo $(date -u) " Modinfo of the driver $DRIVER is: $MODULE_VERIFIER" >> $INSTALLATION_LOG
	if [ -z "$MODULE_VERIFIER" ]
	then
		cat modinfo_err >>$INSTALLATION_LOG
	    echo -e "${YELLOW}WARNING: The driver $DRIVER is not found in the modules list on this VM and cannot be installed. Please install this driver as it is required for recovery to Azure. ${NC}" |& tee -a $INSTALLATION_LOG
		DRIVERS=${DRIVERS//$DRIVER}
	fi
done
}

update_grub_config()
{
if [[ $enable_serial_console == 1 ]] 
then		
	echo $(date -u) "Started enabling Azure serial console on grub config">>$INSTALLATION_LOG

	grub_found=0
	if [[ $VERSION == 6* ]]
	then
		grub_file='/boot/grub/grub.conf'
		if [[ -f  $grub_file ]]
		then
			grub_found=1
			GRUB=$(sed -n '/title/,$p'  $grub_file | grep 'kernel')
		fi
	elif [[ $VERSION_ABOVE_7 == 'true' ]]
	then
		grub_file='/etc/default/grub'
		if [[ -f  $grub_file ]]
		then
			grub_found=1
			GRUB=$(cat $grub_file | grep GRUB_CMDLINE_LINUX)
		fi
	fi
	
	if [[ $grub_found -eq 0 ]]
	then
		echo -e "${YELLOW}WARNING: Failed to enable Azure serial console: $grub_file file not found." |& tee -a $INSTALLATION_LOG
	else
		NEW_GRUB=$(echo $GRUB | sed -e 's/rhgb//' -e 's/quiet//' -e 's/crashkernel=auto//')
		NEW_GRUB=$(echo $NEW_GRUB | sed ':a; s/rootdelay=\S*//; ta')
		NEW_GRUB=$(echo $NEW_GRUB | sed ':a; s/console=\S*//; ta')
		NEW_GRUB=$(echo $NEW_GRUB | sed ':a; s/earlyprintk=\S*//; ta')  

		if [[ $NEW_GRUB == *\" ]] 
		then
			NEW_GRUB=$(echo $NEW_GRUB | sed 's/.$//')
		fi
	
		NEW_GRUB=$NEW_GRUB$GRUB_OPTIONS
	
		if [[ $VERSION_ABOVE_7 == 'true' ]]
		then
			NEW_GRUB=$NEW_GRUB\"
			sed -i -e "s|$GRUB|$NEW_GRUB|" $grub_file
			grub2-mkconfig -o /boot/grub2/grub.cfg 2>GRUB_RESULT
			cat GRUB_RESULT >>$INSTALLATION_LOG
		elif [[ $VERSION == 6* ]]
		then
			NEW_GRUB='\t'$NEW_GRUB
			sed -i -e "s|$GRUB|$NEW_GRUB|" $grub_file
			echo "#This service maintains a agetty on ttyS0.
			stop on runlevel [S016]
			start on [23]
			respawn
			exec agetty -h -L -w /dev/ttyS0 115200 vt102" >  /etc/init/ttyS0.conf
		fi
		echo $(date -u) " Serial Console was enabled succesfully.">>$INSTALLATION_LOG

	fi
fi
}

network_handler_verifier()
{
if [[ $VERSION_ABOVE_7 == 'true' ]] 
then
	echo $(date -u) "Verifying if the network handler service installed">>$INSTALLATION_LOG
	echo $(date -u) "Checking if the network handler service is in enabled state">>$INSTALLATION_LOG
    VERIFY_INSTALLED=$(systemctl list-unit-files | grep 'zerto_network'| grep 'enabled')
elif [[ $VERSION == 6* ]]
then 
	echo $(date -u) "Checking if the network handler service is in enabled state">>$INSTALLATION_LOG
	VERIFY_INSTALLED=$(chkconfig --list | grep 'zerto_network')
fi

if [ ${#VERIFY_INSTALLED} -eq 0 ];
then
		echo -e "${RED}ERROR: Zerto Network Handler Service is not installed properly. Do not continue with the Failover operation ${NC}" |& tee -a $INSTALLATION_LOG
else
		echo $(date -u) "zerto network handler installed successfully">>$INSTALLATION_LOG
fi
}


echo $(date -u) "Zerto Tools version is: "$ZERTO_TOOLS_VERSION |& tee -a $INSTALLATION_LOG
	
echo $(date -u) "Getting linux distribution and version info" >>$INSTALLATION_LOG
RELEASE=$(cat /etc/*release)
echo $(date -u) "Resolved OS is:"$RELEASE>>$INSTALLATION_LOG

RH_OPERATING_SYSTEM=$(echo $RELEASE | grep -i 'centos\|red hat')
IS_RH_OS=${#RH_OPERATING_SYSTEM}

if [[ $IS_RH_OS -eq 0 ]];
then
	echo -e "${RED}ERROR: ZertoTools script can only run on CentOS or Red Hat operating systems. Aborting the operation...  ${NC}" |& tee -a $INSTALLATION_LOG
	#exit 0
fi	

echo $(date -u) "Resolving the operating system version">>$INSTALLATION_LOG
VERSION=$(rpm -q --queryformat '%{VERSION}' $(rpm -qa '(redhat|sl|slf|centos|oraclelinux)(|-linux|-stream)-release(|-server|-workstation|-client|-computenode)'))

calculate_version_above_8
calculate_version_above_7

echo $(date -u) "Resolved OS version is:"$VERSION>>$INSTALLATION_LOG

if   [[ $VERSION != 6* ]] && [[ $VERSION != 7* ]] && [[ $VERSION != 8* ]] && [[ $VERSION != 9* ]]
then
	echo -e "${RED}ERROR: ZertoTools script can only run on CentOS/Red Hat versions 6/7/8/9. Aborting the operation...${NC}" |& tee -a $INSTALLATION_LOG
	exit 0
fi

HV_RESPONSE=$(cat /sys/devices/virtual/dmi/id/sys_vendor | grep -i -E 'microsoft')
echo $(date -u) 'Hypervisor detected is: '$HV_RESPONSE >> $INSTALLATION_LOG
IS_RUN_WITHIN_VCENTER=${#HV_RESPONSE}
if [[ $IS_RUN_WITHIN_VCENTER -gt 0 ]];
then
	echo -e "${RED}ERROR: ZertoTools script can only run on a vCenter Server. Aborting the operation...${NC}" |& tee -a $INSTALLATION_LOG
	exit 0
fi	

while getopts l: flag
do
    case "${flag}" in
        l) enable_serial_console=${OPTARG};;    
		
    esac
done

fstab_verifier

echo $(date -u) "Granting execution permissions to the uninstaller script" >>$INSTALLATION_LOG
chmod +x ./ZertoToolsUninstaller.sh
echo $(date -u) "Running the uninstaller script to clean the environment before installing" |& tee -a $INSTALLATION_LOG
./ZertoToolsUninstaller.sh $INSTALLATION_LOG

echo $(date -u) "Starting the ZertoTools installation" |& tee -a $INSTALLATION_LOG

echo $(date -u) "Creating the" $LOGS_FOLDER " to run the network handler from" $LOGS_FOLDER >>$INSTALLATION_LOG
mkdir -p $LOGS_FOLDER
echo $ZERTO_TOOLS_VERSION &> $VERSION_FILE


echo $(date -u) "Copying zerto network handler file to it's permanent location">>$INSTALLATION_LOG
cp -rf ./zerto_network_handler.sh $NETWORK_HANDLER_PATH
echo $(date -u) "Copying dhcp.conf file to it's permanent location">>$INSTALLATION_LOG
cp -rf ./dhcp.conf $CONF_FILE_PATH

echo $(date -u) "Generating service log file path">>$INSTALLATION_LOG
sed -i -e "s|-target-folder-|$LOGS_FOLDER|" $NETWORK_HANDLER_PATH

# For version 6 the zerto_network_handler script must be in /etc/init.d/.
# For 7 and above it can be in any directory, just make sure to update path in .service file.
if [[ $VERSION == 6* ]] 
then
	echo $(date -u) "Installing network handler">>$INSTALLATION_LOG
	cp -rf $NETWORK_HANDLER_PATH /etc/init.d/zerto_network_handler
	echo $(date -u) "Granting execution permissions to the network handler service">>$INSTALLATION_LOG
	chmod +x /etc/init.d/zerto_network_handler

	echo $(date -u) "Adding service to startup sequence">>$INSTALLATION_LOG
	chkconfig --add zerto_network_handler
	chkconfig zerto_network_handler on	
elif [[ $VERSION_ABOVE_7 == 'true' ]]
then
	echo $(date -u) "Installing network handler">>$INSTALLATION_LOG
	cp -rf $NETWORK_HANDLER_PATH /usr/sbin/zerto_network_handler
	echo $(date -u) "Granting execution permissions to the network handler service">>$INSTALLATION_LOG
	chmod +x /usr/sbin/zerto_network_handler
	
	echo $(date -u) "Copying zerto_network_handler.service unit file to target folder">>$INSTALLATION_LOG
	cp -rf ./zerto_network_handler.service /etc/systemd/system/
	echo $(date -u) "Enable Service zerto_network_handler">>$INSTALLATION_LOG
	systemctl enable zerto_network_handler
fi

echo $(date -u) "Adding drivers to dracut.conf file: "$VERSION>>$INSTALLATION_LOG
add_drivers_to_dracut

echo $(date -u) "Starting network handler service">>$INSTALLATION_LOG
service zerto_network_handler start


update_grub_config
network_handler_verifier
echo -e "${GREEN}The installation was successfully completed! ${NC}" |& tee -a $INSTALLATION_LOG

exit 0