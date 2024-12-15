#!/bin/bash

# Initialize variables to store packages to be installed and removed
pkgs_to_install=""
pkgs_to_remove=""

# Check if pacman is locked by another process
if [ -f /var/lib/pacman/db.lck ]; then
    # Use fuser to verify if the lock file is really in use
    if ! fuser -s /var/lib/pacman/db.lck; then
        rm -f /var/lib/pacman/db.lck
    else
        echo "Pacman is locked by another process"
        ps -f -p $(fuser /var/lib/pacman/db.lck | cut -f2 -d':')
        exit 1
    fi
fi

# Determine the correct version of pactrans to use based on system configuration
if [[ ! -e /usr/share/biglinux/pactrans/bin/pactrans ]] || ldd "/usr/share/biglinux/pactrans/bin/pactrans" | grep -q "=> not found"; then
    pacinstall_cmd="pactrans-overwrite-static"
else
   pacinstall_cmd="pactrans-overwrite"
fi

# Check if unbuffer command is available and assign it to a variable
if [[ -e /usr/bin/unbuffer ]]; then
    unbuffer_cmd='/usr/bin/unbuffer'
fi

# Function to display usage help
function show_help() {
    echo "Usage: $0 [options] [...packages]"
    echo "Options:"
    echo "  --install                                  Install specified packages"
    echo "  --remove                               Remove specified packages"
    echo "  --upgrade                             Upgrade packages"
    echo "  --reinstall-keys                    Reinstalls keyring packages. This process may take a few minutes"
    echo "  --force-reinstall-keys          Caution, this method disables PGP key verification to force install"
    echo "  --json                                    Output the transaction in JSON format"
    echo "  --help                                    Displays this help message"
    echo "  --apply                                  Apply the transaction in the system"
    echo ""
    echo "You can combine --install, --remove, and --upgrade in the same execution."
}

# Function to reinstall keyring packages
function reinstall_keys {
    # Filtering installed keyring packages by folders in /var/lib/pacman/local
    shopt -s extglob # enable extglob
    cd /var/lib/pacman/local
    if verify_key_pkgs=(@(archlinux|manjaro|biglinux)-keyring-*); then
        key_pkgs=${verify_key_pkgs[@]/keyring-*/keyring}
    fi
    cd -
    shopt -u extglob # disable extglob

    # Reinitialize and repopulate the keyring
    pacman-key --init
    pacman-key --populate
    $pacinstall_cmd --dbsync --yolo --overwrite --resolve-replacements=provided --install $key_pkgs 2>&1 | jq -Rn -f jq/pactrans.jq | tee /var/log/pacman.json
}

# Check if no arguments are provided and display help
if [ $# -eq 0 ]; then
    show_help
    exit 1
fi

# Process script arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)
            shift # Remove --install from argument list
            while [[ $# -gt 0 ]] && ! [[ "$1" =~ ^-- ]]; do
                pkgs_to_install+="$1 "
                shift
            done
            ;;
        --remove)
            shift # Remove --remove from argument list
            while [[ $# -gt 0 ]] && ! [[ "$1" =~ ^-- ]]; do
                pkgs_to_remove+="$1 "
                shift
            done
            ;;
        --upgrade)
            shift # Remove --upgrade from argument list
            sysupgrade='--sysupgrade'
            ;;
        --json)
            shift # Remove --json from argument list
            output_type='json'
            ;;
        --apply)
            shift # Remove --apply from argument list
            apply_in_system='true'
            ;;
        --reinstall-keys)
            reinstall_keys
            exit
            ;;
        --force-reinstall-keys)
            # Disable PGP key verification temporarily to reinstall keys
            sed -Ei 's|SigLevel += +PackageRequired|SigLevel = Never|g' /etc/pacman.conf
            reinstall_keys
            # Restore PGP key verification
            sed -Ei 's|SigLevel += +Never|SigLevel = PackageRequired|g' /etc/pacman.conf
            # Refresh keys, using Ubuntu's keyserver if necessary
            if [[ $(grep -Ec 'keyserver +hkp' /etc/pacman.d/gnupg/gpg.conf) -lt 2 ]]; then
                pacman-key --refresh-keys -u --keyserver hkp://keyserver.ubuntu.com:80
            else
                pacman-key --refresh-keys
            fi
            exit
            ;;
        --help)
            show_help
            exit
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Remove packages with cascade if pkgs_to_remove is not empty
if [ -n "$pkgs_to_remove" ]; then
    remove_pkgs="--remove $(pactrans --print-only --yolo $use_resolve_replacements --remove --cascade --recursive $pkgs_to_remove  2>&1 |  awk -F '[ /]+' '/^removing local/ {printf "%s ", $3;}')"
