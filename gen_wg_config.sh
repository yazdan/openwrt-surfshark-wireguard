#!/bin/sh
set -e

read_config() {
    config_folder=$(dirname $(readlink -f $0))

    config_file=${config_folder}/config.json
    wg_keys=${config_folder}/wg.json
    token_file=${config_folder}/token.json
    token_expires=${config_folder}/token_expires.json
    sswg_log=${config_folder}/sswg.log

    baseurl_1="https://api.surfshark.com"
    baseurl_2="https://ux.surfshark.com"
    baseurl_3="https://api.uymgg1.com"
    baseurl_4="https://ux.uymgg1.com"
    urlcount=4
    apiurls=2

    generic_servers_file=${config_folder}/generic_servers.json
    static_servers_file=${config_folder}/static_servers.json
    obfuscated_servers_file=${config_folder}/obfuscated_servers.json
    double_servers_file=${config_folder}/double_servers.json   

    generate_conf=1
    reset_all=0
    wireguard_down=0
    wireguard_up=0
    switch_conf=0
    check_status=0
    generate_servers=0
    renew_token=0
}

parse_arg() {
    while getopts 'cghnrsZ' opt; do
        case "$opt" in
            Z)  reset_all=1         ;;
            c)  check_status=1      ;;
            g)  generate_conf=0     ;;
            n)  renew_token=1       ;;
            r)  generate_servers=1  ;;
            s)  switch_conf=1       ;;
            ?|h)
            echo "Usage: $(basename $0) [-h]"
            echo "  -c check status of user"
            echo "  -g skip generating server conf files"
            echo "  -n renew tokens"
            echo "  -r regenerate the server conf files"
            echo "  -s switch from one surfshark wireguard server to another"
            echo "  -Z clear settings, keys and server profile files"
            exit 1                  ;;
        esac
    done
    shift "$(($OPTIND -1))"
}

wg_login() { # login and recieve jwt token and renewal token
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
        http_status=$(curl -o $tmpfile -w "%{http_code}" -d "$data" -H 'Content-Type: application/json' -X POST $url)
        echo "Login "$url $http_status
        echo "Login "$url $http_status $(cat $tmpfile) >> $sswg_log
    done
    cp -f $tmpfile $token_file
    rm $tmpfile
}

wg_gen_keys() { # generate priavte/public key pair
    echo "generating new keys"
    wg_prv=$(wg genkey)
    wg_pub=$(echo $wg_prv | wg pubkey)
    echo "{\"pub\":\"$wg_pub\", \"prv\":\"$wg_prv\"}" > $wg_keys
}

wg_register_pub() { # check to see if the public key has been registered and/or there is an unexpired token & run appropriate modules
    if [ ! -f ${token_expires} ] && [ -f ${wg_keys} ]; then
        wg_reg_pubkey
        wg_check_pubkey
    elif [ $(eval echo $(jq '.pubKey' $token_expires)) = $(eval echo $(jq '.pub' $wg_keys)) ] && [ $(eval echo $(jq '.expiresAt' $token_expires)) '<' $(eval echo $(date -Iseconds -u)) ]; then
        wg_token_renwal
        wg_check_pubkey
    elif [ $(eval echo $(jq '.pubKey' $token_expires)) = $(eval echo $(jq '.pub' $wg_keys)) ]; then
        wg_check_pubkey
    else
        rm -f ${token_file} ${wg_keys}
        wg_login
        wg_gen_keys
        wg_reg_pubkey
        wg_check_pubkey
    fi
}

wg_user_status() { # get current status of user
    url=$baseurl_1/v1/server/user
    token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
    user_status=$(curl -H "${token}" -H "Content-Type: application/json" ${url})
    echo "User Status "$url $user_status >> $sswg_log
    if [ $(echo $user_status | jq '.secured') ]; then
        echo "surfshark wireguard is currently on and your IP info is "$(echo $user_status | jq '.ip, .city, .country')
    else
        echo "surfshark wireguard is currently off and your IP info is "$(echo $user_status | jq '.ip, city, .country')
    fi
}

