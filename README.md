# Enemy RP

See roleplay profiles across the faction divide.

World of Warcraft will not deliver an addon message from a Horde character to an
Alliance one, so Total RP 3, MyRolePlay and XRP all go quiet the moment the
other faction walks into the tavern. Enemy RP carries the same profile data over
a channel that *does* cross factions — a Battle.net community — and hands what
arrives to whichever roleplay addon you already run.

It speaks [Mary Sue Protocol](docs/PROTOCOL.md#mary-sue-protocol-fields), the
format Total RP 3, MyRolePlay and XRP share, so a Horde Total RP user and an
Alliance XRP user can read each other with nothing special configured on either
side.

## Status

Early. The protocol is implemented and tested end to end against a simulated
client (`tests/`), but it has not yet been through a live crowd of real users.
Treat 0.1.0 as a working foundation rather than a finished addon.

## Installing

Copy the repository into a folder named `EnemyRP`:

```
World of Warcraft/_retail_/Interface/AddOns/EnemyRP/
```

The folder name has to be `EnemyRP` — it must match `EnemyRP.toc`.

Built against retail client **12.0.7** (`## Interface: 120007`). If your client
is newer, bump that line in `EnemyRP.toc`; a stale interface number is the usual
reason an addon shows up as out of date.

## Setting it up

Enemy RP needs a shared channel that both factions can reach. Battle.net
communities are the only thing in the game that qualifies for players who are
not grouped.

1. One person creates a Battle.net community (Guild & Communities → Battle.net
   Community) and, ideally, adds a channel named `relay` to it. The addon
   prefers a channel with that name and falls back to General, so a dedicated
   channel keeps relay traffic out of whatever your members actually read.
2. Share the community's invite link with everyone, on both factions.
3. Each person joins, then runs:

   ```
   /erp club Name Of The Community
   ```

4. `/erp status` should now show the community in green.

Cross-faction Battle.net **friends** work with no community at all — those
exchanges go point to point over Battle.net instead of through the relay. If
everyone you roleplay with is already on your friends list, you can skip the
community entirely.

## Using it

| Command | What it does |
| --- | --- |
| `/erp` | Open the roster of characters the relay has heard from |
| `/erp status` | Connection, detected RP addon, cache size |
| `/erp clubs` | List your Battle.net communities |
| `/erp club <name>` | Use that community as the relay |
| `/erp stream <name>` | Use a specific channel inside it |
| `/erp who` | Characters seen in the last ten minutes |
| `/erp fetch <name>` | Request someone's full profile now |
| `/erp forget <name>` | Drop a cached profile |
| `/erp on` / `/erp off` | Enable or disable the relay |
| `/erp debug` | Verbose logging |
| `/erp reset` | Restore defaults and clear the cache |

Day to day you should not need any of these. Mousing over or targeting someone
on the other faction fetches their profile, and your roleplay addon displays it
the same way it displays anyone else's.

## What it costs

Profiles move rarely. What travels continuously is a heartbeat — map, tooltip
version, and a short fingerprint of your profile — every ninety seconds. Peers
compare the fingerprint against what they already hold and only ask for the
payload when something actually changed. A profile nobody has edited generates
no traffic beyond that heartbeat.

## Privacy

Anything you put in your roleplay profile is already broadcast to your own
faction by your RP addon. Enemy RP widens the audience to everyone in the
configured community, which is a real change: a community is not the same as
"players standing near me". Assume anyone in it can read your profile, and that
your character's name, current zone, and online times are visible to them.

Relay frames carry the sender's character name in the payload, and nothing
prevents a member of the community from putting someone else's name there.
Profiles are therefore claims, not proof of identity. Treat them the way you
would treat a whisper from an unverified alt.

`/erp off` stops all outbound traffic.

## Contributing

`tests/` runs outside the game against a stub of the client API:

```sh
lua5.1 tests/run.lua
```

It covers the encoder, the frame parser (including a fuzz pass over mutated
frames), chunk reassembly, and a full two-client exchange from heartbeat to
injected profile. Please keep it green.

`docs/PROTOCOL.md` is the normative description of the wire format. Changing the
format means bumping `ns.PROTOCOL` in `Core/Init.lua`, which also changes the
frame magic, so old and new clients ignore each other instead of misparsing.

## Origins and licensing

Cross RP proved this was possible, and Enemy RP owes it the idea. It does not
owe it any code: Cross RP is All Rights Reserved, so nothing here is derived
from it. Everything in this repository was written against the public Battle.net
community and Mary Sue Protocol interfaces.

If you contribute, contribute your own work, for the same reason.

Enemy RP is licensed under the **GNU General Public License, version 3 or
later** — see `LICENSE` for the full text. In short: use it, change it, share
it, but anything you distribute that is built on it has to carry the same
freedoms and ship its source. An addon that exists because a closed one stopped
being maintainable should not be able to become that addon.

This is compatible with Blizzard's addon policy, which already requires addons
to be distributed free of charge and with source available.

By contributing you agree that your contribution is licensed the same way.
