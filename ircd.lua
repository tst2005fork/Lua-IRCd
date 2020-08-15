#!/usr/bin/env lua
----------- ircserver.lua

-- Based on The Tcl IRCd (http://www.hping.org/tclircd/) by Salvatore Sanfilippo.
--

local socket = require("socket")

local config = require "config"
assert(config.ip)
assert(config.port)
assert(config.hostname)
assert(config.version)

local function log(line)
	io.stderr:write(line.."\n")
end

local ChannelInfo = {}
local ClientMap = {}
local NickToClientInfo = {}

-- events
local ChannelPrivateMessage = { } -- nil ?

local function newset(self)
	local reverse = {}
	local set = {}
	setmetatable(set, { __index = {
		insert = function(set, value)
			table.insert(set, value)
			reverse[value] = #(set)
			ClientMap[value] =
			{
				Client = value,
				State = "UNREGISTERED",
				Host = type(value) == "tcp{client}" and value:getpeername() or "localhost",
				Port = 0,
				Nick = nil,
				User = nil,
				RealName = nil,
				Channels = {},
			}
		end,
		remove = function(set, value)
			local clientInfo = ClientMap[value]
			if clientInfo and clientInfo.Nick then
				NickToClientInfo[clientInfo.Nick] = nil
			end
			table.remove(set, reverse[value])
			reverse[value] = nil
			ClientMap[value] = nil
		end,
	}})
	return set
end

local irc = {}
irc.ChannelInfo = ChannelInfo
irc.ClientMap = ClientMap
irc.NickToClientInfo = NickToClientInfo
irc.ChannelPrivateMessage = ChannelPrivateMessage

local _set = newset(irc)

irc.set=_set

function irc:ircWrite(clientInfo, text)
	local nick = ""
	if clientInfo then nick = clientInfo.Nick or "" end
	log('->' .. nick .. '  ' .. text)
	local bytes, error = clientInfo.Client:send(text .. "\r\n")
	if error then
		clientInfo.Client:close()
		log("Removing client from set")
		local set = self.set
		set:remove(clientInfo.Client)
	end
end

function irc:SendRawMessage(clientInfo, text)
	self:ircWrite(clientInfo, ":" .. config.hostname .. " " .. text)
end

function irc:SendServerClientMessage(clientInfo, code, text)
	local codeStr = tostring(code)
	if codeStr:len() == 1 then
		codeStr = '00' .. codeStr
	elseif codeStr:len() == 2 then
		codeStr = '0' .. codeStr
	end
	-- FIXME: clientInfo.Nick can be nil
	self:ircWrite(clientInfo, ":" .. config.hostname .. " " .. codeStr .. " " .. (clientInfo.Nick or "-") .. " " .. text)
end

function irc:SendUserMessage(clientInfo, target, text, noSelf)
	local userStr = ":" .. clientInfo.Nick .. "!" .. clientInfo.User .. "@" .. clientInfo.Host
	if target:sub(1, 1) == "#" then
--local ChannelInfo = self.ChannelInfo
		local channel = ChannelInfo[target]
		for _, user in pairs(channel.userList) do
			if noSelf == true and user.clientInfo == clientInfo then
			else
				self:ircWrite(user.clientInfo, userStr .. " " .. text)
			end
		end
	else
		local targetInfo = ClientMap[target]
		if targetInfo then
			self:ircWrite(targetInfo.Client, userStr .. " " .. text)
		end
	end
end

local function Command_TOPIC(self, clientInfo, args)
	print("Topic args: " .. args)
	local _, _, target, topic = args:find("^([^ ]+) +:%s*(.*)%s*$")
	if not target then return end
--local ChannelInfo = self.ChannelInfo
	local channel = ChannelInfo[target]
	if not channel then return end
	channel.topic = topic
	if channel.topic == "" then
		self:SendServerClientMessage(clientInfo, 331, channel.name .. " :No topic is set")
	else
		self:SendServerClientMessage(clientInfo, 332, channel.name .. " :" .. channel.topic)
	end
end

local function Command_NAMES(self, clientInfo, channelName)
	if not channelName then return end
--local ChannelInfo = self.ChannelInfo

	local channel = ChannelInfo[channelName]
	if channel then
		local users = ""
		for userClientInfo, user in pairs(channel.userList) do
			users = users .. user.mode .. userClientInfo.Nick .. " "
		end
		self:SendServerClientMessage(clientInfo, 353, "= " .. channel.name .. " :" .. users)
	end
	self:SendServerClientMessage(clientInfo, 366, channelName .. " :End of /NAMES list.")
end

local function Command_JOIN(self, clientInfo, channels)
--local ChannelInfo = self.ChannelInfo

	for channelName in channels:gmatch('([^ ,]+),*') do
		local channel = ChannelInfo[channelName]
		if not channel then
			channel =
			{
				topic = "",
				userList = {},
				numUsers = 0,
				name = channelName,
			}
			ChannelInfo[channelName] = channel
		end

		local channelUser = channel.userList[clientInfo]
		if not channelUser then
			clientInfo.Channels[channelName] = channel
			channel.userList[clientInfo] = { clientInfo = clientInfo, mode = channel.numUsers > 0 and "" or "@" }
			channel.numUsers = channel.numUsers + 1
			self:SendUserMessage(clientInfo, channelName, "JOIN " .. channelName)
			Command_TOPIC(self, clientInfo, channelName .. " :" .. channel.topic)
			Command_NAMES(self, clientInfo, channelName)
		end
	end
end

local function Command_LIST(self, clientInfo, args)
	local target
	if args then
		local _, _, target = args:find("^:%s*(.+)%s*$")
	end
	for channelName, channel in pairs(clientInfo.Channels) do
		self:SendServerClientMessage(clientInfo, 322, channelName .. " " .. channel.numUsers .. " :" .. channel.topic)
	end
	self:SendServerClientMessage(clientInfo, 323, ":End of LIST")
end

local function Command_MODE(self, clientInfo, args)
	if not args then return end
	local _, _, target, mode = args:find("^+([^ ]+) *(.*)$")
	if not target then return end

	local args = {}
	for arg in mode:gmatch('([^ ]+) *') do
		table.insert(args, arg)
	end
--local ChannelInfo = self.ChannelInfo

	if target:sub(1, 1) == '#' then
		local channel = ChannelInfo[target]
		if args[1] == '+o' or args[1] == '-o' then
			local modeClient = NickToClientInfo[args[2]]
			if not modeClient then return end

			local channelUser = channel.userList[clientInfo]
			if not channelUser then return end
			if channelUser.mode ~= '@' then
				self:SendServerClientMessage(clientInfo, 482, target .. " :You're not channel operator")
				return
			end

			local modeUser = channel.userList[modeClient]
			modeUser.mode = arg[1] == '+o' and '@' or ''

			self:SendUserMessage(clientInfo, target, "MODE " .. target .. " " .. mode)
		else
			self:SendServerClientMessage(clientInfo, 324, target)
		end
	end
end

local function Command_NICK(self, clientInfo, nick)
	if not nick then return end
	local oldNick = clientInfo.Nick
	if NickToClientInfo[nick] then
		self:SendRawMessage(clientInfo, "433 * " .. nick .. " :Nickname is already in use")
		return
	end
	for channelName, channel in pairs(clientInfo.Channels) do
		self:SendUserMessage(clientInfo, channelName, "NICK " .. nick)
	end
	clientInfo.Nick = nick
	NickToClientInfo[nick] = NickToClientInfo[oldNick]
	NickToClientInfo[oldNick] = nil
end

local function Command_NOTICE(self, clientInfo, args)
	if not args then return end
	local _, _, target, message = args:find("^([^ ]+) +:(.*)$")
	if not target then return end
	self:SendUserMessage(clientInfo, target, "NOTICE " .. target .. " :" .. message, true)
end

local function Command_PART(self, clientInfo, args, command, text)
	if not args then return end

--FIXME: "PART #test" no reason => bug: nothing done
	local _, _, target, message = args:find("^([^ ]+) +(.*)$")
	if not target then return end
--local ChannelInfo = self.ChannelInfo

	for channelName in args:gmatch('(#%w+),-') do
		local channel = ChannelInfo[channelName]
		if channel then
			if command == "QUIT" then
				-- FIXME: do not send each part ! ... just quit.
				self:SendUserMessage(clientInfo, channelName, "QUIT " .. text, true)
			elseif command then
				self:SendUserMessage(clientInfo, channelName, command .. " " .. channelName .. " " .. message)
			end

			clientInfo.Channels[channelName] = nil
			channel.userList[clientInfo] = nil
			channel.numUsers = channel.numUsers - 1
			if channel.numUsers == 0 then
				ChannelInfo[channel] = nil
			end
		end
	end
end

local function Command_PING(self, clientInfo, message)
	self:SendRawMessage(clientInfo, "PONG " .. config.hostname .. " " .. message)
end

local function Command_PONG(self, clientInfo, message)
end

local function Command_PRIVMSG(self, clientInfo, args)
	if not args then return end
	local _, _, target, message = args:find("^([^ ]+) +:(.*)$")
	if not target then return end
	self:SendUserMessage(clientInfo, target, "PRIVMSG " .. target .. " :" .. message, true)

	-- channel message
	if not inPrivateMessage and ChannelPrivateMessage then
		local func = ChannelPrivateMessage[target]
		if func then
			inPrivateMessage = true
			curClientInfo = clientInfo
			curTarget = target
			func(clientInfo, target, message)
			inPrivateMessage = nil
		end
	end
end

local function Command_QUIT(self, clientInfo, message)
	for channelName, channel in pairs(clientInfo.Channels) do
		if channel.userList[clientInfo] then
-- FIXME: do not use PART for QUIT...
			Command_PART(self, clientInfo, channelName, "QUIT", message)
		end
	end

	if clientInfo.Nick then
		NickToClientInfo[clientInfo.Nick] = nil
	end
	clientInfo.Client:close()
	local set = self.set
	set:remove(clientInfo.Client)
end

local function Command_USERHOST(self, clientInfo, args)
	if not args then return end
	local _, _, nicks = args:find(":(.+)")
	if not nicks then return end
	local text = ""
	for nick in nicks:gmatch('(.*) -') do
		local nickClient = NickToClientInfo[nick]
		if nickClient then
			local nickInfo = ClientMap[nickClient]

			text = text .. nick .. "=+" .. nickClient.User .. "@" .. nickClient.Host .. " "

		end
	end
	self:SendServerClientMessage(clientInfo, 302, ":" .. text)
end

local function Command_WHO(self, clientInfo, args)
	local _, _, channel = args:find("WHO (.*) (.*)$")
	if channel then
		handleClientWho(clientInfo, channel)
--[[
	foreach {topic userlist usermode} [channelInfoOrReturn $fd $channel] break
	foreach userfd $userlist mode $usermode {
		SendServerClientMessage $fd 352 "$channel ~[clientUser $userfd] [clientHost $userfd] [config hostname] $mode[clientNick $userfd] H :0 [clientRealName $userfd]"
	}
	SendServerClientMessage $fd 315 "$channel :End of /WHO list."
]]--
		return
	end
end

local function Command_WHOIS(self, clientInfo, nick)
	if not nick then return end
	local targetInfo = ClientMap[nick]
	if targetInfo then
		self:SendServerClientMessage(clientInfo, 311, nick .. " ~" .. targetInfo.User .. " " .. targetInfo.Host .. " * :" .. targetInfo.RealName)
		local chans = ""
		for channelName, channel in pairs(targetInfo.Channels) do
			chans = chans .. channelName .. " "
		end
		if chans:len() > 1 then
			self:SendServerClientMessage(clientInfo, 319, nick .. " :" .. chans)
		end
		self:SendServerClientMessage(clientInfo, 312, nick .. " " .. config.hostname .. " :" .. config.hostname)
	end
	self:SendServerClientMessage(clientInfo, 318, nick .. " :End of /WHOIS list.")
end

local CommandDispatch =
{
	PING = Command_PING,
	PONG = Command_PONG,
	MODE = Command_MODE,
	JOIN = Command_JOIN,
	PART = Command_PART,
	PRIVMSG = Command_PRIVMSG,
	NOTICE = Command_NOTICE,
	QUIT = Command_QUIT,
	NICK = Command_NICK,
	TOPIC = Command_TOPIC,
	LIST = Command_LIST,
	WHOIS = Command_WHOIS,
	WHO = Command_WHO,
	USERHOST = Command_USERHOST,
--missing:	NAMES = Command_NAMES,
}
irc.CommandDispatch = CommandDispatch

function irc:ProcessClient(clientInfo)
	local line, error = clientInfo.Client:receive()
	if error == 'closed' then
		Command_QUIT(self, clientInfo, error .. " from client")
	end

	if not line or line == "" then
		return
	end

	local _, _, line = line:find("%s*(.+)%s*")

	print(clientInfo.State .. ": " .. (clientInfo.Nick or "") .. " -> '" .. line .. "'")

	if clientInfo.State == "UNREGISTERED" then
		local _, _, nick = line:find("NICK (.+)")
		if nick then
			if NickToClientInfo[nick] then
				self:SendRawMessage(clientInfo, "433 * " .. nick .. " :Nickname is already in use")
				return
			end
			clientInfo.Nick = nick
		end

		local _, _, user, mode, virtualHost, realName = line:find("USER (.*) (.*) (.*) :(.+)$")

		if user then
			clientInfo.User = user
			clientInfo.Host = virtualHost
			clientInfo.RealName = realName
		end

		if clientInfo.Nick and clientInfo.User then
			clientInfo.State = "REGISTERED"
			self:SendServerClientMessage(clientInfo, 001, "Welcome to the LuaIRC server " .. clientInfo.Nick .. "!" .. clientInfo.User .. "@" .. clientInfo.Host)
			self:SendServerClientMessage(clientInfo, 002, "Your host is " .. config.hostname .. ", running version " .. config.version)
			self:SendServerClientMessage(clientInfo, 003, "This server was created ...")
			self:SendServerClientMessage(clientInfo, 004, config.hostname .. " " .. config.version .. " aAbBcCdDeEfFGhHiIjkKlLmMnNopPQrRsStUvVwWxXyYzZ0123459*@ bcdefFhiIklmnoPqstv")
			NickToClientInfo[clientInfo.Nick] = clientInfo
		end

	elseif clientInfo.State == "REGISTERED" then
		local _, _, command, args = line:find("^%s*([^ ]+) *(.*)%s*$")
		command = command:upper()
		local func = CommandDispatch[command]
		if type(func) == "function" then
			func(self, clientInfo, args)
		else
			self:SendServerClientMessage(clientInfo, 421, line .. " :Unknown command")
		end
	end
end

function irc:RunServer()
	log("Opening server ("..config.hostname..":"..config.port..") ...")
	local serverfd = assert(socket.bind(config.ip, config.port))
	serverfd:settimeout(1) -- make sure we don't block in accept
	local set = self.set
	set:insert(serverfd)

	while true do
		--for i,v in ipairs(set) do print("set[", i, "]=", v) end
		local readable, _, error = socket.select(set, nil)
		for _, input in ipairs(readable) do
			-- is it a server socket?
			if input == serverfd then
				log("Waiting for clients")
				local new = input:accept()
				if new then
					new:settimeout(1)
					log("Inserting client in set")
					self:SendRawMessage({ Client = new }, "NOTICE AUTH :" .. config.version .. " initialized.")
					set:insert(new)
				end
			else
				self:ProcessClient(ClientMap[input])
			end
		end
	end
end

--[[
ChannelPrivateMessage['#lua'] = function(clientInfo, target, message)
	local chunk = loadstring(message)
	if chunk then
		local ircPrint = function(...)
			self:SendUserMessage(curClientInfo, curTarget, 'PRIVMSG ' .. curTarget .. " :" .. arg[1])
		end
		savePrint = print
		print = ircPrint
		pcall(chunk)
		print = savePrint
	end
end
]]--

irc:RunServer()
