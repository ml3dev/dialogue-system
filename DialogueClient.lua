-- Connected Discord-GitHub | Discord: ml3dev | Roblox: Miky_playsroblox
--!strict

--[[
	DialogueClient
	==============
	local-side controller for the npc shop interaction. one LocalScript
	handles the whole flow:

	  ProximityPrompt --\
	                     >--> startShop() ---> Dialogue state, camera tween, ui
	  RemoteEvent ----/                                   |
	                                                      v
	                                            response button clicked
	                                                      |
	                              +------------+----------+
	                              |            |          |
	                          (number)       "END"      "SHOP"
	                              |            |          |
	                              v            v          v
	                          showLine(n)  endShop()   Shop state, ui swap

	a small Idle / Dialogue / Shop state machine guards every transition,
	so we can't end up half-frozen with the ui hidden, etc. the script is
	self-sufficient: even with no server piece the ProximityPrompt path
	drives the whole conversation. if the server fires EnterShop first,
	the Idle guard turns the prompt-trigger into a no-op.
]]

-- ---------------------------------------------------------------------------
-- services (cached so no GetService call happens in a hot path)
-- ---------------------------------------------------------------------------
local Players                = game:GetService("Players")
local TweenService           = game:GetService("TweenService")
local ReplicatedStorage      = game:GetService("ReplicatedStorage")
local SoundService           = game:GetService("SoundService")
local StarterGui             = game:GetService("StarterGui")
local UserInputService       = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local Workspace              = game:GetService("Workspace")

-- ---------------------------------------------------------------------------
-- core references
-- ---------------------------------------------------------------------------
local localPlayer = assert(Players.LocalPlayer, "DialogueClient: no LocalPlayer")
local camera      = assert(Workspace.CurrentCamera, "DialogueClient: no CurrentCamera")

local ShopEvent = ReplicatedStorage:WaitForChild("DialogueOpen") :: RemoteEvent
local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

-- cache every nested ui element once. the typewriter loop runs per
-- character, so re-resolving paths each frame would be wasteful.
local DialogueUI   = playerGui:WaitForChild("DialogueUI") :: ScreenGui
local ShopUI       = playerGui:WaitForChild("ShopUI") :: ScreenGui
local frame        = DialogueUI:WaitForChild("DialogueFrame") :: Frame
local dialogueText = frame:WaitForChild("DialogueText") :: TextLabel
local respondBtn1  = frame:WaitForChild("RespondButton1") :: TextButton
local respondBtn2  = frame:WaitForChild("RespondButton2") :: TextButton
local exitButton   = ShopUI:WaitForChild("ExitButton") :: TextButton

-- list form lets showLine iterate buttons in order, easy to add a third.
local responseButtons = { respondBtn1, respondBtn2 }

-- start hidden but kept loaded, so the next open is instant.
DialogueUI.Enabled = false
ShopUI.Enabled     = false

-- ---------------------------------------------------------------------------
-- audio
-- ---------------------------------------------------------------------------
local GameSFX  = Workspace:WaitForChild("GameSFX")
local sfxClick = GameSFX:WaitForChild("UIClick") :: Sound

-- PlayLocalSound only plays for this client and skips 3D attenuation,
-- which is what we want for ui feedback.
local function playClick()
	if sfxClick then SoundService:PlayLocalSound(sfxClick) end
end

-- ---------------------------------------------------------------------------
-- character refs (filled in by bindCharacter, nil during respawn races)
-- ---------------------------------------------------------------------------
local humanoid: Humanoid? = nil
local hrp:      BasePart? = nil

-- ---------------------------------------------------------------------------
-- tunables
-- ---------------------------------------------------------------------------
local CAMERA = {
	Distance     = 3,    -- how far behind the player the camera sits (studs)
	HeightOffset = 3.5,  -- height above the hrp (studs)
	SideOffset   = 5,    -- side offset, gives the over-the-shoulder feel
	LookAtY      = 3.5,  -- vertical offset of the focus point on the npc
	TweenTime    = 1.5,  -- seconds for the entry tween
}

local TYPEWRITER_CPS = 45

-- short pause before sampling hrp position. lets the server teleport
-- us to the dock first if it's going to.
local PROMPT_GRACE_SECONDS = 0.2