wg_reg_pubkey() { # register the public key using the jwt token 
    basen=1
    error_count=0
    key_reg=start
    until [ -z "${key_reg##*expiresAt*}" ]; do
        baseurl=baseurl_$basen
        url=$(eval echo \${$baseurl})/v1/account/users/public-keys
        data='{"pubKey":'$(jq '.pub' $wg_keys)'}'
        token="Authorization: Bearer $(eval echo $(jq '.token' $token_file))"
        key_reg=$(curl -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url})
        echo "Registration "$url $key_reg
        echo "Registration "$url $key_reg >> $sswg_log
        let basen=$basen+2
        if [ -n "${key_reg##*expiresAt*}" ] && [ $basen -gt $apiurls ]; then
            if [ -z "${key_reg##*400*}" ]; then
                if [ -z "${key_reg##*Bad Request*}" ]; then
                    echo "Curl post appears to be malformed"
                    exit 2
                fi
            elif [ -z "${key_reg##*401*}" ]; then
                if [ -z "${key_reg##*Expired*}" ] && [ $error_count -eq 0 ]; then
                    wg_token_renwal
                    error_count=1
                    basen=1
                elif [ -z "${key_reg##*Expired*}" ] && [ $error_count -eq 1 ]; then
                    echo "Token is expiring immediately."
                    exit 2
                elif [ -z "${key_reg##*Token not found*}" ]; then
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
    if [ -f $token_expires ]; then
    echo "${key_ren}" > $token_expires
    else
    echo "${key_ren}" >> $token_expires
    fi
    echo "token requires renewing prior to "$(eval echo $(jq '.expiresAt' $token_expires))
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
        http_status=$(curl -o $tmpfile -w "%{http_code}" -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url})
        echo "Validation "$url $http_status
        echo "Validation "$url $http_status $(cat $tmpfile) >> $sswg_log
        let basen=$basen+2
    done
    if [ $(eval echo $(jq '.expiresAt' $tmpfile)) = $(eval echo $(jq '.expiresAt' $token_expires)) ]; then
        expire_date=$(eval echo $(jq '.expiresAt' $tmpfile))
        now=$(date -Iseconds -u)
        if [ "${now}" '<' "${expire_date}" ]; then
            echo "Current Date & Time  "${now}          # Display Run Date
            echo "Token will Expire at "${expire_date}  # Display Token Expiry
            logger -t SSWG "RUN DATE:${now}   TOKEN EXPIRES ON: ${expire_date}" # Log Status Information (logread -e SSWG)
        fi
    fi
    rm $tmpfile
}

wg_token_renwal() { # use renewal token to generate new tokens
    basen=1
    error_count=0
    key_ren=start
    until [ -z "${key_ren##*renewToken*}" ]; do
        baseurl=baseurl_$basen
        url=$(eval echo \${$baseurl})/v1/auth/renew
        data='{"pubKey":'$(jq '.pub' $wg_keys)'}'
        token="Authorization: Bearer $(eval echo $(jq '.renewToken' $token_file))"
        key_ren=$(curl -H "${token}" -H "Content-Type: application/json" -d "${data}" -X POST ${url})
        echo "Renewal "$url $key_ren
        echo "Renewal "$url $key_ren >> $sswg_log
        let basen=$basen+2
        if [ -n "${key_ren##*renewToken*}" ] && [ $basen -gt $apiurls ]; then
            if [ -z "${key_ren##*400*}" ]; then
                if [ -z "${key_ren##*Bad Request*}" ]; then
                    echo "Curl post appears to be malformed"
                    exit 2
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
                    exit 2
                elif [ -z "${key_ren##*Token not found*}" ]; then
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
    echo "${key_ren}" > $token_file
    echo "token renewed"
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
            http_status=$(curl -o $tmpfile -w "%{http_code}" -H "${token}" -H "Content-Type: application/json" ${url})
            echo $server" servers "$url $http_status
            echo $server" servers "$url $http_status >> $sswg_log
        done
        server_file="$server""_servers_file"
        server_file=$(eval echo \${$server_file})
        cat $tmpfile > $server_file
        rm $tmpfile
    done
}

