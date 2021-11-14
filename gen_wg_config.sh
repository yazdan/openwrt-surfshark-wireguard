#!/bin/sh

baseurl="https://api.surfshark.com"
config_file="config.json"

read_config() {
    conf_json=$(cat $config_file)
    
    config_folder="$(echo $conf_json | jq '.config_folder')"
    config_folder=$(eval echo $config_folder)
    
    username="$(echo $conf_json | jq '.username')"
    username=$(eval echo $username)

    password="$(echo $conf_json | jq '.password')"
    password=$(eval echo $password)
    
    unset conf_json
}

login () {
    token_file="${config_folder}/token.json"
    if [ -f "$token_file" ]; then
        curl_res=$(cat $token_file)
    else 
        url="$baseurl/v1/auth/login"
        data="{\"username\":\"$username\", \"password\":\"$password\"}"
        curl_res=$(curl -d "$data" -H 'Content-Type: application/json' -X POST $url)
        echo $curl_res > $token_file
    fi
    
    token=$(echo $curl_res | jq '.token')
    renewToken=$(echo $curl_res | jq '.renewToken')
    
}

get_servers() {
    servers_file="${config_folder}/surf_servers.json"
    echo $servers_file
    if [ -f "$servers_file" ]; then
        echo "servers list already exist"
    else 
        url="$baseurl/v4/server/clusters/generic?countryCode="
        curl_res=$(curl -H "Authorization: Bearer $token" -H 'Content-Type: application/json' $url)
        echo $curl_res > $servers_file
    fi
}

select_servers () {
    selected_servers_file="${config_folder}/selected_servers.json"
    cat_res=$(cat $servers_file | jq 'select(any(.[].tags[]; . == "p2p" or . == "physical"))')
    echo $cat_res > $selected_servers_file
}

wg_gen_keys() {
    wg_keys="${config_folder}/wg.json"
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
    if [ $register -eq 1 ]; then
        url="$baseurl/v1/account/users/public-keys"
        data="{\"pubKey\": $wg_pub}"
        token=$(eval echo $token)
        curl_res=$(eval curl -H \"Authorization: Bearer $token\" -H \"Content-Type: application/json\"  -d \'$data\' -X POST $url)
    else
        echo "No need to register pubkey"
    fi
}

wg_check_pubkey() {
    url="$baseurl/v1/account/users/public-keys/validate"
    data="{\"pubKey\": $wg_pub}"
    token=$(eval echo $token)
    curl_res=$(eval curl -H \"Authorization: Bearer $token\" -H \"Content-Type: application/json\"  -d \'$data\' -X POST $url)
    expire_date=$(echo $curl_res | jq '.expiresAt')
    expire_date=$(eval echo $expire_date)
    now=$(date -Iseconds --utc)
    register=1
    if [ "${now}" '<' "${expire_date}" ]
    then
        register=0
    fi
}

gen_client_confs() {
    srv_conf_file_folder="${config_folder}/conf"
    mkdir -p $srv_conf_file_folder
    server_hosts=$(echo "${cat_res}" | jq -c '.[] | [.connectionName, .pubKey]')
    for row in $server_hosts; do
        srv_host="$(echo $row | jq '.[0]')"
        srv_host=$(eval echo $srv_host)

        srv_pub="$(echo $row | jq '.[1]')"
        srv_pub=$(eval echo $srv_pub)

        echo "generating config for $srv_host"

        srv_conf_file="${srv_conf_file_folder}/$srv_host.conf"

        srv_conf="[Interface]\nPrivateKey=$wg_prv\nAddress=10.14.0.2/8\nMTU=1350\n\n[Peer]\nPublicKey=o07k/2dsaQkLLSR0dCI/FUd3FLik/F/HBBcOGUkNQGo=\nAllowedIPs=172.16.0.36/32\nEndpoint=wgs.prod.surfshark.com:51820\nPersistentKeepalive=25\n\n[Peer]\nPublicKey=$srv_pub\nAllowedIPs=0.0.0.0/0\nEndpoint=$srv_host:51820\nPersistentKeepalive=25\n"

        if [ "`echo -e`" = "-e" ]; then
            echo "$srv_conf" > $srv_conf_file
        else
            echo -e "$srv_conf" > $srv_conf_file
        fi
    done
}

read_config
login
get_servers
select_servers
wg_gen_keys
wg_check_pubkey
wg_reg_pubkey
gen_client_confs