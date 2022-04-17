#!/bin/sh
set -e

read_config() {
    config_folder=$(dirname $(readlink -f $0))

    username=$(eval echo $(jq '.username' ${config_folder}/config.json))
    password=$(eval echo $(jq '.password' ${config_folder}/config.json))

    wg_keys="${config_folder}/wg.json"
    token_file="${config_folder}/token.json"
    token_expires="${config_folder}/token_expires.json"

    baseurl_1="https://api.surfshark.com"
    baseurl_2="https://ux.surfshark.com"
    baseurl_3="https://api.uymgg1.com"
    baseurl_4="https://ux.uymgg1.com"
    urlcount=4

    generic_servers_file="${config_folder}/generic_servers.json"
    static_servers_file="${config_folder}/static_servers.json"
    obfuscated_servers_file="${config_folder}/obfuscated_servers.json"
    double_servers_file="${config_folder}/double_servers.json"    

    force_register=0
    register=1
    generate_conf=1
    reset_all=0
    wireguard_down=0
    generate_servers=0
    switch_conf=0
}

parse_arg() {
    while getopts 'fhgrC' opt; do
        case "$opt" in
            C)  reset_all=1         ;;
            f)  force_register=1    ;;
            g)  generate_conf=0     ;;
            r)  generate_servers=1  ;;
            s)  switch_conf=1       ;;
            ?|h)
            echo "Usage: $(basename $0) [-f]"
            echo "  -f force register, ignore checking"
            echo "  -g skip generating server conf files"
            echo "  -r regenerate the server conf files"
            echo "  -s switch from one surfshark wireguard server to another"
            echo "  -C clear settings, keys and profile files before generating new ones"
            exit 1                  ;;
        esac
    done
    shift "$(($OPTIND -1))"
}

wg_login() {
#add in renewal option
#/v1/auth/renew
    http_status=0
    basen=0
    until [ $http_status -eq 200 ]; do
        tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
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
        cp $tmpfile $token_file
        rm $tmpfile
    done
    token=$(eval echo $(jq '.token' $token_file))
    renewToken=$(eval echo $(jq '.renewToken' $token_file))
}

wg_gen_keys() {
    if [ -f "$wg_keys" ]; then
        echo "using existent wg keys"
        wg_prv=$(eval echo $(jq '.prv' $wg_keys))
        wg_pub=$(eval echo $(jq '.pub' $wg_keys))
    else 
        echo "generating new keys"
        wg_prv=$(wg genkey)
        wg_pub=$(echo $wg_prv | wg pubkey)
        echo "{\"pub\":\"$wg_pub\", \"prv\":\"$wg_prv\"}" > $wg_keys
    fi
}

wg_reg_pubkey() {
    curl_reg=401
    basen=1
    error_count_et=0
    error_count_nt=0
    while [ -z "${curl_reg##*401*}" ]; do
        baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            echo "Token was not recognised/expired or the Public Key was rejected please try again."
            echo "If it fails repeatedly check your credentials and that a token exists."
            exit 2
        fi
        url=$(eval echo \${$baseurl})/v1/account/users/public-keys
        data="{\"pubKey\": $wg_pub}"
        token=$(eval echo $token)
        curl_reg=$(eval curl -H \"Authorization: Bearer $token\" -H \"Content-Type: application/json\" -d \'$data\' -X POST $url)
        echo "Registration "$url $curl_reg
        let basen=$basen+2
        if [ -z "${curl_reg##*Expired*}" ] && [ $error_count_et -eq 0 ]; then
            rm -f ${config_folder}/token.json ${config_folder}/wg.json  # temp solution
            wg_login                                                    # until renewal
            wg_gen_keys                                                 # is sorted
            error_count_et=1                                            #
            basen=1                                                     #
        elif [ -z "${curl_reg##*Token not found*}" ] && [ $error_count_nt -eq 0 ]; then
            token=$(eval echo $(jq '.token' $token_file))
            renewToken=$(eval echo $(jq '.renewToken' $token_file))
            error_count_nt=1
            basen=1
        elif [ -z "${curl_reg##*Token not found*}" ] && [ $error_count_nt -eq 1 ]; then
            echo "Token was not recognised."
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
    expire_date=$(eval echo $(jq '.expiresAt' $tmpfile))
    now=$(date -Iseconds --utc)
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
            "{\"description\":\"${srv_host%$postf}\",\"public_key\":\"$srv_pub\",\"endpoint_host\":\"$srv_host\"}" > ${config_folder}/conf/${file_name}.conf
        done
        file_removal="$server""_servers_file"
        file_removal=$(eval echo \${$file_removal})
        rm -f $file_removal
    done
}

surfshark_1st_up() {
    # allow fall back to wan if vpn off, can be overridden by kill switch
    network_wan=$(grep -w -e network.wan.metric=\"1024\" /etc/config/network)
    if [ ! $(IFS=.;set -f -- $network_test1; echo $#) -gt 0 ]; then
        uci set network.wan.metric="1024"
    fi

    network_test1=$(grep -w -e surfshark /etc/config/network)
    network_test2=$(grep -w -e wireguard /etc/config/network)
    if [ ! $(set -f -- $network_test1; echo $#) -gt 0 ] || [ ! $(set -f -- $network_test2; echo $#) -gt 0 ]; then
        wg_prv=$(eval echo $(jq '.prv' $wg_keys))
        uci set network.sswg=device
        uci set network.sswg.name='surfshark'
        uci set network.sswg.ipv6='0'
        uci set network.sswg.promisc='1'
        uci set network.sswg.acceptlocal='1'
        uci set network.surfshark=interface
        uci set network.surfshark.proto='wireguard'
        uci set network.surfshark.private_key=${wg_prv}
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
        surfshark_up
    fi
}

surfshark_switch() {
    echo "Current surfshark wireguard server is: "$(eval echo $(jq '.description' ${config_folder}/surfshark))
    echo "$(ls -xA ${config_folder}/conf/)"
    read -p "Please enter your choice of server: " selection
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
    surfshark_switch
    exit 1
fi

echo "Logging in if needed ..."
wg_login

echo "Generating keys ..."
wg_gen_keys

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
	surfshark_1st_up
fi

echo "Done!"
