# The OpenStack substrate: image, network, firewall, data volume, host.
# A function of the built NixOS image + vars + the outputs ledger -> IR.
{ nivis, nixosImage, vars }:
ledger:
let
  inherit (nivis) mkResource mkData mkProvider toIR drvFile;

  n = vars.name;
  os = type: name: config: mkResource { provider = "openstack"; inherit type name config; };

  # Existing infra we only read: the provider's external (floating IP) network.
  external = mkData {
    provider = "openstack"; type = "openstack_networking_network_v2"; name = "external";
    config.name = vars.externalNetwork;
  };

  # --- the OS crossing into the infra ---------------------------------------
  # `drvFile` makes `nivis apply` build the image derivation and hand the qcow2
  # INSIDE it to Glance ($out is a directory; the file is $out/<fileName>).
  #
  # The RESOURCE NAME carries the store hash, so a changed image is a new
  # resource rather than a replacement of this one. That is not cosmetic: the
  # host holds the image, and nivis refuses to replace an object other
  # resources still hold ("cannot replace ...: these resources still depend on
  # it and exist"). Creating the new image alongside the old one sidesteps that
  # entirely, and the host then replaces to point at it, held by nothing.
  #
  # The cost is that the previous image stays in Glance and in state, because
  # nivis destroys what the configuration still declares and this no longer
  # declares it. That is also the rollback path, and test/e2e.sh sweeps them.
  imageTag = builtins.substring 0 8 (baseNameOf "${nixosImage.drv}");

  image = os "openstack_images_image_v2" "nixos_${imageTag}" {
    name = "${n}-nixos-${imageTag}";
    local_file_path = drvFile nixosImage.drv nixosImage.fileName;
    container_format = "bare";
    disk_format = "qcow2";
    visibility = "private";
  };

  # --- how the host reaches the world, and the world reaches it -------------
  # Two shapes, because clouds differ on what a tenant may create.
  #
  #   router mode (the default): a private network behind a router, with a
  #   floating IP in front. The usual OpenStack shape, and the portable one.
  #
  #   direct mode: a port straight on the provider's external network. Works
  #   when that network is `shared` as well as `router:external`, which is how
  #   Vexxhost ams1 publishes `public`. Needed there because Neutron refuses
  #   `create_router` with an external gateway in the same call (the policy
  #   rule create_router:external_gateway_info:enable_snat is admin-only), and
  #   one call is all the provider makes.
  #
  # Either way the PORT is the durable thing: it keeps its address when the
  # instance is replaced, which is what the blueprint promises.
  direct = vars.directAttach;

  network = os "openstack_networking_network_v2" "main" { name = n; };

  subnet = os "openstack_networking_subnet_v2" "main" {
    name = n;
    network_id = network.refAttr "id";
    cidr = "10.42.0.0/24";
    ip_version = 4;
    dns_nameservers = [ "9.9.9.9" "149.112.112.112" ];
  };

  router = os "openstack_networking_router_v2" "main" {
    name = n;
    external_network_id = external.refAttr "id";
  };

  routerIf = os "openstack_networking_router_interface_v2" "main" {
    router_id = router.refAttr "id";
    subnet_id = subnet.refAttr "id";
  };

  routerResources = [ network subnet router routerIf floatingIp ];

  # --- firewall --------------------------------------------------------------
  secgroup = os "openstack_networking_secgroup_v2" "host" {
    name = n;
    description = "Signalen: HTTP(S) from anywhere, SSH from the admin range";
  };

  allow = name: port: cidr: os "openstack_networking_secgroup_rule_v2" name {
    security_group_id = secgroup.refAttr "id";
    direction = "ingress";
    ethertype = "IPv4";
    protocol = "tcp";
    port_range_min = port;
    port_range_max = port;
    remote_ip_prefix = cidr;
  };

  # --- a stable address: the port outlives the instance ---------------------
  port = os "openstack_networking_port_v2" "host" (
    {
      name = n;
      security_group_ids = [ (secgroup.refAttr "id") ];
    }
    // (
      if direct then
        { network_id = external.refAttr "id"; }
      else
        {
          network_id = network.refAttr "id";
          fixed_ip = [{ subnet_id = subnet.refAttr "id"; }];
        }
    )
  );

  floatingIp = mkResource {
    provider = "openstack"; type = "openstack_networking_floatingip_v2"; name = "host";
    config = { pool = vars.externalNetwork; port_id = port.refAttr "id"; };
    # No attribute links these two, but the router must be wired first.
    meta.dependsOn = [ routerIf.id ];
  };

  # --- all state lives here, never on the (disposable) root disk ------------
  dataVolume = mkResource {
    provider = "openstack"; type = "openstack_blockstorage_volume_v3"; name = "data";
    config = { name = "${n}-data"; size = vars.dataVolumeGb; };
    meta.lifecycle.preventDestroy = vars.protectData;
  };

  # --- the host ---------------------------------------------------------------
  host = os "openstack_compute_instance_v2" "host" {
    name = n;
    flavor_name = vars.flavor;
    image_id = image.refAttr "id";
    network = [{ port = port.refAttr "id"; }];
    # Attached at boot (not afterwards), so /var/lib is there before any
    # service starts. Root disk dies with the instance; the data volume stays.
    block_device = [
      {
        uuid = image.refAttr "id";
        source_type = "image";
        destination_type = "local";
        boot_index = 0;
        delete_on_termination = true;
      }
      {
        uuid = dataVolume.refAttr "id";
        source_type = "volume";
        destination_type = "volume";
        boot_index = 1;
        delete_on_termination = false;
      }
    ];
  };
in
toIR {
  # Credentials come from the environment (OS_CLOUD / clouds.yaml, or OS_*).
  providers.openstack = mkProvider {
    source = "registry.opentofu.org/terraform-provider-openstack/openstack";
    config = { };
  };
  resources = [
    image secgroup
    (allow "ssh" 22 vars.adminCidr)
    (allow "http" 80 "0.0.0.0/0")
    (allow "https" 443 "0.0.0.0/0")
    port dataVolume host
  ] ++ (if direct then [ ] else routerResources);
  dataSources = [ external ];
  # Point DNS for <domain> and api.<domain> at this.
  # In direct mode the address comes from the instance rather than the port:
  # nivis resolves a ref only one attribute deep, and the port's addresses live
  # in the LIST `all_fixed_ips`. Both name the same (stable) port address.
  outputs.address =
    if direct then host.refAttr "access_ip_v4" else floatingIp.refAttr "address";
  inherit ledger;
}
