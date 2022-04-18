# Intro

This is a simple script that generates wireguard client config files for surfshark
You just need to `curl` and `jq`.

# openwrt ASH version usage
To use this file:
1. Replace the credentials in `config.json` your login email & password. This is your "email" & "password" that you use on to login to the website and in the official clients for Android, iOS, or Windoes, not the special OpenVpn username & password.
2. Run `gen_wg_config.sh` or place a link in your run path to be able to call the script as required e.g. `ln -s /etc/config/surfshark/gen_wg_config.sh /usr/bin/surfshark`
3. The script will generate the files and alter the settings using the uci interface. Please see the script for details.

# BASH version usage
To use this file:
1. The script will ask for your login email & password. The BASH version no longer stores them locally. This is your "email" & "password" that you use on to login to the website and in the official clients for Android, iOS, or Windoes, not the special OpenVpn username & password.
2. Run `gen_wg_config.sh` or place a link in your run path to be able to call the script as required e.g. `ln -s /etc/config/surfshark/gen_wg_config.sh /usr/bin/surfshark`
3. The required files will be generated and then using wg-quick your preferred surfshark vpn server can be used.


The server configuration files are named in the following way:
1. Server type, this can be generic (ordinary server suitable for most people), static, obfuscated & double.
2. Server country in ISO 2 digit format e.g. de for germany, us for united states of america
3. Server load, this indicates how busy the server is. In general using the closest is preferable but if another server that is further away is under a much lighter load it is usually best to use the less used server.
4. Server city, this is a 3 letter city code, if a city has more than one server additional identifying information is given.
5. Server tags. Unless tagged virtual the servers are physical. The other tag used is P2P indicating servers that fully support P2P usage.
examples of server names:- generic-ad-004-leu-virtual.conf generic-de-014-fra-p2p.conf generic-se-013-sto.conf static-uk-063-lon-st005-p2p.conf

## usage

```shell
Usage: gen_wg_config.sh [-h]
-c check status of user
-g ignore generating profile files
-d takedown a surfshark wireguard conf setup with this script
-u bring up a surfshark wireguard conf setup with this script
-n renew tokens
-r regenerate the server conf files
-s switch from one surfshark wireguard conf to another
-Z clear settings, keys and server profile files
```

The -u & -d switches are only in the bash version (ends .bash) not the ash version (ends .sh) as it makes use of features not present in ash including making use of wg-quick which is a bash script unsuitable for ash. Eventually both scripts should have parity of features.

# Caveats

Please take the following caveats into consideration

## Your private/public key expires

The token will last 7 days so it needs to be regenerated before then.
It's recommend that a cron job is set run every day during a known slack period with -n flag.

## The server list changes every so often and the load changes fairly often.

It is best to regularly update the server list and make sure you're still using the best server(s) for you.

## Sometimes registering or validating the public key fails

If you are not able to use the generated config files, there might be a chance that there is an unhandled corner case in one of the functions. Check that wg.json and token.json files have been generated. Review the output, this should show where the script failed. Output is logged to sswg.log in the same folder as the script

# TODO

- implement auto refresh of the login token
- implement auto refresh of the Server confs
- limit size of log file

Contributors:
yazdan
ruralroots
kyndair
