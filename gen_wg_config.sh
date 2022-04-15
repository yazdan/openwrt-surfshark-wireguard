#!/bin/sh
set -e

read_config1() {
    config_folder=$(dirname $(readlink -f $0))

    config_file=${config_folder}/"config.json"
    conf_json=$(cat $config_file)
   
    username="$(echo $conf_json | jq '.username')"
    username=$(eval echo $username)

    password="$(echo $conf_json | jq '.password')"
    password=$(eval echo $password)

    wg_keys="${config_folder}/wg.json"
    token_file="${config_folder}/token.json"

    baseurl_1="https://api.surfshark.com"
    baseurl_2="https://ux.surfshark.com"
    baseurl_3="https://api.uymgg1.com"
    baseurl_4="https://ux.uymgg1.com"
    urlcount=4

    force_register=0
    register=1
    generate_conf=1
    reset_all=0
    wireguard_down=0
    generate_servers=0
    switch_conf=0

    unset conf_json
}

parse_arg() {
    while getopts 'fhgrC' opt; do
        case "$opt" in
            C)  reset_all=1         ;;
            f)  force_register=1    ;;
            g)  generate_conf=0     ;;
            r)  generate_servers=1  ;;
#            s)  switch_conf=1       ;;
            ?|h)
            echo "Usage: $(basename $0) [-f]"
            echo "  -f force register, ignore checking"
            echo "  -g skip generating server conf files"
            echo "  -r regenerate the server conf files"
#            echo "  -s switch from one surfshark wireguard conf to another"
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
        curl_res=$(cat $token_file)
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
            data="{\"username\":\"$username\", \"password\":\"$password\"}"
            token=$(eval echo $token)
            http_status=$(curl -o $tmpfile -s -w "%{http_code}" -d "$data" -H 'Content-Type: application/json' -X POST $url)
            echo "Login "$url $http_status
        done
        cp $tmpfile $token_file
        rm $tmpfile
    fi
    token=$(echo $curl_res | jq '.token')
    renewToken=$(echo $curl_res | jq '.renewToken')
}

wg_gen_keys() {
    if [ -f "$wg_keys" ]; then
        echo "using existent wg keys"
        wg_pub=$(cat $wg_keys | jq '.pub')
        wg_prv=$(cat $wg_keys | jq '.prv')
        wg_prv=$(eval echo $wg_prv)
    else 
        echo "generating new keys"
        wg_prv=$(wg genkey)
        wg_pub=$(echo $wg_prv | wg pubkey)
        echo "{\"pub\":\"$wg_pub\", \"prv\":\"$wg_prv\"}" > $wg_keys
    fi
}

read_config2() {
    curl_res=$(cat $token_file)
    token=$(echo $curl_res | jq '.token')
    renewToken=$(echo $curl_res | jq '.renewToken')

    generic_servers_file="${config_folder}/generic_servers.json"
    static_servers_file="${config_folder}/static_servers.json"
    obfuscated_servers_file="${config_folder}/obfuscated_servers.json"
    double_servers_file="${config_folder}/double_servers.json"
}

