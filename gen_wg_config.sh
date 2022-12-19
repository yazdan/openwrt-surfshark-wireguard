#!/bin/sh
set -e

parse_arg() {
    while getopts 'fhgn:k:ld:' opt; do
        case "$opt" in
            f)
            force_register=1
            ;;
            g)
            generate_conf=0
            ;;
            l)
            list_registered=1
            ;;
            d)
            delete_registered="$OPTARG"
            ;;
            n)
            key_name="$OPTARG"
            ;;
            k)
            wg_prv="$OPTARG"
            ;;
            ?|h)
            echo "Usage: $(basename $0) [-f]"
            echo "  -f force register ignore checking"
            echo "  -g ignore generating profile files"
            echo "  -n <name> create a manual named key"
            echo "  -k <key> use provided private key"
            echo "  -l list registered manual keys"
            echo "  -d <key-id> delete registered manual key"
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
    list_registered=0
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
    if [ -z "$wg_prv" ] && [ -f "$wg_keys" ]; then
        echo "wg keys already exist"
        wg_pub=$(cat $wg_keys | jq '.pub')
        wg_prv=$(cat $wg_keys | jq '.prv')
        wg_prv=$(eval echo $wg_prv)
    else
        if [ -z "$wg_prv" ]; then
            wg_prv=$(wg genkey)
        fi

        wg_pub=$(echo $wg_prv | wg pubkey)

        if [ ! -f "$wg_keys" ]; then
            echo "{\"pub\":\"$wg_pub\", \"prv\":\"$wg_prv\"}" > $wg_keys
        fi
    fi
}

