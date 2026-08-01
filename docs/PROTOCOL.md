# Enemy RP wire protocol, version 1

This is the normative description of what Enemy RP puts on the wire. Anything
here that disagrees with the code is a bug in one of the two.

The protocol version appears in the frame magic (`ERP1`). Incrementing
`ns.PROTOCOL` in `Core/Init.lua` therefore makes old and new clients ignore each
other's frames entirely, which is the intended upgrade path — there is no
negotiation.

## Transports

A transport carries opaque text between clients. Two exist:

| Transport | Reach | Direction |
| --- | --- | --- |
| Battle.net community | Everyone in the configured community | Broadcast only |
| Battle.net friend | One character, if a friend is logged into it | Directed only |

The community is the discovery mechanism: it is the only way to learn that a
character on the other faction exists. Directed sends are preferred whenever a
route exists, because a profile transfer concerns exactly two people and has no
business in a shared channel.

Neither transport is trusted. Every field below is parsed defensively and a
malformed value causes the frame to be dropped, never an error.

## Frames

One frame is one chat message:

```
ERP1 <sender> <faction> <id> <seq> <total> <chunk>#
```

| Field | Format | Meaning |
| --- | --- | --- |
| `ERP1` | literal | magic and protocol version |
| `<sender>` | `Name-Realm`, no spaces | the sending character, using the normalized realm name |
| `<faction>` | `A`, `H` or `N` | sender's faction |
| `<id>` | 4 base36 characters | message identifier, unique per sender within the reassembly window |
| `<seq>` | 1..255 | this chunk's position |
| `<total>` | 1..255 | how many chunks the message has |
| `<chunk>` | anything | payload slice; may contain spaces |
| `#` | literal | sentinel |

Everything before `<chunk>` is space-free, so a frame is parsed by matching six
space-delimited tokens and taking the remainder as the chunk.

The trailing `#` exists because chat transports may strip trailing whitespace.
A chunk boundary can fall on a space, and without a sentinel that space would be
silently lost, corrupting the reassembled body. Parsers must remove exactly one
trailing character.

Frames are capped at `maxFrameLength` (default 900) characters. Both transports
accept more; the margin is deliberate.

`<sender>` is a **claim**. Nothing in the protocol proves that the sender of a
community message is the character named in it. Consumers must not treat a name
as authenticated.

## Bodies

Concatenating a message's chunks in `seq` order yields a body:

```
<OPCODE> <payload>
```

`<OPCODE>` is two uppercase letters. A body with no payload omits the space.

Reassembly buffers are keyed by `(sender, id)`, expire after 30 seconds, and are
limited to 4 concurrent buffers per sender so that a peer cannot exhaust memory
by opening transfers it never finishes.

Receivers must ignore frames whose `<sender>` is themselves, and must deduplicate
on `(sender, id, seq)` — a peer who is both a community member and a Battle.net
friend can legitimately deliver the same frame twice.

### `HB` — heartbeat

```
HB <mapId> <tooltipVersion> <fingerprint>
```

Broadcast every `heartbeatInterval` seconds (default 90) plus up to 25% jitter.

`<fingerprint>` is an FNV-1a 32-bit hash, lowercase hex, over every field the
sender would be willing to send. A receiver whose stored fingerprint for that
character differs knows the profile changed without asking for it. The hash
catches edits that the roleplay addon forgot to bump a version number for.

### `RQ` — request

```
RQ <target> <FIELD>=<version>,<FIELD>=<version>,...
```

Sent directed where possible, broadcast otherwise. A client must ignore an `RQ`
whose `<target>` is not itself.

`<version>` is the version the requester already holds, or `0` for none. The
responder omits any field whose version matches, so re-asking for an unchanged
profile costs one small frame and produces no reply at all.

Responders rate limit per requesting name (`requestsPerMinute`, default 6).

### `RS` — response

```
RS <FIELD>^<version>^<packed>~<FIELD>^<version>^<packed>~...
```

Fields carry the responder's current version. `<packed>` is encoded as below.

Receivers must discard any field code outside the schema in
[Mary Sue Protocol fields](#mary-sue-protocol-fields) before passing data to a
roleplay addon — the field code becomes a table key, and a peer must not be able
to choose arbitrary keys.

### `BY` — farewell

```
BY
```

Advisory: the sender is going away and can be dropped from presence lists. Never
required; a peer that vanishes simply stops heartbeating.

## Value encoding

Values are escaped so that they cannot contain a separator, break the frame, or
be interpreted by anything that renders them. Each is prefixed with its mode:

| Prefix | Encoding |
| --- | --- |
| `t:` | percent-escaped text |
| `b:` | base64 (standard alphabet, `=` padded) |

Percent escaping replaces `%`, `|`, `~`, `^`, every control character, and
`0x7F` with `%XX` (uppercase hex). It is close to 1:1 for ordinary prose, which
is what profiles are made of.

Base64 is used when the value is not valid UTF-8 — chat transports may mangle
invalid sequences — or when escaping would inflate it by more than 40%.

`|` is escaped because an unescaped `|c` or `|H` in a profile would otherwise be
rendered as a colour code or hyperlink by any frame that displays it.

## Mary Sue Protocol fields

Enemy RP relays the shared MSP field set and nothing else. Anything outside this
list is dropped on receipt.

**Tooltip fields** — requested on mouseover, cheap, requested often:

`VP` protocol version · `VA` addon versions · `NA` name · `NH` house ·
`NI` nickname · `NT` title · `RA` race · `RC` class · `IC` icon ·
`CU` currently · `CO` currently (OOC) · `FR` roleplay style · `FC` in or out of
character

**Body fields** — fetched when someone opens the profile:

`AE` eye colour · `AG` age · `AH` height · `AW` weight · `DE` description ·
`HB` birthplace · `HH` home · `HI` history · `MO` motto

`TT` (the tooltip cache version) is carried in the heartbeat rather than as a
field.

Adding a field means adding it to `Bridge.TOOLTIP_FIELDS` or
`Bridge.FULL_FIELDS` in `Profile/MSPBridge.lua`; no other file needs to change,
and clients that do not know the field will drop it harmlessly.
