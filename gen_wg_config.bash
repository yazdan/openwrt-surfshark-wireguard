#!/bin/bash
#set -e
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
    baseurl_2="https://api.uymgg1.com"
    baseurl_3="https://api.surf-chiny.com"
    baseurl_4="https://api.shark-china.com"
    urlcount=4

    generic_servers_file=${config_folder}/generic_servers.json
    static_servers_file=${config_folder}/static_servers.json
    obfuscated_servers_file=${config_folder}/obfuscated_servers.json
    double_servers_file=${config_folder}/double_servers.json

    generate_conf=1
    reset_all=0
    generate_servers=0
    renew_token=0
}

parse_arg() {
    while getopts 'hgnrZ' opt; do
        case "$opt" in
            Z)  reset_all=1         ;;
            g)  generate_conf=0     ;;
            n)  renew_token=1       ;;
            r)  generate_servers=1  ;;
            ?|h)
            echo "Usage: $(basename $0) [-h]"
            echo "  -g ignore generating profile files"
            echo "  -n renew tokens"
            echo "  -r regenerate the server conf files"
            echo "  -Z clear settings, keys and server profile files"
            exit 1                  ;;
        esac
    done
    shift "$(($OPTIND -1))"
}

wg_login() { #login and receive jwt token and renewal token
    echo "[wg_login]S         ========================================"
    username=$(eval echo $(jq '.username' ${config_file}))
    password=$(eval echo $(jq '.password' ${config_file}))
    tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
    http_status=0
    basen=0
    until [ $http_status -eq 200 ]; do
        let basen=$basen+1; baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            echo "[wg_login]          Unable to login, check your credentials."
            echo "[wg_login]E         ========================================"
            rm $tmpfile
            exit 100
        fi
        url=$(eval echo \${$baseurl})/v1/auth/login
        data='{"username":"'${username}'","password":"'${password}'"}'
        http_status=$(curl -fsS -o $tmpfile -w "%{http_code}" -d "$data" -H 'Content-Type: application/json' -X POST $url)
        echo "[$(date -Iseconds)] [wg_login] Login "$url $http_status $(cat $tmpfile) >> $sswg_log
    done
    rm -f $token_file
    token="$(eval echo $(jq '.token' $tmpfile))"
    rtoken="$(eval echo $(jq '.renewToken' $tmpfile))"
    echo -e "{\n\t\"apiurl\":\"$(eval echo \${$baseurl})\",\n\t\"token\":\"$token\",\n\t\"renewToken\":\"$rtoken\"\n}" >> $token_file
    rm $tmpfile
    echo "[wg_login]          Used \"$(eval echo \${$baseurl})\" for api calls"
    echo "[wg_login]E         ========================================"
}

wg_gen_keys() { # generate priavte/public key pair
    echo "[wg_gen_keys]S      ========================================"
    echo "[wg_gen_keys]       Generating new keys"
    wg_prv=$(wg genkey)
    wg_pub=$(echo $wg_prv | wg pubkey)
    rm -f $wg_keys
    echo -e "{\n\t\"pub\":\"$wg_pub\",\n\t\"prv\":\"$wg_prv\"\n}" >> $wg_keys
    echo "[wg_gen_keys]E      ========================================"
}

wg_register_pub() { # check to see if the public key has been registered and/or there is an unexpired token & run appropriate modules
    echo "[wg_register_pub]S  ========================================"
    if [ ! -f ${token_expires} ] && [ -f ${wg_keys} ]; then
        echo "[wg_register_pub]   token_expires not found but wg_keys available"
        echo "[wg_register_pub]   will reg then check pubkey"
        wg_reg_pubkey
#        wg_check_pubkey
    elif [ "$(eval echo $(jq '.pubKey' $token_expires))" = "$(eval echo $(jq '.pub' $wg_keys))" ] && [ "$(eval echo $(jq '.expiresAt' $token_expires))" < "$(eval echo $(date -Iseconds -u))" ]; then
        echo "[wg_register_pub]   token_expires and wg_key pubkey match "
        echo "[wg_register_pub]   but token has expired "
        echo "[wg_register_pub]   will renew keys and check "
        wg_token_renwal
#        wg_check_pubkey
    elif [ "$(eval echo $(jq '.pubKey' $token_expires))" = "$(eval echo $(jq '.pub' $wg_keys))" ]; then
        echo "[wg_register_pub]   token_expires and wg_key pubkey match "
        echo "[wg_register_pub]   will check pubkey "
        wg_check_pubkey
    else
        echo "[wg_register_pub]   keys expired will gen new keys reg and check "
        rm -f ${token_file} ${wg_keys}
        wg_login
        wg_gen_keys
        wg_reg_pubkey
        wg_check_pubkey
    fi
    echo "[wg_register_pub]E  ========================================"
}