wg_reg_pubkey() {
    echo "registering pubkey..."
    url="$baseurl/v1/account/users/public-keys"
    if [ -n "$key_name" ]; then
        data='{"pubKey": "'$wg_pub'", "name": "'$key_name'", "manual": true}'
    else
        data='{"pubKey": "'$wg_pub'"}'
    fi

    token=$(eval echo $token)
    curl_res=$(eval curl -s -H \"Authorization: Bearer "$token"\" \
        -H \"Content-Type: application/json\"  -d \'$data\' -X POST $url)
    wg_key_data_check "$curl_res"
}

wg_key_data_check() {
    keyinfo="$1"
    is_refresh="$2"

    now=$(date -Iseconds --utc)
    expire_date=$(echo "$keyinfo" | jq -r '.expiresAt')
    name=$(echo "$keyinfo" | jq -r '.name')
    error_code=$(echo "$keyinfo" | jq -r '.code')

    if [ "$error_code" != "null" ]; then
        echo "Error $error_code: $(echo "$keyinfo" | jq -r '.message')"
        exit 1
    fi

    if [ -n "$key_name" ] && [ "$key_name" != "$name" ]; then
        echo "Provided name '$key_name' does not match key '$name'"
        exit 1
    fi

    if [ "${now}" '<' "${expire_date}" ]; then
        register=0
        if [ -n "$is_refresh" ]; then
            printf '%b' "\n\tWG AUTHENTICATION KEY REFRESH\n\n    RUN DATE:   ${now}\n\n"
        fi
        printf '%b' "$name KEY EXPIRES:   ${expire_date}\n\n"
        logger -t SSWG "RUN DATE:${now}   KEYS EXPIRE ON: ${expire_date}"

        return 0
    fi

    return 1
}

wg_get_registered() {
    tmpfile=$(mktemp /tmp/wg-curl-res.XXXX)
    url="$baseurl/v1/account/users/public-keys"
    token=$(eval echo "$token")
    http_status=$(eval curl -o "$tmpfile" -s -w "%{http_code}" \
        -H \"Authorization: Bearer "$token"\" \
        -H \"Content-Type: application/json\" -X GET "$url")
    if [ "$http_status" -eq 200 ]; then
        cat "$tmpfile"
    elif [ "$http_status" -eq 401 ]; then
        rm -f "$token_file"
        echo "Unauthorized. Please run again"
        rm "$tmpfile"
        exit 1
    fi
}

wg_list_registered() {
    registered="$(wg_get_registered)"
    n_keys=$(echo "$registered" | jq '. | length')

    if [ "$n_keys" -gt 0 ]; then
        echo " Name ¦ Public Key ¦ Expiration date ¦ Creation date ¦ ID"
        echo "---------------------------------------------------------"
    fi

    for i in $(seq 0 "$((n_keys-1))"); do
        keyinfo="$(echo "$registered" | jq '.['"$i"']')"
        name=$(echo "$keyinfo" | jq -r '.name')
        pubkey=$(echo "$keyinfo" | jq -r '.pubKey')
        id=$(echo "$keyinfo" | jq -r '.id')
        expiration=$(echo "$keyinfo" | jq -r '.expiresAt')
        creation=$(echo "$keyinfo" | jq -r '.createdAt')
        echo "$name ¦ $pubkey ¦ $expiration ¦ $creation ¦ $id"
    done
}

wg_delete_registered() {
    url="$baseurl/v1/account/users/public-keys/$delete_registered"
    token=$(eval echo "$token")
    http_status=$(eval curl -o /dev/null -s -w "%{http_code}" \
        -H \"Authorization: Bearer "$token"\" \
        -H \"Content-Type: application/json\" -X DELETE "$url")

    if [ "$http_status" = 200 ]; then
        return 0
    elif [ "$http_status" = 404 ]; then
        echo "Deletion failed: key '$delete_registered' not found"
    else
        echo "Deletion failed: $http_status"
    fi

    exit 1
}

wg_check_registered_pubkeys() {
    registered="$(wg_get_registered)"
    n_keys=$(echo "$registered" | jq '. | length')

    for i in $(seq 0 "$((n_keys-1))"); do
        keyinfo="$(echo "$registered" | jq '.['"$i"']')"
        pubkey=$(echo "$keyinfo" | jq '.pubKey')
        if [ "$pubkey" = "$wg_pub" ]; then
            name=$(echo "$keyinfo" | jq -r '.name')
            echo "pubkey for key '$name' found"
            if wg_key_data_check "$keyinfo"; then
                return 0
            fi
            break
        fi
    done

    return 1
}

wg_check_pubkey() {
    tmpfile=$(mktemp /tmp/wg-curl-res.XXXXXX)
    url="$baseurl/v1/account/users/public-keys/validate"
    data="{\"pubKey\": $wg_pub}"
    token=$(eval echo $token)
    http_status=$(eval curl -o $tmpfile -s -w "%{http_code}" -H \"Authorization: Bearer $token\" -H \"Content-Type: application/json\"  -d \'$data\' -X POST $url)
    if [ $http_status -eq 200 ]; then
        curl_res=$(cat $tmpfile)
        wg_key_data_check "$curl_res" "true"
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
    server_hosts=$(echo "${cat_res}" | jq -c '.[] | [.connectionName, .pubKey, .tags]')
    for row in $server_hosts; do
        srv_host="$(echo $row | jq -r '.[0]')"
        srv_pub="$(echo $row | jq -r '.[1]')"
        srv_tags="$(echo $row | jq -r '.[2]')"

        basename=ss-${srv_host%$postf}
        basename=${basename%.prod}

        taginfo=
        if [ "$(echo "$srv_tags" | jq -r 'index("p2p")')" != 'null' ]; then
            basename="${basename}-p2p"
            taginfo="p2p"
        fi
        if [ "$(echo "$srv_tags" | jq -r 'index("virtual")')" != 'null' ]; then
            basename="${basename}-v"
            if [ -z "$taginfo" ]; then
                taginfo="virtual"
            else
                taginfo="${taginfo}, virtual"
            fi
        fi

        if [ -n "$taginfo" ]; then
            echo "generating config for $srv_host ($taginfo)"
        else
            echo "generating config for $srv_host"
        fi

        srv_conf_file="${srv_conf_file_folder}/${basename}.conf"
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

if [ $list_registered -eq 1 ]; then
    wg_list_registered
    exit
fi

if [ -n "$delete_registered" ]; then
    wg_delete_registered
    exit
fi

echo "Getting the list of servers ..."
get_servers
echo "Selecting servers ..."
select_servers

echo "Generating keys ..."
wg_gen_keys

if [ $force_register -eq 0 ]; then
    echo "Checking pubkey ..."
    if ! wg_check_registered_pubkeys; then
        wg_check_pubkey
    fi
fi

if [ $register -eq 1 ]; then
    echo "Registring pubkey $key_name..."
    wg_reg_pubkey
else
    echo "No need to register pubkey"
fi

if [ $generate_conf -eq 1 ]; then
echo "Generating profiles..."
    gen_client_confs
fi
echo "Done!"