fi

# Set install_pkgs if pkgs_to_install is not empty
if [ -n "$pkgs_to_install" ]; then
    install_pkgs="--install $pkgs_to_install"
fi

use_resolve_replacements='--resolve-replacements=provided'

# Verify the transaction and try again with resolve-replacements=provided if needed
echo "Verifying transaction..."
pacinstall_output=$($pacinstall_cmd --print-only --dbsync --yolo --overwrite $use_resolve_replacements $sysupgrade $install_pkgs $remove_pkgs  2>&1 | grep -v 'is newer than' | tee /var/log/pacman-log-complete.pactrans | jq -Rn -f jq/pactrans.jq | tee /var/log/pacman.json)

if [ -z "$pacinstall_output" ]; then
    echo "Verifying package replacements..."
    use_resolve_replacements='--resolve-replacements=all'
    pacinstall_output=$($pacinstall_cmd --print-only --dbsync --yolo --overwrite $use_resolve_replacements $sysupgrade $install_pkgs $remove_pkgs  2>&1 | grep -v 'is newer than' | tee /var/log/pacman-log-complete.pactrans | jq -Rn -f jq/pactrans.jq | tee /var/log/pacman.json)
fi

if [ -z "$pacinstall_output" ]; then
    echo "nothing to do"
    exit
fi

if grep -q 'unresolvable package conflicts detected' /var/log/pacman-log-complete.pactrans; then
    use_resolve_replacements='--resolve-replacements=all'
    pacinstall_output=$($pacinstall_cmd --print-only --yolo --overwrite $use_resolve_replacements $sysupgrade $install_pkgs $remove_pkgs  2>&1 | tee /var/log/pacman-log-complete.pactrans | jq -Rn -f jq/pactrans.jq | tee /var/log/pacman.json)
fi

if grep -q 'error: no targets provided.' /var/log/pacman-log-complete.pactrans && [[ $(echo "$(</var/log/pacman-log-complete.pactrans)" | wc -l) == 1 ]]; then
    echo "Package not found"
    exit
fi

# Check if sysupgrade is empty and pacinstall output contains an error, then try with --sysupgrade
if [[ -z $sysupgrade ]] && echo "$pacinstall_output" | grep -q '"type": "error",'; then
    sysupgrade='--sysupgrade'
    pacinstall_output=$($pacinstall_cmd --print-only --yolo --overwrite $use_resolve_replacements $sysupgrade $install_pkgs $remove_pkgs  2>&1 | tee /var/log/pacman-log-complete.pactrans | jq -Rn -f jq/pactrans.jq | tee /var/log/pacman.json)
fi

# Handle missing dependency errors
missing_dependency_pkgs=$(awk -F"'" '$1 ~ "error: missing dependency " {printf " " $4}' /var/log/pacman-log-complete.pactrans | tr ' ' '\n' | sort -u | tr '\n' ' ')

