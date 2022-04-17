# Intro

This is a simple script that generates wireguard client config files for surfshark
You just need to `curl` and `jq`.

# How to use
To use this file:
1. Replace the credentials in `config.json` your login email & password. This is your "email" & "password" that you use on to login to the website and in the official clients for Android, iOS, or Windoes, not the special OpenVpn username & password.
2. Run `gen_wg_config.sh` or place a link in your run path to be able to call the script as required e.g. `ln -s /etc/config/surfshark/gen_wg_config.sh /usr/bin/surfshark`
3. The bash version will generate the required files then use wg-quick to bring up your preferred surfshark vpn server.
4. The openwrt ash version will generate the files and setup the required data using the uci interface.

The server configuration files are named in the following way:
1. Server type, this can be generic (ordinary server suitable for most people), static, obfuscated & double.
2. Server country in ISO 2 digit format e.g. de for germany us for united states of america
3. Server load, this indicates how busy the server is. In general using the closest is preferable but if another server that is further away is under a much lighter load it is usually best to use the less used server.
4. Server city, this is a 3 letter city code.
5. Server tags. Unless tagged virtual the servers are physical. The other tag used is P2P indicating servers that fully support P2P usage.

## usage

```shell
Usage: gen_wg_config.sh [-f]
-f forces registeration, ignores validation
-g ignore generating server configuration profile files
-C clear keys and profile files before generating new ones
-r regenerate server configuration profiles
-s switch from one surfshark wireguard conf to another
-u bring up wireguard
-d shutdown wireguard
```

The -u & -d switches are only in the bash version (ends .bash) not the ash version (ends .sh) as it makes use of features not present in ash including making use of wg-quick which is a bash script unsuitable for ash. Eventually both scripts should have parity of features.

# Caveats

Please take the following caveats into consideration

## Your private/public key expires

The token will last 7 days so it needs to be regenerated before then.
I recommend setting up a cron job to run every 5 days during a known slack period, and with `-g` parameter.

## The server list changes every so often and the load changes fairly often.

It is best to regularly update the server list and make sure you're still using the best server(s) for you.

## Sometimes registering or validating the public key fails

If you are not able to use the generated config files, there might be a chance that there is an unhandled corner case in one of the functions. Check that wg.json and token.json files have been generated. Review the output, this should show where the script failed. It may be worth trying to force the registration of the public key with the -f switch.

# TODO

- implement auto refresh of the login token
- implement auto refresh of the Server confs

Contributors:
yazdan
ruralroots
kyndair
