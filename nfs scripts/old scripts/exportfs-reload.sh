#!/bin/bash

# Log file path
LOGFILE="/var/log/exportfs-reload.log"

# Function to log messages
log_message() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" >> $LOGFILE
}

# Clear the log file at the start of the service
> $LOGFILE
log_message "Log file cleared and service started."

# Run exportfs command
log_message "Running exportfs -a to re-export NFS shares..."
exportfs -a
if [ $? -eq 0 ]; then
    log_message "NFS exports successfully updated."
else
    log_message "Failed to update NFS exports."
fi

# Log the current list of exported file systems
log_message "Current exported NFS shares:"
exportfs -v >> $LOGFILE

