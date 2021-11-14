# Intro

This is a simple script that generates wireguard client config files for surfshark

You just need to `curl` and `jq`.

I'm using this to generate configs on openwrt

# How to use
To use this file:
1. copy `config.json.sample` into `config.json`
2. replace `config.json` values with your account values
3. run `gen_wg_config.sh`

# TODO

- implement refresh token
- generate luci configuration