#!/bin/bash
set -e

read_config() {
    config_folder=$(dirname $(readlink -f $0))

    config_file=${config_folder}/config.json
    wg_keys=${config_folder}/wg.json
    token_file=${config_folder}/token.json
    token_expires=${config_folder}/token_expires.json

    baseurl_1="https://api.surfshark.com"
    baseurl_2="https://ux.surfshark.com"
    baseurl_3="https://api.uymgg1.com"
    baseurl_4="https://ux.uymgg1.com"
    urlcount=4

    generic_servers_file=${config_folder}/generic_servers.json
    static_servers_file=${config_folder}/static_servers.json
    obfuscated_servers_file=${config_folder}/obfuscated_servers.json
    double_servers_file=${config_folder}/double_servers.json   

    force_register=0
    register=1
    generate_conf=1
    reset_all=0
    wireguard_down=0
    wireguard_up=0
    switch_conf=0
    generate_servers=0
}

parse_arg() {
    while getopts 'fhgudrsC' opt; do
        case "$opt" in
            C)  reset_all=1         ;;
            f)  force_register=1    ;;
            g)  generate_conf=0     ;;
            u)  wireguard_up=1      ;;
            d)  wireguard_down=1    ;;
            r)  generate_servers=1  ;;
            s)  switch_conf=1       ;;
            ?|h)
            echo "Usage: $(basename $0) [-f]"
            echo "  -f force register, ignore checking"
            echo "  -g ignore generating profile files"
            echo "  -d takedown a surfshark wireguard conf setup with this script"
            echo "  -u bring up a surfshark wireguard conf setup with this script"
            echo "  -r regenerate the server conf files"
            echo "  -s switch from one surfshark wireguard conf to another"
            echo "  -C clear keys and profile files before generating new ones"
            exit 1                  ;;
        esac
    done
    shift "$(($OPTIND -1))"
}

wg_login() {
#add in renewal option
#/v1/auth/renew
    if [ -f "$token_file" ]; then
        echo "login not required ..."
    else
        tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
        http_status=0
        basen=0
        until [ $http_status -eq 200 ]; do
            let basen=$basen+1; baseurl=baseurl_$basen
            if [ $basen -gt $urlcount ]; then
                echo "Unable to login, check your credentials."
                rm $tmpfile
                exit 2
            fi
            url=$(eval echo \${$baseurl})/v1/auth/login
            data='{"username":'$(jq '.username' ${config_file})',"password":'$(jq '.password' ${config_file})'}'
            http_status=$(curl -o $tmpfile -s -w "%{http_code}" -d "$data" -H 'Content-Type: application/json' -X POST $url)
            echo "Login "$url $http_status
        done
        cp $tmpfile $token_file
        rm $tmpfile
    fi
}

wg_gen_keys() {
    if [ -f "$wg_keys" ]; then
        echo "using existent wg keys"
    else 
        echo "generating new keys"
        wg_prv=$(wg genkey)
        wg_pub=$(echo $wg_prv | wg pubkey)
        echo "{\"pub\":\"$wg_pub\", \"prv\":\"$wg_prv\"}" > $wg_keys
    fi
}

wg_register_pub() { # check to see if the public key has been registered and there is an unexpired token & run appropriate modules
    if [ ! -f ${token_expires} ] && [ -f ${wg_keys} ]; then
        wg_reg_pubkey
        wg_check_pubkey
    elif [ $(eval echo $(jq '.pubKey' $token_expires)) = $(eval echo $(jq '.pub' $wg_keys)) ] && [ $(eval echo $(jq '.expiresAt' $token_expires)) '<' $(eval echo $(date -Iseconds -u)) ]; then
        rm -f ${token_file} ${wg_keys} ${token_expires}     # temp solution
        wg_login                                            # until renewal
        wg_gen_keys                                         # is sorted
        wg_reg_pubkey                                       #
        wg_check_pubkey                                     #
    else
        wg_check_pubkey
    if
}

