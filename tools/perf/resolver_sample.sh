#!/bin/bash
# V0 resolver sampling — replicates Resolver::default() fetches at pin cfafeb4:
# GET {beacon}/v2/kaspa/mainnet/any/wrpc/borsh  (tls=false -> "any", Borsh encoding)
BEACONS=""
for n in eric maxim sean troy; do BEACONS="$BEACONS https://$n.kaspa.stream"; done
for n in john mike paul alex; do BEACONS="$BEACONS https://$n.kaspa.red"; done
for n in jake mark adam liam; do BEACONS="$BEACONS https://$n.kaspa.green"; done
for n in noah ryan jack luke; do BEACONS="$BEACONS https://$n.kaspa.blue"; done
echo "beacon,http_code,time_total_s,node_uid_or_err"
for b in $BEACONS; do
  url="$b/v2/kaspa/mainnet/any/wrpc/borsh"
  rm -f /tmp/resolver_body.json; out=$(curl -sL -o /tmp/resolver_body.json -w "%{http_code},%{time_total}" --max-time 10 "$url" 2>&1)
  code="${out%%,*}"; t="${out##*,}"
  if [ "$code" = "200" ]; then
    node=$(python3 -c "import json;d=json.load(open('/tmp/resolver_body.json'));print(d.get('uid','?')[:12]+' '+d.get('url','?')[:40])" 2>/dev/null || echo parse-err)
  else
    node=$(head -c 60 /tmp/resolver_body.json 2>/dev/null | tr -d '\n,' )
  fi
  echo "$b,$code,$t,$node"
done
