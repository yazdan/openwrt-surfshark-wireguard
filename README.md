# Intro

This is a simple script that generates wireguard client config files for surfshark
You just need to `curl` and `jq`.

# How to use
To use this file:
1. copy `config.json.sample` into `config.json`
2. replace `config.json` values with your account values. Normally user your "email" and "password" that you use on your official client on Android, iOS, or web, not specially OpenVpn username and password
3. run `gen_wg_config.sh` or place a link in your run path to be able to call the script as required e.g. ln -sf /etc/config/surfshark/gen_wg_config.sh /usr/bin/surfshark
4. for the bash version it will then use wg-quick to bring up your preferred surfshark vpn server

## usage

```shell
Usage: gen_wg_config.sh [-f]
-f forces registeration, ignores validation
-g ignore generating profile files
-C clear keys and profile files before generating new ones
-s switch from one surfshark wireguard conf to another
-d shutdown wireguard
```

The -s & -d switches are only in the bash version (ends .bash) not the ash version (ends .sh) as it makes use of features not present in ash including wg-quick.

# Caveats

Please consider following caveats

## Your private/public key expires

The token will last 7 days so it needs to be regenerated before then.
I recommend setting up a cron job to run once a week during a known slack period, and with `-g` parameter.

## Sometimes registering or validating the public key fails

If you are not able to use the generated config files, there might be a chance that there is an unhandled corner case in one of the functions. Check that wg.json and token.json files have been generated. Review the output, this should show where the script failed. It may be worth trying to force the registration of the public key with the -f switch.

# TODO

- implement auto refresh token
- generate luci configuration

Contributors:
yazdan
ruralroots
kyndair
