#!/bin/bash
source scripts/read_yn.sh
source scripts/read_non_empty.sh
source scripts/read_ip.sh
function backup_server () {
    logfile="/var/log/backup_${remote_name}.log"
    error_logfile="/var/log/backup_${remote_name}_error.log"
    echo "--------------------BACKUP SERVER--------------------" | tee -a $logfile
    echo ""
    echo ""
    echo -e "\e[31m--------------------------------------------------------------------------------------------\e[0m"
    echo ""
    echo -e "\e[31mYou need at least another server, ideally with FTP.\e[0m"
    echo ""
    echo -e "\e[31m--------------------------------------------------------------------------------------------\e[0m"
    echo ""
    echo ""
    backup_server_ask=$(read_yn "Do you want to setup a backup server? (y/n): ")
    if [ "$backup_server_ask" = "n" ]; then
        echo "Skipping backup server" | tee -a $logfile
        return
    fi

    ftp_transfer=$(read_yn "Do you have a FTP server? (y/n): ")
    rsync_transfer=$(read_yn "Do you have a server via rsync, or do you want to transfer the data to it? (y/n): ")

    if [ "$ftp_transfer" = "n" ] && [ "$rsync_transfer" = "n" ]; then
        echo "You need at least one transfer method." | tee -a $logfile
        echo "Skipping backup server" | tee -a $logfile
        echo "You can run this script again to setup a backup server with the third option."
        return
    fi

    remote_name=$(read_non_empty "Enter the backup's name (what you want): ")
    remote_retention=$(read_non_empty "Enter the remote server's backup retention (in days, how many days the data will be stored): ")
    remote_compression=$(read_yn "Enter the remote server's backup compression (y/n): ")



    if [ "$ftp_transfer" = "y" && "$rsync_transfer" = "y" ]; then
        both_transfer=true
    fi

    if [ "$ftp_transfer" = "y" ]; then
        ftp_address=$(read_non_empty "Enter the FTP server's domain: ")
        ftp_username=$(read_non_empty "Enter the FTP server's username: ")
        ftp_password=$(read_non_empty "Enter the FTP server's password: ")
        ftp_dir=$(read_non_empty "Enter the FTP server's backup directory: ")
    fi

    if [ "$rsync_transfer" = "y" ]; then
        remote_ip=$(read_ip)
        remote_username=$(read_non_empty "Enter the remote server's username: ")
        remote_password=$(read_non_empty "Enter the remote server's password: " true)
        echo ""
        remote_port=$(read_non_empty "Enter the remote server's ssh port: ")
        remote_dir=$(read_non_empty "Enter the remote server's backup directory (where your data will be stored): ")
        ssh-keygen -t rsa -b 4096 -f "${home_dir}/.ssh/${remote_name}_rsa" -N "" |& tee -a $logfile
        echo "SSH key pair generated: ${home_dir}/.ssh/${remote_name}_rsa" | tee -a $logfile

        echo "Trying to copy the public key to the remote server..." | tee -a $logfile
        sshpass -p "$remote_password" ssh-copy-id -p "${remote_port}" -i "${home_dir}/.ssh/${remote_name}_rsa.pub" "${remote_username}@${remote_ip}" |& tee -a $logfile
    fi

    if [ $USER = "root" ]; then
        home_dir="/root"
    else
        home_dir="/home/${USER}"
    fi

    backup_script="${home_dir}/backup_${remote_name}.sh"
    touch $backup_script && chmod +x $backup_script
    touch $logfile
    touch $error_logfile

    echo "#!/bin/bash" > $backup_script
    echo "current_time=\$(date +\"%d.%m.%Y_%H:%M\")" >> "$backup_script"
    echo "echo \"\${current_time}: Starting backup\" >> $logfile" >> "$backup_script"
    echo "docker stop \$(docker ps -q)" >> "$backup_script"
    echo "for container in \$(lxc-ls); do lxc-stop -n \"\$container\"; done" >> "$backup_script"
    echo "dirs_to_backup=(\"/etc\" \"/var/lib/lxc\" \"/home/devops\")" >> "$backup_script"
    echo "current_date=\$(date +%Y%m%d_%H%M)" >> "$backup_script"
    echo "tarball_name=\"${remote_name}_\${current_date}.tar.gz\"" >> "$backup_script"
    echo "tar -czf /root/backups/${tarball_name} \"\${dirs_to_backup[@]}\" 2>> $error_logfile" >> "$backup_script"

    echo "local_hash=\$(sha256sum /root/backups/${tarball_name} | awk '{ print \$1 }')" >> "$backup_script"
    echo "echo \"Local hash: \${local_hash}\"" >> "$backup_script"

    if [ "$both_transfer" = true ]; then
        echo "ftp -n ${ftp_address} <<END_SCRIPT" >> "$backup_script"
        echo "quote USER ${ftp_username}" >> "$backup_script"
        echo "quote PASS ${ftp_password}" >> "$backup_script"
        echo "cd backups" >> "$backup_script"
        echo "put /root/backups/${tarball_name} ${tarball_name}" >> "$backup_script"
        echo "quit" >> "$backup_script"
        echo "END_SCRIPT" >> "$backup_script"

        echo "curl -u '${ftp_username}:${ftp_password}' ftp://${ftp_address}/backups/${tarball_name} -o /root/backups/temp_${tarball_name}" >> "$backup_script"
        echo "remote_hash=\$(sha256sum /root/backups/temp_${tarball_name} | awk '{ print \$1 }')" >> "$backup_script"
        echo "echo \"Remote hash: \${remote_hash}\"" >> "$backup_script"
        echo "rm /root/backups/temp_${tarball_name}" >> "$backup_script"

        echo "if [ \"\${local_hash}\" == \"\${remote_hash}\" ]; then" >> "$backup_script"
        echo "  echo \"Hashes match.\"" >> "$backup_script"
        echo "else" >> "$backup_script"
        echo "  echo \"Hashes do not match.\"" >> "$backup_script"
        echo "fi" >> "$backup_script"

        echo "rsync -avz -e \"ssh -i ${home_dir}/.ssh/${remote_name}_rsa -p $remote_port\" \"\${tarball_name}\" \"${remote_username}@${remote_ip}:${remote_dir}/\" 2>> $error_logfile" >> "$backup_script"
    fi
    if [ "$ftp_transfer" = "y" ]; then
        echo "ftp -n ${ftp_address} <<END_SCRIPT" >> "$backup_script"
        echo "quote USER ${ftp_username}" >> "$backup_script"
        echo "quote PASS ${ftp_password}" >> "$backup_script"
        echo "cd /" >> "$backup_script"
        echo "put ${tarball_name}" >> "$backup_script"
        echo "quit" >> "$backup_script"
        echo "END_SCRIPT" >> "$backup_script"

        echo "curl -u ${ftp_username}:${ftp_password} ftp://${ftp_address}/${tarball_name} -o /root/backups/temp_${tarball_name}" >> "$backup_script"
        echo "remote_hash=\$(sha256sum /root/backups/temp_${tarball_name} | awk '{ print \$1 }')" >> "$backup_script"
        echo "echo \"Remote hash: \${remote_hash}\"" >> "$backup_script"
        echo "rm /root/backups/temp_${tarball_name}" >> "$backup_script"

        echo "if [ \"\${local_hash}\" == \"\${remote_hash}\" ]; then" >> "$backup_script"
        echo "  echo \"Hashes match.\"" >> "$backup_script"
        echo "else" >> "$backup_script"
        echo "  echo \"Hashes do not match.\"" >> "$backup_script"
        echo "fi" >> "$backup_script"
    fi
    if [ "$rsync_transfer" = "y" ]; then
        echo "rsync -avz -e \"ssh -i ${home_dir}/.ssh/${remote_name}_rsa -p $remote_port\" \"\${tarball_name}\" \"${remote_username}@${remote_ip}:${remote_dir}/\" 2>> $error_logfile" >> "$backup_script"
    fi

    echo "find /root/backups -name \"backup_${remote_name}_*.tar.gz\" -type f -mtime +${remote_retention} -delete 2>> $error_logfile" >> "$backup_script"
    echo "docker start \$(docker ps -a -q)" >> "$backup_script"
    echo "for container in \$(/usr/bin/lxc-ls); do" >> "$backup_script"
    echo "  /usr/bin/lxc-start -n \"\${container}\" --logfile /var/log/lxc-\"\${container}.log\" --logpriority DEGUB >> "$backup_script"
    echo "  sleep 10" >> "$backup_script""
    echo "done" >> "$backup_script"

    echo "Backup script generated: $backup_script" | tee -a $logfile

    echo "Adding cron job..." | tee -a $logfile
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" > /etc/cron.d/backup
    echo "0 2 * * * root ${backup_script}" >> "/etc/cron.d/backup"
    chmod 600 "/etc/cron.d/backup"
    echo "" >> /etc/cron.d/backup

    echo "Cron job added to run the backup script every day at 2 AM" | tee -a $logfile
}