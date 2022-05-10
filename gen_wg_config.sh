#!/bin/sh
set -e

parse_arg() {
    while getopts 'fhg' opt; do
        case "$opt" in
            f)
            force_register=1
            ;;
            g)
            generate_conf=0
            ;;
            ?|h)
            echo "Usage: $(basename $0) [-f]"
            echo "  -f force register ignore checking"
            echo "  -g ignore generating profile files"
            exit 1
            ;;
        esac
    done
    shift "$(($OPTIND -1))"
}


read_config() {
    config_file="config.json"
    conf_json=$(cat $config_file)
    
    config_folder="$(echo $conf_json | jq '.config_folder')"
    config_folder=$(eval echo $config_folder)
    
    username="$(echo $conf_json | jq '.username')"
    username=$(eval echo $username)

    password="$(echo $conf_json | jq '.password')"
    password=$(eval echo $password)

    token_file="${config_folder}/token.json"

    baseurl="https://api.surfshark.com"
    force_register=0
    register=1
    generate_conf=1
    selected_servers_file="${config_folder}/selected_servers.json"
    servers_file="${config_folder}/surf_servers.json"
    wg_keys="${config_folder}/wg.json"
    srv_conf_file_folder="${config_folder}/conf"
    
    unset conf_json
}

login () {
    if [ -f "$token_file" ]; then
        curl_res=$(cat $token_file)
    else
        tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
        url="$baseurl/v1/auth/login"
        data="{\"username\":\"$username\", \"password\":\"$password\"}"
        http_status=$(curl -o $tmpfile -s -w "%{http_code}" -d "$data" -H 'Content-Type: application/json' -X POST $url)
        if [ $http_status -eq 200 ]; then
            cp $tmpfile $token_file
        fi
        rm $tmpfile
    fi
    
    token=$(echo $curl_res | jq '.token')
    renewToken=$(echo $curl_res | jq '.renewToken')
    
}

get_servers() {
    if [ -f "$servers_file" ]; then
        echo "servers list already exist"
    else
        tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
        url="$baseurl/v4/server/clusters/generic?countryCode="
        http_status=$(curl -o $tmpfile -s -w "%{http_code}" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' $url)
        if [ $http_status -eq 200 ]; then
            cat $tmpfile > $servers_file
        fi
        rm $tmpfile
    fi
}

select_servers () {
    cat_res=$(cat $servers_file | jq 'select(any(.[].tags[]; . == "p2p" or . == "physical"))')
    echo $cat_res > $selected_servers_file
}

wg_gen_keys() {
    if [ -f "$wg_keys" ]; then
        echo "wg keys already exist"
        wg_pub=$(cat $wg_keys | jq '.pub')
        wg_prv=$(cat $wg_keys | jq '.prv')
        wg_prv=$(eval echo $wg_prv)
    else 
        wg_prv=$(wg genkey)
        wg_pub=$(echo $wg_prv | wg pubkey)
        echo "{\"pub\":\"$wg_pub\", \"prv\":\"$wg_prv\"}" > $wg_keys
    fi
}

wg_reg_pubkey() {
    url="$baseurl/v1/account/users/public-keys"
    data="{\"pubKey\": $wg_pub}"
    token=$(eval echo $token)
    curl_res=$(eval curl -H \"Authorization: Bearer $token\" -H \"Content-Type: application/json\"  -d \'$data\' -X POST $url)
}

wg_check_pubkey() {
    tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
    url="$baseurl/v1/account/users/public-keys/validate"
    data="{\"pubKey\": $wg_pub}"
    token=$(eval echo $token)
    http_status=$(eval curl -o $tmpfile -s -w "%{http_code}" -H \"Authorization: Bearer $token\" -H \"Content-Type: application/json\"  -d \'$data\' -X POST $url)
    if [ $http_status -eq 200 ]; then
        curl_res=$(cat $tmpfile)
        expire_date=$(echo $curl_res | jq '.expiresAt')
        expire_date=$(eval echo $expire_date)
        now=$(date -Iseconds --utc)
        if [ "${now}" '<' "${expire_date}" ];then
            register=0
	printf '%b' "\n\n\tWG AUTHENTICATION KEY REFRESH\n\n    RUN DATE:   "${now}"\n\n"
	printf '%b' " KEY EXPIRES:   "${expire_date}"\n\n"
	logger -t SSWG "RUN DATE:${now}   KEYS EXPIRE ON: ${expire_date}"
        fi
    elif [ $http_status -eq 401 ]; then
        rm -f $token_file
        echo "Unauthorized. Please run again"
        rm $tmpfile
        exit 1
    fi
    rm $tmpfile
}

gen_client_confs() {
    postf=".surfshark.com"
    mkdir -p $srv_conf_file_folder
    server_hosts=$(echo "${cat_res}" | jq -c '.[] | [.connectionName, .pubKey]')
    for row in $server_hosts; do
        srv_host="$(echo $row | jq '.[0]')"
        srv_host=$(eval echo $srv_host)

        srv_pub="$(echo $row | jq '.[1]')"
        srv_pub=$(eval echo $srv_pub)

        echo "generating config for $srv_host"

        srv_conf_file="${srv_conf_file_folder}/${srv_host%$postf}.conf"

        srv_conf="[Interface]\nPrivateKey=$wg_prv\nAddress=10.14.0.2/8\nMTU=1350\n\n[Peer]\nPublicKey=o07k/2dsaQkLLSR0dCI/FUd3FLik/F/HBBcOGUkNQGo=\nAllowedIPs=172.16.0.36/32\nEndpoint=wgs.prod.surfshark.com:51820\nPersistentKeepalive=25\n\n[Peer]\nPublicKey=$srv_pub\nAllowedIPs=0.0.0.0/0\nEndpoint=$srv_host:51820\nPersistentKeepalive=25\n"

        uci_conf=""

        if [ "`echo -e`" = "-e" ]; then
            echo "$srv_conf" > $srv_conf_file
        else
            echo -e "$srv_conf" > $srv_conf_file
        fi
    done
}

read_config
parse_arg "$@"

echo "Loggin in if needed ..."
login
echo "Getting the list of servers ..."
get_servers
echo "Selecting servers ..."
select_servers

echo "Generating keys ..."
wg_gen_keys

if [ $force_register -eq 0 ]; then
    echo "Checking pubkey ..."
    wg_check_pubkey
fi

if [ $register -eq 1 ]; then
    echo "Registring pubkey ..."
    wg_reg_pubkey
else
    echo "No need to register pubkey"
fi

if [ $generate_conf -eq 1 ]; then
echo "Generating profiles..."
    gen_client_confs
fi
echo "Done!"
