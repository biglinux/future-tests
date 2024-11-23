#!/usr/bin/env bash

#  Created: 2024/01/17
#
#  Copyright (c) 2023-2024, Bruno Gonçalves <www.biglinux.com.br>
#  All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#
#  THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
#  IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
#  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
#  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
#  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
#  NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
#  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
#  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
#  THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Load config file
source /usr/share/biglinux/bigstore-cli/config.sh

# Load JSON file for search
pacmanResult="$cacheFolderHome/pacmanResult.txt"
aurResult="$cacheFolderHome/aurResult.txt"
flatpakResult="$cacheFolderHome/flatpakResult.txt"
snapResult="$cacheFolderHome/snapResult.txt"

numberOfTotalResults="$cacheFolderHome/numberOfTotalResults.json"

# Defining the paths of the scripts
aurSearchScript="/usr/share/biglinux/bigstore-cli/aur_search.sh"
pacmanSearchScript="/usr/share/biglinux/bigstore-cli/pacman_search.sh"
flatpakSearchScript="/usr/share/biglinux/bigstore-cli/flatpak_search.sh"
snapSearchScript="/usr/share/biglinux/bigstore-cli/snap_search.sh"

# Initialize search mode flags
searchAur=false
searchPacman=false
searchFlatpak=false
searchSnap=false

# Checking if the -j parameter was provided
jsonMode=false
if [ "$1" = "-j" ]; then
    jsonMode=true
    shift # Remove the -j parameter from the arguments
fi

# Process each argument
for arg in "$@"
do
    case $arg in
        --aur)
            searchAur=true
            shift # Remove the --aur parameter
            ;;
        --pacman)
            searchPacman=true
            shift # Remove the --pacman parameter
            ;;
        --flatpak)
            # Verify if Flatpak is installed
            if [[ -e /usr/bin/flatpak ]]; then
                searchFlatpak=true
            fi
            shift # Remove the --flatpak parameter
            ;;
        --snap)
            # Verify if Snap is installed
            if [[ -e /usr/bin/snap ]]; then
                searchSnap=true
            fi
            shift # Remove the --snap parameter
            ;;
        --help)
            echo "Usage: $0 [options] [search term]"
            echo "Without arguments, it will search all."
            echo ""
            echo "Options:"
            echo "    --help      Show this help message"
            echo "    --aur       Search only in AUR"
            echo "    --flatpak   Search only in Flatpak"
            echo "    --pacman    Search only in Pacman"
            echo "    --snap      Search only in Snap"
            echo "    -j          Output in JSON format"
            exit 0
            ;;
        *)
            # Unknown option or search term
            ;;
    esac
done

# If no specific search mode is selected, search all
if ! $searchAur && ! $searchPacman && ! $searchFlatpak && ! $searchSnap; then
    searchPacman=true
    searchAur=true
    if [ "$(systemctl is-active --user flatpak-portal.service)" = "active" ];then
        searchFlatpak=true
    fi
    if [ "$(systemctl is-active snapd.socket)" = "active" ];then
        searchSnap=true
    fi
fi

# Execute the search based on selected modes
execute_search() {
    if $searchAur; then
        $aurSearchScript "$@" > $aurResult &
    fi
    if $searchPacman; then
        $pacmanSearchScript "$@" > $pacmanResult &
    fi
    if $searchFlatpak; then
        $flatpakSearchScript "$@" > $flatpakResult &
    fi
    if $searchSnap; then
        $snapSearchScript "$@" > $snapResult &
    fi
    wait
    
    if $jsonMode; then

        if [[ $searchAur = true ]]; then
            numberOfResultsAur=$(LANG=C wc -l "$aurResult" | cut -f1 -d" ")
            sort "$aurResult" | head -n500
        fi
        if [[ $searchPacman = true ]]; then
            numberOfResultsPacman=$(LANG=C wc -l "$pacmanResult" | cut -f1 -d" ")
            sort "$pacmanResult" | head -n500
        fi
        if [[ $searchFlatpak = true ]]; then
            numberOfResultsFlatpak=$(LANG=C wc -l "$flatpakResult" | cut -f1 -d" ")
            sort "$flatpakResult" | head -n500
        fi
        if [[ $searchSnap = true ]]; then
            numberOfResultsSnap=$(LANG=C wc -l "$snapResult" | cut -f1 -d" ")
            sort "$snapResult" | head -n500
        fi
        
        # Print the number of results for each search mode in json format
        echo "
            {\"numberOfResults\": {
                \"AUR\": \"$numberOfResultsAur\",
                \"Pacman\": \"$numberOfResultsPacman\",
                \"Flatpak\": \"$numberOfResultsFlatpak\",
                \"Snap\": \"$numberOfResultsSnap\"
                }
            }
        " > $numberOfTotalResults

    else

        [ $searchAur = true ] && cat "$aurResult"
        [ $searchPacman = true ] && cat "$pacmanResult"
        [ $searchFlatpak = true ] && cat "$flatpakResult"
        [ $searchSnap = true ] && cat "$snapResult"

    fi
}

# Processing the output based on the mode
if $jsonMode; then
    # JSON Mode
    echo '['
    execute_search -j "$@" | LANG=C sort | LANG=C cut -d' ' -f2- | sed '$ s/,$//'
    echo ']'
else
    # Terminal Mode
    execute_search "$@" | LANG=C sort -r | LANG=C cut -d' ' -f2- | LANG=C sed 's|\t,,,|\n    |g' | sed '$ s/,$//'
fi
