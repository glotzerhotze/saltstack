# /srv/salt/grains_from_pillar/init.sls
# Setzt jeden Eintrag unter pillar:grains_from_pillar als Grain.
# state.apply kompiliert die Pillar frisch, ein vorheriges refresh_pillar ist nicht nötig.
{% set wanted = salt['pillar.get']('local_grains', {}) %}
{% for key, value in wanted.items() %}
grain_from_pillar_{{ key }}:
  grains.present:
  - name: {{ key }}
  - value: {{ value | json }}
  - force: True
{% endfor %}

{% if wanted %}
# Grains im laufenden Minion neu laden, damit Targeting (-G) sofort greift
grains_from_pillar_refresh:
  module.run:
  - saltutil.refresh_grains: []
  - onchanges:
{% for key in wanted %}
    - grains: grain_from_pillar_{{ key }}
{% endfor %}
{% endif %}