wg_reg_pubkey() {
    curl_reg=401
    basen=1
    error_count=0
    while [ -z "${curl_reg##*401*}" ]; do
        baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            echo "Token was not recognised, or Public Key was rejected please try again."
            echo "If it fails repeatedly check your credentials and that a token exists."

            exit 2
        fi
        url=$(eval echo \${$baseurl})/v1/account/users/public-keys
        data="{\"pubKey\": $wg_pub}"
        token=$(eval echo $token)
        curl_reg=$(eval curl -H \"Authorization: Bearer $token\" -H \"Content-Type: application/json\" -d \'$data\' -X POST $url)
        echo "Registration "$url $curl_reg
        let basen=$basen+2
        if [ -z "${curl_reg##*Expired*}" ]; then
            rm -f ${config_folder}/token.json ${config_folder}/wg.json  # temp solution
            wg_login                                                    # until renewal
            wg_gen_keys                                                 # is sorted
            basen=1                                              #
            continue                                                       #
        elif [ -z "${curl_reg##*Token not found*}" ] && [ $error_count -eq 0 ]; then
            curl_res=$(cat $token_file)
            token=$(echo $curl_res | jq '.token')
            renewToken=$(echo $curl_res | jq '.renewToken')
            error_count=1
            basen=1
        elif [ -z "${curl_reg##*Token not found*}" ] && [ $error_count -eq 1 ]; then
            echo "Token was not recognised, or Public Key was rejected please try again."
            echo "If it fails repeatedly check your credentials and that a token exists."
            exit 2
        fi
    done
}

wg_check_pubkey() {
    tmpfile=$(mktemp /tmp/wg-curl-val.XXXXXX)
    http_status=0
    basen=0
    until [ $http_status -eq 200 ]; do
        let basen=$basen+1; baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            echo "Public Key was not validated & authorised, please try again."
            echo "If it fails repeatedly check your credentials and that key registration has completed."
            rm $tmpfile
            exit 2
        fi
        url=$(eval echo \${$baseurl})/v1/account/users/public-keys/validate
        data="{\"pubKey\": $wg_pub}"
        token=$(eval echo $token)
        http_status=$(eval curl -o $tmpfile -s -w "%{http_code}" -H \"Authorization: Bearer $token\" -H \"Content-Type: application/json\" -d \'$data\' -X POST $url)
        echo "Validation "$url $http_status
    done
    curl_val=$(cat $tmpfile)
    expire_date=$(echo $curl_val | jq '.expiresAt')
    expire_date=$(eval echo $expire_date)
    now=$(date -Iseconds --utc)
    if [ "${now}" '<' "${expire_date}" ];then
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
            http_status=$(curl -o $tmpfile -s -w "%{http_code}" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' $url)
            echo $server" servers "$url $http_status
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

#            echo "generating file for $srv_host"
            
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

			srv_conf_file=${config_folder}/conf/${file_name}.conf

            srv_conf="[Peer]\ndescription=${srv_host%$postf}\npublic_key=$srv_pub\nendpoint_host=$srv_host"

            if [ -f "$srv_conf_file" ]; then
                echo -e "$srv_conf" > $srv_conf_file
            else
                echo -e "$srv_conf" >> $srv_conf_file
            fi

        done
        file_removal="$server""_servers_file"
        file_removal=$(eval echo \${$file_removal})
        rm -f $file_removal
    done
}

surfshark_up() {
    network_test1=$(grep -w -e surfshark /etc/config/network)
    network_test2=$(grep -w -e wireguard /etc/config/network)
    if [ ! $(set -f -- $network_test1; echo $#) -gt 0 ] || [ ! $(set -f -- $network_test2; echo $#) -gt 0 ]; then
        wg_prv=$(cat $wg_keys | jq '.prv')
        wg_prv=$(eval echo $wg_prv)
        uci add network device
        uci set network.@device[-1]=device
        uci set network.@device[-1].name='surfshark'
        uci set network.@device[-1].ipv6='0'
        uci set network.@device[-1].promisc='1'
        uci set network.@device[-1].acceptlocal='1'
        uci set network.surfshark=interface
        uci set network.surfshark.proto='wireguard'
        uci set network.surfshark.private_key=${wg_prv}
        uci set network.surfshark.listen_port='51820'
        uci set network.surfshark.addresses='10.14.0.2/8'
        uci add network wireguard_surfshark
        uci set network.@wireguard_surfshark[-1]=wireguard_surfshark
        uci set network.@wireguard_surfshark[-1].description='wgs'
        uci set network.@wireguard_surfshark[-1].public_key='o07k/2dsaQkLLSR0dCI/FUd3FLik/F/HBBcOGUkNQGo='
        uci set network.@wireguard_surfshark[-1].allowed_ips='172.16.0.36/32'
        uci set network.@wireguard_surfshark[-1].route_allowed_ips='1'
        uci set network.@wireguard_surfshark[-1].endpoint_host='wgs.prod.surfshark.com'
        uci set network.@wireguard_surfshark[-1].endpoint_port='51820'
        uci set network.@wireguard_surfshark[-1].persistent_keepalive='25'
        uci commit network
        /etc/init.d/network restart
    else
        echo "No changes made to the network"
    fi

    firewall_test1=$(grep -w -e surfsharkwg /etc/config/firewall)
    firewall_test2=$(grep -w -e surfshark /etc/config/firewall)
    if [ ! $(set -f -- $firewall_test1; echo $#) -gt 0 ] || [ ! $(set -f -- $firewall_test2; echo $#) -gt 0 ]; then
        uci add firewall zone
        uci set firewall.@zone[-1]=zone
        uci set firewall.@zone[-1].name='surfsharkwg'
        uci set firewall.@zone[-1].input='REJECT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='REJECT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci set firewall.@zone[-1].network='surfshark'
        uci add firewall forwarding
        uci set firewall.@forwarding[-1]=forwarding
        uci set firewall.@forwarding[-1].src='lan'
        uci set firewall.@forwarding[-1].dest='surfsharkwg'
        uci commit firewall
        /etc/init.d/firewall restart
    else
        echo "No changes made to the firewall"
    fi
 
    echo "$(ls -xA ${config_folder}/conf/)"
    read -p "Please enter your choice of server: " selection
    if [ -f ${config_folder}/conf/${selection} ]; then
        peer_desc=$(awk -F '=' '$1 ~ /^d/ {print $2}' ${config_folder}/conf/${selection})
        peer_key=$(awk -F '=' '$1 ~ /^p/ {print $2}' ${config_folder}/conf/${selection})
        peer_host=$(awk -F '=' '$1 ~ /^e/ {print $2}' ${config_folder}/conf/${selection})
        uci add network wireguard_surfshark
        uci set network.@wireguard_surfshark[-1]=wireguard_surfshark
        uci set network.@wireguard_surfshark[-1].description=${peer_desc}
        uci set network.@wireguard_surfshark[-1].public_key=${peer_key}=
        uci set network.@wireguard_surfshark[-1].allowed_ips='0.0.0.0/0'
        uci set network.@wireguard_surfshark[-1].route_allowed_ips='1'
        uci set network.@wireguard_surfshark[-1].endpoint_host=${peer_host}
        uci set network.@wireguard_surfshark[-1].endpoint_port='51820'
        uci set network.@wireguard_surfshark[-1].persistent_keepalive='25'
        uci commit network
        /etc/init.d/network restart
        echo "${config_folder}/conf/${selection}" >> ${config_folder}/surfshark
    else
        echo "server conf not recognised"
        surfshark_up
    fi
}

reset_surfshark() {
#    if [ -e ${config_folder}/surfshark ]; then
#        rm ${config_folder}/surfshark
#    fi
    if [ -e ${config_folder}/wg.json ]; then
        echo "Clearing old settings ..."
        rm -fr ${config_folder}/conf ${config_folder}/*servers.json ${config_folder}/token.json ${config_folder}/wg.json
    else
        echo "No old keys or profiles found."
    fi
}

read_config1
parse_arg "$@"

if [ $reset_all -eq 1 ]; then
    reset_surfshark
fi

if [ $generate_servers -eq 1 ]; then
    read_config2
    get_servers
    gen_client_confs
    echo "server list now:"
    echo "$(ls -xA ${config_folder}/conf/)"
    exit 1
fi

#if [ $switch_conf -eq 1 ]; then
#    surfshark_up
#    exit 1
#fi

echo "Logging in if needed ..."
wg_login

echo "Generating keys ..."
wg_gen_keys

read_config2

if [ $register -eq 1 ]; then
    echo "Registring pubkey ..."
    wg_reg_pubkey
else
    echo "No need to register pubkey"
fi

if [ $force_register -eq 0 ]; then
    echo "Checking pubkey ..."
    wg_check_pubkey
fi

echo "Getting the list of servers ..."
get_servers

if [ $generate_conf -eq 1 ]; then
echo "Generating profiles ..."
    gen_client_confs
fi

if [ ! -e ${config_folder}/surfshark ]; then
	surfshark_up
fi

echo "Done!"
