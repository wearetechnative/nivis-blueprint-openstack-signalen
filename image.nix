# How the host becomes a qcow2 for Glance.
#
# This mirrors nixpkgs' maintainers/scripts/openstack/openstack-image.nix, but
# does not use it, because the two things worth changing there are `let`
# bindings rather than options:
#
#   qcow2-compressed   the image is uploaded on every apply, so its size is the
#                      single largest cost in a deploy
#   copyChannel=false  a host that is replaced rather than rebuilt in place has
#                      no use for a nixos channel or the manual
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
    "${modulesPath}/virtualisation/openstack-config.nix"
    "${modulesPath}/image/file-options.nix"
  ];

  image.baseName = "nixos";
  image.extension = "qcow2";
  system.nixos.tags = [ "openstack" ];

  documentation.enable = false;
  documentation.nixos.enable = false;

  # Lets OpenStack shut the host down gracefully and freeze the filesystem for
  # a snapshot, rather than pulling the plug.
  services.qemuGuest.enable = true;

  system.build.image = import "${modulesPath}/../lib/make-disk-image.nix" {
    inherit lib config pkgs;
    inherit (config.image) baseName;
    format = "qcow2-compressed";
    copyChannel = false;
    additionalSpace = "1024M";
  };
}
