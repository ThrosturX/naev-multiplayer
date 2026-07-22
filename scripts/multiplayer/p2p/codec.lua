-- MP2P/1 packet codec. This module is deliberately independent of Naev.
local codec = {}

codec.VERSION = "MP2P/1"
codec.MAX_PACKET = 16 * 1024

local function escape ( value )
   return tostring(value):gsub("([^%w%-%._~])", function ( c )
      return string.format("%%%02X", string.byte(c))
   end)
end

local function unescape ( value )
   local at=1
   while true do
      local mark=value:find("%",at,true)
      if not mark then break end
      if not value:sub(mark+1,mark+2):match("^%x%x$") then return nil,"invalid escape" end
      at=mark+3
   end
   return (value:gsub("%%(%x%x)", function ( hex )
      return string.char(tonumber(hex, 16))
   end))
end

codec.escape = escape
codec.unescape = unescape

local valid_types = {
   hello=true, query=true, hint=true, claim=true, leave=true,
   player_manifest=true, player_state=true, chat=true,
   npc_manifest=true, npc_add=true, npc_remove=true, npc_state=true,
   craft_manifest=true, craft_state=true, craft_remove=true,
}

local required = {
   hello={"node","cap"}, query={"node","system"},
   hint={"node","system","host","endpoint","claim","ttl"},
   claim={"node","system","claim","endpoint"}, leave={"node","system"},
   player_manifest={"node","system","entity","ship","name"},
   player_state={"node","system","entity","seq","x","y","vx","vy","dir"},
   chat={"node","system","seq","text"},
   npc_manifest={"node","system","claim","seq","entities"},
   npc_add={"node","system","claim","entity","seq","ship","name","faction"},
   npc_remove={"node","system","claim","entity","seq"},
   npc_state={"node","system","claim","seq","entities"},
   craft_manifest={"node","system","owner","entity","seq","ship","name"},
   craft_state={"node","system","owner","seq","entities"},
   craft_remove={"node","system","owner","entity","seq"},
}

local numeric = {
   seq={0, 9007199254740991}, ttl={1, 60},
   x={-1e9,1e9}, y={-1e9,1e9}, vx={-1e7,1e7}, vy={-1e7,1e7},
   dir={-1e6,1e6}, accel={0,1}, primary={0,1}, secondary={0,1},
   armour={0,1e9}, shield={0,1e9}, stress={0,1e9}, energy={0,1e9},
}

local function validate ( message )
   if not valid_types[message.type] then return nil, "unknown type" end
   for _index, key in ipairs(required[message.type]) do
      if message[key] == nil or message[key] == "" then
         return nil, "missing " .. key
      end
   end
   if message.cap and message.cap ~= "player" and message.cap ~= "directory" then
      return nil, "invalid capability"
   end
   if message.type == "hello" and message.cap == "player" then
      if type(message.name) ~= "string" or message.name == "" then return nil, "missing name" end
   end
   if message.name and (#message.name > 240 or message.name:find("[%z\1-\31\127]")) then
      return nil, "invalid name"
   end
   if message.system and (#message.system > 240 or message.system:find("[%z\1-\31\127]")) then
      return nil, "invalid system"
   end
   if message.claim and (#message.claim > 128 or message.claim:find("[%z\1-\31\127]")) then
      return nil, "invalid claim"
   end
   if message.node and not message.node:match("^[%x]+$") then return nil, "invalid node" end
   if message.host and not message.host:match("^[%x]+$") then return nil, "invalid host" end
   if message.endpoint and (not message.endpoint:match("^[^%s:]+:%d+$") or #message.endpoint > 255) then
      return nil, "invalid endpoint"
   end
   for key, bounds in pairs(numeric) do
      if message[key] ~= nil then
         local n = tonumber(message[key])
         if not n or n ~= n or n < bounds[1] or n > bounds[2] then
            return nil, "invalid " .. key
         end
         message[key] = n
      end
   end
   return message
end

codec.validate = validate

function codec.encode ( message )
   local checked, err = validate(message)
   if not checked then return nil, err end
   local keys = {}
   for key in pairs(message) do
      if key ~= "type" then table.insert(keys, key) end
   end
   table.sort(keys)
   local lines = { codec.VERSION .. " " .. message.type }
   for _index, key in ipairs(keys) do
      table.insert(lines, escape(key) .. "=" .. escape(message[key]))
   end
   local packet = table.concat(lines, "\n") .. "\n"
   if #packet > codec.MAX_PACKET then return nil, "packet too large" end
   return packet
end

function codec.decode ( packet )
   if type(packet) ~= "string" then return nil, "packet is not a string" end
   if #packet > codec.MAX_PACKET then return nil, "packet too large" end
   local header, body = packet:match("^([^\n]+)\n?(.*)$")
   if not header then return nil, "missing header" end
   local version, kind = header:match("^(%S+) ([%w_]+)$")
   if version ~= codec.VERSION then return nil, "incompatible version" end
   local message = { type=kind }
   for line in body:gmatch("([^\n]+)") do
      local raw_key, raw_value = line:match("^([^=]+)=(.*)$")
      if not raw_key then return nil, "invalid field" end
      local key, keyerr = unescape(raw_key)
      local value, valueerr = unescape(raw_value)
      if not key then return nil, keyerr end
      if not value then return nil, valueerr end
      if message[key] ~= nil or key == "type" then return nil, "duplicate field" end
      message[key] = value
   end
   return validate(message)
end

return codec
