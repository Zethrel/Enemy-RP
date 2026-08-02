# Architecture

Enemy RP is four layers. Each one only knows about the layer below it, which is
what keeps the interesting parts testable outside the game.

```
  UI/            roster window, /erp commands
  Chat/          relaying and displaying say, emote and yell
  Profile/       what to ask for, what to answer, what to keep
  Transport/     how bytes leave and arrive
  Core/          framing, encoding, chunking, geometry, plumbing
```

## Core

`Init.lua` is the namespace, a small module registry, game-event dispatch, and an
internal message bus. Modules are created with `ns:NewModule(name)` and get
`OnInitialize` (saved variables exist) and `OnEnable` (the world is loaded and
the player's identity is reliable) called in load order.

The message bus matters more than it looks: modules communicate by firing named
messages, which is why `Profile/Sync.lua` has no idea whether a frame arrived
over a community or a Battle.net whisper.

`Codec.lua`, `Protocol.lua` and `Chunker.lua` implement the wire format
described in [PROTOCOL.md](PROTOCOL.md). None of them touch the game API beyond
`GetTime`, so the test suite exercises them directly.

`Geo.lua` answers "how far away is someone the client cannot see". Map
positions are normalized 0..1 and say nothing about yards, so both ends go
through `C_Map.GetWorldPosFromMapPos` onto a shared continent grid before being
compared.

`Util.lua` holds identity helpers, the FNV-1a hash used for profile
fingerprints, and a token-bucket send queue. Every outbound path goes through
one of those queues, because Battle.net chat is throttled server-side and
dropped messages are silent.

## Transport

`Relay.lua` is the bus. Backends register themselves and advertise capabilities:

```lua
backend:IsReady()             -- usable right now
backend:CanBroadcast()        -- can reach peers we have never met
backend:Broadcast(frame)
backend:CanReach(fullName)    -- has a direct route to one character
backend:SendTo(fullName, f)
```

`Relay:SendTo` prefers a direct route and falls back to broadcasting, walking
backends in registration order — which is why the `.toc` loads the direct and
authenticated transports before the community.

Frame size is a per-backend property, not a global one: an addon message caps at
255 characters where a community message allows thousands. `Relay` chunks the
same body separately for each backend but reuses one message id across them.
That matters for correctness, not tidiness. A peer reachable on two transports
receives the same id with different chunk counts; the first complete copy wins
and the other's chunks are suppressed or expire. Fresh ids per backend would
deliver the message twice — harmless for a profile, very much not for chat.

`AddonLink.lua` carries party, raid, instance and guild. These became
cross-faction when grouping and guilds did, and they are the best transport
available: nothing to join, nothing to configure, and the server reports who
actually sent each message. That last part makes them the only path in the addon
where a sender cannot lie — `Relay:Incoming` rejects any frame whose in-band
name disagrees with the server's. Both backends share one file because
`CHAT_MSG_ADDON` is a single event covering every distribution; registering it
twice would process each message twice.

`ClubLink.lua` is the Battle.net community backend, and the only one that
reaches strangers. Listening and sending are deliberately asymmetric:

- It listens on one channel in *every* community the player belongs to, so
  joining a community is the entire setup. `CLUB_MESSAGE_ADDED` only fires for
  *focused* streams, so the addon calls `C_Club.FocusStream` on each itself.
- It refuses to send into a channel until it has grounds to think the addon is
  welcome — the player named it, relay traffic has been seen on it, or it is
  literally called `relay`. Broadcasting into an unrelated community would dump
  raw protocol frames into the chat window of every member without the addon.
- Relay frames are ordinary chat to the server, so a
  `CHAT_MSG_COMMUNITIES_CHANNEL` filter hides them from the docked frames.

`BNetLink.lua` handles Battle.net friends. It maps `Name-Realm` to a game
account id by walking the friends list, and normalizes realm names on the way
(the friends list says "Moon Guard"; every other name in the addon says
"MoonGuard").

## Profile

`MSPBridge.lua` is the only file that knows a roleplay addon exists. Total RP 3,
MyRolePlay and XRP all expose Mary Sue Protocol through the shared `msp` table,
so targeting that table instead of any one addon's internals is what makes a
Horde Total RP user readable by an Alliance XRP user. It also means a new RP
addon is a change to one file.

`Cache.lua` stores received profiles in saved variables. Persisting them matters
more here than for same-faction roleplay: a relayed profile costs a round trip
through Battle.net, so discarding the cache at logout would mean re-fetching the
same crowd every evening. Entries expire after `cacheDays` and are pruned to
`cacheLimit`, oldest first.

`Sync.lua` is policy — the only file with opinions about *when* things happen:

- broadcast a heartbeat every `heartbeatInterval` seconds, jittered
- on a heartbeat whose fingerprint changed, fetch the tooltip fields
- on mouseover or target, fetch regardless of the same-map and auto-fetch
  settings, because looking at someone is the strongest signal there is
- on a request addressed to us, answer within the per-requester budget
- on a response, drop unknown field codes, cache, and hand to the RP addon

## Chat

`Outbound.lua` listens for `CHAT_MSG_SAY` and friends rather than hooking
`SendChatMessage`. The events fire on what the server actually accepted, so
muted, throttled and filtered messages never reach the relay, and lines sent by
other addons are picked up for free. It refuses to broadcast when no
cross-faction character has been heard from on the current map, which keeps an
entire roleplay session off the community channel when nobody is listening.

`Inbound.lua` is the least trusted code in the addon, and the only place that
renders a stranger's text. Everything else the addon receives ends up in a cache
or a profile field; this ends up in the player's chat frame, where `AddMessage`
interprets `|` escapes and an unsanitized line would let a sender inject
hyperlinks into every reader's chat. `Inbound.Sanitize` strips colour codes,
textures and atlas markup, collapses hyperlinks to their display text, and
removes any pipe not part of a `||` pair.

The rest is gating, in order: master switch, faction (same-faction speech is
already audible and would show twice), chat type, per-sender rate limit, ignore
list, range, and the optional Elixir of Tongues requirement.

## UI

`Roster.lua` lists who the relay has heard from. It deliberately does not render
profiles: once `MSPBridge` hands the fields over, Total RP 3 or XRP shows them in
its own window, which is what people already know how to read. The roster only
answers "who is out there, and do I have their profile yet".

`Slash.lua` carries configuration. The settings that matter are one-time — which
community to relay through — and are easier to paste into guild chat than to
describe as a click path.

## Testing

`tests/wow.lua` stubs the parts of the client API the addon uses and can spin up
several independent clients in one Lua state, each with its own sandboxed
globals. `tests/run.lua` uses that to run two clients on opposite factions
through a real exchange: heartbeat, request, chunked response, injection into
the receiver's `msp` table.

Timers are virtual, so a test can advance the clock without waiting.

The suite also fuzzes the frame parser with mutated and random input. Everything
arriving from a transport is attacker-controlled, and the parser's contract is
that it returns nil rather than raising.

## Not implemented

- Chat bubbles. Relayed speech goes to chat frames only; the client will not
  raise a bubble over a character it does not know is there.
- Any authentication of relayed chat. A community member can claim any name at
  any position. Range and rate limits are behavioural, not evidential.
- Compression. Codec has the seam for it. Version markers and fingerprints keep
  profiles off the wire in the first place, which is the larger win, so it has
  not been worth the bug surface yet.
- Any verification that a sender is who they claim to be. See the privacy note
  in the README; this is a protocol limitation, not an oversight.
