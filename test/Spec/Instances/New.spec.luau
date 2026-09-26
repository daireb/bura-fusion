--!strict
--!nolint LocalUnused
local task = nil -- Disable usage of Roblox's task scheduler

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = ReplicatedStorage.Fusion

local New = require(Fusion.Instances.New)
local doCleanup = require(Fusion.Memory.doCleanup)

return function()
	local it = getfenv().it

	it("should create a new instance", function()
		local expect = getfenv().expect

		local scope = {}
		local ins = New(scope, "Frame")({})
		expect(typeof(ins) == "Instance").to.be.ok()
		expect(ins:IsA("Frame")).to.be.ok()
	end)

	it("should throw for non-existent class types", function()
		local expect = getfenv().expect

		expect(function()
			local scope = {}
			New(scope, "This is not a valid class type")({})
			doCleanup(scope)
		end).to.throw("cannotCreateClass")
	end)

	it("should preserve engine defaults, including behavioral properties", function()
		local expect = getfenv().expect
		local cases = {
			Frame = { "BackgroundColor3", "BorderColor3", "BorderSizePixel" },
			TextButton = { "AutoButtonColor", "Text", "TextColor3", "TextSize", "Font" },
			TextBox = { "ClearTextOnFocus", "Text" },
			ScreenGui = { "ResetOnSpawn", "ZIndexBehavior" },
			Part = { "Anchored", "Size" },
		}
		for className, properties in cases do
			local scope = {}
			local engine = Instance.new(className)
			table.insert(scope, engine)
			local instance = New(scope, className)({})
			for _, property in properties do
				expect((instance :: any)[property]).to.equal((engine :: any)[property])
			end
			doCleanup(scope)
		end
	end)

	it("should apply explicit values over engine defaults", function()
		local expect = getfenv().expect
		local scope = {}
		local gui = New(scope, "ScreenGui")({ ResetOnSpawn = false })
		local frame = New(scope, "Frame")({ BorderSizePixel = 0 })
		expect((gui :: ScreenGui).ResetOnSpawn).to.equal(false)
		expect((frame :: Frame).BorderSizePixel).to.equal(0)
		doCleanup(scope)
	end)

	it("doesn't incorrectly cache scope between invocations", function()
		local expect = getfenv().expect

		local scope1 = {}
		local scope2 = {}
		New(scope1, "Frame")({})
		New(scope2, "Frame")({})
		expect(#scope1).to.equal(1)
		expect(#scope2).to.equal(1)

		doCleanup(scope1)
		doCleanup(scope2)
	end)
end
