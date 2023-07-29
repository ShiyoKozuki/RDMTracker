addon.name      = 'RDMTracker';
addon.author    = 'Shiyo';
addon.version   = '2.0.2';
addon.desc      = 'Tracks buffs on party members';
addon.link      = 'https://ashitaxi.com/';


--Includes
require('common');
local fonts = require('fonts');
local settings = require('settings');
local windowWidth = AshitaCore:GetConfigurationManager():GetFloat('boot', 'ffxi.registry', '0001', 1024);
local windowHeight = AshitaCore:GetConfigurationManager():GetFloat('boot', 'ffxi.registry', '0002', 768);
local partyBuffPointer = AshitaCore:GetPointerManager():Get('party.statusicons');
partyBuffPointer = ashita.memory.read_uint32(partyBuffPointer);

--Configuration
-- TODO: # of merits for Phalanx duration
local default_settings = T{
	font = T{
        visible = true,
        font_family = 'Arial',
        font_height = 15,
        color = 0xFFFFFFFF,
        position_y = 787,
        position_x = 1518,
		background = T{
			visible = true,
			color = 0x80000000,
		}
    }
};
local deleteDelay = 5; --How long after buff expires to delete timer
local monitoredSpells = T{
    { SpellId = 57, BuffId = 33, BuffName='Haste', Duration = 180 },
    { SpellId = 493, BuffId = 432, BuffName='Temper', Duration = 180 },
    { SpellId = 107, BuffId = 116, BuffName='Phalanx', Duration = 120 },
    { SpellId = 109, BuffId = 43, BuffName='Refresh', Duration = 150 },
};

--State
local activeTimers = T{};
local idMap = T{};
local tracker = T{
	settings = settings.load(default_settings)
};


local function ParseActionPacket(e)
    local bitData;
    local bitOffset;
    local function UnpackBits(length)
        local value = ashita.bits.unpack_be(bitData, 0, bitOffset, length);
        bitOffset = bitOffset + length;
        return value;
    end

    local actionPacket = T{};
    bitData = e.data_raw;
    bitOffset = 40;
    actionPacket.UserId = UnpackBits(32);
    local targetCount = UnpackBits(6);
    bitOffset = bitOffset + 4;
    actionPacket.Type = UnpackBits(4);
    actionPacket.Id = UnpackBits(32);
    actionPacket.Recast = UnpackBits(32);

    --Save a little bit of processing for packets that won't relate to SC..
    if (T{3, 4, 6}:contains(actionPacket.Type) == false) then
        return;
    end

    actionPacket.Targets = T{};
    for i = 1,targetCount do
        local target = T{};
        target.Id = UnpackBits(32);
        local actionCount = UnpackBits(4);
        target.Actions = T{};
        for j = 1,actionCount do
            local action = {};
            action.Reaction = UnpackBits(5);
            action.Animation = UnpackBits(12);
            action.SpecialEffect = UnpackBits(7);
            action.Knockback = UnpackBits(3);
            action.Param = UnpackBits(17);
            action.Message = UnpackBits(10);
            action.Flags = UnpackBits(31);

            local hasAdditionalEffect = (UnpackBits(1) == 1);
            if hasAdditionalEffect then
                local additionalEffect = {};
                additionalEffect.Damage = UnpackBits(10);
                additionalEffect.Param = UnpackBits(17);
                additionalEffect.Message = UnpackBits(10);
                action.AdditionalEffect = additionalEffect;
            end

            local hasSpikesEffect = (UnpackBits(1) == 1);
            if hasSpikesEffect then
                local spikesEffect = {};
                spikesEffect.Damage = UnpackBits(10);
                spikesEffect.Param = UnpackBits(14);
                spikesEffect.Message = UnpackBits(10);
                action.SpikesEffect = spikesEffect;
            end

            target.Actions:append(action);
        end
        actionPacket.Targets:append(target);
    end
    return actionPacket;
end
local function GetPartyMemberBuffs(index)
    local buffs = T{};
    if (index == 0) then
        local icons = AshitaCore:GetMemoryManager():GetPlayer():GetStatusIcons();
        for i = 1,32 do
            if icons[i] ~= 255 then
                buffs:append(icons[i]);
            else
                break;
            end
        end
        return buffs;
    end

    local partyMgr = AshitaCore:GetMemoryManager():GetParty();
    local playerId = partyMgr:GetMemberServerId(index)
    for i = 0,4 do
        if partyMgr:GetStatusIconsServerId(i) == playerId then
            local memberPtr = partyBuffPointer + (0x30 * i);
            for j = 0,31 do
                local highBits = ashita.memory.read_uint8(memberPtr + 8 + (math.floor(j / 4)));
                local fMod = math.fmod(j, 4) * 2;
                highBits = bit.lshift(bit.band(bit.rshift(highBits, fMod), 0x03), 8);
                local lowBits = ashita.memory.read_uint8(memberPtr + 16 + j);
                local buff = highBits + lowBits;
                if (buff == 255) then
                    break;
                else
                    buffs:append(buff);
                end
            end
        end
    end
    return buffs;
end
local function GetNameFromId(id)
    local name = idMap[id];
    if name then
        return name;
    end
    
    local entMgr = AshitaCore:GetMemoryManager():GetEntity();
    
    --Check entity array..
    for i = 0x400,0x700 do
        if entMgr:GetServerId(i) == id then
            local name = entMgr:GetName(i);
            idMap[id] = name;
            return name;
        end
    end
