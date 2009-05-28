{ config, pkgs, nix, modprobe, nssModulesPath, nixEnvVars, optionDeclarations
, kernelPackages, mount, kdePackages
}:

let 

  makeJob = import ../upstart-jobs/make-job.nix {
    inherit (pkgs) runCommand;
  };

  optional = cond: service: pkgs.lib.optional cond (makeJob service);

  requiredTTYs =
    config.services.mingetty.ttys
    ++ config.boot.extraTTYs
    ++ [config.services.syslogd.tty];

  # looks for a job file foreach attr name found in services from config
  # passes { thisConfig, config, pkgs }
  # a job must return { options = {}; job =; }
  # options is the same format as options.nix, but only contains documentation for this job
  # TODO check validation
  newProposalJobs =
  (
  let
    inherit (pkgs.lib) attrByPath; 
    inherit (builtins) attrNames pathExists map hasAttr getAttr;
    services = attrByPath [ "servicesProposal" ] {} config;
    nameToJobs = name : (
      (
      let p = ./new-proposal + "/${name}.nix";
          p2 = ./new-proposal + "/${name}/default.nix";
          thisConfig = attrByPath [ name ] {} services;
          path = [name];
          args = confgiV : {
            inherit config pkgs thisConfig path;
            lib = pkgs.lib;
            upstartHelpers = { # some useful functions 
              inherit configV; # the first time a error function is passed to get the option list
                               # the second time a function is passed getting the option for you automatically,
                               # either returning the default option or the user supplied value (the function apply is applied when given)
                               # maybe this is complicated, but easy to use (IMHO)
              mkOption = pkgs.lib.mkOption; # the same function used in options.nix
              autoGeneratedEtcFile = { name, commentChar ? "#", content } :
                 { source = pkgs.writeText name 
                     ("${commentChar} nixos autogenerated etc file based on /etc/nixos/configuration.nix\n" + content);
                   target = name;
                 };
            };
          };
          jobFunc = if pathExists p  
                    then import p
                    else if pathExists p2 then import p2 
                        else abort "service ${name} requested but there is no ${p}.nix or ${p}/default.nix file!";
          options = (jobFunc (args (abort "you can't use configV within options!"))).options;
          errorWhere = name : "${name} of service ${builtins.toString path}";
          configV = name : if (hasAttr name options ) then
                             let opt = (getAttr name options ); # this config option description
                             in if (hasAttr name thisConfig )
                                then let v = (getAttr name thisConfig); in if opt ? apply then opt.apply v else v
                                else if opt ? default then opt.default else abort "you need to specify the configuration option ${errorWhere name}"
                           else abort "unkown option ${errorWhere name}";
          checkConfig = (attrByPath ["environment" "checkConfigurationOptions"] 
                  optionDeclarations.environment.checkConfigurationOptions.default
                  config);
      in # TODO: pass path to checker so it can show full path in the abort case
          pkgs.checker ( (jobFunc (args configV)).jobs )
                      checkConfig
                      options
                      thisConfig

      ));
  in pkgs.lib.concatLists ( map nameToJobs (attrNames services)));
    
  jobs = map makeJob
    (newProposalJobs ++ [
    
    # Syslogd.
    (import ../upstart-jobs/syslogd.nix {
      inherit (pkgs) sysklogd writeText;
      inherit config;
    })

    # Klogd.
    (import ../upstart-jobs/klogd.nix {
      inherit (pkgs) sysklogd writeText;
      inherit config;
    })

    # The udev daemon creates devices nodes and runs programs when
    # hardware events occur.
    (import ../upstart-jobs/udev.nix {
      inherit modprobe config;
      inherit (pkgs) stdenv writeText substituteAll udev procps;
      inherit (pkgs.lib) cleanSource;
      firmwareDirs =
           pkgs.lib.optional config.networking.enableIntel2200BGFirmware pkgs.ipw2200fw
        ++ pkgs.lib.optional config.networking.enableIntel3945ABGFirmware pkgs.iwlwifi3945ucode
        ++ pkgs.lib.optional config.networking.enableIntel4965AGNFirmware kernelPackages.iwlwifi4965ucode
        ++ pkgs.lib.optional config.networking.enableIntel5000Firmware pkgs.iwlwifi5000ucode
        ++ pkgs.lib.optional config.networking.enableZydasZD1211Firmware pkgs.zd1211fw
        ++ pkgs.lib.optional config.hardware.enableGo7007 "${kernelPackages.wis_go7007}/firmware"
        ++ config.services.udev.addFirmware
        ++ ["${kernelPackages.kernel}/lib/firmware"];
      extraUdevPkgs =
           pkgs.lib.optional config.services.hal.enable pkgs.hal
        ++ pkgs.lib.optional config.hardware.enableGo7007 kernelPackages.wis_go7007
        ++ config.services.udev.addUdevPkgs;
    })
      
    # Makes LVM logical volumes available. 
    (import ../upstart-jobs/lvm.nix {
      inherit modprobe;
      inherit (pkgs) lvm2 devicemapper;
    })
      
    # Activate software RAID arrays.
    (import ../upstart-jobs/swraid.nix {
      inherit modprobe;
      inherit (pkgs) mdadm;
    })
      
    # Mount file systems.
    (import ../upstart-jobs/filesystems.nix {
      inherit mount;
      inherit (pkgs) utillinux e2fsprogs;
      fileSystems = config.fileSystems;
    })

    # Swapping.
    (import ../upstart-jobs/swap.nix {
      inherit (pkgs) utillinux lib;
      swapDevices = config.swapDevices;
    })

    # Network interfaces.
    (import ../upstart-jobs/network-interfaces.nix {
      inherit modprobe config;
      inherit (pkgs) nettools wirelesstools bash writeText;
    })
      
    # Nix daemon - required for multi-user Nix.
    (import ../upstart-jobs/nix-daemon.nix {
      inherit config pkgs nix nixEnvVars;
    })

    # Name service cache daemon.
    (import ../upstart-jobs/nscd.nix {
      inherit (pkgs) glibc;
      inherit nssModulesPath;
    })

    # Console font and keyboard maps.
    (import ../upstart-jobs/kbd.nix {
      inherit (pkgs) glibc kbd gzip;
      ttyNumbers = requiredTTYs;
      defaultLocale = config.i18n.defaultLocale;
      consoleFont = config.i18n.consoleFont;
      consoleKeyMap = config.i18n.consoleKeyMap;
    })

    # Handles the maintenance/stalled event (single-user shell).
    (import ../upstart-jobs/maintenance-shell.nix {
      inherit (pkgs) bash;
    })

    # Ctrl-alt-delete action.
    (import ../upstart-jobs/ctrl-alt-delete.nix)

  ])

  # At daemon.
  ++ optional config.services.atd.enable
    (import ../upstart-jobs/atd.nix {
      at = pkgs.at;
      config = config.services.atd;
     })

  # ifplugd daemon for monitoring Ethernet cables.
  ++ optional config.networking.interfaceMonitor.enable
    (import ../upstart-jobs/ifplugd.nix {
      inherit (pkgs) ifplugd writeScript bash;
      inherit config;
    })

  # DHCP server.
  ++ optional config.services.dhcpd.enable
    (import ../upstart-jobs/dhcpd.nix {
      inherit pkgs config;
    })

  # SSH daemon.
  ++ optional config.services.sshd.enable
    (import ../upstart-jobs/sshd.nix {
      inherit (pkgs) writeText openssh glibc;
      inherit (pkgs.xorg) xauth;
      inherit nssModulesPath;
      inherit (config.services.sshd) forwardX11 allowSFTP permitRootLogin gatewayPorts;
    })

  # GNU lshd SSH2 deamon.
  ++ optional config.services.lshd.enable
    (import ../upstart-jobs/lshd.nix {
      inherit (pkgs) lib;
      inherit (pkgs) lsh;
      inherit (pkgs.xorg) xauth;
      inherit nssModulesPath;
      lshdConfig = config.services.lshd;
    })

  # GNUnet daemon.
  ++ optional config.services.gnunet.enable
    (import ../upstart-jobs/gnunet.nix {
      inherit (pkgs) gnunet lib writeText;
      gnunetConfig = config.services.gnunet;
    })

  # NTP daemon.
  ++ optional config.services.ntp.enable
    (import ../upstart-jobs/ntpd.nix {
      inherit modprobe;
      inherit (pkgs) ntp glibc writeText;
      servers = config.services.ntp.servers;
    })

  # Avahi daemon.
  ++ optional config.services.avahi.enable
    (import ../upstart-jobs/avahi-daemon.nix {
      inherit (pkgs) avahi writeText lib;
      config = config.services.avahi;
    })

  # X server.
  ++ optional config.services.xserver.enable
    (import ../upstart-jobs/xserver.nix {
      inherit config pkgs kernelPackages kdePackages;
      fontDirectories = import ../system/fonts.nix {inherit pkgs config;};
    })

  ++ optional config.services.kdm.enable
    (import ../upstart-jobs/kdm.nix {
      inherit config pkgs kernelPackages;
      fontDirectories = import ../system/fonts.nix {inherit pkgs config;};
    })

  # Apache httpd.
  ++ optional (config.services.httpd.enable && !config.services.httpd.experimental)
    (import ../upstart-jobs/httpd.nix {
      inherit config pkgs;
      inherit (pkgs) glibc;
      extraConfig = pkgs.lib.concatStringsSep "\n"
        (map (job: job.extraHttpdConfig) jobs);
    })

  # Apache httpd (new style).
  ++ optional (config.services.httpd.enable && config.services.httpd.experimental)
    (import ../upstart-jobs/apache-httpd {
      inherit config pkgs;
    })

  # MySQL server
  ++ optional config.services.mysql.enable
    (import ../upstart-jobs/mysql.nix {
      inherit config pkgs;
    })

  # Postgres SQL server
  ++ optional config.services.postgresql.enable
    (import ../upstart-jobs/postgresql.nix {
      inherit config pkgs;
    })

  # EJabberd service
  ++ optional config.services.ejabberd.enable
    (import ../upstart-jobs/ejabberd.nix {
      inherit config pkgs;
    })  

  # OpenFire XMPP server
  ++ optional config.services.openfire.enable
    (import ../upstart-jobs/openfire.nix {
      inherit config pkgs;
    })

  # JBoss service
  ++ optional config.services.jboss.enable
    (import ../upstart-jobs/jboss.nix {
      inherit config pkgs;
    })  

  # Apache Tomcat service
  ++ optional config.services.tomcat.enable
    (import ../upstart-jobs/tomcat.nix {
      inherit config pkgs;
    })

  # Samba service.
  ++ optional config.services.samba.enable
    (import ../upstart-jobs/samba.nix {
      inherit pkgs;
      inherit (pkgs) glibc samba;
    })

  # CUPS (printing) daemon.
  ++ optional config.services.printing.enable
    (import ../upstart-jobs/cupsd.nix {
      inherit config pkgs modprobe;
    })

  # Gateway6
  ++ optional config.services.gw6c.enable
    (import ../upstart-jobs/gw6c.nix {
      inherit config pkgs;
    })

  # VSFTPd server
  ++ optional config.services.vsftpd.enable
    (import ../upstart-jobs/vsftpd.nix {
      inherit (pkgs) vsftpd;
      inherit (config.services.vsftpd) anonymousUser localUsers
        writeEnable anonymousUploadEnable anonymousMkdirEnable
        chrootlocaluser userlistenable userlistdeny;
    })

  # X Font Server
  ++ optional config.services.xfs.enable
    (import ../upstart-jobs/xfs.nix {
      inherit config pkgs;
    })

  ++ optional config.services.ircdHybrid.enable
    (import ../upstart-jobs/ircd-hybrid.nix {
      inherit config pkgs;
    })

  ++ optional config.services.bitlbee.enable
    (import ../upstart-jobs/bitlbee.nix {
      inherit (pkgs) bitlbee;
      inherit (config.services.bitlbee) portNumber interface;
    })

  # ALSA sound support.
  ++ optional config.sound.enable
    (import ../upstart-jobs/alsa.nix {
      inherit modprobe;
      inherit (pkgs) alsaUtils;
    })

  # ACPI daemon.
  ++ optional config.powerManagement.enable
    (import ../upstart-jobs/acpid.nix {
      inherit config pkgs;
    })

  # D-Bus system-wide daemon.
  ++ optional config.services.dbus.enable
    (import ../upstart-jobs/dbus.nix {
      inherit (pkgs) stdenv dbus;
      dbusServices =
        pkgs.lib.optional config.services.hal.enable pkgs.hal ++
        pkgs.lib.optional config.services.avahi.enable pkgs.avahi ++
	pkgs.lib.optional config.services.consolekit.enable pkgs.ConsoleKit ++
        pkgs.lib.optional config.services.disnix.enable pkgs.disnix
        ;
    })

  # HAL daemon.
  ++ optional config.services.hal.enable
    (import ../upstart-jobs/hal.nix {
      inherit (pkgs) stdenv hal;
      inherit config;
    })

  ++ optional config.services.gpm.enable 
    (import ../upstart-jobs/gpm.nix {
      inherit (pkgs) gpm;
      gpmConfig = config.services.gpm;
    })

  # Nagios system/network monitoring daemon.
  ++ optional config.services.nagios.enable
    (import ../upstart-jobs/nagios {
      inherit config pkgs;
    })

  # Zabbix agent daemon.
  ++ optional config.services.zabbixAgent.enable
    (import ../upstart-jobs/zabbix-agent.nix {
      inherit config pkgs;
    })

  # Zabbix server daemon.
  ++ optional config.services.zabbixServer.enable
    (import ../upstart-jobs/zabbix-server.nix {
      inherit config pkgs;
    })
  
  # ConsoleKit daemon.
  ++ optional config.services.consolekit.enable
    (import ../upstart-jobs/consolekit.nix {
      inherit config pkgs;
    })
  
  # Postfix mail server.
  ++ optional config.services.postfix.enable
    (import ../upstart-jobs/postfix.nix {
      inherit config pkgs;
    })

  # Dovecot POP3/IMAP server.
  ++ optional config.services.dovecot.enable
    (import ../upstart-jobs/dovecot.nix {
      inherit config pkgs;
    })

  # ISC BIND domain name server.
  ++ optional config.services.bind.enable
    (import ../upstart-jobs/bind.nix {
      inherit config pkgs;
    })

  # Disnix server
  ++ optional config.services.disnix.enable
    (import ../upstart-jobs/disnix.nix {
      inherit config pkgs;
    })

  # Handles the reboot/halt events.
  ++ (map
    (event: makeJob (import ../upstart-jobs/halt.nix {
      inherit (pkgs) bash utillinux;
      inherit event;
    }))
    ["reboot" "halt" "system-halt" "power-off"]
  )
    
  # The terminals on ttyX.
  ++ (map 
    (ttyNumber: makeJob (import ../upstart-jobs/mingetty.nix {
        inherit (pkgs) mingetty;
        inherit ttyNumber;
        loginProgram = "${pkgs.pam_login}/bin/login";
    }))
    (config.services.mingetty.ttys)
  )

  # Transparent TTY backgrounds.
  ++ optional (config.services.ttyBackgrounds.enable && kernelPackages.splashutils != null)
    (import ../upstart-jobs/tty-backgrounds.nix {
      inherit (pkgs) stdenv;
      inherit (kernelPackages) splashutils;
      
      backgrounds =
      
        let
        
          specificThemes =
            config.services.ttyBackgrounds.defaultSpecificThemes
            ++ config.services.ttyBackgrounds.specificThemes;
            
          overridenTTYs = map (x: x.tty) specificThemes;

          # Use the default theme for all the mingetty ttys and for the
          # syslog tty, except those for which a specific theme is
          # specified.
          defaultTTYs =
            pkgs.lib.filter (x: !(pkgs.lib.elem x overridenTTYs)) requiredTTYs;

        in      
          (map (ttyNumber: {
            tty = ttyNumber;
            theme = config.services.ttyBackgrounds.defaultTheme;
          }) defaultTTYs)
          ++ specificThemes;
          
    })

  # User-defined events.
  ++ (map makeJob (config.services.extraJobs))

  # For the built-in logd job.
  ++ [(makeJob { jobDrv = pkgs.upstart; })];

  
in import ../upstart-jobs/gather.nix {
  inherit (pkgs) runCommand;
  inherit jobs;
}