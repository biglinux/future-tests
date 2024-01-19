#!/usr/bin/env bash

#  2023-2023, Bruno Gonçalves <www.biglinux.com.br>
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

# This script retrieves information about a package from the Pacman package manager in Arch Linux.
# It first tries to get detailed information about the package using the `pacman -Sii` command.
# If the command fails, it falls back to using the `pacman -Qi` command to get basic information.
# If both commands fail, the script exits with an error.

pacmanInfo="$(LANG=C pacman -Sii $1)"
if [[ $? != 0 ]]; then
  pacmanInfo="$(LANG=C pacman -Qi $1)"
    if [[ $? != 0 ]]; then
      exit 1
    fi
fi

# Break line after echo because if have package in more than one repository, the preferred repository is the first
# and separate with a blank line, to help filter verify break line, and add a blank line in the end for just one result
echo "$pacmanInfo
" | grep -E -B 999  -m1 '^$' | \
awk -v RS="" '{
  split($0, lines, "\n");
  print "{";
  for (i in lines) {
    if (lines[i] ~ /^(Repository|Name|Version|Description|Architecture|URL|Licenses|Download Size|Installed Size|Packager|Build Date|MD5 Sum|SHA-256 Sum|Signatures)/) {
      split(lines[i], kv, / : /);
      gsub(/"/, "\\\"", kv[2]);
      kv[1] = gensub(/ +$/, "", "g", kv[1]);  # Trim trailing spaces in key
      print "\"" kv[1] "\": \"" kv[2] "\",";
    }
    else if (lines[i] ~ /^(Groups|Provides|Depends On|Optional Deps|Required By|Optional For|Conflicts With|Replaces)/) {
      split(lines[i], kv, / : /);
      kv[1] = gensub(/ +$/, "", "g", kv[1]);  # Trim trailing spaces in key
      printf "\"" kv[1] "\": [";
      n = split(kv[2], values, /  /);
      for (j=1; j<=n; j++) {
        gsub(/"/, "\\\"", values[j]);
        if (values[j] != "None" && values[j] != "") {
          printf "\"" values[j] "\"";
          if (j < n) printf ", ";
        }
      }
      print "],";
    }
  }
  print "\"end\":\"\"}"
}' | \
jq  'del(.end) |
      .Groups |= if . == [""] then null else . end |
      .Provides |= if . == [""] then null else . end |
      .["Depends On"] |= if . == [""] then null else . end |
      .["Optional Deps"] |= if . == [""] then null else . end |
      .["Required By"] |= if . == [""] then null else . end |
      .["Optional For"] |= if . == [""] then null else . end |
      .["Conflicts With"] |= if . == [""] then null else . end |
      .Replaces |= if . == [""] then null else . end'

