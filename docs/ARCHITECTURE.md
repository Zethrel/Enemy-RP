# Architecture

Enemy RP is four layers. Each one only knows about the layer below it, which is
what keeps the interesting parts testable outside the game.

```
  UI/            roster window, /erp commands
  Profile/       what to ask for, what to answer, what to keep
  Transport/     how bytes leave and arrive
  Core/          framing, encoding, chunking, plumbing
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

`Relay:SendTo` prefers a direct route and falls back to broadcasting. Adding a
transport — cross-faction party chat, say, or guild for a cross-faction guild —
means writing one file and registering it. Nothing above `Transport/` changes.

`ClubLink.lua` is the Battle.net community backend, and the only one that
reaches strangers. Two details are load-bearing:

- `CLUB_MESSAGE_ADDED` only fires for *focused* streams, so the addon calls
  `C_Club.FocusStream` itself rather than hoping the Communities UI has the
  right channel open.
- Relay frames are ordinary chat as far as the server is concerned, so a
  `CHAT_MSG_COMMUNITIES_CHANNEL` filter hides them, and the addon prefers a
  channel named `relay` that nobody reads by hand.

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

- Cross-faction chat relay. The transport layer would carry it; the policy and
  UI work (chat bubbles, range, translation gating) is a project of its own.
- Compression. Codec has the seam for it. Version markers and fingerprints keep
  profiles off the wire in the first place, which is the larger win, so it has
  not been worth the bug surface yet.
- Any verification that a sender is who they claim to be. See the privacy note
  in the README; this is a protocol limitation, not an oversight.
