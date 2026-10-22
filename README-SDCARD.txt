NixOS for the Doogee U10 tablet
===============================

Put these files on this partition (FIRMWARE):

  wifi.conf        Your Wi-Fi network. Copy wifi.conf.example and edit it.
  authorized_keys  Your SSH public key(s), e.g. a copy of ~/.ssh/id_ed25519.pub

Log in:

  Wi-Fi:  ssh root@doogee-u10.local
  USB:    connect the tablet's USB-C port to a PC, then
          ssh root@10.42.0.1
  Console (USB keyboard): root / doogee  (change with passwd)

Power button: short press = suspend / wake up, hold 3 s = power off.

Boot logs for troubleshooting are written here as dmesg-initrd.txt and
dmesg-stage2.txt.
