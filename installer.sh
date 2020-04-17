#!/bin/bash
echo "#######################################################"
echo "     Duplicity-lvm-snapshot installer"
echo "#######################################################"
echo "First we need to generate a password for encrypting the snapshots"
echo "The password length should be at least 20 chars"
# read -p 'How long should this password be: ' varname

while [ ! ${finished} ]
do
read -p 'How long should this password be: ' input
    if [[ "$input" -lt 20 ]]; then
        echo "The given input is not acceptable! Please, set an integer which is greater then 20!"
    else
        finished=true
    fi
done

echo "$(pwgen ${input})"


# if [[ ${varname} -gt 0 ]]; then
#     sed 's/{{ password }}/'$(pwgen ${varname})'/g' settings.json > settings_new.json
# fi
