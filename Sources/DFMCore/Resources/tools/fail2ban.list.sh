#!/bin/sh
# fail2ban's banned addresses, one "jail<TAB>address" line each, for every jail.
for j in $(fail2ban-client status | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); do
  fail2ban-client status "$j" | sed -n 's/.*Banned IP list:[[:space:]]*//p' | tr ' ' '\n' | awk -v j="$j" 'NF { print j "\t" $1 }'
done
