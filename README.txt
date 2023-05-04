Azure ZertoTools For Linux

The ZertoTools for Linux script is required when failing over VMs with Linux operating systems to Azure.
The ZertoTools for Linux script should be executed on the Protected VM.
This script enables changing the network configuration of the VM to DHCP on the recovered Azure site and adds the missing modules to dracut.conf.
This script also enables azure serial console by changing the grub configuration. To skip this step, you can add a flag. For details, see below.
This script saves a backup to initramfs (on the Protected machine) and also to the network configuration files before Failing over to Azure.

To execute the Azure ZertoTools For Linux:

1. On the Protected Linux VM, create a new folder.

2. Copy all files from the folder "Zerto Tools For Linux" to the new folder.

3. Make sure the Syntax is in Unix format. If not, run the following:
	a. Use vi to edit ZertoTools.sh. Write:" :set ff=unix " and press Enter. To save and exit run ":wq".
	b. Use vi to edit zerto_network_handler.sh. Write:" :set ff=unix " and press Enter. To save and exit run ":wq".
	
4. To enable the Azure Serial Console, the script will make changes on the grub configuration. To skip this step, run the command with the flag "-l 0" 

5. On the Recovery Linux VM, the following files will be deleted:
   •  /etc/udev/rules.d/70-persistent-net.rules 
   •  /etc/udev/rules.d/75-persistent-net-generator.rules
   •  /etc/udev/rules.d/80-net-name-slot-rules 
   A backup of these files is in the path: /etc/ZertoTools/rules.tar.gz 

6. On the Protected Linux VM, run the ZertoTools script, using the following commands: 
               chmod +x ./ZertoTools.sh
               ./ZertoTools.sh

7. Before Failing over, make sure the changes were applied to the selected checkpoint by waiting for a new checkpoint, or by performing a force sync.

8. Perform Failover / Move operations.																	   