wg_reg_pubkey() { # register the public key using the jwt token 
    echo "[wg_reg_pubkey]S    ========================================"
    error_count=0
    key_reg=start
    until [ -z "${key_reg##*expiresAt*}" ]; do
        url="$(eval echo $(jq '.apiurl' $token_file))/v1/account/users/public-keys"
        data='{"pubKey":'$(jq '.pub' $wg_keys)'}'
        token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
        echo "[wg_reg_pubkey] Using \"$(eval echo $(jq '.apiurl' $token_file))\" for api calls"
        key_reg=$(curl -fsS -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url} | jq '.')
        echo "[$(date -Iseconds)] [wg_reg_pubkey] Registration "$url $key_reg >> $sswg_log 

        if [ -n "${key_reg##*expiresAt*}" ] && [ $error_count -ne '0' ]; then
            if [ -z "${key_reg##*400*}" ]; then
                if [ -z "${key_reg##*Bad Request*}" ]; then
                    echo "[wg_reg_pubkey]     Curl post appears to be malformed"
                    echo "[wg_reg_pubkey]E    ========================================"
                    exit 110
                fi
            elif [ -z "${key_reg##*401*}" ]; then
                if [ -z "${key_reg##*Expired*}" ] && [ $error_count -eq 0 ]; then
                    wg_token_renwal
                    error_count=1
                elif [ -z "${key_reg##*Expired*}" ] && [ $error_count -eq 1 ]; then
                    echo "[wg_reg_pubkey]     Token is expiring immediately."
                    echo "[wg_reg_pubkey]E    ========================================"
                    exit 111
                elif [ -z "${key_reg##*Token not found*}" ]; then
                    echo "[wg_reg_pubkey]     Token was not recognised as a token."
                    echo "[wg_reg_pubkey]     If it fails repeatedly check your credentials and that a token exists."
                    echo "[wg_reg_pubkey]E    ========================================"
                    exit 112
                fi
            else
                echo "[wg_reg_pubkey]     Unknown error"
                echo "[wg_reg_pubkey]E    ========================================"
                exit 113
            fi
        fi
    done
    rm -f $token_expires
    echo "${key_reg}" | jq '.' >> $token_expires
    echo "[wg_reg_pubkey]     token requires renewing prior to "$(eval echo $(jq '.expiresAt' $token_expires))
    echo "[wg_reg_pubkey]E    ========================================"
}

wg_check_pubkey() { # validates the public key registration process and confirms token expiry
    echo "[wg_check_pubkey]S  ========================================"
    tmpfile=$(mktemp /tmp/wg-curl-val.XXXXXX)
    http_status=0
    error_count=0
    until [ $http_status -eq 200 ]; do
        let error_count=$error_count+1
        if [ $error_count -gt 5 ]; then
            echo "[wg_check_pubkey]   Public Key was not validated & authorised, after $error_count tried."
            echo "[wg_check_pubkey]   If it fails repeatedly check your credentials and that key registration has completed."
            echo $(cat $tmpfile)
            rm $tmpfile
            echo "[wg_check_pubkey]E  ========================================"
            exit 120
        fi
        url="$(eval echo $(jq '.apiurl' $token_file))/v1/account/users/public-keys/validate"
        data='{"pubKey":'$(jq '.pub' $wg_keys)'}'
        token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
        echo "[wg_check_pubkey]   Using \"$(eval echo $(jq '.apiurl' $token_file))\" for api calls"
        http_status=$(curl -fsS -o $tmpfile -w "%{http_code}" -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url})
        echo "[$(date -Iseconds)] [wg_check_pubkey] Validation "$url $http_status $(cat $tmpfile) >> $sswg_log
        let error_count=$error_count+1
    done
    if [ "$(eval echo $(jq '.expiresAt' $tmpfile))" != "$(eval echo $(jq '.expiresAt' $token_expires))" ]; then
        echo "[wg_check_pubkey]   New token expiry date found updating"
        expire_date=$(eval echo $(jq '.expiresAt' $tmpfile))
        now=$(date -Iseconds -u)
        if [ "${now}" '<' "${expire_date}" ]; then
            echo "[wg_check_pubkey]   Current Date & Time  "${now}          # Display Run Date
            echo "[wg_check_pubkey]   Token will Expire at "${expire_date}  # Display Token Expiry
            logger -t SSWG "[wg_check_pubkey] RUN DATE:${now}   TOKEN EXPIRES ON: ${expire_date}" # Log Status Information (logread -e SSWG)
        fi
        rm -f $token_expires
        echo $(cat $tmpfile | jq '.') >> $token_expires
        echo "[wg_check_pubkey]   token requires renewing prior to "$(eval echo $(jq '.expiresAt' $token_expires))
    fi
    rm $tmpfile
    echo "[wg_check_pubkey]E  ========================================"
}

