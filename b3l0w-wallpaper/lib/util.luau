--!strict
-- Helpers puros: sin estado compartido, sin acceso a disco ni al host.

local M = {}

type AnyMap = { [any]: any }

function M.trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

function M.clamp(n: number, lo: number, hi: number): number
	if n < lo then
		return lo
	end
	if n > hi then
		return hi
	end
	return n
end

return M
