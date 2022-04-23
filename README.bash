# Intro

This is a simple script that generates wireguard client config files for
surfshark

You just need to have `curl` and `jq` installed.

# How to use
To use this file:
1. copy `config.json.sample` into `config.json`
2. replace `config.json` values with your account values.
Normally its your "email" and "password" that you use on your official client
on Android, iOS, or web, not the OpenVpn username and password
For "config_folder" value best to use full path and make sure directory exists.
The "config_folder" will have all needed keys etc and a directory called configs
will be created under it where all generated wireguard server conf files will
be generated.
3. run `gen_wg_config.bash`

## usage

```bash shell
Usage: gen_wg_config.bash [-h]
  -g ignore generating profile files
  -n renew tokens
  -r regenerate the server conf files
  -Z clear settings, keys and server profile files
...

# Caveats
Please consider following caveats

## Disclaimer
Use the script at your own risk :).
We are not responsable if anything goes wrong

## First time running script
You may need to run script a few timed with no parameters if you have never run
script before. This is to make sure all needed files are created and your keys
are registered.
If you keep getting registeration errors, wait a bit (no idea how long) and try
later it eventually will work.

## Your private/public key expires
The token will last around 7 days so it needs to be regenerated before then.
I run the script with no parameters every 6 days.
It's also recommendef that a cron job is set to run every day during a known
slack period with -n flag to keep your keys refreshed

## The server list changes every so often and the load changes fairly often.
It is best to regularly update the server list and make sure you're
still using the best server(s) for you. I noticed especially for static servers some go and come.
You can do this by runnimg with -r option to regenerate server list.

## Sometimes registering or validating the public key fails
If you are not able to use the generated config files, there might be a chance that there is an
unhandled corner case in one of the functions. Check that wg.json and token.json files have been
generated. Review the output, this should show where the script failed. Output is logged to
sswg.log in the same folder as the script.

# TODO
- fold in any updates done by kyndair :).

Contributors: 
yazdan  - original concept script
kyndair - original author of bash script
yarafie - modified kyndair's bash script to work similar as yazdan's sh script