if [[ -n "$missing_dependency_pkgs" ]]; then
    use_resolve_replacements='--resolve-replacements=provided'
    missing_dependency_pkgs_depended=$(awk -F"'" '$1 ~ "error: missing dependency " {printf " " $2}' /var/log/pacman-log-complete.pactrans | tr ' ' '\n' | sort -u | tr '\n' ' ')

    # Try to install depended packages first
    missing_dependency_pkgs_install=$($pacinstall_cmd --print-only --yolo --overwrite $use_resolve_replacements $sysupgrade --install $missing_dependency_pkgs_depended  2>&1)

    if echo "$missing_dependency_pkgs_install" | grep -q 'error: could not locate package'; then
        package_not_found=$(awk -F"'" '$1 ~ "error: could not locate package " {print $2}' <<<"$missing_dependency_pkgs_install")
        missing_dependency_pkgs_install=$(echo "$missing_dependency_pkgs_depended" | tr ' ' '\n' | grep -vxf <(echo "$package_not_found") | sort -u | tr '\n' ' ')

        # If install_pkgs is not empty, add missing_dependency_pkgs_install to it
        install_pkgs=${install_pkgs:+$install_pkgs $missing_dependency_pkgs_install}
        # If install_pkgs is empty, create it with missing_dependency_pkgs_install
        install_pkgs=${install_pkgs:---install $missing_dependency_pkgs_install}

        else
        # If install_pkgs is not empty, add missing_dependency_pkgs_install to it
        install_pkgs=${install_pkgs:+$install_pkgs $missing_dependency_pkgs_depended}
        # If install_pkgs is empty, create it with missing_dependency_pkgs_install
        install_pkgs=${install_pkgs:---install $missing_dependency_pkgs_depended}
    fi
    
        pacinstall_output=$($pacinstall_cmd --print-only --yolo --overwrite $use_resolve_replacements $sysupgrade $install_pkgs $remove_pkgs  2>&1 | tee /var/log/pacman-log-complete.pactrans | jq -Rn -f jq/pactrans.jq | tee /var/log/pacman.json)

        missing_dependency_pkgs=$(awk -F"'" '$1 ~ "error: missing dependency " {printf " " $4}' /var/log/pacman-log-complete.pactrans)

    if [[ -n $missing_dependency_pkgs ]]; then 
        missing_dependency_pkgs_recursive=$($pacinstall_cmd --print-only --yolo --overwrite $use_resolve_replacements --remove --cascade --recursive $missing_dependency_pkgs  2>&1 |  awk -F '[ /]+' '/^removing local/ {printf "%s ", $3;}')

        # If remove_pkgs is not empty, add missing_dependency_pkgs_recursive to it
        remove_pkgs=${remove_pkgs:+$remove_pkgs $missing_dependency_pkgs_recursive}
        # If remove_pkgs is empty, create it with missing_dependency_pkgs_recursive
        remove_pkgs=${remove_pkgs:---remove $missing_dependency_pkgs_recursive}
    fi
fi

# Update pacinstall_output if broken_pkgs_without_not_locate or missing_dependency_pkgs_recursive is not empty
if [[ -n "$broken_pkgs_without_not_locate" ]] || [[ -n "$missing_dependency_pkgs_recursive" ]]; then
    pacinstall_output=$($pacinstall_cmd --print-only --yolo --overwrite $use_resolve_replacements $sysupgrade $install_pkgs $remove_pkgs  2>&1 | tee /var/log/pacman-log-complete.pactrans | jq -Rn -f jq/pactrans.jq | tee /var/log/pacman.json)
fi

# Output the transaction based on the output_type
if [[ "$apply_in_system" != "true" ]]; then
    if [[ "$output_type" == "json" ]]; then
        echo "$pacinstall_output"
    else
        ##################### CLI OUTPUT START

        # Show general info
        grep -vE '^installing|^removing|^Download Size:|^Installed Size:|^Size Delta:|up to date -- reinstalling' /var/log/pacman-log-complete.pactrans

        # Show info about installing, removing, and updating packages
        awk -F'[ /()]' '
            $1 == "installing" && $7 != "" && $5 != $7 { print "1 \033[33mupdate \033[0m " $3 " \033[36m" $5 " " $6 " " $7 "|||" $2 }
            $1 == "installing" && $7 != "" && $5 == $7 { print "1 \033[35mreinstall \033[0m" $3 " \033[36m" $5 "|||" $2 }
            $1 == "installing" && $7 == "" { print "2 \033[32minstall\033[0m " $3 " \033[36m" $5 "|||" $2}
            $1 == "removing" { print "3 \033[31mremove \033[0m " $3 " \033[36m" $5 }
        ' /var/log/pacman-log-complete.pactrans | sort | cut -f2- -d" " | column -t -s'|||'

        # Show info about replacing and selecting packages to solve dependencies
        awk -F"'" '
            $1 == ":: replacing package " && $2 != "" { print "\033[34mreplace \033[0m" $2 "\033[36m with \033[0m" $4 }
            $1 == ":: uninstalling package " && $2 != "" { print "\033[34mreplace \033[0m" $2 "\033[36m with \033[0m" $4}
            $1 == ":: selecting package " && $2 != "" { print "\033[35mselect  \033[0m" $2 " \033[36mto \033[0m" $4}
        ' /var/log/pacman-log-complete.pactrans | sort

        # Show info about download size, installed size, and size delta
        echo -e "\033[0m"
        grep -E '^Download Size:|^Installed Size:|^Size Delta:' /var/log/pacman-log-complete.pactrans

        # Ask user if they want to apply the changes
        echo -e "\033[1;33m"
        echo -en "Do you want to apply these changes to the system? \033[0m (y/n): "
        read -r response

        if [[ "$response" =~ ^[YySs]$ ]]; then
            apply_in_system="true"
        fi

        ##################### CLI OUTPUT END
    fi
