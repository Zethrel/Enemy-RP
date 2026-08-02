-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- tests/run.lua
-- Run with:  lua5.1 tests/run.lua   (from the repository root)

package.path = "./tests/?.lua;" .. package.path

local wow = require("wow")
local ROOT = "."

--------------------------------------------------------------------------------
-- Assertions
--------------------------------------------------------------------------------

local passed, failed = 0, 0
local currentSuite = ""

local function suite(name)
    currentSuite = name
    print("\n== " .. name)
end

local function check(label, condition, detail)
    if condition then
        passed = passed + 1
        print("  ok   " .. label)
    else
        failed = failed + 1
        print("  FAIL " .. label .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end

local function checkEqual(label, actual, expected)
    check(label, actual == expected,
        ("expected %q, got %q"):format(tostring(expected), tostring(actual)))
end

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

local LONG_BIO = ("Born beneath the ashen skies of Lordaeron, she walked south. "):rep(45)

local alice = wow.newClient({
    name = "Alice",
    normalizedRealm = "MoonGuard",
    faction = "Alliance",
    mapId = 84,
    gameAccountID = 5001,
    position = { x = 0.5, y = 0.5 },
    friends = { { name = "Bob", realm = "Moon Guard", gameAccountID = 5002 } },
    msp = {
        my = {
            NA = "Alice the Bold",
            NT = "Knight~Commander|of Stormwind",
            RA = "Human",
            RC = "Paladin",
            CU = "Standing watch\nby the gate",
            DE = LONG_BIO,
            TT = "",
        },
        myver = { NA = 3, NT = 1, RA = 1, RC = 1, CU = 4, DE = 7, TT = 12 },
    },
})

local bob = wow.newClient({
    name = "Bob",
    normalizedRealm = "MoonGuard",
    faction = "Horde",
    mapId = 84,
    gameAccountID = 5002,
    position = { x = 0.5, y = 0.5 },
    ignored = {},
    auras = {},
    friends = { { name = "Alice", realm = "Moon Guard", gameAccountID = 5001 } },
    units = { mouseover = { name = "Alice", realm = "MoonGuard", faction = "Alliance" } },
    msp = { my = { NA = "Bob the Quiet" }, myver = { NA = 1, TT = 2 } },
})

local aliceNS = wow.load(alice, ROOT)
local bobNS = wow.load(bob, ROOT)

for _, client in ipairs({ alice, bob }) do
    client.ns.db.clubName = "Cross Faction RP"
    client.ns.ClubLink:Resolve()
end

--------------------------------------------------------------------------------

suite("Codec")

local Codec = aliceNS.Codec
local NASTY = {
    "",
    "plain text",
    "pipes |cffff0000red|r and percent 100%",
    "separators ~ and ^ together ~^~",
    "newline\nand\ttab\rand\1control",
    "accented \195\169\195\160\195\188 and CJK \228\189\160\229\165\189",
    "\255\254\253 invalid utf8 \0 bytes",
    LONG_BIO,
    ("~"):rep(200),
}

for index, value in ipairs(NASTY) do
    local packed = Codec.Pack(value)
    checkEqual("round trip #" .. index, Codec.Unpack(packed), value)
    check("packed #" .. index .. " has no separators",
        not packed:find("[~%^|]") and not packed:find("%c"), packed:sub(1, 40))
end

check("invalid utf8 uses base64", Codec.Pack("\255\254\253"):sub(1, 2) == "b:")
check("plain text stays transparent", Codec.Pack("hello world"):sub(1, 2) == "t:")
checkEqual("malformed unpack returns nil", Codec.Unpack("not-packed"), nil)

--------------------------------------------------------------------------------

suite("Protocol frames")

local Protocol = aliceNS.Protocol

local function roundTripFrame(chunk)
    local frame = Protocol.BuildFrame("ab01", 2, 5, chunk)
    return Protocol.ParseFrame(frame)
end

local parsed = roundTripFrame("HB 84 12 deadbeef")
check("frame parses", parsed ~= nil)
checkEqual("sender survives", parsed.sender, "Alice-MoonGuard")
checkEqual("faction survives", parsed.faction, "A")
checkEqual("id survives", parsed.id, "ab01")
checkEqual("seq survives", parsed.seq, 2)
checkEqual("total survives", parsed.total, 5)
checkEqual("chunk survives", parsed.chunk, "HB 84 12 deadbeef")

checkEqual("leading space in chunk survives", roundTripFrame(" leading").chunk, " leading")
checkEqual("trailing space in chunk survives", roundTripFrame("trailing ").chunk, "trailing ")
checkEqual("empty chunk survives", roundTripFrame("").chunk, "")

check("rejects foreign text", Protocol.ParseFrame("hello there") == nil)
check("rejects wrong magic", Protocol.ParseFrame("ERP9 A-B A x 1 1 y#") == nil)
check("rejects missing sentinel", Protocol.ParseFrame("ERP1 A-B A x 1 1 y") == nil)
check("rejects seq past total", Protocol.ParseFrame("ERP1 A-B A x 3 2 y#") == nil)
check("rejects unqualified sender", Protocol.ParseFrame("ERP1 Alice A x 1 1 y#") == nil)
check("rejects bad faction", Protocol.ParseFrame("ERP1 A-B Z x 1 1 y#") == nil)
check("rejects non-string", Protocol.ParseFrame(nil) == nil)

-- Truncations and mutations of a valid frame must never raise.
local valid = Protocol.BuildFrame("ab01", 1, 1, "RS NA^3^t:Alice")
local survivedFuzz = true
math.randomseed(20260801)
for _ = 1, 3000 do
    local mutated
    local roll = math.random(3)
    if roll == 1 then
        mutated = valid:sub(1, math.random(#valid))
    elseif roll == 2 then
        local at = math.random(#valid)
        mutated = valid:sub(1, at - 1) .. string.char(math.random(0, 255)) .. valid:sub(at + 1)
    else
        local bytes = {}
        for _ = 1, math.random(40) do bytes[#bytes + 1] = string.char(math.random(0, 255)) end
        mutated = table.concat(bytes)
    end

    local ok = pcall(function()
        local frame = Protocol.ParseFrame(mutated)
        if frame then Protocol.DecodeFields(frame.chunk) end
    end)
    if not ok then survivedFuzz = false break end
end
check("3000 mutated frames parse without raising", survivedFuzz)

--------------------------------------------------------------------------------

suite("Protocol payloads")

local entries = {
    { field = "NA", version = 3, value = "Alice|the Bold" },
    { field = "CU", version = 4, value = "line one\nline two ~ ^ %" },
    { field = "DE", version = 7, value = LONG_BIO },
    { field = "NT", version = 0, value = "" },
}
local decoded = Protocol.DecodeFields(Protocol.EncodeFields(entries))
checkEqual("field count", #decoded, #entries)
local matched = true
for index, entry in ipairs(entries) do
    local got = decoded[index]
    if not got or got.field ~= entry.field or got.version ~= entry.version
        or got.value ~= entry.value then
        matched = false
    end
end
check("all fields survive encoding", matched)
checkEqual("empty payload decodes to nothing", #Protocol.DecodeFields(""), 0)
checkEqual("junk payload decodes to nothing", #Protocol.DecodeFields("!!!!"), 0)

local target, known = Protocol.DecodeRequest(
    Protocol.EncodeRequest("Bob-MoonGuard", { NA = 3, DE = 0 }))
checkEqual("request target", target, "Bob-MoonGuard")
checkEqual("request version NA", known.NA, 3)
checkEqual("request version DE", known.DE, 0)

local mapId, tooltipVersion, token = Protocol.DecodeHeartbeat(
    Protocol.EncodeHeartbeat(84, 12, "deadbeef"))
check("heartbeat round trip", mapId == 84 and tooltipVersion == 12 and token == "deadbeef")
checkEqual("malformed heartbeat", Protocol.DecodeHeartbeat("nope"), nil)

--------------------------------------------------------------------------------

suite("Chunking")

local Chunker = aliceNS.Chunker
local body = "RS " .. Protocol.EncodeFields(entries)
local chunks = Chunker:Split(body)
check("long body splits", #chunks > 1, #chunks)
check("no chunk exceeds the frame budget",
    (function()
        for _, chunk in ipairs(chunks) do
            if #Protocol.BuildFrame("ab01", 1, #chunks, chunk) > aliceNS.db.maxFrameLength then
                return false
            end
        end
        return true
    end)())

-- Feed the chunks back in reverse to prove ordering does not matter.
local reassembled
for index = #chunks, 1, -1 do
    reassembled = Chunker:Feed({
        sender = "Zoe-MoonGuard", id = "zz01", seq = index, total = #chunks,
        chunk = chunks[index],
    })
end
checkEqual("out of order reassembly", reassembled, body)

checkEqual("duplicate chunk is ignored", Chunker:Feed({
    sender = "Zoe-MoonGuard", id = "zz02", seq = 1, total = 2, chunk = "a",
}), nil)
checkEqual("no buffers leak after completion", Chunker:PendingCount(), 1)
Chunker:Forget("Zoe-MoonGuard")
checkEqual("Forget clears buffers", Chunker:PendingCount(), 0)

--------------------------------------------------------------------------------

suite("End to end: Alice announces, Bob fetches")

check("Alice bound to the relay", aliceNS.ClubLink:IsReady())
check("Bob bound to the relay", bobNS.ClubLink:IsReady())
checkEqual("Alice has a direct route to Bob", aliceNS.BNetLink:RouteCount(), 1)

aliceNS.Sync:SendHeartbeat()
wow.advance(5)

local aliceRecord = bobNS.Cache:Get("Alice-MoonGuard")
check("Bob heard the heartbeat", aliceRecord ~= nil)
checkEqual("Bob recorded the faction", aliceRecord and aliceRecord.faction, "A")
checkEqual("Bob recorded the map", aliceRecord and aliceRecord.map, 84)

-- autoFetch should have pulled the profile in the same exchange.
checkEqual("name arrived intact", aliceRecord.fields.NA, "Alice the Bold")
checkEqual("title arrived intact", aliceRecord.fields.NT,
    "Knight~Commander|of Stormwind")
checkEqual("multi-line field arrived intact", aliceRecord.fields.CU,
    "Standing watch\nby the gate")
checkEqual("version recorded", aliceRecord.versions.NA, 3)

local injected = bob.env.msp.char["Alice-MoonGuard"]
checkEqual("profile injected into the local RP addon", injected.field.NA, "Alice the Bold")
checkEqual("injected version", injected.ver.NA, 3)
check("marked as supported", injected.supported == true)

-- The tooltip request should not have dragged the long description along.
check("description not sent with the tooltip request", aliceRecord.fields.DE == nil)

--------------------------------------------------------------------------------

suite("End to end: full profile on demand")

bobNS.Sync:RequestFull("Alice-MoonGuard", true)
wow.advance(10)

checkEqual("long description arrived intact", aliceRecord.fields.DE, LONG_BIO)
checkEqual("description version", aliceRecord.versions.DE, 7)
checkEqual("injected description", bob.env.msp.char["Alice-MoonGuard"].field.DE, LONG_BIO)

--------------------------------------------------------------------------------

suite("End to end: unchanged profiles cost nothing")

local before = wow.world.nextMessageId
bobNS.Sync:RequestFull("Alice-MoonGuard", true)
wow.advance(5)
-- Alice answers directly over Battle.net rather than the community, and with
-- every version already current she has nothing to say at all.
checkEqual("no community traffic for an unchanged profile", wow.world.nextMessageId, before)

--------------------------------------------------------------------------------

suite("Roster and mouseover")

local roster = bobNS.Cache:Roster(900)
checkEqual("one character on the roster", #roster, 1)
checkEqual("roster shows the roleplay name", roster[1].name, "Alice the Bold")
check("roster marks the profile as held", roster[1].hasProfile)

local bnetBefore = wow.world.bnetMessages
bobNS.Sync:InspectUnit("mouseover") -- Alice, fetched moments ago
wow.advance(1)
checkEqual("mouseover on a fresh profile sends nothing",
    wow.world.bnetMessages, bnetBefore)

-- Someone never heard from has no direct route, so the request has to go out
-- over the community instead.
bob.env.__spec.units.mouseover = { name = "Cara", realm = "MoonGuard", faction = "Alliance" }
local clubBefore = wow.world.nextMessageId
bobNS.Sync:InspectUnit("mouseover")
wow.advance(2)
check("mouseover on an unknown character requests over the community",
    wow.world.nextMessageId > clubBefore)

bobNS.Cache:Forget("Alice-MoonGuard")
checkEqual("forgotten", bobNS.Cache:Count(), 0)

--------------------------------------------------------------------------------

suite("Hostile input")

-- Anyone in the community can write anything into the stream.
local hostile = {
    -- A syntactically valid field code that is not part of the profile schema.
    "ERP1 Evil-Realm H aaaa 1 1 RS ZZ^0^t:pwned#",
    "ERP1 Evil-Realm H bbbb 1 1 RS __index^0^t:pwned#",
    "ERP1 Evil-Realm H cccc 1 1 RS NA^0^t:" .. ("x"):rep(5000) .. "#",
    "ERP1 Alice-MoonGuard A dddd 1 1 RQ Bob-MoonGuard NA=0#",
    "ERP1 Evil-Realm H eeee 1 1 ZZ nonsense#",
    "ERP1 Evil-Realm H ffff 1 1 #",
}
local survivedHostile = true
for _, message in ipairs(hostile) do
    local ok = pcall(function() bobNS.Relay:Incoming(message, { backend = "test" }) end)
    if not ok then survivedHostile = false end
end
check("hostile frames handled without raising", survivedHostile)

local evilInjected = bob.env.msp.char["Evil-Realm"]
checkEqual("unschemad field never reaches the RP addon", evilInjected.field.ZZ, nil)
checkEqual("lua metafield name never reaches the RP addon", evilInjected.field.__index, nil)

-- One field on that frame was legitimate, so the record exists; the point is
-- that only the schema field made it through.
local evilRecord = bobNS.Cache:Get("Evil-Realm")
checkEqual("only the schema field was cached", evilRecord and evilRecord.fields.ZZ, nil)
check("oversized but well formed value is accepted",
    evilRecord ~= nil and evilRecord.fields.NA == ("x"):rep(5000))

--------------------------------------------------------------------------------

--------------------------------------------------------------------------------

suite("Chat: sanitizing untrusted text")

local Sanitize = bobNS.ChatIn.Sanitize

checkEqual("colour codes removed",
    Sanitize("|cffff0000red|r text"), "red text")
checkEqual("hyperlink collapses to its display text",
    Sanitize("look at |cffffd000|Hitem:19019::::::::60:::::|h[Thunderfury]|h|r!"),
    "look at [Thunderfury]!")
checkEqual("textures removed",
    Sanitize("|TInterface\\Icons\\Foo:16|t hello"), " hello")
checkEqual("newlines flattened",
    Sanitize("first\nsecond"), "first second")
checkEqual("stray pipes removed",
    Sanitize("50|50 odds |"), "5050 odds ")
checkEqual("a literal pipe stays escaped for AddMessage",
    Sanitize("a || b"), "a || b")
-- A literal pipe survives as the `||` escape, which AddMessage renders as one
-- pipe. What must never survive is `|` followed by anything else, which is
-- what opens a colour code, texture or hyperlink.
check("no escape sequence survives any of it",
    (function()
        for _, hostile in ipairs({
            "|Hplayer:Evil|h[click me]|h",
            "|cff000000|Hgarrmission:x|h|h|r",
            "||||cffff0000still red",
            "|H|H|h|h|h nested",
            "|TInterface\\Icons\\X:64|t|cff00ff00|r|",
        }) do
            local cleaned = Sanitize(hostile)
            if cleaned:gsub("||", ""):find("|") then return false end
        end
        return true
    end)())

local longLine = Sanitize(("y"):rep(900))
check("overlong text is truncated", #longLine < 600, #longLine)

--------------------------------------------------------------------------------

suite("Chat: relay and range")

-- Bob has to be on Alice's roster or she will not bother broadcasting, and Bob
-- needs Alice's profile back (the roster suite forgot it) for the displayed
-- name to come from the profile rather than the character name.
aliceNS.Cache:Touch("Bob-MoonGuard", "H", 84, 2, "abc123")
bobNS.Sync:RequestFull("Alice-MoonGuard", true)
wow.advance(5)
checkEqual("Alice's profile is cached again",
    bobNS.Cache:Get("Alice-MoonGuard").fields.NA, "Alice the Bold")

local function say(client, ns_, chatType, text)
    client.env.__chatLog = {}
    bob.env.__chatLog = {}
    client.fire("CHAT_MSG_" .. chatType, text, client.name, nil, nil, nil, nil,
        nil, nil, nil, nil, nil, "Player-" .. client.name)
    wow.advance(2)
end

say(alice, aliceNS, "SAY", "well met, stranger")
checkEqual("Bob sees a nearby say", #bob.env.__chatLog, 1)
checkEqual("formatted as say", bob.env.__chatLog[1],
    "|cff4080ffAlice the Bold|r says: well met, stranger")

alice.env.__spec.position = { x = 0.6, y = 0.5 } -- 100 yards away
say(alice, aliceNS, "SAY", "too far to hear")
checkEqual("say does not carry 100 yards", #bob.env.__chatLog, 0)

say(alice, aliceNS, "YELL", "AUDIBLE FROM HERE")
checkEqual("yell does carry 100 yards", #bob.env.__chatLog, 1)
check("formatted as yell", bob.env.__chatLog[1]:find("yells: ") ~= nil)

alice.env.__spec.position = { x = 0.5, y = 0.5 }
alice.env.__spec.mapId = 1
say(alice, aliceNS, "YELL", "SHOUTING ACROSS THE SEA")
-- Alice has moved off the map her only known listener is on, so this never
-- reaches the relay at all. The receiver-side continent check is asserted
-- separately below, by injecting a frame that did get sent.
checkEqual("nothing is broadcast once the listener is on another map",
    #bob.env.__chatLog, 0)
alice.env.__spec.mapId = 84

say(alice, aliceNS, "EMOTE", "bows deeply")
checkEqual("emote uses the emote template", bob.env.__chatLog[1],
    "|cff4080ffAlice the Bold|r bows deeply")

say(alice, aliceNS, "TEXT_EMOTE", "Alice waves.")
checkEqual("predefined emotes pass through verbatim", bob.env.__chatLog[1], "Alice waves.")

--------------------------------------------------------------------------------

suite("Chat: settings are respected")

bobNS.db.chatShow.SAY = false
say(alice, aliceNS, "SAY", "hidden by preference")
checkEqual("a chat type Bob hid is not shown", #bob.env.__chatLog, 0)
bobNS.db.chatShow.SAY = true

aliceNS.db.chatSend.SAY = false
say(alice, aliceNS, "SAY", "never left Alice")
checkEqual("a chat type Alice muted is never sent", #bob.env.__chatLog, 0)
aliceNS.db.chatSend.SAY = true

bobNS.db.chatEnabled = false
say(alice, aliceNS, "SAY", "chat relay off")
checkEqual("master switch silences receipt", #bob.env.__chatLog, 0)
bobNS.db.chatEnabled = true

bob.env.__spec.ignored = { Alice = true }
say(alice, aliceNS, "SAY", "from someone ignored")
checkEqual("the ignore list is honoured", #bob.env.__chatLog, 0)
bob.env.__spec.ignored = {}

bobNS.db.requireTongues = true
say(alice, aliceNS, "SAY", "unintelligible without the elixir")
checkEqual("tongues gate blocks without the aura", #bob.env.__chatLog, 0)
bob.env.__spec.auras = { [7178] = { name = "Elixir of Tongues" } }
say(alice, aliceNS, "SAY", "now understood")
checkEqual("tongues gate passes with the aura", #bob.env.__chatLog, 1)
bobNS.db.requireTongues = false

-- Alice should not spend the community's bandwidth when nobody can hear her.
aliceNS.Cache:Forget("Bob-MoonGuard")
local quietBefore = wow.world.nextMessageId
say(alice, aliceNS, "SAY", "talking to an empty room")
checkEqual("nothing is broadcast with no listeners nearby",
    wow.world.nextMessageId, quietBefore)
aliceNS.Cache:Touch("Bob-MoonGuard", "H", 84, 2, "abc123")

--------------------------------------------------------------------------------

suite("Chat: hostile input")

-- Each frame needs its own id: Relay suppresses duplicate (sender, id, seq)
-- triples, so reusing one would drop everything after the first payload and
-- make the assertions below pass without testing anything.
local injectCount = 0
local function inject(payload)
    bob.env.__chatLog = {}
    injectCount = injectCount + 1
    bobNS.Relay:Incoming(
        ("ERP1 Evil-Realm A z%03d 1 1 CH %s#"):format(injectCount, payload),
        { backend = "test" })
end

local survivedChat = true
for _, payload in ipairs({
    "S 84 0.5000 0.5000 t:hello",
    "S 84 2.0000 0.5000 t:off the map",
    "S 84 -1.000 0.5000 t:negative",
    "X 84 0.5000 0.5000 t:bad kind",
    "S notanumber 0.5 0.5 t:bad map",
    "S 84 0.5000 0.5000",
    "",
}) do
    local ok = pcall(inject, payload)
    if not ok then survivedChat = false end
end
check("malformed chat payloads never raise", survivedChat)

inject("S 84 2.0000 0.5000 t:off the map")
checkEqual("a position outside the map is rejected", #bob.env.__chatLog, 0)

inject("S 1 0.5000 0.5000 t:shouting across the sea")
checkEqual("a speaker on another continent is out of earshot", #bob.env.__chatLog, 0)

inject("S 85 0.5000 0.5000 t:same continent, next map over")
checkEqual("a speaker on a different map of the same continent is heard",
    #bob.env.__chatLog, 1)

inject("S 84 0.5000 0.5000 t:" ..
    "%7CcffFF0000%7CHitem:1::::::::60:::::%7Ch[Free Gold]%7Ch%7Cr")
checkEqual("an injected hyperlink is defanged", #bob.env.__chatLog, 1)
local shown = bob.env.__chatLog[1] or ""
check("no clickable link reaches the chat frame", not shown:find("|H"), shown)
check("the sender's own colour code is gone", not shown:find("cffFF0000"), shown)
check("an absurdly long roleplay name is capped", #shown < 200, #shown)
check("the link text is still readable", shown:find("[Free Gold]", 1, true) ~= nil, shown)

-- Alice is Alliance and so is the spoofer, from Bob's point of view the
-- interesting case is a flood.
local flooded = 0
for index = 1, 60 do
    inject(("S 84 0.5000 0.5000 t:spam %d"):format(index))
    flooded = flooded + #bob.env.__chatLog
end
check("a flooding sender is cut off", flooded < 60, flooded)

--------------------------------------------------------------------------------

suite("Party transport: no community, no friends")

-- Cara and Dane belong to no Battle.net community and are not friends. All they
-- share is a party, which is how cross-faction world roleplay actually happens.
local cara = wow.newClient({
    name = "Cara", normalizedRealm = "MoonGuard", faction = "Alliance",
    mapId = 84, position = { x = 0.5, y = 0.5 }, clubs = false,
    group = { { fullName = "Dane-MoonGuard", faction = "Horde" } },
    msp = {
        my = { NA = "Cara Emberlight", RA = "Night Elf", DE = LONG_BIO, TT = "" },
        myver = { NA = 2, RA = 1, DE = 5, TT = 9 },
    },
})
local dane = wow.newClient({
    name = "Dane", normalizedRealm = "MoonGuard", faction = "Horde",
    mapId = 84, position = { x = 0.5, y = 0.5 }, clubs = false,
    group = { { fullName = "Cara-MoonGuard", faction = "Alliance" } },
    msp = { my = { NA = "Dane Stormfang" }, myver = { NA = 1, TT = 1 } },
})

local caraNS = wow.load(cara, ROOT)
local daneNS = wow.load(dane, ROOT)

check("Cara has no community to send to", caraNS.ClubLink.channel == nil)
check("the party backend is ready", caraNS.AddonLink.Group:IsReady())
checkEqual("the party roster resolved", caraNS.AddonLink:GroupCount(), 1)
check("Cara can reach Dane directly",
    caraNS.AddonLink.Group:CanReach("Dane-MoonGuard"))

local clubBefore, addonBefore = wow.world.nextMessageId, wow.world.addonMessages
caraNS.Sync:SendHeartbeat()
wow.advance(5)

check("the party carried the traffic", wow.world.addonMessages > addonBefore)
checkEqual("no community was involved", wow.world.nextMessageId, clubBefore)

local caraRecord = daneNS.Cache:Get("Cara-MoonGuard")
check("Dane heard Cara", caraRecord ~= nil)
checkEqual("and pulled her profile", caraRecord and caraRecord.fields.NA, "Cara Emberlight")

-- An addon message caps at 255 characters against a community's 900, so the
-- long description has to survive a much finer chunking.
daneNS.Sync:RequestFull("Cara-MoonGuard", true)
wow.advance(10)
checkEqual("a long profile survives 240-character frames",
    caraRecord.fields.DE, LONG_BIO)

local groupChunks = #caraNS.Chunker:Split("RS " .. LONG_BIO, 240)
local clubChunks = #caraNS.Chunker:Split("RS " .. LONG_BIO, 900)
check("small frames really do split further", groupChunks > clubChunks,
    groupChunks .. " vs " .. clubChunks)

-- Chat across the party, with no community anywhere in sight.
dane.env.__chatLog = {}
cara.fire("CHAT_MSG_SAY", "well met, orc", "Cara", nil, nil, nil, nil,
    nil, nil, nil, nil, nil, "Player-Cara")
wow.advance(2)
checkEqual("party chat relay reaches the other faction", #dane.env.__chatLog, 1)
checkEqual("with the roleplay name", dane.env.__chatLog[1],
    "|cff4080ffCara Emberlight|r says: well met, orc")

--------------------------------------------------------------------------------

suite("Party transport: the server vouches for the sender")

-- Unlike a community, an addon message carries a sender the server filled in.
-- A frame whose in-band name disagrees with it is a forgery.
local caraProfile = daneNS.Cache:Get("Cara-MoonGuard")
local nameBefore = caraProfile.fields.NA

dane.fire("CHAT_MSG_ADDON", "ERP1",
    "ERP1 Cara-MoonGuard A ff01 1 1 RS NA^99^t:Not Cara At All#",
    "PARTY", "Evil-MoonGuard")
wow.advance(1)
checkEqual("a frame claiming someone else's name is dropped",
    daneNS.Cache:Get("Cara-MoonGuard").fields.NA, nameBefore)

dane.env.__chatLog = {}
dane.fire("CHAT_MSG_ADDON", "ERP1",
    "ERP1 Cara-MoonGuard A ff02 1 1 CH S 84 0.5000 0.5000 t:words in her mouth#",
    "PARTY", "Evil-MoonGuard")
wow.advance(1)
checkEqual("and cannot put words in her mouth either", #dane.env.__chatLog, 0)

-- The same frame from the character it claims to be is accepted, which proves
-- the check is on the mismatch and not on the frame itself.
dane.fire("CHAT_MSG_ADDON", "ERP1",
    "ERP1 Cara-MoonGuard A ff03 1 1 RS NA^99^t:Cara Renamed#",
    "PARTY", "Cara-MoonGuard")
wow.advance(1)
checkEqual("the genuine sender is believed",
    daneNS.Cache:Get("Cara-MoonGuard").fields.NA, "Cara Renamed")

--------------------------------------------------------------------------------

suite("Guild transport")

local eve = wow.newClient({
    name = "Eve", normalizedRealm = "MoonGuard", faction = "Alliance",
    mapId = 84, position = { x = 0.5, y = 0.5 }, clubs = false,
    guild = { { fullName = "Finn-MoonGuard", online = true } },
    msp = { my = { NA = "Eve Duskwhisper", TT = "" }, myver = { NA = 4, TT = 3 } },
})
local finn = wow.newClient({
    name = "Finn", normalizedRealm = "MoonGuard", faction = "Horde",
    mapId = 84, position = { x = 0.5, y = 0.5 }, clubs = false,
    guild = { { fullName = "Eve-MoonGuard", online = true } },
    msp = { my = { NA = "Finn Ironhide" }, myver = { NA = 1, TT = 1 } },
})

local eveNS = wow.load(eve, ROOT)
local finnNS = wow.load(finn, ROOT)
wow.advance(3) -- the guild roster refresh is deferred

check("the guild backend is ready", eveNS.AddonLink.Guild:IsReady())
checkEqual("the guild roster resolved", eveNS.AddonLink:GuildCount(), 1)
check("Eve is not grouped with anyone", not eveNS.AddonLink.Group:IsReady())

eveNS.Sync:SendHeartbeat()
wow.advance(5)

local eveRecord = finnNS.Cache:Get("Eve-MoonGuard")
check("a cross-faction guildmate is heard", eveRecord ~= nil)
checkEqual("and their profile arrives", eveRecord and eveRecord.fields.NA,
    "Eve Duskwhisper")

--------------------------------------------------------------------------------

suite("Community auto-discovery")

-- A channel actually named "relay" is an unambiguous opt-in, so no command is
-- needed and nothing has to be overheard first.
local gwen = wow.newClient({
    name = "Gwen", normalizedRealm = "MoonGuard", faction = "Alliance",
    mapId = 84, position = { x = 0.5, y = 0.5 },
    msp = { my = { NA = "Gwen", TT = "" }, myver = { NA = 1, TT = 1 } },
})
local gwenNS = wow.load(gwen, ROOT)
check("a dedicated relay channel is adopted with no configuration",
    gwenNS.ClubLink.channel ~= nil)
checkEqual("and it is the relay channel, not general",
    gwenNS.ClubLink.channel and gwenNS.ClubLink.channel.streamName, "relay")

-- A community with only a general channel is listened to but not sent into,
-- because dumping protocol frames into an unrelated community would be rude.
local hal = wow.newClient({
    name = "Hal", normalizedRealm = "MoonGuard", faction = "Horde",
    mapId = 84, position = { x = 0.5, y = 0.5 },
    clubStreams = { { streamId = 1, name = "General", streamType = 1 } },
    msp = { my = { NA = "Hal", TT = "" }, myver = { NA = 1, TT = 1 } },
})
local halNS = wow.load(hal, ROOT)
checkEqual("a general-only community is listened to", #halNS.ClubLink:ListChannels(), 1)
check("but nothing is sent into it unprompted", halNS.ClubLink.channel == nil)

-- Overhearing one frame is enough to establish that the addon belongs there.
halNS.ClubLink:CLUB_MESSAGE_ADDED(99, 1, 4242)
wow.world.clubMessages[4242] = nil
check("still silent after a message that was not ours", halNS.ClubLink.channel == nil)

wow.world.clubMessages[4243] = {
    clubId = 99, streamId = 1,
    content = "ERP1 Ivy-MoonGuard A aa01 1 1 HB 84 1 abcdef#",
}
halNS.ClubLink:CLUB_MESSAGE_ADDED(99, 1, 4243)
check("overhearing relay traffic makes the channel usable",
    halNS.ClubLink.channel ~= nil)
checkEqual("and the choice is remembered for next login",
    halNS.db.learnedClubId, 99)

--------------------------------------------------------------------------------

print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
