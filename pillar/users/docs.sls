# -*- coding: utf-8 -*-
# vim: ft=yaml
---
users-formula:
  use_vim_formula: false
  lookup:  # override the defauls in map.jinja
    root_group: root

users:
  ## Minimal required pillar values
  docs:
    fullname: docs
    password: {{ salt['onepassword.read']('op://infra/tk-user/password-hash') | yaml_dquote }}   # keep quoted
    enforce_password: true
    # WARNING: If 'empty_password' is set to true, the 'password' statement
    # will be ignored by enabling password-less login for the user.
    #empty_password: false
    #hash_password: false
    system: false
    home: /home/docs
    homedir_owner: docs
    homedir_group: docs
    #user_dir_mode: 750
    #createhome: true
    #roomnumber: "A-1"
    #workphone: "(555) 555-5555"
    #homephone: "(555) 555-5551"
    #manage_vimrc: false
    allow_gid_change: true
    #manage_bashrc: false
    #manage_profile: false
    #expire: 16426
    # Disables user management except sudo rules.
    # Useful for setting sudo rules for system accounts created by package instalation
    sudoonly: false
    sudouser: true
    # sudo_rules doesn't need the username as a prefix for the rule
    # this is added automatically by the formula.
    # ----------------------------------------------------------------------
    # In case your sudo_rules have a colon please have in mind to not leave
    # spaces around it. For example:
    # ALL=(ALL) NOPASSWD: ALL    <--- THIS WILL NOT WORK (Besides syntax is ok)
    # ALL=(ALL) NOPASSWD:ALL     <--- THIS WILL WORK
    sudo_rules:
      - ALL=(ALL) NOPASSWD:ALL
    #- ALL=(root) /usr/bin/find
    #- ALL=(otheruser) /usr/bin/script.sh
    sudo_defaults:
      - '!requiretty'
    # enable polkitadmin to make user an AdminIdentity for polkit
    polkitadmin: true
    #shell: /bin/bash
    #remove_groups: false
    prime_group:
      name: docs
      gid: 2000
    #groups:
    #- users
    #optional_groups:
    #- some_groups_that_might
    #- not_exist_on_all_minions
    #ssh_key_type: rsa
    #ssh_keys:
      # You can inline the private keys ...
      # privkey: PRIVATEKEY
      # pubkey: PUBLICKEY
      # or you can provide path to key on Salt fileserver
      #privkey: salt://path_to_PRIVATEKEY
      #pubkey: salt://path_to_PUBLICKEY
      # you can provide multiple keys, the keyname is taken as filename
      # make sure your public keys suffix is .pub
      #foobar: PRIVATEKEY
      #foobar.pub: PUBLICKEY
    ssh_key_type: ed25519
    ssh_keys:
      privkey: {{ salt['onepassword.read']('op://infra/tk-user/ssh-private-key') | yaml_dquote }}
      pubkey: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFoWv7STNMUVkQWz0Ns/Ixf2g3RIA5gZw426VAxmr+fr tk@homelab
    # ... or you can pull them from a different pillar,
    # for example one called "ssh_keys":
    #ssh_keys_pillar:
    #  id_rsa: "ssh_keys"
    #  another_key_pair: "ssh_keys"
    #ssh_auth:
    #- PUBLICKEY
    #ssh_auth.absent:
    #- PUBLICKEY_TO_BE_REMOVED
    # Generates an authorized_keys file for the user
    # with the given keys
    ssh_auth_file:
    - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC4Gk+zdKj3YE2BqQ3xe6VL/7WPZGjj0Qq7yNxlbK1Nrgfhr1600XlRMnXApeLri7Bs3IArOyV2X8RBCJ7TMoL9b/tYKT/3RAT23625urVz7UtayzcVzOjM9azEaKQVI57WRtJvOOEUzTI9pLef45gGrYQznJa95qY8/4aMSV3fbif/VkkeUKzc9DiQUOQj2T3/7FHorNsri6iNmBvTxraxUUwsiJc1r3clDNSpZiZZ2vwmqRigz/OJe+jmlULN2rKdrnsD7k7s6GDsL5BlEYviGqsdhqwfSTzJQkXQghzwlvtrpt8bSqUcrxGCjFfx/SSMybbE7mYqiDz6XpcexlLL tk@homebox.homework.lan  # noqa 204
    - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFoWv7STNMUVkQWz0Ns/Ixf2g3RIA5gZw426VAxmr+fr tk@homelab
    - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDVi1LQ9Bs4lxV6UPJE07WJXaENTKXUJmZVJPYBEks0VDUxib6WGHaO96/GIluH6tcl2b73wQw5I8e0qwkWYnZOypEoGDVWqXdwYzqVekgDONyAfo2ymw++Z6CMwgTvfV00rpFZsPUTvUnXJA8H+BNq3ulBP+7CY2Uhn0C4ATA+Wa8OqJYSt/Ddv62mPLX1HcPEhF321ZqmtzHFvHfpsRvg10gpUe5gJYJ5Uoywcmi8v4HB/L7cZDAk7k1OqknEDd9OIFYexb198oTIoCSut/6jkD+hYM/rK40DJ3lmngTkH7DqhzXz4GV6A+X17gVlGKISrhjc79xBOIytcTDLgRPB document-scanner  # noqa 204
    - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDTkV+Piwxly6P0Zsi+eUG+kFoURlpuwAeZdLgFSitM81vKL5oxaIOVDPi8uxGhpCWsoxx7vAg6+IKL8BOuS4QONBSuW5xDGfMT9OzvMAb9eo7ZJTpKBv3lRObVs8VqyadBoNz2b+Pa5vL31p+8FgKQcVQ6nEx/UNEOsd09tdlykD77+z5y6wcgRhJMqgJ7G43T4HokCWewxwm7emh5bxh7RLBNspu3PEZUP4Ixiu0dC9OA4s61OdZIVEs3b8HV+4lR8dnEixGOyRO9kkx8pVAQvoCA8rpheJeDOMrim8o4q8+6S6+vkqtr4CcbKybMjZRv8ebcT5OivXXulTpIgFwp root@BR000EC6EC1B11  # noqa 204
    # ... or you can pull them from a different pillar similar to ssh_keys_pillar
    #ssh_auth_pillar:
    #  id_rsa: "ssh_keys"
    # If you prefer to keep public keys as files rather
    # than inline in pillar, this works.
    #ssh_auth_sources:
    #- salt://keys/buser.id_rsa.pub
    #ssh_auth_sources.absent:
    #- salt://keys/deleteduser.id_rsa.pub  # PUBLICKEY_FILE_TO_BE_REMOVED
    # Manage the ~/.ssh/config file
    #ssh_known_hosts:
    #  importanthost:
    #    port: 22
    #    fingerprint: 16:27:ac:a5:76:28:2d:36:63:1b:56:4d:eb:df:a6:48
    #    key: PUBLICKEY
    #    enc: ssh-rsa
    #    hash_known_hosts: true
    #    timeout: 5
    #    fingerprint_hash_type: sha256
    #ssh_known_hosts.absent:
    #- notimportanthost
    ssh_config:
      all:
        hostname: "*"
        options:
        - "StrictHostKeyChecking no"
        - "UserKnownHostsFile=/dev/null"
    #  importanthost:
    #    hostname: "needcheck.example.com"
    #    options:
    #    - "StrictHostKeyChecking yes"

    # Using gitconfig without Git installed will result in an error
    # https://docs.saltstack.com/en/latest/ref/states/all/salt.states.git.html:
    # This state module now requires git 1.6.5 (released 10 October 2009) or newer.
    gitconfig:
      user.name: T. Klessen
      user.email: tilo@klessen.cloud
      "url.https://.insteadOf": "git://"

    #gitconfig.absent:
    #- push.default
    #- color\..+

    #google_2fa: true
    #google_auth:
    #  sshd: |
    #    SOMEGAUTHHASHVAL
    #    " RESETTING_TIME_SKEW 46956472+2 46991595-2
    #    " RATE_LIMIT 3 30 1415800560
    #    " DISALLOW_REUSE 47193352
    #    " TOTP_AUTH
    #    11111111
    #    22222222
    #    33333333
    #    44444444
    #    55555555
    # unique: true allows user to have non unique uid
    unique: false
    uid: 2000

    #user_files:
    #  enabled: true
    #  # 'source' allows you to define an arbitrary directory to sync,
    #  # useful to use for default files.
    #  # should be a salt fileserver path either with or without 'salt://'
    #  # if not present, it defaults to 'salt://users/files/user/<username>
    #  source: users/files
    #  # template: jinja
    #  # You can specify octal mode for files and symlinks that will be copied.
    #  # Since version 2016.11.0 it's possible to use 'keep' for file_mode,
    #  # to preserve file original mode, thus you can save execution bit for example.
    #  file_mode: keep
    #  # You can specify octal mode for directories as well.
    #  # This won't work on Windows minions
    #  # dir_mode: 775
    #  sym_mode: 640
    #  exclude_pat: "*.gitignore"
