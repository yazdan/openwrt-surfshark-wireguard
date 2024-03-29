#!/bin/bash
set -e
#
#get location of script
#
SCRIPT=$(readlink -f $0)
SCRIPTPATH=`dirname $SCRIPT`
cd $SCRIPTPATH

read_config() {
    config_file=$"config.json"
    config_folder=$(eval echo $(jq '.config_folder' ${config_file}))

    wg_keys=${config_folder}/wg.json
    token_file=${config_folder}/token.json
    token_expires=${config_folder}/token_expires.json
    sswg_log=${config_folder}/sswg.log

    baseurl_1="https://api.surfshark.com"
    baseurl_2="https://ux.surfshark.com"
    baseurl_3="https://api.uymgg1.com"
    baseurl_4="https://ux.uymgg1.com"
    baseurl_5="https://api.surf-chiny.com"
    baseurl_6="https://ux.surf-chiny.com"
    urlcount=6

    generic_servers_file=${config_folder}/generic_servers.json
    static_servers_file=${config_folder}/static_servers.json
    obfuscated_servers_file=${config_folder}/obfuscated_servers.json
    double_servers_file=${config_folder}/double_servers.json

    generate_conf=1
    reset_all=0
    check_status=0
    generate_servers=0
    renew_token=0
}

parse_arg() {
    while getopts 'hgnrZk:' opt; do
        case "$opt" in
            Z)  reset_all=1         ;;
            g)  generate_conf=0     ;;
            n)  renew_token=1       ;;
            k)  wg_prv="$OPTARG"    ;;
            r)  generate_servers=1  ;;
            ?|h)
            echo "Usage: $(basename $0) [-h]"
            echo "  -g ignore generating profile files"
            echo "  -n renew tokens"
            echo "  -r regenerate the server conf files"
            echo "  -Z clear settings, keys and server profile files"
            echo "  -k <key> use provided private key"
            exit 1                  ;;
        esac
    done
    shift "$(($OPTIND -1))"
}

wg_login() { #login and recieve jwt token and renewal token
    username=$(eval echo $(jq '.username' ${config_file}))
    password=$(eval echo $(jq '.password' ${config_file}))
    tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
    http_status=0
    basen=0
    until [ $http_status -eq 200 ]; do
        let basen=$basen+1; baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            echo "[wg_login] Unable to login, check your credentials."
            rm $tmpfile
            exit 100
        fi
        url=$(eval echo \${$baseurl})/v1/auth/login
        data='{"username":"'${username}'","password":"'${password}'"}'
        http_status=$(curl -o $tmpfile -w "%{http_code}" -d "$data" -H 'Content-Type: application/json' -X POST $url)
        echo "[$(date -Iseconds)] [wg_login] Login "$url $http_status $(cat $tmpfile) >> $sswg_log
    done
    rm -f $token_file
    echo $(cat $tmpfile | jq '.') >> $token_file
    rm $tmpfile
}

wg_gen_keys() { # generate priavte/public key pair
    if [ -z "$wg_prv" ]; then
        echo "[wg_gen_keys] generating new keys"
        wg_prv=$(wg genkey)
    else
        echo "[wg_gen_keys] generating public key"
    fi
    wg_pub=$(echo $wg_prv | wg pubkey)
    rm -f $wg_keys
    echo -e "{\n\t\"pub\":\"$wg_pub\",\n\t\"prv\":\"$wg_prv\"\n}" >> $wg_keys
}

wg_register_pub() { # check to see if the public key has been registered and/or there is an unexpired token & run appropriate modules
    if [ ! -f ${token_expires} ] && [ -f ${wg_keys} ]; then
        if wg_reg_pubkey; then
            true
        else
            reg_exit_code=$?
            if [ $reg_exit_code -ne 113 ]; then
                exit $reg_exit_code
            fi
        fi
        wg_check_pubkey
    elif [ "$(jq -r '.expiresAt' $token_expires)" '<' "$(date -Iseconds -u)" ]; then
        wg_token_renwal
        wg_check_pubkey
    elif [ -f "${wg_keys}" ]; then
        wg_check_pubkey
    else
        rm -f ${token_file} ${wg_keys}
        wg_login
        wg_gen_keys
        wg_reg_pubkey || exit $?
        wg_check_pubkey
    fi
}

