# Minimal touch GUI: sway, started automatically as user "tablet".
#
# - Windows are tabbed (each one fills the screen, tap the tabs to switch)
# - Top bar buttons: apps (launcher), keyboard (on-screen keyboard),
#   rotate, brightness, close window; volume, battery and clock on the right
# - The screen follows the accelerometer; the rotate button overrides that
#   until the tablet is turned
# - Power off, Reboot and Suspend are in the app launcher
# - The screen turns off after 10 minutes; touch it to turn it back on
{
  config,
  lib,
  pkgs,
  ...
}:

let
  output = "DSI-1";
  # ALSA card of the RK817 codec ("rockchip,card-name = rockchip-rk817")
  # and the mixer control the volume buttons change
  card = "rockchiprk817";
  volumeControl = "DAC";

  # Volume buttons
  volume = pkgs.writeShellScript "doogee-volume" ''
    ${pkgs.alsa-utils}/bin/amixer -q -c ${card} set ${volumeControl} "$1"
    # Tell the bar to redraw (the timeout in case it isn't running)
    ${pkgs.coreutils}/bin/timeout 1 sh -c 'echo > "$XDG_RUNTIME_DIR/doogee-bar"'
  '';

  # i3bar protocol: blocks with names, taps come back on stdin as JSON
  # lines ("click_events"). Swaybar turns a tap into a button 1 click.
  bar = pkgs.writeShellScript "doogee-bar" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.procps
        pkgs.alsa-utils
        pkgs.brightnessctl
        config.programs.sway.package
      ]
    }

    block() { printf '{"name":"%s","full_text":" %s ","separator_block_width":8}' "$1" "$2"; }
    status() {
      bat=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
      case $(cat /sys/class/power_supply/battery/status 2>/dev/null) in
        Charging) bat="$bat%+" ;;
        *) bat="$bat%" ;;
      esac
      vol=$(amixer -c ${card} get ${volumeControl} 2>/dev/null | grep -o -m1 '[0-9]*%')
      printf '[%s,%s,%s,%s,%s,%s,%s,%s],\n' \
        "$(block apps "☰ Apps")" \
        "$(block kbd "⌨")" \
        "$(block rotate "⟳")" \
        "$(block light "☀ $(brightnessctl -m | cut -d, -f4)")" \
        "$(block close "✕")" \
        "$(block vol "♪ $vol")" \
        "$(block bat "$bat")" \
        "$(block clock "$(date +%H:%M)")"
    }

    echo '{"version":1,"click_events":true}'
    echo '['
    status

    # Redraw every 20 s, or when something writes to the FIFO
    fifo=$XDG_RUNTIME_DIR/doogee-bar
    rm -f "$fifo"
    mkfifo "$fifo"
    exec 3<>"$fifo"
    while true; do
      read -r -t 20 -u 3 _
      status
    done &
    trap 'kill $!' EXIT

    # The tap reader must stay in the foreground: a background job's stdin
    # is /dev/null in a script. Events look like { "name": "apps", ... }.
    while read -r ev; do
      case ''${ev// /} in
        *'"name":"apps"'*) swaymsg -q exec fuzzel ;;
        *'"name":"kbd"'*) pkill -RTMIN -x wvkbd-mobintl ;;
        *'"name":"rotate"'*) swaymsg -q output ${output} transform 90 clockwise ;;
        *'"name":"light"'*)
          # 100% -> 50% -> 15% -> 100%
          case $(brightnessctl -m | cut -d, -f4) in
            100%) brightnessctl -q set 50% ;;
            5?%|4?%) brightnessctl -q set 15% ;;
            *) brightnessctl -q set 100% ;;
          esac ;;
        *'"name":"close"'*) swaymsg -q kill ;;
      esac
      status
    done
  '';

  # Screen rotation from the accelerometer (Rockchip sensor framework,
  # read with ioctls like rk3562deb's rk-screen-rotate.py). The panel is
  # natively portrait. Rotates only when the orientation changes, so the
  # manual rotate button stays in effect until the tablet is turned.
  autorotate = pkgs.writers.writePython3 "doogee-autorotate" {
    flakeIgnore = [ "E501" ];
  } ''
    import array
    import fcntl
    import os
    import subprocess
    import time

    DEV = "/dev/mma8452_daemon"
    GSENSOR_IOCTL_START = 0x6103
    GSENSOR_IOCTL_APP_SET_RATE = 0x40026110
    GSENSOR_IOCTL_GETDATA = 0x800D6108
    THRESHOLD = 6000  # about half of 1 g
    STABLE = 3  # readings in a row, so a brief tilt doesn't flip the screen
    TRANSFORMS = {
        "normal": "normal",
        "left": "270",
        "right": "90",
        "inverted": "180",
    }


    def orientation(x, y):
        if abs(x) < THRESHOLD and abs(y) < THRESHOLD:
            return None  # flat
        if abs(x) >= abs(y):
            return "left" if x > 0 else "right"
        return "inverted" if y > 0 else "normal"


    if not os.path.exists(DEV):
        raise SystemExit(0)
    fd = os.open(DEV, os.O_RDWR | os.O_CLOEXEC)
    fcntl.ioctl(fd, GSENSOR_IOCTL_START, 0)
    fcntl.ioctl(fd, GSENSOR_IOCTL_APP_SET_RATE, array.array("h", [20]), True)

    current, candidate, count = None, None, 0
    while True:
        time.sleep(0.5)
        data = array.array("i", [0, 0, 0, 0])
        try:
            fcntl.ioctl(fd, GSENSOR_IOCTL_GETDATA, data, True)
        except OSError:
            continue
        o = orientation(data[0], data[1])
        if o is None or o == current:
            candidate, count = None, 0
            continue
        if o == candidate:
            count += 1
        else:
            candidate, count = o, 1
        if count >= STABLE:
            cmd = ["swaymsg", "-q", "output", "${output}",
                   "transform", TRANSFORMS[o]]
            if subprocess.run(cmd).returncode == 0:
                current = o
            candidate, count = None, 0
  '';

  swayConfig = pkgs.writeText "sway-config" ''
    # 800x1280 at about 150 dpi; start in landscape like the console
    output ${output} scale 1.25 transform 90
    input type:touch map_to_output ${output}

    font pango:DejaVu Sans 11
    workspace_layout tabbed
    default_border none
    hide_edge_borders --i3 both
    focus_on_window_activation focus

    bar {
      position top
      font pango:DejaVu Sans 14
      status_command ${bar}
      workspace_buttons no
      status_padding 6
      colors {
        background #202020
        statusline #ffffff
      }
    }

    # On-screen keyboard, hidden until the ⌨ button is tapped
    exec wvkbd-mobintl --hidden -H 250 -L 200
    exec swayidle -w \
      timeout 600 'swaymsg "output * power off"' \
      resume 'swaymsg "output * power on"' \
      after-resume 'swaymsg "output * power on"'
    exec foot
    exec ${autorotate}

    bindsym --locked XF86AudioRaiseVolume exec ${volume} 5%+
    bindsym --locked XF86AudioLowerVolume exec ${volume} 5%-

    # For a USB or Bluetooth keyboard
    bindsym Mod4+Return exec foot
    bindsym Mod4+d exec fuzzel
    bindsym Mod4+q kill
    bindsym Mod4+Shift+e exit
  '';
