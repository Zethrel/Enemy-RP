# Enemy RP

See roleplay profiles across the faction divide.

World of Warcraft will not deliver an addon message from a Horde character to an
Alliance one, so Total RP 3, MyRolePlay and XRP all go quiet the moment the
other faction walks into the tavern. Enemy RP carries the same profile data over
the channels that *do* cross factions — your party, your guild, your Battle.net
friends, or a shared community — and hands what arrives to whichever roleplay
addon you already run.

It speaks [Mary Sue Protocol](docs/PROTOCOL.md#mary-sue-protocol-fields), the
format Total RP 3, MyRolePlay and XRP share, so a Horde Total RP user and an
Alliance XRP user can read each other with nothing special configured on either
side.

It also relays **say, emote and yell**, so you can actually hold a conversation
across the divide rather than just read each other's profiles.

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

Often: nothing. Enemy RP uses whichever cross-faction channel you already have.

| If you are… | Setup needed |
| --- | --- |
| In a party or raid together | **None.** Just group up |
| In a cross-faction guild | **None** |
| Battle.net friends | **None** |
| Strangers in the open world | Share a Battle.net community |

**Grouping is the best case**, and it is the one cross-faction world roleplay
usually already satisfies. Party, raid and instance groups carry everything —
profiles and chat — with nothing to join and nothing to configure. They are also
the only channel where the server tells the addon who really sent each message,
so nobody in your group can impersonate anyone else.

For strangers, a Battle.net community is the only thing in the game that
reaches them:

1. One person creates a Battle.net community (Guild & Communities → Battle.net
   Community) and adds a channel named **`relay`** to it. The name matters: the
   addon treats a channel called `relay` as an explicit invitation and starts
   using it with no command. It also keeps protocol traffic out of whatever
   channel your members actually read.
2. Share the invite link. Everyone joins, on both factions.
3. That is all. `/erp status` should show the community in green.

The addon listens on every Battle.net community you belong to, so it will find
the right one by itself. It will **not** send into a community until it has
reason to think it belongs there — the channel is named `relay`, or relay
traffic has already been seen on it, or you named it with `/erp club <name>` —
so it can never dump protocol frames into an unrelated community's chat.

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
| `/erp chat` | Chat relay settings |
| `/erp on` / `/erp off` | Enable or disable the relay |
| `/erp debug` | Verbose logging |
| `/erp reset` | Restore defaults and clear the cache |

Day to day you should not need any of these. Mousing over or targeting someone
on the other faction fetches their profile, and your roleplay addon displays it
the same way it displays anyone else's.

## Chat

Say, emote and yell are relayed both ways and appear in whichever chat window
you already show that chat type in. Range is respected — 40 yards for say and
emote, 300 for yell, measured properly in yards rather than by map coordinates —
so someone across the zone does not turn up in your chat.

Sending and showing are separate settings, because reading the other faction
without broadcasting yourself is a reasonable thing to want:

```
/erp chat send yell      toggle relaying your own yells
/erp chat show emote     toggle showing their emotes
/erp chat range 30       tighten say and emote range
/erp chat off            stop both directions
```

For the immersive option, `/erp chat tongues` makes the other faction
unintelligible unless you are under Elixir of Tongues. Off by default. If it
ever stops detecting the buff, the spell id is a setting rather than a constant
— that check is the one part of this that has not been verified against a live
client.

Relayed speakers are shown with their roleplay name where one is cached, and
always faction-coloured, which native chat never is — that colouring is how you
tell a relayed line from a real one.

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

How much a relayed name can be trusted depends on how it reached you:

- **Party, raid and guild are trustworthy.** The server reports who sent each
  addon message, and the addon drops any frame whose claimed name disagrees.
  Nobody in your group can impersonate anyone.
- **Community and Battle.net frames are not.** They carry the sender's name as
  part of the payload, and nothing stops a member from writing someone else's
  name there. Treat those the way you would treat a whisper from an unverified
  alt.

That gap matters most for chat: over a community, someone can put words in
another character's mouth and the addon cannot tell. What it does regardless is
strip every escape sequence from relayed text before displaying it, so a sender
cannot inject clickable links or colour codes into your chat frame, rate limit
each sender, and honour your ignore list. If a name is being abused, the
practical fix is removing that person from the community — or doing your
roleplay in a group, where the problem does not exist.

Chat is only broadcast when a cross-faction character has been heard from on
your map recently, so an empty room costs nothing.

`/erp off` stops all outbound traffic.

## Contributing

`tests/` runs outside the game against a stub of the client API:

```sh
lua5.1 tests/run.lua
```

It covers the encoder, the frame parser (including a fuzz pass over mutated
frames), chunk reassembly, a full two-client exchange from heartbeat to injected
profile, the chat relay end to end including range, gating and the display
sanitizer, and each transport in isolation — party with no community in sight,
guild, sender-spoofing rejection, and community auto-discovery. Please keep it
green.

The harness loads exactly the files `EnemyRP.toc` lists, in that order, and
validates the toc itself — every listed file exists, every source file is
listed, and no line is something the client would mistake for a filename. A
`.toc` accepts `## Key: value` directives, `#` comments, blank lines and paths;
a `--` comment is read as a path and fails at login before any Lua runs.

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