end
local function RecastToString(timer)
    if (timer < 1) then
        return '0:00';
    end

    if (timer >= 3600) then
        local h = math.floor(timer / (3600));
        local m = math.floor(timer / 60);
        return string.format('%i:%02i', h, m);
    elseif (timer >= 60) then
        local m = math.floor(timer / 60);
        local s = math.fmod(timer, 60);
        return string.format('%i:%02i', m, s);
    else
        return string.format('0:%02i', timer);
    end
end
local function UpdateSettings(settings)
    tracker.settings = settings;
    if (tracker.font ~= nil) then
        tracker.font:apply(tracker.settings.font)
    end
end

local function CheckStateOnLoad()
    for i = 0, 5 do
        local targetIndex = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(i);
        if (targetIndex ~= 0) then
            local playerName = AshitaCore:GetMemoryManager():GetParty():GetMemberName(i);
            local buffs = GetPartyMemberBuffs(i);

            for _,spell in ipairs(monitoredSpells) do
                if buffs:contains(spell.BuffId) then
                    activeTimers:append({ Name = playerName, Buff=spell.BuffName, Timer = os.clock() + spell.Duration });
                end
            end
        end
    end
end
local function UpdateTimers()
    local time = os.clock();
    local newTable = T{};

    for _,timer in ipairs(activeTimers) do
        if (timer.Timer + deleteDelay) > time then
            newTable[#newTable + 1] = timer;
        end
    end

    activeTimers = newTable;

    table.sort(activeTimers, function(a,b)
        return a.Timer < b.Timer;
    end);
end
local function GetFontString()
    UpdateTimers();
    local output = ''
    local first = true
    local activeColor = '|cFF00FF00|'
    
    for _,timer in ipairs(activeTimers) do
        if not first then
            output = output .. '\n';
        end
        first = false;

        local time = RecastToString(timer.Timer - os.clock());
        output = output .. string.format('%s%s(%s) %s', activeColor, timer.Buff, timer.Name, time);
    end

    return output;
end

local function GetMeritCount(meritId)
    local pInventory = AshitaCore:GetPointerManager():Get('inventory');
    if (pInventory > 0) then
        local ptr = ashita.memory.read_uint32(pInventory);
        if (ptr ~= 0) then                    
            ptr = ashita.memory.read_uint32(ptr);
            if (ptr ~= 0) then
                ptr = ptr + 0x2CFF4;
                local count = ashita.memory.read_uint16(ptr + 2);
                local meritptr = ashita.memory.read_uint32(ptr + 4);
                if (count > 0) then
                    for i = 1,count do
                        local meritId = ashita.memory.read_uint16(meritptr + 0);
                        if (meritId == matchId) then
                            return ashita.memory.read_uint8(meritptr + 3);
                        end
                        meritptr = meritptr + 4;
                    end
                end
            end
        end
    end
    return 0;
end
monitoredSpells[2].Duration = GetMeritCount(2310) * 30;

ashita.events.register('load', 'load_cb', function ()
    tracker.font = fonts.new(tracker.settings.font);
    settings.register('settings', 'settingchange', UpdateSettings);
    CheckStateOnLoad();
end);

ashita.events.register('packet_in', 'HandleIncomingPacket', function (e)
    --Check if it's an action packet..
    if (e.id == 0x28) then
        local actionPacket = ParseActionPacket(e);
        -- Check if packet parsed properly and was an action initiated by ourselves..
        if (actionPacket ~= nil) and (actionPacket.UserId == AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0)) then            
            -- Check if packet is a spell finish packet..
            if (actionPacket.Type == 4) then
                --Check if packet is one of our monitored spells..
                for _,spell in ipairs(monitoredSpells) do
                    if actionPacket.Id == spell.SpellId then
                        --Check if phalanx, update duration from merits..
                        if (spell.SpellId == 107) then
                            spell.Duration = GetMeritCount(2310) * 30;
                        end

                        --Get the name of the target, and check if it's valid..
                        local targetName = GetNameFromId(actionPacket.Targets[1].Id);
                        if (targetName ~= nil) and (targetName ~= AshitaCore:GetMemoryManager():GetParty():GetMemberName(0)) then

                            --Check if a timer already exists for this buff on this person..
                            local foundActive = false;
                            for _,timer in ipairs(activeTimers) do
                                if (timer.Name == targetName) and (timer.Buff == spell.BuffName) then
                                    --It does, so update the timer.
                                    timer.Timer = os.clock() + spell.Duration;
                                    foundActive = true;
                                end
                            end

                            --It doesn't, so create it.
                            if not foundActive then
                                activeTimers:append({ Buff=spell.BuffName, Name=targetName, Timer = os.clock() + spell.Duration });
                            end
                        end
                    end
                end
            end
        end
    end
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    local mJob = AshitaCore:GetMemoryManager():GetPlayer():GetMainJob();

    local fontObject = tracker.font;
    if (fontObject.position_x > windowWidth) then
      fontObject.position_x = 0;
    end
    if (fontObject.position_y > windowHeight) then
      fontObject.position_y = 0;
    end
    if (fontObject.position_x ~= tracker.settings.font.position_x) or (fontObject.position_y ~= tracker.settings.font.position_y) then
        tracker.settings.font.position_x = fontObject.position_x;
        tracker.settings.font.position_y = fontObject.position_y;
        settings.save()
    end

    if (mJob == 5) then
        tracker.font.text = GetFontString();
        tracker.font.visible = true;
    else
       tracker.font.visible = false;
    end
end);

ashita.events.register('unload', 'unload_cb', function ()
    if (tracker.font ~= nil) then
        tracker.font:destroy();
    end
    settings.save();
end);