wg_reg_pubkey() { # register the public key using the jwt token 
    basen=1
    error_count_et=0
    error_count_nt=0
    key_reg=start
    until [ -z "${key_reg##*expiresAt*}" ]; do
        baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            echo "Token was not recognised/expired or the Public Key was rejected please try again."
            echo "If it fails repeatedly check your credentials and that a token exists."
            exit 2
        fi
        url=$(eval echo \${$baseurl})/v1/account/users/public-keys
        data='{"pubKey":'$(jq '.pub' $wg_keys)'}'
        token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
        key_reg=$(curl -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url})
        echo "Registration "$url $key_reg
        let basen=$basen+2
        if [ -n "${key_reg##*expiresAt*}" ]; then
            if [ -z "${key_reg##*400*}" ]; then
                if [ -z "${key_reg##*Bad Request*}" ]; then
                    echo "Curl post appears to be malformed"
                    exit 2
                fi
            elif [ -z "${key_reg##*401*}" ]; then
                if [ -z "${key_reg##*Expired*}" ] && [ $error_count_et -eq 0 ]; then
                    rm -f ${token_file} ${wg_keys}  # temp solution
                    wg_login                        # until renewal
                    wg_gen_keys                     # is sorted
                    error_count_et=1                #
                    basen=1                         #
                elif [ -z "${key_reg##*Expired*}" ] && [ $error_count_et -eq 1 ]; then
                    error_count_et=2
                elif [ -z "${key_reg##*Expired*}" ] && [ $error_count_et -eq 2 ]; then
                    echo "Token is expiring immediately."
                    exit 2
                elif [ -z "${key_reg##*Token not found*}" ] && [ $error_count_nt -eq 0 ]; then
                    error_count_nt=1
                elif [ -z "${key_reg##*Token not found*}" ] && [ $error_count_nt -eq 1 ]; then
                    echo "Token was not recognised as a token."
                    echo "If it fails repeatedly check your credentials and that a token exists."
                    exit 2
                fi
            else
                echo "Unknown error"
                exit 2
            fi
        fi
    done
    $key_reg > $token_expires
    echo "token requires renewing prior to "$(eval echo $(jq '.expiresAt' $key_reg))
}

wg_check_pubkey() { # validates the public key registration process and confirms token expiry
    tmpfile=$(mktemp /tmp/wg-curl-val.XXXXXX)
    http_status=0
    basen=1
    until [ $http_status -eq 200 ]; do
        baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            echo "Public Key was not validated & authorised, please try again."
            echo "If it fails repeatedly check your credentials and that key registration has completed."
            echo $(cat $tmpfile)
            rm $tmpfile
            exit 2
        fi
        url=$(eval echo \${$baseurl})/v1/account/users/public-keys/validate
        data='{"pubKey":'$(jq '.pub' $wg_keys)'}'
        token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
        http_status=$(curl -o $tmpfile -s -w "%{http_code}" -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url})
        echo "Validation "$url $http_status
        let basen=$basen+2
    done
    expire_date=$(eval echo $(jq '.expiresAt' $tmpfile))
    now=$(date -Iseconds -u)
    if [ "${now}" '<' "${expire_date}" ];then
        cp -f $tmpfile $token_expires
        register=0
        echo "TODAYS DATE"              # Display Run Date
        echo ""${now}""                 # and Time
        echo ""                         #
        echo "TOKEN EXPIRES ON:"        # Display WG Authentication Token
        echo "${expire_date}"           # Expiry Date and Time
        logger -t SSWG "RUN DATE:${now}   TOKEN EXPIRES ON: ${expire_date}"       # Log Status Information (logread -e SSWG)
    fi
    rm $tmpfile
}

wg_token_renwal() {
    basen=1
    error_count_et=0
    error_count_nt=0
    key_ren=start
    until [ -z "${key_ren##*expiresAt*}" ]; do
        baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            echo "Token was not recognised/expired or the Public Key was rejected please try again."
            echo "If it fails repeatedly check your credentials and that a token exists."
            exit 2
        fi
        url=$(eval echo \${$baseurl})/v1/auth/renew
        token="Authorization: Bearer $(eval echo $(jq '.renewToken' $token_file))"
        key_ren=$(curl -H "${token}" -H "Content-Type: application/json" -X POST ${url})
        echo "Renewal "$url $key_ren
        let basen=$basen+2
        if [ -n "${key_ren##*expiresAt*}" ]; then
            if [ -z "${key_ren##*400*}" ]; then
                if [ -z "${key_ren##*Bad Request*}" ]; then
                    echo "Curl post appears to be malformed"
                    exit 2
                fi
            elif [ -z "${key_ren##*401*}" ]; then
                if [ -z "${tmpfile##*Expired*}" ] && [ $error_count_et -eq 0 ]; then
                    rm -f ${token_file} ${wg_keys}  # temp solution
                    wg_login                        # until renewal
                    wg_gen_keys                     # is sorted
                    error_count_et=1                #
                    basen=1                         #
                elif [ -z "${key_ren##*Expired*}" ] && [ $error_count_et -eq 1 ]; then
                    error_count_et=2
                elif [ -z "${key_ren##*Expired*}" ] && [ $error_count_et -eq 2 ]; then
                    echo "Token is expiring immediately."
                    exit 2
                elif [ -z "${key_ren##*Token not found*}" ] && [ $error_count_nt -eq 0 ]; then
                    error_count_nt=1
                elif [ -z "${key_ren##*Token not found*}" ] && [ $error_count_nt -eq 1 ]; then
                    echo "Token was not recognised as a token."
                    echo "If it fails repeatedly check your credentials and that a token exists."
                    exit 2
                fi
            else
                echo "Unknown error"
                exit 2
            fi
        fi
    done
    $key_ren > $token_expires
    echo "token requires renewing prior to "$(eval echo $(jq '.expiresAt' $key_ren))
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
                echo "Unable to download server information."
                rm $tmpfile
                exit 2
            fi
            url=$(eval echo \${$baseurl})/v4/server/clusters/$server?countryCode=
            token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
            http_status=$(curl -o $tmpfile -s -w "%{http_code}" -H "${token}" -H "Content-Type: application/json" ${url})
            echo $server" servers "$url $http_status
        done
        server_file="$server""_servers_file"
        server_file=$(eval echo \${$server_file})
        cat $tmpfile > $server_file
        rm $tmpfile
    done
}