wg_user_status() { # get current status of user
    url=$baseurl_1/v1/server/user
    token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
    user_status=$(curl -H "${token}" -H "Content-Type: application/json" ${url} | jq '.')
    echo "[$(date -Iseconds)] [wg_user_status] User Status "$url $user_status >> $sswg_log
    if [ $(echo $user_status | jq '.secured') ]; then
        echo "[wg_user_status] surfshark wireguard is currently on and your IP info is "$(echo $user_status | jq '.ip, .city, .country')
    else
        echo "[wg_user_status] surfshark wireguard is currently off and your IP info is "$(echo $user_status | jq '.ip, city, .country')
    fi
}

wg_reg_pubkey() { # register the public key using the jwt token 
    basen=1
    error_count=0
    key_reg=
    tmpfile=$(mktemp /tmp/wg-curl-val.XXXXXX)
    until [ -n "$(echo "$key_reg" | jq -r '.expiresAt')" ]; do
        baseurl=baseurl_$basen
        url=$(eval echo \${$baseurl})/v1/account${url}/users/public-keys
        data='{"pubKey": "'$wg_pub'"}'
        token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
        http_status=$(curl -o "$tmpfile" -s -w "%{http_code}" -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST "${url}")
        let basen=$basen+2

        if [ $basen -gt $urlcount ] &&
            [ "$http_status" -lt 200 ] || [ "$http_status" -gt 202 ]; then
            key_reg=$(cat "$tmpfile")
            rm "$tmpfile"

            if [ "$http_status" -eq 400 ]; then
                echo "[wg_reg_pubkey] Curl post appears to be malformed"
                return 110
            elif [ "$http_status" -eq 401 ]; then
                if [ -z "${key_reg##*Expired*}" ] && [ $error_count -eq 0 ]; then
                    wg_token_renwal
                    error_count=1
                    basen=1
                elif [ -z "${key_reg##*Expired*}" ] && [ $error_count -eq 1 ]; then
                    echo "[wg_reg_pubkey] Token is expiring immediately."
                    return 111
                elif [ -z "${key_reg##*Token not found*}" ]; then
                    echo "[wg_reg_pubkey] Token was not recognised as a token."
                    echo "[wg_reg_pubkey] If it fails repeatedly check your credentials and that a token exists."
                    return 112
                fi
            elif [ "$http_status" -eq 409 ]; then
                echo "[wg_reg_pubkey] Trying to register a key that is already registered"
                return 113
            fi

            echo "[wg_reg_pubkey] Got HTTP error: $http_status, $key_reg"
            return 114
        fi

        key_reg=$(jq '.' "$tmpfile")
        echo "[$(date -Iseconds)] [wg_reg_pubkey] Registration "$url $key_reg >> $sswg_log
    done
    rm -f $token_expires
    echo "${key_reg}" >> $token_expires
    echo "[wg_reg_pubkey] token requires renewing prior to "$(eval echo $(jq '.expiresAt' $token_expires))
    rm "$tmpfile"
}

wg_udpate_expire_token() {
    key_data="$1"

    if  [ ! -f "$token_expires" ] ||
        [ "$(echo "$key_data" | jq -r '.expiresAt')" != "$(jq -r '.expiresAt' "$token_expires")" ]; then
        expire_date=$(echo "$key_data" | jq -r '.expiresAt')
        now=$(date -Iseconds -u)
        if [ "${now}" '<' "${expire_date}" ]; then
            echo "Current Date & Time  "${now}          # Display Run Date
            echo "Token will Expire at "${expire_date}  # Display Token Expiry
            logger -t SSWG "[wg_check_pubkey] RUN DATE:${now}   TOKEN EXPIRES ON: ${expire_date}" # Log Status Information (logread -e SSWG)
        fi
        echo "${key_data}" > "$token_expires"
        echo "[wg_check_pubkey] token requires renewing prior to $expire_date"
    fi
}

