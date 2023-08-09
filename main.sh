#!/bin/bash
source scripts/vps_setup_single.sh
source scripts/backup_server.sh
source scripts/reset_server.sh
source scripts/create_container.sh
# checks if the script is launched as root or not
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# checks if the ipcalc package is installed or not
if ! dpkg -l | grep -w "ipcalc" >/dev/null; then
    echo "ipcalc, curl and wget packages are not installed... installing it"
    apt-get install ipcalc curl wget -y >/dev/null
    sleep 2
    echo "ipcalc package installed successfully"
fi

function main () {
    echo ""
    echo "   ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░"
    echo "  ░░░░██████╗░██████╗███████╗██╗░░░██╗███╗░░██╗███████╗██████╗░░█████╗░██╗░░░░░░██████╗░░░"
    echo " ░░░░██╔════╝██╔════╝██╔════╝██║░░░██║████╗░██║██╔════╝██╔══██╗██╔══██╗██║░░░░░██╔════╝░░░░"
    echo "░░░░░╚█████╗░╚█████╗░█████╗░░██║░░░██║██╔██╗██║█████╗░░██████╔╝███████║██║░░░░░╚█████╗░░░░░░"
    echo "░░░░░░╚═══██╗░╚═══██╗██╔══╝░░██║░░░██║██║╚████║██╔══╝░░██╔══██╗██╔══██║██║░░░░░░╚═══██╗░░░░░"
    echo " ░░░░██████╔╝██████╔╝██║░░░░░╚██████╔╝██║░╚███║███████╗██║░░██║██║░░██║███████╗██████╔╝░░░░"
    echo "  ░░░╚═════╝░╚═════╝░╚═╝░░░░░░╚═════╝░╚═╝░░╚══╝╚══════╝╚═╝░░╚═╝╚═╝░░╚═╝╚══════╝╚═════╝░░░░"
    echo "   ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░"
    echo -e "\n---------------------------------------------"
    echo ""
    echo "This script is an installation tool used to setup a system for containers"
    echo ""
    echo "---------------------------------------------"
    echo ""

    local choice_state=false

    while [[ $choice_state == false ]]; do
        echo "    - Setup your system [1]"
        echo "    - Setup a new container [2]"
        echo "    - Setup the backup [3]"
        echo "    - Reset the server [4]"

	    echo ""
        read -p "What would you like to do: " user_choice
        case $user_choice in
            1)
                vps_setup_single
                choice_state=true
                ;;
            2)
            	create_container
            	choice_state=true
            	;;
            3)
                backup_server
            	choice_state=true
                	;;
            4)
                reset_server
                choice_state=true
                ;;
            *)
            	echo "Wrong input"
            	;;
    	esac
    done

}

main "$@"