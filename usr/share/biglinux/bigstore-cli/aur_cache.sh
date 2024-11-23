#!/usr/bin/env bash

#  Created: 2024/01/15
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
# shellcheck source=/usr/share/biglinux/bigstore-cli/config.sh
. /usr/share/biglinux/bigstore-cli/config.sh

# Folder to save list of packages
FileToSaveCacheFiltered="$cacheFolder/aur_filtered.json"
FileToInstalledPackagesFile="$cacheFolder/installed_packages_not_in_repository.cache"
FileToInstalledPackagesObsolete="$cacheFolder/installed_packages_obsolete.json"

# Create a temporary file with installed packages and their versions
pacman -Qm >"$FileToInstalledPackagesFile" &

# Original json file
originalJsonFile="$cacheFolder/packages-meta-ext-v1.json"

# verify if exist '/var/tmp/pamac/aur_filtered.json' and if is less than 10MB
if [[ ! -e $originalJsonFile || $(stat -c %s "$originalJsonFile") -le 10485760 ]]; then
    echo "Cache file '$originalJsonFile' not found or less than 10MB, attempting download now."

    aur_download.sh
    if [[ $? -eq 0 ]]; then
        echo "Download of AUR database completed successfully. Continuing..."
        if [[ ! -e $originalJsonFile || $(stat -c %s "$originalJsonFile") -le 10485760 ]]; then
            echo "Cache file '$originalJsonFile' is less than 10MB, which might indicate an error."
            echo "Trying to generate a new cache file."
            exit
        fi
    else
        echo "Download of AUR database failed. Try again..."
        exit
    fi
fi

# Translate descriptions
DisableTranslate="false"

# Check if the first argument is empty
if [[ -z $1 ]]; then
    # If the system locale file exists for the language with the country code
    if [[ -e $localeFolder/${LANG%.*}.txt ]]; then
        localeFile="$localeFolder/${LANG%.*}.txt"

    # If the system locale file exists for the language without the country code
    elif [[ -e $localeFolder/${LANG:0:2}.txt ]]; then
        localeFile="$localeFolder/${LANG:0:2}.txt"

    else
        # If no locale file is found, display an error message and run without translated descriptions
        echo "Locale file not found: $localeFile
        Running without translation."
        DisableTranslate="true"
    fi

elif [[ "$1" == "disable-translate" ]]; then
    DisableTranslate="true"

elif [[ "$1" =~ "help" ]]; then
    echo "Usage: aur_cache_with_translation.sh [language code]
    Example: aur_cache_with_translation.sh pt_BR
    Example: aur_cache_with_translation.sh disable-translate
    Not use any argument to use the system locale.
    Files for translation must be in the folder: $localeFolder"
    exit 0

else
    if [[ -e $localeFolder/$1.txt ]]; then
        localeFile="$localeFolder/$1.txt"

    else
        echo "Locale file not found: $localeFile
        Running without translation."
        DisableTranslate="true"
    fi
fi

if [[ "$1" == "disable-translate" ]]; then
    DisableTranslate="true"
fi

# Create the folder to save files if it doesn't exist
if [[ ! -e $cacheFolder ]]; then
    mkdir -p $cacheFolder
fi

# jaq is slightly faster than jq
if type jaq >/dev/null 2>&1; then
    jqBinary="jaq"
else
    jqBinary="jq"
fi

wait # Wait for pacman -Qm to finish

# If the locale file exists, and not manual disabled the translation, use the translated description
if [[ "$DisableTranslate" == "false" ]]; then

    awk_translate="-v localeFile=$localeFile"
    awk_file="$awk_folder/aur_cache_with_translate.awk"
else

    awk_translate=''
    awk_file="$awk_folder/aur_cache_without_translate.awk"
fi

# Read translations from the translations.txt file into an associative array
# In -v FS="\u0001", set the field separator to the unicode character \u0001
# In -v installedPackagesFile="$FileToInstalledPackagesFile", pass the installed packages file path to awk, file generated by pacman -Qm
# Import the awk script, because the script is too long
$jqBinary -r '.[] | "\(.Name)\u0001\(.Description)\u0001\(.Version)\u0001\(.NumVotes)\u0001\(.Popularity)\u0001\(.OutOfDate)\u0001\(.Maintainer)"' /var/tmp/pamac/packages-meta-ext-v1.json |
    awk -v FS="\u0001" -v installedPackagesFile="$FileToInstalledPackagesFile" $awk_translate -f $awk_file > "$FileToSaveCacheFiltered"

# Read the list of installed packages that are not in the repository
# Remove the packages that are in the AUR from the list, leaving only the obsolete ones
# Include the description and convert to JSON format
PackagesObsoleteFilter=$(rg -o '.*p":"([^"]*).*,"i":"true"' -r '-ve $1 ' "$FileToSaveCacheFiltered" | tr '\n' ' ')

if [[ -n $PackagesObsoleteFilter ]]; then

    LANG=C pacman -Qi $(rg -N $(rg -o '.*p":"([^"]*).*,"i":"true"' -r '-ve $1 ' "$FileToSaveCacheFiltered" | tr '\n' ' ') $FileToInstalledPackagesFile | rg -o '.* ') | rg '^Name |^Version |^Description ' | awk '
BEGIN {print "["}
/Name/ {if (NR!=1) print "},"
        gsub("Name            : ", "");
        printf "{\"p\":\"" $0 "\""}
/Version/ {gsub("Version         : ", "");
            printf ", \"v\":\"" $0 "\""}
/Description/ {gsub("Description     : ", "");
                printf ", \"d\":\"" $0 "\""}
END {print "},\n{}]" }' >"$FileToInstalledPackagesObsolete"

fi
