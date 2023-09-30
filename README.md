# ipset-blocklist

A Bash shell script which uses ipset and iptables to ban a large number of IP addresses published in IP blocklists. ipset uses a hashtable to store/fetch IP addresses and thus the IP lookup is a lot (!) faster than thousands of sequentially parsed iptables ban rules. ~~However, the limit of an ipset list is 2^16 entries.~~

The ipset command doesn't work under OpenVZ. It works fine on dedicated and fully virtualized servers like KVM though.

## What's new

- 10/17/2018: Added support for CIDR aggregation if iprange command is available
- 10/17/2018: Merged Shellcheck PR from [@extremeshok](https://github.com/extremeshok)
- 05/10/2018: Added regex filter improvements from [@sbujam](https://github.com/sbujam)
- 08/15/2017: Filtering default gateway and multicast ranges
- 01/20/2017: Ignoring "Service unavailable" HTTP status code, removed IGNORE_CURL_ERRORS 
- 11/04/2016: Documentation added to show how to prevent fail2ban from inserting its rules above the ipset-blocklist when restarting the fail2ban service
- 11/11/2015: Merged all suggestions from [@drzraf](https://github.com/drzraf)
- 10/24/2015: Outsourced the entire configuration in it's own configuration file. Makes updating the shell script way easier!
- 10/22/2015: Changed the documentation, the script should be put in /usr/local/sbin not /usr/local/bin

## Quick start for Debian/Ubuntu based installations

1. `wget -O /usr/local/sbin/update-blocklist.sh https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/update-blocklist.sh`
2. `chmod +x /usr/local/sbin/update-blocklist.sh`
3. `mkdir -p /etc/ipset-blocklist ; wget -O /opt/ipset-blocklist/ipset-blocklist.conf https://raw.githubusercontent.com/rgnldo/ipset-blocklist/master/ipset-blocklist.conf`
4. Modify `ipset-blocklist.conf` according to your needs. Per default, the blocklisted IP addresses will be saved to `/opt/ipset-blocklist/ip-blocklist.restore`
5. `apt-get install ipset`
6. Create the ipset blocklist and insert it into your iptables input filter (see below). After proper testing, make sure to persist it in your firewall script or similar or the rules will be lost after the next reboot.
7. Auto-update the blocklist using a cron job

## First run, create the list

to generate the `/opt/ipset-blocklist/ip-blocklist.restore`:

```sh
/usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf
```

## iptables filter rule

```sh
# Enable blocklists
ipset restore < /opt/ipset-blocklist/ip-blocklist.restore
iptables -I INPUT 1 -m set --match-set blocklist src -j DROP
```

Make sure to run this snippet in a firewall script or just insert it to `/etc/rc.local`.

## Cron job

In order to auto-update the blocklist, copy the following code into `/etc/cron.d/update-blocklist`. Don't update the list too often or some blocklist providers will ban your IP address. Once a day should be OK though.

```sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=root
33 23 * * *      root /usr/local/sbin/update-blocklist.sh /opt/ipset-blocklist/ipset-blocklist.conf
```

## Check for dropped packets

Using iptables, you can check how many packets got dropped using the blocklist:

```sh
drfalken@wopr:~# iptables -L INPUT -v --line-numbers
Chain INPUT (policy DROP 60 packets, 17733 bytes)
num   pkts bytes target            prot opt in  out source   destination
1       15  1349 DROP              all  --  any any anywhere anywhere     match-set blocklist src
2        0     0 fail2ban-vsftpd   tcp  --  any any anywhere anywhere     multiport dports ftp,ftp-data,ftps,ftps-data
3      912 69233 fail2ban-ssh-ddos tcp  --  any any anywhere anywhere     multiport dports ssh
4      912 69233 fail2ban-ssh      tcp  --  any any anywhere anywhere     multiport dports ssh
```

Since iptable rules are parsed sequentally, the ipset-blocklist is most effective if it's the **topmost** rule in iptable's INPUT chain. However, restarting fail2ban usually leads to a situation, where fail2ban inserts its rules above our blocklist drop rule. To prevent this from happening we have to tell fail2ban to insert its rules at the 2nd position. Since the iptables-multiport action is the default ban-action we have to add a file to `/etc/fail2ban/action.d`:

```sh
tee << EOF /etc/fail2ban/action.d/iptables-multiport.local
[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> 2 -p <protocol> -m multiport --dports <port> -j f2b-<name>
EOF
```

(Please keep in in mind this is entirely optional, it just makes dropping blocklisted IP addresses most effective)

## Modify the blocklists you want to use

Edit the BLOCKLIST array in /opt/ipset-blocklist/ipset-blocklist.conf to add or remove blocklists, or use it to add your own blocklists.

```sh
BLOCKLISTS=(
"http://www.mysite.me/files/mycustomblocklist.txt" # Your personal blocklist
"http://www.projecthoneypot.org/list_of_ips.php?t=d&rss=1" # Project Honey Pot Directory of Dictionary Attacker IPs
# I don't want this: "http://www.openbl.org/lists/base.txt"  # OpenBL.org 30 day List
)
```

If you for some reason want to ban all IP addresses from a certain country, have a look at [IPverse.net's](http://ipverse.net/ipblocks/data/countries/) aggregated IP lists which you can simply add to the BLOCKLISTS variable. For a ton of spam and malware related blocklists, check out this github repo: https://github.com/firehol/blocklist-ipsets

## Troubleshooting

### Set blocklist-tmp is full, maxelem 65536 reached

Increase the ipset list capacity. For instance, if you want to store up to 80,000 entries, add these lines to your ipset-blocklist.conf:  

```conf
MAXELEM=80000
```

### ipset v6.20.1: Error in line 2: Set cannot be created: set with the same name already exists

If this happens after changing the `MAXELEM` parameter: ipset seems to be unable to recreate an exising list with a different size. You will have to solve this manually by deleting and inserting the blocklist in ipset and iptables. A reboot will help as well and may be easier. You may want to remove `/opt/ipset-blocklist/ip-blocklist.restore` too because it may still contain the old MAXELEM size.

### ipset v6.12: No command specified: unknown argument -file

You're using an outdated version of ipset which is not supported.
