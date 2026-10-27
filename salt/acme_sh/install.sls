{#- Installs acme.sh from git #}
{%- from tpldir ~ '/map.jinja' import acme_sh with context %}
{%- set marker = acme_sh.home ~ '/.salt-installed-rev' %}
{%- set account_conf = acme_sh.config_home ~ '/account.conf' %}

{%- if acme_sh.packages %}

acme_sh_packages:
  pkg.installed:
    - pkgs: {{ acme_sh.packages | tojson }}
    - require_in:
      - git: acme_sh_source
{%- endif %}

acme_sh_source:
  git.latest:
    - name: {{ acme_sh.repo | tojson }}
    - target: {{ acme_sh.source_dir | tojson }}
    - rev: {{ acme_sh.version | string | tojson }}
    - force_reset: True

{#- acme.sh --install copies the script and its dnsapi/deploy/notify hooks
    into --home and, unless profile is false, adds acme.sh's usual `acme.sh`
    alias to root's shell profile. It is re-run whenever the checked-out
    commit or the account e-mail changes. Renewal is set up by renewal.sls,
    so acme.sh's own cron job is not installed here. #}
acme_sh_install:
  cmd.run:
    - name: >-
        ./acme.sh --install --nocron
        {%- if not acme_sh.profile %} --noprofile{% endif %}
        --home {{ acme_sh.home | quote }}
        --config-home {{ acme_sh.config_home | quote }}
        --cert-home {{ acme_sh.cert_home | quote }}
        {%- if acme_sh.email %}
        --accountemail {{ acme_sh.email | quote }}
        {%- endif %}
        && git rev-parse HEAD > {{ marker | quote }}
    - cwd: {{ acme_sh.source_dir | tojson }}
    - unless:
      - test -x {{ (acme_sh.home ~ '/acme.sh') | quote }}
      - test "$(cat {{ marker | quote }} 2>/dev/null)" = "$(git -C {{ acme_sh.source_dir | quote }} rev-parse HEAD)"
      {%- if acme_sh.email %}
      - sh -c '. "$1" && [ "${ACCOUNT_EMAIL:-}" = "$2" ]' _ {{ account_conf | quote }} {{ acme_sh.email | quote }}
      {%- endif %}
    - require:
      - git: acme_sh_source

acme_sh_state_dir:
  file.directory:
    - name: {{ acme_sh.state_dir | tojson }}
    - mode: '0700'
    - makedirs: True
    - require:
      - cmd: acme_sh_install