wg_token_renwal() { # use renewal token to generate new tokens
    echo "[wg_token_renwal]S  ========================================"
    basen=1
    error_count=0
    key_ren=start
    until [ -z "${key_ren##*renewToken*}" ]; do
        url="$(eval echo $(jq '.apiurl' $token_file))/v1/auth/renew"
        data='{"pubKey":'$(jq '.pub' $wg_keys)'}'
        token="Authorization: Bearer $(eval echo $(jq '.renewToken' $token_file))"
        echo "[wg_token_tenwal]   Using \"$(eval echo $(jq '.apiurl' $token_file))\" for api calls"
        key_ren=$(curl -fsS  -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url} | jq '.')
        echo "[$(date -Iseconds)] [wg_token_renwal] Renewal "$url $key_ren >> $sswg_log
        let basen=$basen+1
        if [ -n "${key_ren##*renewToken*}" ] && [ $basen -lt 5 ]; then
            if [ -z "${key_ren##*400*}" ]; then
                if [ -z "${key_ren##*Bad Request*}" ]; then
                    echo "[wg_token_renwal]   Curl post appears to be malformed"
                    echo "[wg_token_renwal]E  ========================================"
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
                    echo "[wg_token_renwal]   Token is expiring immediately."
                    echo "[wg_token_renwal]E  ========================================"
                    exit 131
                elif [ -z "${key_ren##*Token not found*}" ]; then
                    echo "[wg_token_renwal]   Token was not recognised as a token."
                    echo "[wg_token_renwal]   If it fails repeatedly check your credentials and that a token exists."
                    echo "[wg_token_renwal]E  ========================================"
                    exit 132
                fi
            else
                echo "[wg_token_renwal]   Unknown error"
                echo "[wg_token_renwal]E  ========================================"
                exit 133
            fi
        fi
    done
    token="$(eval echo $(echo $key_ren | jq '.token'))"
    rtoken="$(eval echo $(echo $key_ren | jq '.renewToken'))"
    apiurl="$(eval echo $(jq '.apiurl' $token_file))"
    rm -f $token_file
    echo -e "{\n\t\"apiurl\":\"$apiurl\",\n\t\"token\":\"$token\",\n\t\"renewToken\":\"$rtoken\"\n}" >> $token_file
    echo "[wg_token_renwal]   token renewed"
    echo "[wg_token_renwal]E  ========================================"
}

get_servers() {
    echo "[get_servers]S      ========================================"
    server_type='generic static obfuscated double'
    for server in $server_type; do
    echo "[get_servers]       Getting $server servers"
        tmpfile=$(mktemp /tmp/wg-curl-ser.XXXXXX)
        http_status=0
        basen=0
        until [ $http_status -eq 200 ]; do
            let basen=$basen+1
            if [ $basen -gt 5 ]; then
                echo "[get_servers]       Unable to download server information after 5 tries."
                echo "[get_servers]E      ========================================"
                rm $tmpfile
                exit 140
            fi
            url="$(eval echo $(jq '.apiurl' $token_file))/v4/server/clusters/$server?countryCode="
            token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
            echo "[get_servers]       Using \"$(eval echo $(jq '.apiurl' $token_file))\" for api calls"
            http_status=$(curl -fsS -o $tmpfile -w "%{http_code}" -H "${token}" -H "Content-Type: application/json" ${url})
            echo "[$(date -Iseconds)] [get_servers]" $server" servers "$url $http_status >> $sswg_log
        done
        server_file="$server""_servers_file"
        server_file=$(eval echo \${$server_file})
        rm -f $server_file
        echo $(cat $tmpfile | jq '.') >> $server_file
        rm $tmpfile
    done
    echo "[get_servers]E      ========================================"
}

