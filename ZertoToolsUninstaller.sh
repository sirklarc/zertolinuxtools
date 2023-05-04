#!/usr/bin/env bash

INSTALLATION_LOG=$1

echo 'Stopping service'>>$INSTALLATION_LOG
service zerto_network_handler stop
echo 'Removing service source'>>$INSTALLATION_LOG
rm -rf /etc/ZertoTools/
echo 'Removing unit file'>>$INSTALLATION_LOG
rm -rf /etc/systemd/system/zerto_network_handler.service
echo 'Removing service zerto_network_handler'>>$INSTALLATION_LOG
rm -rf /usr/sbin/zerto_network_handler
rm -rf /etc/init.d/zerto_network_handler
echo 'Success'>>$INSTALLATION_LOG
