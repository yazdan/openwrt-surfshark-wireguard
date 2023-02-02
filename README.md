# Intro

This is a simple script that generates wireguard client config files for surfshark

You just need to `curl` and `jq`.

I'm using this to generate configs on openwrt. But it can also be used to
generate config files for the [android wireguard client](https://git.zx2c4.com/wireguard-android/about/)
or for any linux distro.

# How to use
To use this file:
1. copy `config.json.sample` into `config.json`
2. replace `config.json` values with your account values. Normally user your
   "email" and "password" that you use on your official client on Android, iOS,
   or web, not specially OpenVPN username and password
3. run `gen_wg_config.sh`:
   - Run with no arguments to create (or update) wireguard temporary key pairs
   - Use the `-n` argument to create a new manual wireguard key pair (it will
     have an expiration time of 10 years)
   - It's possible to generate config files from a private key that is already
     registered, using the `-k` argument, or setting it in `wg.json`
   - Using `-z` option can generate an archive that can be imported straight
     forward to the android wireguard app

## usage

```shell
Usage: gen_wg_config.sh [-f]
  -f force register ignore checking
  -g ignore generating profile files
  -n <name> create a manual named key
  -k <key> use provided private key
  -l list registered manual keys
  -d <key-id> delete registered manual key
  -z [zip-file] zip archive in which to save the config files
```

# Caveates

Please consider following caveates

## Non-manual private/public key expires

As the date of writing this, each key pair expires in around 6 days so you need to rerun
the script every now and then.

I suggest to run it in crontab every day, and with `-g` parameter.

## Sometimes checking if public key is peresent fails

If you are not able to use the generated config files, there might be a chance that
there is an unhandleded corner case in `wg_check_pubkey` function. I suggest you to 
run the scring using `-f` parameter to force the script to register the key pair 
without checking if it exists.

# TODO

- implement refresh token
- generate luci configuration