in
{
  users.users.tablet = {
    isNormalUser = true;
    extraGroups = [
      "video"
      "input"
      "audio"
      "wheel"
    ];
    initialPassword = "doogee";
  };

  programs.sway = {
    enable = true;
    xwayland.enable = false;
    extraPackages = with pkgs; [
      foot
      fuzzel
      wvkbd
      swayidle
      brightnessctl
    ];
  };
  environment.etc."sway/config".source = lib.mkForce swayConfig;

  programs.firefox = {
    enable = true;
    policies = {
      DisableTelemetry = true;
      DisableFirefoxStudies = true;
      DisablePocket = true;
      FirefoxHome = {
        SponsoredTopSites = false;
        SponsoredStories = false;
        Stories = false;
      };
      UserMessaging = {
        ExtensionRecommendations = false;
        FeatureRecommendations = false;
        SkipOnboarding = true;
      };
    };
  };

  # Power off, reboot and suspend as entries in the app launcher
  environment.systemPackages =
    map
      (
        { name, desktopName }:
        pkgs.makeDesktopItem {
          inherit name desktopName;
          exec = "systemctl ${name}";
        }
      )
      [
        {
          name = "poweroff";
          desktopName = "Power off";
        }
        {
          name = "reboot";
          desktopName = "Reboot";
        }
        {
          name = "suspend";
          desktopName = "Suspend";
        }
      ];

  # Log in automatically; if sway exits, it is started again
  services.greetd = {
    enable = true;
    settings = rec {
      initial_session = {
        command = "sway";
        user = "tablet";
      };
      default_session = initial_session;
    };
  };

  # Backlight access for brightnessctl (group video)
  services.udev.packages = [ pkgs.brightnessctl ];
  fonts.enableDefaultPackages = true;

  environment.etc."xdg/foot/foot.ini".text = ''
    font=DejaVu Sans Mono:size=10
  '';
  environment.etc."xdg/fuzzel/fuzzel.ini".text = ''
    [main]
    font=DejaVu Sans:size=16
    lines=10
    width=30
    icons-enabled=no
    terminal=foot -e
  '';
}