-- ---------------------------------------------------------------------------
-- state machine
-- ---------------------------------------------------------------------------
local STATE = { Idle = "Idle", Dialogue = "Dialogue", Shop = "Shop" }
local current: string = STATE.Idle
local currentLine = 1

-- ---------------------------------------------------------------------------
-- camera controller
-- exists to cache the active tween so we can :Cancel it cleanly when
-- the player exits early or triggers a second LookAt before the first
-- finishes. without that, two tweens fight for the camera every frame.
-- ---------------------------------------------------------------------------
local CameraController = {}
CameraController.__index = CameraController

export type CameraController = typeof(setmetatable(
	{} :: {
		camera: Camera,
		activeTween: Tween?,
	},
	CameraController
))

function CameraController.new(cam: Camera): CameraController
	local self = setmetatable({
		camera      = cam,
		activeTween = nil :: Tween?,
	}, CameraController)
	return self
end

-- CFrame.new(pos, look) faces the look point automatically, no manual
-- pitch / yaw math needed.
function CameraController.LookAt(self: CameraController, camPos: Vector3, focus: Vector3, tweenTime: number)
	self.camera.CameraType = Enum.CameraType.Scriptable
	if self.activeTween then self.activeTween:Cancel() end
	local tween = TweenService:Create(
		self.camera,
		TweenInfo.new(tweenTime, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ CFrame = CFrame.new(camPos, focus) }
	)
	self.activeTween = tween
	tween:Play()
end

function CameraController.Restore(self: CameraController, humanoidSubject: Humanoid?)
	if self.activeTween then
		self.activeTween:Cancel()
		self.activeTween = nil
	end
	self.camera.CameraType    = Enum.CameraType.Custom
	self.camera.CameraSubject = humanoidSubject
end

local cameraCtrl = CameraController.new(camera)

-- ---------------------------------------------------------------------------
-- movement freeze + reset button
-- ---------------------------------------------------------------------------
-- closure that knows how to undo freezeMovement, set when freezing.
local restoreSpeed: (() -> ())? = nil

-- SetCore("ResetButtonCallback", ...) can throw "not yet registered"
-- in the first frames after a respawn. pcall swallows that quietly.
local function setResetButton(enabled: boolean)
	pcall(function()
		StarterGui:SetCore("ResetButtonCallback", enabled)
	end)
end

-- LocalTransparencyModifier only affects this client's view, no server
-- replication, so we don't need permission to dim other players.
local function setOthersTransparency(value: number)
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		if plr ~= localPlayer and char then
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = value
				end
			end
		end
	end
end

local function freezeMovement()
	local hum = humanoid
	if not hum then return end
	-- capture current values (not defaults) so any active buff system's
	-- speed change comes back on restore.
	local oldSpeed = hum.WalkSpeed
	local oldJump  = hum.JumpPower
	hum.WalkSpeed = 0
	hum.JumpPower = 0
	hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	-- closure captures `hum` (the local), not the module-level upvalue.
	-- that way a respawn can't make us restore the wrong body. the
	-- Parent check guards against the humanoid being destroyed by then.
	restoreSpeed = function()
		if hum.Parent then
			hum.WalkSpeed = oldSpeed
			hum.JumpPower = oldJump
			hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end
		restoreSpeed = nil
	end
end

-- NPCShopPosition is an invisible part the level designer places in
-- front of the npc, gives us a stable focus independent of the rig.
local function lookAtNPC()
	local dock = Workspace:FindFirstChild("NPCShopPosition") :: BasePart?
	local h = hrp
	if not dock or not h then return end
	-- offset is in hrp-local space: X = side, Y = up, Z = behind
	-- (roblox is -Z forward, so positive Z is behind the player).
	local offset = Vector3.new(CAMERA.SideOffset, CAMERA.HeightOffset, CAMERA.Distance)
	local camPos = h.CFrame:PointToWorldSpace(offset)
	local focus  = dock.Position + Vector3.new(0, CAMERA.LookAtY, 0)
	cameraCtrl:LookAt(camPos, focus, CAMERA.TweenTime)
end