wg_get_registered() {
    tmpfile=$(mktemp /tmp/wg-curl-val.XXXXXX)
    http_status=0
    basen=1

    until [ "$http_status" -eq 200 ]; do
        baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            return 1
        fi

        url=$(eval echo \${"$baseurl"})/v1/account/users/public-keys
        token="Authorization: Bearer $(jq -r '.token' "$token_file")"
        http_status=$(curl -o "$tmpfile" -s -w "%{http_code}" -H "${token}" \
            -H "Content-Type: application/json" -d "${data}" -X GET "${url}")
        let basen=$basen+2
    done

    cat "$tmpfile"
    rm -f "$tmpfile"
}

wg_check_registered_pubkeys() {
    registered="$(wg_get_registered)"
    if [ $? != 0 ]; then
        echo "[wg_get_registered] impossible to get the registered keys"
        return 1
    fi

    n_keys=$(echo "$registered" | jq '. | length')

    for i in $(seq 0 "$((n_keys-1))"); do
        keyinfo="$(echo "$registered" | jq '.['"$i"']')"
        pubkey=$(echo "$keyinfo" | jq -r '.pubKey')
        if [ "$pubkey" = "$wg_pub" ]; then
            name=$(echo "$keyinfo" | jq -r '.name')
            echo "pubkey '$name' found"
            wg_udpate_expire_token "$keyinfo"
            return 0
        fi
    done

    return 1
}

wg_check_pubkey() { # validates the public key registration process and confirms token expiry
    if wg_check_registered_pubkeys; then
        return 0
    fi

    tmpfile=$(mktemp /tmp/wg-curl-val.XXXXXX)
    http_status=0
    basen=1
    until [ $http_status -eq 200 ]; do
        baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            echo "[wg_check_pubkey] Public Key was not validated & authorised, please try again."
            echo "[wg_check_pubkey] If it fails repeatedly check your credentials and that key registration has completed."
            echo $(cat $tmpfile)
            rm $tmpfile
            exit 120
        fi
        url=$(eval echo \${$baseurl})/v1/account/users/public-keys/validate
        data='{"pubKey": "'$wg_pub'"}'
        token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
        http_status=$(curl -o $tmpfile -w "%{http_code}" -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url})
        echo "[$(date -Iseconds)] [wg_check_pubkey] Validation "$url $http_status $(cat $tmpfile) >> $sswg_log
        let basen=$basen+2
    done
    wg_udpate_expire_token "$(cat "$tmpfile")"
    rm -f "$tmpfile"
}

wg_token_renwal() { # use renewal token to generate new tokens
    basen=1
    error_count=0
    key_ren=start
    until [ -z "${key_ren##*renewToken*}" ]; do
        baseurl=baseurl_$basen
        url=$(eval echo \${$baseurl})/v1/auth/renew
        data='{"pubKey": "'$wg_pub'"}'
        token="Authorization: Bearer $(eval echo $(jq '.renewToken' $token_file))"
        key_ren=$(curl -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url} | jq '.')
        echo "[$(date -Iseconds)] [wg_token_renwal] Renewal "$url $key_ren >> $sswg_log
        let basen=$basen+2
        if [ -n "${key_ren##*renewToken*}" ] && [ $basen -gt $urlcount ]; then
            if [ -z "${key_ren##*400*}" ]; then
                if [ -z "${key_ren##*Bad Request*}" ]; then
                    echo "[wg_token_renwal] Curl post appears to be malformed"
                    exit 130
                fi
            elif [ -z "${key_ren##*401*}" ]; then
                if [ -z "${key_ren##*Expired*}" ] && [ $error_count -eq 0 ]; then
                    rm -f ${token_file} ${wg_keys} # reset keys and token if renewal fails
                    wg_login
                    wg_gen_keys
                    error_count=1
                    basen=1
                elif [ -z "${key_ren##*Expired*}" ] && [ $error_count -eq 1 ]; then
                    echo "Token is expiring immediately."
                    exit 131
                elif [ -z "${key_ren##*Token not found*}" ]; then
                    echo "[wg_token_renwal] Token was not recognised as a token."
                    echo "[wg_token_renwal] If it fails repeatedly check your credentials and that a token exists."
                    exit 132
                fi
            else
                echo "[wg_token_renwal] Unknown error"
                exit 133
            fi
        fi
    done
    echo "${key_ren}" > $token_file
    echo "[wg_token_renwal] token renewed"
}

