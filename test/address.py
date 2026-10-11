import json
import sys

state = json.load(open(sys.argv[1]))["resources"]
for key in ("openstack.openstack_networking_floatingip_v2.host",
            "openstack.openstack_networking_port_v2.host"):
    res = state.get(key)
    if not res:
        continue
    attrs = res["attrs"]
    value = attrs.get("address") or (attrs.get("all_fixed_ips") or [None])[0]
    if value:
        print(value)
        break