gen_client_confs() {
    servers='generic static'
    rm 
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
            file_name=${file_name/'-'/'-'$(printf %03d $srv_load)'-'}
            srv_tags=${srv_tags/'physical'/}
            srv_tags=${srv_tags/'['/}
            srv_tags=${srv_tags/']'/}
            srv_tags=${srv_tags/','/}
            srv_tags=${srv_tags//' '/}
            if [ "$srv_tags" = '' ]; then
				file_name=${server}-${file_name}
            else
				file_name=${server}-${file_name}-${srv_tags}
			fi
			srv_conf_file=${config_folder}/conf${file_name}.conf

            srv_conf="[Interface]\nPrivateKey=$wg_prv\nAddress=10.14.0.2/8\n\n[Peer]\nPublicKey=o07k/2dsaQkLLSR0dCI/FUd3FLik/F/HBBcOGUkNQGo=\nAllowedIPs=172.16.0.36/32\nEndpoint=wgs.prod.surfshark.com:51820\nPersistentKeepalive=25\n\n[Peer]\nPublicKey=$srv_pub\nAllowedIPs=0.0.0.0/0\nEndpoint=$srv_host:51820\nPersistentKeepalive=25\n"
            echo -e "$srv_conf" > $srv_conf_file
        done
        file_removal="$server""_servers_file"
        file_removal=$(eval echo \${$file_removal})
        rm -f $file_removal
    done
}

surfshark_up() {
    if [ -e ${config_folder}/surfshark ]; then
        surfshark_down
    fi

    PS3="Please enter your choice: "
    echo "Please select your preferred server."
    configs="$(ls -A ${config_folder}/conf/)"
    select server in ${configs}; do
        wg-quick up "${config_folder}/conf/${server}"
        cp -f "${config_folder}/conf/${server}" ${config_folder}/surfshark
        break
    done
}

surfshark_down() {
    if [ -e ${config_folder}/surfshark ]; then
        wg_config=$(cat ${config_folder}/surfshark)
        wg-quick down "${wg_config}"
        rm ${config_folder}/surfshark
    else
        echo "wireguard not started from this script, please clear manually"
    fi
}

reset_surfshark() {
    if [ -e ${config_folder}/surfshark ]; then
        surfshark_down
    fi

    echo "Clearing old settings ..."
    rm -fr ${config_folder}/conf
    rm -f ${config_folder}/*servers.json
    rm -f ${config_folder}/wg.json
    rm -f ${config_folder}/token.json
    rm -f ${config_folder}/token_expires.json
    rm -f ${config_folder}/surfshark
}

read_config
parse_arg "$@"

if [ $reset_all -eq 1 ]; then
    reset_surfshark
fi

if [ $generate_servers -eq 1 ]; then
    get_servers
    gen_client_confs
    echo "server list now:"
    echo "$(ls -xA ${config_folder}/conf/)"
    exit 1
fi

if [ $switch_conf -eq 1 ]; then
    surfshark_down
    surfshark_up
    exit 1
fi

if [ $wireguard_up -eq 1 ]; then
    if [ -f $token_expires ]; then
        if [ $(eval echo $(jq '.expiresAt' $token_expires)) '>' $(date -Iseconds -u) ]; then
            surfshark_up
            exit 1
        else
            wg_reg_pubkey
            wg_check_pubkey
            get_servers
            gen_client_confs
            surfshark_up
            exit 1
        fi
    fi
fi

if [ $wireguard_down -eq 1 ]; then
    surfshark_down
    exit 1
fi

echo "Logging in if needed ..."
wg_login

echo "Generating keys ..."
wg_gen_keys

echo "Registring public key ..."
wg_register_pub

if [ $generate_conf -eq 1 ]; then
    echo "Getting the list of servers ..."
    get_servers

    echo "Generating server profiles ..."
    gen_client_confs
fi

if [ ! -e ${config_folder}/surfshark ]; then
    surfshark_up
fi

echo "Done!"