fi

# Apply the transaction in the system (CLI output)
if [[ "$apply_in_system" == "true" ]] && [[ "$output_type" != "json" ]]; then
    # Ensure that key packages are installed before other upgrades
    sync_first=$(pacman -Quq $(awk -F'=' '$1 ~ "^ *SyncFirst" {print $2}'  /etc/pacman.conf) 2>&- | tr '\n' ' ')
    if [ -n "$sync_first" ]; then
         $pacinstall_cmd --yolo --overwrite $use_resolve_replacements --install $sync_first 2>&1 | tee /var/log/pacman-log-complete.pactrans
    fi

    # if [[ -n "$use_resolve_replacements" ]]; then
        # Upgrade or installation processes with resolve-replacements=provided
        # $pacinstall_cmd --yolo --overwrite $use_resolve_replacements $sysupgrade $install_pkgs $remove_pkgs 2>&1 | tee /var/log/pacman-log-complete.pactrans

        # Run another time without resolve-replacements=provided
        # $pacinstall_cmd --yolo --overwrite $sysupgrade $install_pkgs $remove_pkgs 2>&1 | tee /var/log/pacman-log-complete.pactrans
    # else
        # Run without resolve-replacements=provided
        $pacinstall_cmd --yolo --overwrite $use_resolve_replacements $sysupgrade $install_pkgs $remove_pkgs 2>&1 | tee /var/log/pacman-log-complete.pactrans
    # fi
fi

# Apply the transaction in the system (JSON output)
if [[ "$apply_in_system" == "true" ]] && [[ "$output_type" == "json" ]]; then
    # Ensure that key packages are installed before other upgrades
    sync_first=$(pacman -Quq $(awk -F'=' '$1 ~ "^ *SyncFirst" {print $2}'  /etc/pacman.conf) 2>&- | tr '\n' ' ')
    if [ -n "$sync_first" ]; then
        $unbuffer_cmd $pacinstall_cmd --yolo --overwrite $use_resolve_replacements --install $sync_first 2>&1 | tee /var/log/pacman-log-complete.pactrans | jq --unbuffered -Rn -f jq/pactrans.jq | tee /var/log/pacman.json
    fi

    if [[ -n "$use_resolve_replacements" ]]; then
        # Upgrade or installation processes with resolve-replacements=provided
        $unbuffer_cmd $pacinstall_cmd --yolo --overwrite $use_resolve_replacements $sysupgrade $install_pkgs $remove_pkgs 2>&1 | tee /var/log/pacman-log-complete.pactrans | jq --unbuffered -Rn -f jq/pactrans.jq | tee /var/log/pacman.json

        # Run another time without resolve-replacements=provided
        $unbuffer_cmd $pacinstall_cmd --yolo --overwrite $use_resolve_replacements $sysupgrade $install_pkgs $remove_pkgs 2>&1 | tee /var/log/pacman-log-complete.pactrans | jq --unbuffered -Rn -f jq/pactrans.jq | tee /var/log/pacman.json
    else
        # Run without resolve-replacements=provided
        $unbuffer_cmd $pacinstall_cmd --yolo --overwrite $use_resolve_replacements $sysupgrade $install_pkgs $remove_pkgs 2>&1 | tee /var/log/pacman-log-complete.pactrans | jq --unbuffered -Rn -f jq/pactrans.jq | tee /var/log/pacman.json
    fi
fi

# Verify key error and try reinstalling keys
if grep -q -e 'could not be looked up remotely key' -e 'invalid or corrupted package (PGP signature)' /var/log/pacman-log-complete.pactrans; then
    reinstall_keys
fi
