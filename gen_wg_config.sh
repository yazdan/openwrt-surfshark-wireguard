#!/bin/sh
set -e

read_config() {
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

    generic_servers_file="${config_folder}/generic_servers.json"
    static_servers_file="${config_folder}/static_servers.json"
    obfuscated_servers_file="${config_folder}/obfuscated_servers.json"
    double_servers_file="${config_folder}/double_servers.json"

    force_register=0
    register=1
    generate_conf=1
    reset_all=0
    wireguard_down=0
    switch_conf=0

    unset conf_json
}

parse_arg() {
    while getopts 'fhgsC' opt; do
        case "$opt" in
            C)  reset_all=1         ;;
            f)  force_register=1    ;;
            g)  generate_conf=0     ;;
            s)  switch_conf=1       ;;
            ?|h)
            echo "Usage: $(basename $0) [-f]"
            echo "  -f force register, ignore checking"
            echo "  -g ignore generating profile files"
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

wg_reg_pubkey() {
    curl_res=401
    basen=0
    while [ -z "${curl_res##*401*}" ]; do
        let basen=$basen+1; baseurl=baseurl_$basen
        if [ $basen -gt $urlcount ]; then
            echo "Token was not recognised, or Public Key was rejected please try again."
            echo "If it fails repeatedly check your credentials and that a token exists."
            rm $tmpfile
            exit 2
        fi
        url=$(eval echo \${$baseurl})/v1/account/users/public-keys
        data="{\"pubKey\": $wg_pub}"
        token=$(eval echo $token)
        curl_res=$(eval curl -H \"Authorization: Bearer $token\" -H \"Content-Type: application/json\" -d \'$data\' -X POST $url)
        echo "Registration "$url $curl_res
        if [ '$curl_res' = '{"code":401,"message":"Expired JWT Token"}' ]; then
            rm "${config_folder}/token.json"; wg_login
        elif [ '$curl_res' = '{"code":401,"message":"JWT Token not found"}' ]; then
            wg_login
        fi
    done
}

wg_check_pubkey() {
    tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
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
    curl_res=$(cat $tmpfile)
    expire_date=$(echo $curl_res | jq '.expiresAt')
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
    mkdir -p "${config_folder}/conf"
    server_type='generic static obfuscated double'
    for server in $server_type; do
        tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
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
    servers='generic static'
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

            echo "generating file for $srv_host"
            
            file_name=${srv_host%$postf}
            file_name=${file_name/'-'/'-'$srv_load'-'}
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
    done
}

surfshark_up() {
#automate the following

#NETWORK

#config interface 'surfshark'
#        option proto 'wireguard'
#        option private_key '$wg_prv'
#        list addresses '10.14.0.2/8'

#config wireguard_surfshark
#        option description 'wgs'
#        option public_key 'o07k/2dsaQkLLSR0dCI/FUd3FLik/F/HBBcOGUkNQGo='
#        list allowed_ips '172.16.0.36/32'
#        option endpoint_host 'wgs.prod.surfshark.com'
#        option endpoint_port '51820'
#        option persistent_keepalive '25'

#config wireguard_surfshark
#        option description '$conf_desc'
#        option public_key '$conf_pub_key'
#        list allowed_ips '0.0.0.0/0'
#        option endpoint_host '$conf_endpoint_host'
#        option endpoint_port '51820'
#        option persistent_keepalive '25'

#FIREWALL

#config zone
#        option name 'wireguard'
#        option input 'REJECT'
#        option output 'ACCEPT'
#        option forward 'REJECT'
#        option masq '1'
#        option mtu_fix '1'
#        list network 'surfshark'

#config forwarding
#        option src 'lan'
#        option dest 'wireguard' 
  
    echo "$(ls -xA ${config_folder}/conf/)"
    read -p "Please enter your choice of server: " selection
    read -p "Please enter the interface name: " interface
    if [ -f ${config_folder}/conf/${selection} ]; then
        sed -i "s/Address=/#Address=/" ${config_folder}/conf/${selection}
        sed -i "s/MTU=/#MTU=/" ${config_folder}/conf/${selection} 
        wg setconf ${interface} ${config_folder}/conf/${selection}
        echo "${config_folder}/conf/${selection}" >> ${config_folder}/surfshark
    else
        echo "server conf not recognised"
        surfshark_up
    fi
}

reset_surfshark() {
    if [ -e ${config_folder}/surfshark ]; then
        sed -i "s/#Address=/Address=/" $(cat ${config_folder}/surfshark)
        sed -i "s/#MTU=/MTU=/" $(cat ${config_folder}/surfshark)
        rm ${config_folder}/surfshark
    fi
    if [ -e ${config_folder}/wg.json ]; then
        echo "Clearing old settings ..."
        rm -fr ${config_folder}/conf ${config_folder}/selected_servers.json ${config_folder}/surf_servers.json ${config_folder}/token.json ${config_folder}/wg.json
    else
        echo "No old keys or profiles found."
    fi
}

read_config
parse_arg "$@"

if [ $reset_all -eq 1 ]; then
    reset_surfshark
fi

if [ $switch_conf -eq 1 ]; then
    surfshark_up
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
	surfshark_up
fi

echo "Done!"