-- ---------------------------------------------------------------------------
-- dialogue tree
-- each response's `next` is either a line index, "SHOP", or "END".
-- adding a branch is just adding an entry and pointing some `next` at it.
-- ---------------------------------------------------------------------------
type Response = { text: string, next: number | string }
type DialogueLine = { text: string, responses: { Response } }

local DIALOGUE: { DialogueLine } = {
	{
		text = "Oh, someone's come at last. Do you seek the relics I keep?",
		responses = {
			{ text = "Let me see what you've got",   next = 2 },
			{ text = "No, I'm just passing through", next = 3 },
		},
	},
	{
		text = "Very well. Give me a moment to prepare the shop...",
		responses = { { text = "Continue", next = "SHOP" } },
	},
	{
		text = "As you wish. Safe travels.",
		responses = { { text = "Alright", next = "END" } },
	},
}

-- ---------------------------------------------------------------------------
-- typewriter
-- token pattern lets a new typewriterPlay invalidate any in-flight one
-- without having to track / kill the coroutine directly.
-- ---------------------------------------------------------------------------
local typewriterToken = 0
local fullLineText    = ""

local function typewriterPlay(text: string)
	typewriterToken += 1
	local myToken = typewriterToken
	fullLineText = text
	dialogueText.Text = ""
	task.spawn(function()
		local interval = 1 / TYPEWRITER_CPS
		for i = 1, #text do
			if typewriterToken ~= myToken then return end -- invalidated
			dialogueText.Text = string.sub(text, 1, i)
			task.wait(interval)
		end
	end)
end

local function typewriterFinish()
	typewriterToken += 1
	if fullLineText ~= "" then
		dialogueText.Text = fullLineText
	end
end

local function isTyping(): boolean
	return dialogueText.Text ~= fullLineText
end

-- ---------------------------------------------------------------------------
-- ui rendering
-- ---------------------------------------------------------------------------
local function showLine(n: number)
	local line = DIALOGUE[n]
	if not line then return end
	typewriterPlay(line.text or "...")
	for i, btn in ipairs(responseButtons) do
		local r = line.responses[i]
		if r then
			btn.Text    = r.text
			btn.Visible = true
		else
			btn.Visible = false
		end
	end
end

local function hideAllUI()
	DialogueUI.Enabled = false
	ShopUI.Enabled     = false
end

-- ---------------------------------------------------------------------------
-- state transitions
-- every cleanup path (response, exit button, death, respawn) flows
-- through endShop, so the unwind logic only lives in one place.
-- ---------------------------------------------------------------------------
local function endShop()
	if current == STATE.Idle then return end
	current     = STATE.Idle
	currentLine = 1
	setResetButton(true)
	hideAllUI()
	if restoreSpeed then restoreSpeed() end
	cameraCtrl:Restore(humanoid)
	setOthersTransparency(0)
	-- pcall: the remote could have been removed by an admin tool /
	-- studio reload, don't let cleanup throw mid-unwind.
	pcall(function() ShopEvent:FireServer("ExitShop") end)
end

local function startShop()
	-- guarded so a second trigger doesn't re-freeze (which would lose
	-- the original walkspeed value).
	if current ~= STATE.Idle then return end
	if not humanoid or not hrp then return end
	current = STATE.Dialogue
	setResetButton(false)
	freezeMovement()
	lookAtNPC()
	setOthersTransparency(0.5)
	currentLine = 1
	DialogueUI.Enabled = true
	ShopUI.Enabled     = false
	showLine(currentLine)
end

local function handleResponse(index: number)
	local line = DIALOGUE[currentLine]
	if not line then
		endShop()
		return
	end
	local response = line.responses[index]
	if not response then return end
	local nxt = response.next
	if nxt == "END" then
		endShop()
	elseif nxt == "SHOP" then
		-- camera + freeze stay applied, only the visible ui swaps.
		current = STATE.Shop
		DialogueUI.Enabled = false
		ShopUI.Enabled     = true
	elseif type(nxt) == "number" then
		currentLine = nxt
		showLine(currentLine)
	end
end

