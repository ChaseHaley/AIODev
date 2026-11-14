-- JSON has no executable fallback: decoding never invokes loadstring.
local json = {}
local escapes = {['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t'}
local function quote(s)
	return '"' .. s:gsub('[%z\1-\31\\"]', function(c) return escapes[c] or string.format('\\u%04x', c:byte()) end) .. '"'
end
function json.encode(value, opts)
	local seen, indent = {}, opts and opts.indent
	if type(indent) == 'number' then indent = string.rep(' ', math.max(0, math.min(indent, 16))) end
	if type(indent) ~= 'string' then indent = nil end
	local function encode(v, depth)
		local t = type(v)
		if t == 'nil' then return 'null' end
		if t == 'boolean' then return tostring(v) end
		if t == 'number' then
			if v ~= v or v == math.huge or v == -math.huge then error('non-finite number', 0) end
			-- The shorter form when it reads back as the same double.
			local text = string.format('%.14g', v)
			if tonumber(text) ~= v then text = string.format('%.17g', v) end
			return text
		end
		if t == 'string' then return quote(v) end
		if t ~= 'table' then error('cannot encode ' .. t, 0) end
		if seen[v] then error('cannot encode a cycle', 0) end
		if depth > 128 then error('JSON nesting exceeds 128', 0) end
		seen[v] = true
		local count, largest, array = 0, 0, true
		for k in pairs(v) do
			count = count + 1
			if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then array = false else largest = math.max(largest, k) end
		end
		array = array and count > 0 and largest == count
		local parts = {}
		if array then
			for i = 1, count do parts[i] = encode(v[i], depth + 1) end
		else
			local keys = {}
			for k in pairs(v) do
				if type(k) ~= 'string' then error('object keys must be strings', 0) end
				keys[#keys + 1] = k
			end
			table.sort(keys)
			for _, k in ipairs(keys) do parts[#parts + 1] = quote(k) .. (indent and ': ' or ':') .. encode(v[k], depth + 1) end
		end
		seen[v] = nil
		local open, close = array and '[' or '{', array and ']' or '}'
		if indent and #parts > 0 then
			return open .. '\n' .. string.rep(indent, depth + 1) .. table.concat(parts, ',\n' .. string.rep(indent, depth + 1)) .. '\n' .. string.rep(indent, depth) .. close
		end
		return open .. table.concat(parts, ',') .. close
	end
	local ok, result = pcall(encode, value, 0)
	if ok then return result end
	return nil, result
end
local function utf8(n)
	if n < 128 then return string.char(n) end
	if n < 2048 then return string.char(192 + math.floor(n / 64), 128 + n % 64) end
	if n < 65536 then return string.char(224 + math.floor(n / 4096), 128 + math.floor(n / 64) % 64, 128 + n % 64) end
	return string.char(240 + math.floor(n / 262144), 128 + math.floor(n / 4096) % 64, 128 + math.floor(n / 64) % 64, 128 + n % 64)
end
function json.decode(text)
	if type(text) ~= 'string' then return nil, 'JSON text must be a string' end
	local pos, length = 1, #text
	local function fail(message) error('JSON at byte ' .. pos .. ': ' .. message, 0) end
	local function space() local _, last = text:find('^[ \t\r\n]*', pos); pos = (last or pos - 1) + 1 end
	local function str()
		pos = pos + 1
		local parts, start = {}, pos
		while pos <= length do
			local c = text:sub(pos, pos)
			if c == '"' then parts[#parts + 1] = text:sub(start, pos - 1); pos = pos + 1; return table.concat(parts) end
			if c:byte() < 32 then fail('control character in string') end
			if c == '\\' then
				parts[#parts + 1] = text:sub(start, pos - 1)
				pos = pos + 1
				local e = text:sub(pos, pos)
				local simple = {['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t'}
				if e == 'u' then
					local h = text:sub(pos + 1, pos + 4)
					if #h ~= 4 or not h:match('^%x%x%x%x$') then fail('invalid Unicode escape') end
					local n = tonumber(h, 16); pos = pos + 4
					if n >= 0xd800 and n <= 0xdbff then
						local low = text:sub(pos + 1, pos + 6)
						if not low:match('^\\u%x%x%x%x$') then fail('missing low surrogate') end
						local m = tonumber(low:sub(3), 16)
						if m < 0xdc00 or m > 0xdfff then fail('invalid low surrogate') end
						n = 0x10000 + (n - 0xd800) * 1024 + m - 0xdc00; pos = pos + 6
					elseif n >= 0xdc00 and n <= 0xdfff then fail('unexpected low surrogate') end
					parts[#parts + 1] = utf8(n)
				elseif simple[e] then parts[#parts + 1] = simple[e]
				else fail('invalid escape') end
				pos = pos + 1; start = pos
			else pos = pos + 1 end
		end
		fail('unterminated string')
	end
	local parse
	parse = function(depth)
		if depth > 128 then fail('nesting exceeds 128') end
		space()
		local c = text:sub(pos, pos)
		if c == '"' then return str() end
		if c == '{' or c == '[' then
			local object, result, index = c == '{', {}, 1
			local close = object and '}' or ']'
			pos = pos + 1; space()
			if text:sub(pos, pos) == close then pos = pos + 1; return result end
			while true do
				local key = index
				if object then
					if text:sub(pos, pos) ~= '"' then fail('expected object key') end
					key = str(); space()
					if text:sub(pos, pos) ~= ':' then fail('expected colon') end
					pos = pos + 1
				end
				result[key] = parse(depth + 1); index = index + 1; space()
				local sep = text:sub(pos, pos); pos = pos + 1
				if sep == close then return result end
				if sep ~= ',' then fail('expected comma') end
				space()
			end
		end
		for token, value in pairs({['true']=true, ['false']=false}) do
			if text:sub(pos, pos + #token - 1) == token then pos = pos + #token; return value end
		end
		if text:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil end
		local number = text:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
		local bad = not number or number == '' or number:match('^-?0%d') or number:match('%.$')
			or number:match('%.[eE]') or number:match('[eE][+-]?$')
		if bad then fail('expected value') end
		local n = tonumber(number)
		if not n or n == math.huge or n == -math.huge then fail('invalid number') end
		pos = pos + #number; return n
	end
	local ok, result = pcall(parse, 0)
	if not ok then return nil, result end
	space()
	if pos <= length then return nil, 'JSON at byte ' .. pos .. ': trailing data' end
	return result
end
return json
