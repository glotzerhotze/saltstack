# /home/salt/data/reactor/grains_from_pillar.sls
# Der Reactor läuft auf dem Master und kennt die Pillar des Minions nicht.
# Er stößt daher nur einen State auf genau dem Minion an, der das Event
# ausgelöst hat. Der State liest die Pillar und setzt die Grains.
{% if data.get('id') %}
local_grains_{{ data['id'] }}:
  local.state.apply:
  - tgt: {{ data['id'] }}
  - args:
    - mods: local_grains
{% endif %}