-- ---------------------------------------------------------------------------
-- input wiring
-- ---------------------------------------------------------------------------
respondBtn1.MouseButton1Click:Connect(function() playClick(); handleResponse(1) end)
respondBtn2.MouseButton1Click:Connect(function() playClick(); handleResponse(2) end)
exitButton.MouseButton1Click:Connect(function() playClick(); endShop() end)

-- E / Space: skip the typewriter, then auto-pick if there's only one
-- response. don't auto-pick when there are two, the player needs to
-- read both options instead of being railroaded by mashing space.
UserInputService.InputBegan:Connect(function(input: InputObject, gpe: boolean)
	if gpe or current ~= STATE.Dialogue then return end
	if input.KeyCode ~= Enum.KeyCode.E and input.KeyCode ~= Enum.KeyCode.Space then
		return
	end
	if isTyping() then
		typewriterFinish()
		return
	end
	local line = DIALOGUE[currentLine]
	if line and #line.responses == 1 then
		playClick()
		handleResponse(1)
	end
end)

-- ---------------------------------------------------------------------------
-- character lifecycle
-- ---------------------------------------------------------------------------
local function bindCharacter(char: Model)
	local hum  = char:WaitForChild("Humanoid") :: Humanoid
	local root = char:WaitForChild("HumanoidRootPart") :: BasePart
	humanoid = hum
	hrp      = root
	hum.Died:Connect(function()
		if current ~= STATE.Idle then endShop() end
	end)
end

-- handle the case where the script loads after the first character.
local initialChar = localPlayer.Character
if initialChar then
	bindCharacter(initialChar)
end

-- on respawn, reset state BEFORE binding the new character so the new
-- humanoid doesn't inherit a frozen state and the camera gets handed
-- the new humanoid as its subject.
localPlayer.CharacterAdded:Connect(function(char: Model)
	if current ~= STATE.Idle then
		current     = STATE.Idle
		currentLine = 1
		setResetButton(true)
		hideAllUI()
		restoreSpeed = nil
		setOthersTransparency(0)
	end
	bindCharacter(char)
	cameraCtrl:Restore(humanoid)
end)

-- ---------------------------------------------------------------------------
-- triggers (server remote + proximity prompt)
-- both paths end at the same startShop / endShop, so the Idle guard
-- inside startShop makes them safe to coexist.
-- ---------------------------------------------------------------------------
ShopEvent.OnClientEvent:Connect(function(action: string)
	if action == "EnterShop" then
		startShop()
	elseif action == "ExitShop" then
		endShop()
	end
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, plr: Player)
	if plr ~= localPlayer then return end
	local part = prompt.Parent
	if not part then return end
	local owner = part.Parent
	if not owner or owner.Name ~= "ShopNPC" then return end
	if current ~= STATE.Idle then return end
	-- grace pause lets the server teleport us first if it's going to,
	-- so lookAtNPC samples the post-teleport hrp position.
	task.wait(PROMPT_GRACE_SECONDS)
	if current == STATE.Idle then startShop() end
end)

-- ---------------------------------------------------------------------------
-- npc idle animation, only while a player is at the shop
-- driven off the InShop attribute so server systems can plug in too.
-- ---------------------------------------------------------------------------
task.spawn(function()
	local npc = Workspace:WaitForChild("ShopNPC", 30)
	if not npc then return end
	local hum        = npc:FindFirstChildOfClass("Humanoid")
	local animator   = hum and hum:FindFirstChildOfClass("Animator")
	local animFolder = npc:FindFirstChild("Animations")
	local idle: Animation? = nil
	if animFolder then
		idle = animFolder:FindFirstChild("IdleAnimation") :: Animation?
	end
	if not animator or not idle then return end

	local track = animator:LoadAnimation(idle)
	track.Priority = Enum.AnimationPriority.Idle
	track.Looped   = true

	-- guard both sides: :Play on a playing track restarts it, :Stop
	-- on a stopped track is wasted work.
	local function sync()
		if not npc.Parent then return end
		if npc:GetAttribute("InShop") and not track.IsPlaying then
			track:Play(0.1)
		elseif (not npc:GetAttribute("InShop")) and track.IsPlaying then
			track:Stop()
		end
	end
	npc:GetAttributeChangedSignal("InShop"):Connect(sync)
	sync() -- run once in case InShop was set before we attached
end)