get_servers() {
    server_type='generic static obfuscated double'
    for server in $server_type; do
        tmpfile=$(mktemp /tmp/wg-curl-ser.XXXXXX)
        http_status=0
        basen=0
        until [ $http_status -eq 200 ]; do
            let basen=$basen+1; baseurl=baseurl_$basen
            if [ $basen -gt $urlcount ]; then
                echo "[get_servers] Unable to download server information."
                rm $tmpfile
                exit 140
            fi
            url=$(eval echo \${$baseurl})/v4/server/clusters/$server?countryCode=
            token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
            http_status=$(curl -o $tmpfile -w "%{http_code}" -H "${token}" -H "Content-Type: application/json" ${url})
            echo "[$(date -Iseconds)] [get_servers]" $server" servers "$url $http_status >> $sswg_log
        done
        server_file="$server""_servers_file"
        server_file=$(eval echo \${$server_file})
        rm -f $server_file
        echo $(cat $tmpfile | jq '.') >> $server_file
        rm $tmpfile
    done
}

gen_client_confs() {
    mkdir -p "${config_folder}/configs"
    rm -f ${config_folder}/configs/*.conf
    servers='generic static obfuscated' # still need to work on obfuscated & double, they will need separate conf gens
    for server in $servers; do
        postf=".prod.surfshark.com"
        server_hosts="$server""_servers_file"
        server_hosts=$(eval echo \${$server_hosts})
        server_hosts=$(cat $server_hosts)
        server_hosts=$(echo "${server_hosts}" | jq -c '.[] | [.connectionName,.load,.tags,.pubKey]')
        for row in $server_hosts; do
            srv_host="$(echo $row | jq '.[0]')"
            srv_host=$(eval echo $srv_host)

            srv_load="$(echo $row | jq '.[1]')"
            srv_load=$(eval echo $srv_load)

            srv_tags="$(echo $row | jq '.[2]')"
            srv_tags=$(eval echo $srv_tags)

            srv_pub="$(echo $row | jq '.[3]')"
            srv_pub=$(eval echo $srv_pub)

            file_name=${srv_host%$postf}
            file_name=${file_name}.prod
            srv_tags=${srv_tags/'physical'/}
            srv_tags=${srv_tags/'['/}
            srv_tags=${srv_tags/']'/}
            srv_tags=${srv_tags/','/}
            srv_tags=${srv_tags//' '/}
            srv_conf_file=${config_folder}/configs/${file_name}.conf

            echo -e "#$srv_host SERVER:[$server] LOAD:[$srv_load] TAGS:[$srv_tags] PUB:[$srv_pub}" > $srv_conf_file
            srv_conf="[Interface]\nPrivateKey=$wg_prv\nAddress=10.14.0.2/8\n\n[Peer]\nPublicKey=o07k/2dsaQkLLSR0dCI/FUd3FLik/F/HBBcOGUkNQGo=\nAllowedIPs=172.16.0.36/32\nEndpoint=wgs.prod.surfshark.com:51820\nPersistentKeepalive=25\n\n[Peer]\nPublicKey=$srv_pub\nAllowedIPs=0.0.0.0/0\nEndpoint=${srv_host}:51820\nPersistentKeepalive=25\n"
            echo -e "$srv_conf" >> $srv_conf_file
        done
        file_removal="$server""_servers_file"
        file_removal=$(eval echo \${$file_removal})
        rm -f $file_removal
    done
}

reset_surfshark() {
    echo "[reset_surfshark] Clearing old settings ..."
    rm -fr ${config_folder}/configs
    rm -f ${config_folder}/*servers.json
    rm -f ${config_folder}/wg.json
    rm -f ${config_folder}/token.json
    rm -f ${config_folder}/token_expires.json
}

echo "=========Start Main==========="
read_config
parse_arg "$@"

if [ -f "$token_expires" ]; then
    if [ -f "$wg_keys" ] &&
       [ "$(jq -r '.pubKey' "$token_expires")" != "$(jq -r '.pub' "$wg_keys")" ] ||
       [ ! -f "$wg_keys" ]; then
        echo "Token expires does not match key configuration, removing it"
        rm -f "$token_expires"
    fi
fi

if [ $reset_all -eq 1 ]; then
    echo "--------------"
    echo "Reset All  ..."
    reset_surfshark
    echo "--------------"
    exit 0
fi

if [ $generate_servers -eq 1 ]; then
    echo "----------------------------------"
    echo "Generate Servers and Profiles  ..."
    get_servers
    gen_client_confs
    echo "server list now:"
    echo "$(ls -xA ${config_folder}/configs/)"
    echo "----------------------------------"
    exit 0
fi

if [ $renew_token -eq 1 ]; then
    echo "----------------"
    echo "Renew Token  ..."
        wg_token_renwal
        wg_check_pubkey
    echo "----------------"
    exit 0
fi

echo "------------------------"
echo "Logging in if needed ..."
if [ -f "$token_file" ]; then
    echo "login not required ..."
else
    echo "login required ..."
    wg_login
fi
echo "------------------------"

echo "-------------------"
echo "Generating keys ..."
if [ -f "$wg_keys" ]; then
    wg_prv=$(jq -r .prv "$wg_keys")
    wg_pub=$(echo "$wg_prv" | wg pubkey)

    if [ "$(jq -r .pub "$wg_keys")" != "$wg_pub" ]; then
        echo "Pubkey mismatch"
        wg_pub=
    fi
fi

if [ -n "$wg_prv" ] && [ -n "$wg_pub" ]; then
    echo "using existent wg keys"
else
    wg_gen_keys
fi
echo "-------------------"

echo "-------------------------"
echo "Registering public key ..."
wg_register_pub
echo "-------------------------"

if [ $generate_conf -eq 1 ]; then
    echo "-------------------------------"
    echo "Getting the list of servers ..."
    get_servers
    echo "Generating server profiles ..."
    gen_client_confs
    echo "-------------------------------"
fi

echo "Done!"
echo "========================="
#############################################################################
# --------------------
# TABLE OF ERROR CODES
# --------------------
# gen_wgconfig
# 0 All Good
#
# wg_login()
# 100 "Unable to login, check your credentials."
#
# wg_reg_pubkey()
# 110 "Curl post appears to be malformed"
# 111 "Token is expiring immediately."
# 112 "Token was not recognised as a token."
# 113 "Conflict, key is already registered as manual key"
# 114 "Unknown error"
#
# wg_check_pubkey()
# 120 "Public Key was not validated & authorised, please try again."
#
# wg_token_renwal()
# 130 "Curl post appears to be malformed"
# 131 "Token is expiring immediately."
# 132 "Token was not recognised as a token."
# 133 "Unknown error"
#
# get_servers()
# 140 "Unable to download server information."
#
#############################################################################
