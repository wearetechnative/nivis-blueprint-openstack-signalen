# The base host: a NixOS OpenStack guest that is rebuilt, never patched.
{ settings, ... }:
{
  system.stateVersion = "26.05";
  networking.hostName = settings.name;
  time.timeZone = "Europe/Amsterdam";

  # The Cinder data volume (second disk). Everything stateful on NixOS lives
  # under /var/lib, so the whole tree goes on it and survives an instance
  # replacement. Formatted on first boot only.
  #
  # /var/lib is on NixOS's pathsNeededForBoot list, so this is mounted in stage
  # 1. autoFormat (the x-systemd.makefs mount option) therefore only works
  # because stage 1 runs systemd, which is the default from 26.05 on. On 25.05
  # the scripted initrd silently dropped the option and panicked on the blank
  # volume instead.
  fileSystems."/var/lib" = {
    device = "/dev/vdb";
    fsType = "ext4";
    autoFormat = true;
  };

  # The OpenStack image profile logs to tty1 only, which Nova does not capture,
  # so `openstack console log show` comes back empty just when it is wanted.
  boot.kernelParams = [ "console=ttyS0,115200n8" ];

  # Access is declared here, not injected by the cloud, so the whole EC2-style
  # metadata path is dead weight. Leaving it on is not merely wasteful: the
  # fetcher wgets 169.254.169.254 with --retry-connrefused and no timeout, and
  # a port on a provider network has no Neutron metadata proxy to answer. It
  # then retries forever, and because ec2-data.nix orders apply-ec2-data before
  # sshd-keygen, sshd never starts at all.
  systemd.services.openstack-init.enable = false;
  systemd.services.apply-ec2-data.enable = false;
  systemd.services.amazon-init.enable = false;

  users.users.root.openssh.authorizedKeys.keys = [ settings.adminSshKey ];
  services.openssh.settings.KbdInteractiveAuthentication = false;

  networking.firewall.allowedTCPPorts = [ 22 80 443 ];

  # No in-place changes: a new config is a new image.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc.automatic = true;
}
