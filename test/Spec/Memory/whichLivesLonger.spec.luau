--!strict
--!nolint LocalUnused
local task = nil -- Disable usage of Roblox's task scheduler

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = ReplicatedStorage.Fusion

local External = require(Fusion.External)
local RobloxExternal = require(Fusion.RobloxExternal)
local checkLifetime = require(Fusion.Memory.checkLifetime)
local scoped = require(Fusion.Memory.scoped)
local whichLivesLonger = require(Fusion.Memory.whichLivesLonger)

-- `Fusion.setEnvironment` is `External.setEnvironment`. Requiring Fusion here
-- would swap the spec scheduler for the Roblox one.
local setEnvironment = External.setEnvironment

-- In one scope, the later of two objects is destroyed first.
local function twoInOneScope()
	local scope = scoped({})
	local a, b = {}, {}
	table.insert(scope, a)
	table.insert(scope, b)
	return scope, a, b
end

return function()
	local it = getfenv().it

	it("should scan scopes in development", function()
		local expect = getfenv().expect

		expect(setEnvironment("development")).to.equal("development")
		local scope, a, b = twoInOneScope()
		expect(whichLivesLonger(scope, a, scope, b)).to.equal("definitely-a")
		setEnvironment(nil)
	end)

	it("should skip the scan when live", function()
		local expect = getfenv().expect

		expect(setEnvironment("live")).to.equal("live")
		local scope, a, b = twoInOneScope()
		expect(whichLivesLonger(scope, a, scope, b)).to.equal("unsure")
		setEnvironment(nil)
		expect(whichLivesLonger(scope, a, scope, b)).to.equal("definitely-a")
	end)

	it("should follow the provider's environment unless one is forced", function()
		local expect = getfenv().expect

		local specProvider = External.setExternalProvider(nil)
		External.setExternalProvider(setmetatable({
			policies = {allowWebLinks = false, environment = "live"}
		}, {__index = specProvider}) :: any)
		local ok, err = pcall(function()
			local scope, a, b = twoInOneScope()
			expect(whichLivesLonger(scope, a, scope, b)).to.equal("unsure")
			expect(setEnvironment("development")).to.equal("development")
			expect(whichLivesLonger(scope, a, scope, b)).to.equal("definitely-a")
			expect(setEnvironment(nil)).to.equal("live")
			expect(whichLivesLonger(scope, a, scope, b)).to.equal("unsure")
		end)
		External.setExternalProvider(specProvider)
		setEnvironment(nil)
		if not ok then
			error(err, 0)
		end
		expect(setEnvironment(nil)).to.equal("development")
	end)

	it("should still error on use after destroy when live", function()
		local expect = getfenv().expect

		setEnvironment("live")
		local scope = scoped({})
		expect(function()
			checkLifetime.bOutlivesA(scope, {}, nil, {}, checkLifetime.formatters.useFunction)
		end).to.throw("useAfterDestroy")
		setEnvironment(nil)
	end)

	it("should reject unknown environments", function()
		local expect = getfenv().expect

		expect(function()
			setEnvironment("auto" :: any)
		end).to.throw("invalidEnvironment")
		expect(setEnvironment(nil)).to.equal("development")
	end)

	it("should detect development in Studio or with a mock game", function()
		local expect = getfenv().expect

		expect(RobloxExternal.policies.environment).to.equal("development")
	end)
end