gen_client_confs() {
    echo "[gen_client_confs]S ========================================"
    mkdir -p "${config_folder}/configs"
    rm -f ${config_folder}/configs/*.conf
    servers='generic static obfuscated double' # worked out parsing logic for obfuscated and double should work
    for server in $servers; do
        echo "[gen_client_confs]  Generating $server configs"
        postf=".prod.surfshark.com"
        server_hosts="$server""_servers_file"
        server_hosts=$(eval echo \${$server_hosts})
        server_hosts=$(cat $server_hosts)

        if [ "$server" = "double" ]; then
           server_hosts=$(echo "${server_hosts}" | jq -c '.[] | [.transitCluster.connectionName,.load,.tags,.pubKey]')
	elif [ "$server" = "obsfuscated" ]; then
           server_hosts=$(echo "${server_hosts}" | jq -c '.[] | select( .info != null)| [.connectionName,.load,.tags,.info[].entry.value]')
        else
           server_hosts=$(echo "${server_hosts}" | jq -c '.[] | [.connectionName,.load,.tags,.pubKey]')
        fi

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
            srv_conf="[Interface]\nPrivateKey=$(eval echo $(jq '.prv' $wg_keys))\nAddress=10.14.0.2/8\n\n[Peer]\nPublicKey=o07k/2dsaQkLLSR0dCI/FUd3FLik/F/HBBcOGUkNQGo=\nAllowedIPs=172.16.0.36/32\nEndpoint=wgs.prod.surfshark.com:51820\nPersistentKeepalive=25\n\n[Peer]\nPublicKey=$srv_pub\nAllowedIPs=0.0.0.0/0, ::/0\nEndpoint=${srv_host}:51820\nPersistentKeepalive=25\n"
            echo -e "$srv_conf" >> $srv_conf_file
        done
        file_removal="$server""_servers_file"
        file_removal=$(eval echo \${$file_removal})
        rm -f $file_removal
    done
    echo "[gen_client_confs]E ========================================"
}

reset_surfshark() {
    echo "[reset_surfshark]S  ========================================"
    echo "[reset_surfshark]   Clearing old settings ..."
    rm -fr ${config_folder}/configs
    rm -f ${config_folder}/*servers.json
    rm -f ${config_folder}/wg.json
    rm -f ${config_folder}/token.json
    rm -f ${config_folder}/token_expires.json
    rm -f ${config_folder}/sswg.log
    echo "[reset_surfshark]   All Settings cleared rerun script to regenerate..."
    echo "[reset_surfshark]E  ========================================"
}

echo "========================Start Main========================="
read_config
parse_arg "$@"

if [ $reset_all -eq 1 ]; then
    reset_surfshark
    exit 0
fi

if [ $generate_servers -eq 1 ]; then
    if [ -f "$token_file" ]; then
       get_servers
       gen_client_confs
       echo "[MAIN]-r server list now:"
       echo "$(ls -xA ${config_folder}/configs/)"
       exit 0
    else
       echo "[MAIN]-r No token file exiting  "
       exit 500
    fi
fi

if [ $renew_token -eq 1 ]; then
    if [ -f "$token_file" ]; then
       wg_token_renwal
       wg_check_pubkey
       exit 0
    else
       echo "[MAIN]-n No token file exiting  "
       exit 500
    fi
fi

echo "[MAIN] Logging in if needed ..."
if [ -f "$token_file" ]; then
    echo "[MAIN] login not required ..."
else
    echo "[MAIN] login required ..."
    wg_login
fi

echo "[MAIN] Generating keys ..."
if [ -f "$wg_keys" ]; then
    echo "[MAIN] using existent wg keys"
else
    wg_gen_keys
fi

echo "[MAIN] Registering public key ..."
wg_register_pub

if [ $generate_conf -eq 1 ]; then
    echo "[MAIN]-g Getting the list of servers ..."
    get_servers
    echo "[MAIN]-g Generating server profiles ..."
    gen_client_confs
fi

echo "===========================DONE!==========================="

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
# 113 "Unknown error"
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