gen_client_confs() {
    mkdir -p "${config_folder}/conf"
    rm -f ${config_folder}/conf/*.conf
    servers='generic static' # still need to work on obfuscated & double, they will need separate conf gens
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
            echo "{\"description\":\"${srv_host%$postf}\",\"public_key\":\"$srv_pub\",\"endpoint_host\":\"$srv_host\"}" >> ${config_folder}/conf/${file_name}.conf
        done
        file_removal="$server""_servers_file"
        file_removal=$(eval echo \${$file_removal})
        rm -f $file_removal
    done
}

surfshark() {
    # allow fall back to wan if vpn off, can be overridden by removing lan to wan forwarding (aka kill switch)
    uci set network.wan.metric='1024'

    network_test1=$(grep -w -e surfshark /etc/config/network)
    network_test2=$(grep -w -e wireguard /etc/config/network)
    if [ ! $(set -f -- $network_test1; echo $#) -gt 0 ] || [ ! $(set -f -- $network_test2; echo $#) -gt 0 ]; then
        uci set network.sswg=device
        uci set network.sswg.name='surfshark'
        uci set network.sswg.ipv6='0'
        uci set network.sswg.promisc='1'
        uci set network.sswg.acceptlocal='1'
        uci set network.surfshark=interface
        uci set network.surfshark.proto='wireguard'
        uci set network.surfshark.private_key=$(eval echo $(jq '.prv' $wg_keys))
        uci set network.surfshark.listen_port='51820'
        uci set network.surfshark.addresses='10.14.0.2/8'
        uci set network.wgs_surfshark=wireguard_surfshark
        uci set network.wgs_surfshark.description='wgs'
        uci set network.wgs_surfshark.public_key='o07k/2dsaQkLLSR0dCI/FUd3FLik/F/HBBcOGUkNQGo='
        uci set network.wgs_surfshark.allowed_ips='172.16.0.36/32'
        uci set network.wgs_surfshark.route_allowed_ips='1'
        uci set network.wgs_surfshark.endpoint_host='wgs.prod.surfshark.com'
        uci set network.wgs_surfshark.endpoint_port='51820'
        uci set network.wgs_surfshark.persistent_keepalive='25'
        uci commit network
        /etc/init.d/network restart
    else
        echo "No changes made to the network"
    fi

    firewall_test1=$(grep -w -e surfsharkwg /etc/config/firewall)
    firewall_test2=$(grep -w -e surfshark /etc/config/firewall)
    if [ ! $(set -f -- $firewall_test1; echo $#) -gt 0 ] || [ ! $(set -f -- $firewall_test2; echo $#) -gt 0 ]; then
        uci set firewall.sswg_zone=zone
        uci set firewall.sswg_zone.name='surfsharkwg'
        uci set firewall.sswg_zone.input='REJECT'
        uci set firewall.sswg_zone.output='ACCEPT'
        uci set firewall.sswg_zone.forward='REJECT'
        uci set firewall.sswg_zone.masq='1'
        uci set firewall.sswg_zone.mtu_fix='1'
        uci set firewall.sswg_zone.network='surfshark'
        uci set firewall.sswg_forwarding=forwarding
        uci set firewall.sswg_forwarding.src='lan'
        uci set firewall.sswg_forwarding.dest='surfsharkwg'
        uci commit firewall
        /etc/init.d/firewall restart
    else
        echo "No changes made to the firewall"
    fi
 
    echo "$(ls -xA ${config_folder}/conf/)"
    read -p "Please enter your choice of server: " selection
    echo "Peer selected "$selection >> $sswg_log
    if [ -f ${config_folder}/conf/${selection} ]; then
        peer_desc=$(eval echo $(jq '.description' ${config_folder}/conf/${selection}))
        peer_key=$(eval echo $(jq '.public_key' ${config_folder}/conf/${selection}))
        peer_host=$(eval echo $(jq '.endpoint_host' ${config_folder}/conf/${selection}))
        uci set network.peer_surfshark=wireguard_surfshark
        uci set network.peer_surfshark.description=${peer_desc}
        uci set network.peer_surfshark.public_key=${peer_key}
        uci set network.peer_surfshark.allowed_ips='0.0.0.0/0'
        uci set network.peer_surfshark.route_allowed_ips='1'
        uci set network.peer_surfshark.endpoint_host=${peer_host}
        uci set network.peer_surfshark.endpoint_port='51820'
        uci set network.peer_surfshark.persistent_keepalive='25'
        uci commit network
        /etc/init.d/network restart
        cp "${config_folder}/conf/${selection}" ${config_folder}/surfshark
    else
        echo "server conf not recognised"
        surfshark
    fi
}

surfshark_switch() {
    echo "Current surfshark wireguard server is: "$(eval echo $(jq '.description' ${config_folder}/surfshark))
    echo "$(ls -xA ${config_folder}/conf/)"
    read -p "Please enter your choice of server: " selection
    echo "Peer selected "$selection >> $sswg_log
    if [ -f ${config_folder}/conf/${selection} ]; then
        peer_desc=$(eval echo $(jq '.description' ${config_folder}/conf/${selection}))
        peer_key=$(eval echo $(jq '.public_key' ${config_folder}/conf/${selection}))
        peer_host=$(eval echo $(jq '.endpoint_host' ${config_folder}/conf/${selection}))
        uci set network.peer_surfshark.description=${peer_desc}
        uci set network.peer_surfshark.public_key=${peer_key}
        uci set network.peer_surfshark.endpoint_host=${peer_host}
        uci commit network
        /etc/init.d/network restart
        cp -f "${config_folder}/conf/${selection}" ${config_folder}/surfshark
    else
        echo "server conf not recognised"
        surfshark_switch
    fi
}

reset_surfshark() {
    # set everything back to a blank state excluding config.json
    echo "removing network settings"
    uci -q delete network.sswg
    uci -q delete network.surfshark
    uci -q delete network.wgs_surfshark
    uci -q delete network.peer_surfshark
    uci commit network
    /etc/init.d/network restart
    echo "removing firewall settings"
    uci -q delete firewall.sswg_zone
    uci -q delete firewall.sswg_forwarding
    uci commit firewall
    /etc/init.d/firewall restart
    echo "removing generated configuration files"
    rm -fr ${config_folder}/conf
    rm -f ${config_folder}/*servers.json
    rm -f ${config_folder}/wg.json
    rm -f ${config_folder}/token.json
    rm -f ${config_folder}/token_expires.json
    rm -f ${config_folder}/surfshark
    echo "All settings deleted." >> $sswg_log
}

read_config
parse_arg "$@"

if [ $reset_all -eq 1 ]; then
    reset_surfshark
    exit 1
fi

if [ $generate_servers -eq 1 ]; then
    get_servers
    gen_client_confs
    echo "server list now:"
    echo "$(ls -xA ${config_folder}/conf/)"
    exit 1
fi

if [ $switch_conf -eq 1 ]; then
    surfshark_switch
    exit 1
fi

if [ $check_status -eq 1 ]; then
    wg_user_status
    exit 1
fi

if [ $renew_token -eq 1 ]; then
        wg_token_renwal
        wg_check_pubkey
    exit 1
fi

echo "Logging in if needed ..."
if [ -f "$token_file" ]; then
    echo "login not required ..."
else
    wg_login
fi

echo "Generating keys ..."
if [ -f "$wg_keys" ]; then
    echo "using existent wg keys"
else 
    wg_gen_keys
fi

echo "Registring public key ..."
wg_register_pub

if [ $generate_conf -eq 1 ]; then
    echo "Getting the list of servers ..."
    get_servers

    echo "Generating server profiles ..."
    gen_client_confs
fi

if [ ! -f ${config_folder}/surfshark ]; then
	surfshark
fi

echo "Done!"
