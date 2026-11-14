-- The aio API and the coroutine scheduler. state.odin loads this once per state with the natives
-- table, the JSON module, the host configuration and the set of event names, and keeps the
-- returned table for its entry points.
local native, json, config, names = ...
local aio = {json = json}
_G.aio = aio
-- tasks: suspended or running entry points. processes: unfinished aio.system handles by id.
local tasks, handlers, timers, processes, errors = {}, {}, {}, {}, {}
local current, timer_count, stop_code = nil, 0, nil
-- A top level that suspended and has since finished, until runtime.top hands it over.
local top_outcome = nil
-- Deadlines use the host's step clock. Between steps it is estimated from the monotonic native
-- clock, so a timer set long after the last step still counts from when it was set.
local offset, anchored = 0, false
local origin = config.script and 'script' or 'config'
local streams = {'stdout', 'stderr'}
local MAX_TIMERS = 1024

local function clock() return native.clock() + offset end
local function context(pane, source) return {pane = pane or config.pane, origin = source or origin} end
local function pane() return current and current.ctx.pane or config.pane end
local function report(message) errors[#errors + 1] = tostring(message) end
local function pack(...) return {n = select('#', ...), ...} end

local getinfo = debug.getinfo
-- True while a Config host's top level loads: it may declare, and commands are refused.
local declaring = false

-- The first frame outside this file is the script's call, even through pcall or a tail call.
local function caller()
	for level = 2, 64 do
		local info = getinfo(level, 'Sl')
		if not info then break end
		if info.what ~= 'C' and info.currentline > 0 and info.source ~= '@aio/runtime.lua' then
			return info.source:sub(1, 1) == '@' and info.source:sub(2) or info.short_src, info.currentline
		end
	end
	return '?', 0
end

local function interest()
	local wanted = {}
	for name, list in pairs(handlers) do if #list > 0 then wanted[name] = true end end
	for task in pairs(tasks) do if task.wait and task.wait.event then wanted[task.wait.event] = true end end
	native.interest(wanted)
end

-- A finished entry point takes the non-detached processes it started with it.
local function cleanup(task)
	tasks[task] = nil
	if task.scoped then
		for _, p in pairs(processes) do
			if p.owner == task and not p.detach then native.process('kill', p.id) end
		end
	end
	if task.timer then task.timer.running = nil end
end

-- Returns ok, finished and the first result (or the error message).
local function resume(task, ...)
	local previous, before = current, task.wait
	current, task.wait = task, nil
	native.arm(task.co)
	local values = pack(coroutine.resume(task.co, ...))
	native.disarm()
	current = previous
	if previous then native.arm(previous.co) end
	local ok, finished, value = true, true, values[2]
	if not values[1] then
		ok = false
	elseif coroutine.status(task.co) ~= 'dead' then
		if type(value) == 'table' and value.aio_wait then
			task.wait, finished, value = value, false, nil
		else
			ok, value = false, 'unsupported coroutine yield; use aio.sleep, aio.wait or a process wait'
		end
	end
	if finished then cleanup(task) end
	if (before and before.event) or (task.wait and task.wait.event) then interest() end
	return ok, finished, value
end

-- refuse names why the task may not yield (a loading init.lua or a wait filter), or is nil.
local function start(fn, ctx, refuse, scoped, ...)
	local task = {co = coroutine.create(fn), ctx = ctx, refuse = refuse, scoped = scoped}
	tasks[task] = true
	return task, resume(task, ...)
end

local function callback(fn, ctx, ...)
	local task, ok, _, message = start(fn, ctx, nil, true, ...)
	if not ok then report(message) end
	return task
end

-- A suspended top level's outcome belongs to the host (runtime.top), not to the handler errors.
local function resume_async(task, ...)
	local ok, finished, value = resume(task, ...)
	if task.top then
		if finished then top_outcome = {ok = ok, value = value} end
	elseif not ok then
		report(value)
	end
end

-- True when the running code may suspend its entry point.
local function can_yield()
	return current ~= nil and current.refuse == nil and coroutine.running() == current.co
end

-- Callers return relay(yield_wait(...)) rather than tail-calling yield_wait: a tail call drops
-- the API function's frame, and yield_wait's errors would then miss the script's position.
local function relay(...) return ... end

local function yield_wait(kind, wait)
	if not current then return nil, 'aio.' .. kind .. ' requires a coroutine' end
	if current.refuse then error('aio.' .. kind .. ' cannot run ' .. current.refuse, 3) end
	if coroutine.running() ~= current.co then
		error('aio.' .. kind .. ' must run in the entry point, not in a nested coroutine', 3)
	end
	wait.aio_wait = true
	return coroutine.yield(wait)
end

-- Commands --------------------------------------------------------------------------------

function aio.run(name, fields)
	if type(name) ~= 'string' then return nil, 'command name must be a string' end
	-- The host would refuse it too; reporting it here names the line, as a bad declaration does.
	if declaring then
		local message = 'commands cannot run while init.lua loads'
		local file, line = caller()
		report(file .. ':' .. line .. ': aio.' .. name .. ': ' .. message)
		return nil, message, 1
	end
	if fields ~= nil and type(fields) ~= 'table' then return nil, 'command fields must be a table' end
	local encoded, message = json.encode(fields or {})
	if not encoded then return nil, message end
	local reply, decode_error = json.decode(native.command(pane(), name, encoded, origin))
	if type(reply) ~= 'table' then return nil, decode_error or 'invalid command reply' end
	if not reply.ok then return nil, reply.error or 'command failed', reply.status end
	reply.ok, reply.status, reply.error = nil, nil, nil
	return reply
end

local function field(name, fields, key)
	local reply, message, status = aio.run(name, fields)
	if not reply then return nil, message, status end
	return reply[key]
end

function aio.invoke(name, args) return field(name, args, 'result') end

-- app.view lists each tab's nodes flat, because its JSON cannot hold pointers: roots and split
-- children are 1-based positions in the tab's nodes, 0 for none. Lua gets the trees nested, a leaf
-- as {pane} and a split as {split, ratio, first, second}, and no nodes list.
local function nest_view(view)
	if type(view) ~= 'table' or type(view.workspaces) ~= 'table' then return view end
	for _, workspace in ipairs(view.workspaces) do
		for _, tab in ipairs(type(workspace.tabs) == 'table' and workspace.tabs or {}) do
			local nodes = type(tab.nodes) == 'table' and tab.nodes or {}
			-- depth bounds a malformed list whose positions loop back.
			local function node(index, depth)
				local raw = type(index) == 'number' and depth <= #nodes and nodes[index]
				if type(raw) ~= 'table' then return nil end
				if raw.split == nil then return {pane = raw.pane} end
				return {split = raw.split, ratio = raw.ratio or 0, first = node(raw.first, depth + 1),
					second = node(raw.second, depth + 1)}
			end
			tab.root = node(tab.root, 1)
			for _, float in ipairs(type(tab.floats) == 'table' and tab.floats or {}) do
				float.root = node(float.root, 1)
			end
			tab.nodes = nil
		end
	end
	return view
end

function aio.view()
	local view, message, status = field('app.view', nil, 'view')
	if view == nil then return nil, message, status end
	return nest_view(view)
end

function aio.notify(opts)
	if type(opts) ~= 'table' then return nil, 'notify expects a table' end
	return aio.run('app.notify', {title = opts.title, text = opts.body})
end

-- aio.<ns>.<name>(fields) runs "<ns>.<name>". Explicit helpers are plain fields, so they win.
local function namespace(prefix, explicit)
	return setmetatable(explicit or {}, {__index = function(t, name)
		if type(name) ~= 'string' then return nil end
		local fn = function(fields) return aio.run(prefix .. '.' .. name, fields) end
		rawset(t, name, fn)
		return fn
	end})
end

setmetatable(aio, {__index = function(t, name)
	if type(name) ~= 'string' then return nil end
	local ns = namespace(name)
	rawset(t, name, ns)
	return ns
end})

aio.clipboard = namespace('clipboard', {
	get = function() return field('edit.clipboard_read', nil, 'text') end,
	set = function(text) return aio.run('edit.clipboard_write', {text = text}) end,
})

aio.settings = namespace('settings', {
	get = function(key) return field('settings.get', {name = key}, 'text') end,
	set = function(key, value) return aio.run('settings.set', {name = key, text = tostring(value)}) end,
})

function aio.log(level, message)
	if message == nil then level, message = 'info', level end
	native.log(tostring(level), tostring(message))
end

-- Sandbox ---------------------------------------------------------------------------------

if not config.script then
	-- init.lua has no console; its output belongs in the app log.
	_G.print = function(...)
		local values = {}
		for i = 1, select('#', ...) do values[i] = tostring((select(i, ...))) end
		native.log('info', table.concat(values, '\t'))
	end
end
io.popen = function() error('use aio.system', 2) end
os.execute = function() error('use aio.system', 2) end
package.path = config.root .. '\\?.lua;' .. config.root .. '\\?\\init.lua'

-- Layout ----------------------------------------------------------------------------------

aio.layout = namespace('layout', {
	pane = function(opts)
		if type(opts) ~= 'table' then return nil, 'layout.pane expects a table' end
		return {name = opts.name, command = opts.command, cwd = opts.cwd, profile = opts.profile}
	end,
	split = function(direction, ratio, first, second)
		if direction ~= 'right' and direction ~= 'down' then return nil, 'split direction must be right or down' end
		if type(ratio) ~= 'number' or ratio <= 0 or ratio >= 1 then return nil, 'split ratio must be between 0 and 1' end
		if type(first) ~= 'table' or type(second) ~= 'table' then return nil, 'split needs two layout nodes' end
		return {split = direction, ratio = ratio, first = first, second = second}
	end,
	float = function(opts)
		if type(opts) ~= 'table' then return nil, 'layout.float expects a table' end
		return {bounds = opts.bounds, unit = opts.unit, pane = opts.pane}
	end,
	apply = function(opts)
		if type(opts) ~= 'table' then return nil, 'layout.apply expects a table' end
		if type(opts.root) ~= 'table' then return nil, 'layout.apply needs a root node' end
		local document = {tab = opts.tab, cwd = opts.cwd, root = opts.root, floats = opts.floats}
		return aio.run('layout.apply', {layout = document})
	end,
})

-- Events and timers -----------------------------------------------------------------------

local function known(name)
	if type(name) ~= 'string' or not names[name] then error('unknown event ' .. tostring(name), 3) end
end

function aio.on(name, fn)
	known(name)
	if type(fn) ~= 'function' then error('event handler must be a function', 2) end
	handlers[name] = handlers[name] or {}
	table.insert(handlers[name], fn)
	interest()
	return fn
end

function aio.wait(name, filter, timeout)
	known(name)
	if filter ~= nil and type(filter) ~= 'table' and type(filter) ~= 'function' then return nil, 'filter must be a table or function' end
	if timeout ~= nil and (type(timeout) ~= 'number' or timeout < 0) then return nil, 'timeout must be nonnegative' end
	return relay(yield_wait('wait', {event = name, filter = filter, deadline = timeout and clock() + timeout}))
end

function aio.sleep(seconds)
	if type(seconds) ~= 'number' or seconds < 0 or seconds ~= seconds then return nil, 'sleep duration must be nonnegative' end
	return relay(yield_wait('sleep', {deadline = clock() + seconds}))
end

local Timer = {}
Timer.__index = Timer
function Timer:cancel()
	if self.live then
		self.live = false
		timers[self] = nil
		timer_count = timer_count - 1
	end
end
function Timer:active() return self.live end

local function timer(seconds, fn, repeating)
	if type(seconds) ~= 'number' or seconds < 0 or seconds ~= seconds or (repeating and seconds == 0) then
		return nil, 'timer duration must be positive'
	end
	if type(fn) ~= 'function' then return nil, 'timer callback must be a function' end
	if timer_count >= MAX_TIMERS then
		if config.script then stop_code = 1 end
		error('at most ' .. MAX_TIMERS .. ' live timers are allowed', 3)
	end
	local t = setmetatable({deadline = clock() + seconds, interval = repeating and seconds or nil,
		fn = fn, ctx = context(pane(), 'timer'), live = true}, Timer)
	timers[t] = true
	timer_count = timer_count + 1
	return t
end

function aio.after(seconds, fn) return timer(seconds, fn, false) end
function aio.every(seconds, fn) return timer(seconds, fn, true) end

-- Script host -----------------------------------------------------------------------------

if config.script then
	aio.pane_id = config.pane
	aio.args = json.decode(config.args)
	if aio.args == nil then aio.args = {} end
	function aio.stop(code)
		if code ~= nil and (type(code) ~= 'number' or code % 1 ~= 0) then return nil, 'stop code must be an integer' end
		stop_code = code or 0
		-- The entry point never resumes; the host ends the script once stopped reports a code.
		if can_yield() then return relay(yield_wait('stop', {stopped = true})) end
	end
end

-- Prompts ---------------------------------------------------------------------------------

local function prompt_wait(id, on_done, transform)
	local function answer()
		local ev, message = aio.wait('prompt.closed', {prompt = id})
		if not ev then return nil, message end
		if ev.cancelled then return nil end
		return transform(ev)
	end
	if on_done then
		callback(function() on_done(answer()) end, context(pane(), current and current.ctx.origin))
		return id
	end
	return answer()
end

aio.ui = namespace('ui', {
	select = function(items, opts, on_choice)
		if type(items) ~= 'table' then return nil, 'items must be a table' end
		opts = opts or {}
		local labels = {}
		for i, item in ipairs(items) do
			local label = item
			if opts.format_item then
				local ok, formatted = pcall(opts.format_item, item)
				if not ok then return nil, formatted end
				label = formatted
			end
			labels[i] = tostring(label)
		end
		local encoded, message = json.encode(labels)
		if not encoded then return nil, message end
		-- An empty Lua table encodes as an object, but the prompt needs an array.
		if #labels == 0 then encoded = '[]' end
		local reply, err, status = aio.run('app.select', {title = opts.prompt, items = encoded})
		if not reply then return nil, err, status end
		return prompt_wait(reply.prompt, on_choice, function(ev) return items[ev.index], ev.index end)
	end,
	input = function(opts, on_confirm)
		opts = opts or {}
		local reply, err, status = aio.run('app.input', {title = opts.prompt, text = opts.default})
		if not reply then return nil, err, status end
		return prompt_wait(reply.prompt, on_confirm, function(ev) return ev.text end)
	end,
})

-- Processes -------------------------------------------------------------------------------

local function finish_process(p, output)
	p.result = {code = output.code, stdout = table.concat(p.out), stderr = table.concat(p.err),
		ok = output.code == 0 and not p.timed_out, timed_out = p.timed_out or false}
	processes[p.id] = nil
	native.process('destroy', p.id)
	if p.on_exit then callback(p.on_exit, p.ctx, p.result) end
end

local function poll_process(p)
	if p.result then return end
	if p.kill_at and native.clock() >= p.kill_at then
		p.timed_out, p.kill_at = true, nil
		native.process('kill', p.id)
	end
	local output = native.process('poll', p.id)
	for _, name in ipairs(streams) do
		local chunk = output[name]
		if #chunk > 0 then
			local list = name == 'stdout' and p.out or p.err
			list[#list + 1] = chunk
			if type(p.opts[name]) == 'function' then callback(p.opts[name], p.ctx, nil, chunk) end
		end
	end
	if output.exited then finish_process(p, output) end
end

local Process = {}
Process.__index = Process

function Process:wait(timeout)
	if self.result then return self.result end
	if timeout ~= nil and (type(timeout) ~= 'number' or timeout < 0) then return nil, 'timeout must be nonnegative' end
	if can_yield() then
		return relay(yield_wait('system wait', {process = self, deadline = timeout and clock() + timeout}))
	end
	if not config.script then
		if current and current.refuse then error('a process wait cannot run ' .. current.refuse, 2) end
		return nil, 'a process wait requires a coroutine'
	end
	-- A Script host has no frame to keep responsive, so it may block here.
	local began = native.clock()
	while true do
		poll_process(self)
		if self.result then return self.result end
		if timeout and native.clock() - began >= timeout then return nil, 'timeout' end
		native.pause()
	end
end

function Process:write(data)
	if self.result then return nil, 'process is closed' end
	if type(data) ~= 'string' then return nil, 'process input must be a string' end
	return native.process('write', self.id, data)
end

function Process:close_stdin()
	if self.result then return true end
	return native.process('close_stdin', self.id)
end

function Process:kill()
	if self.result then return true end
	return native.process('kill', self.id)
end

function Process:is_closing()
	return self.result ~= nil or native.process('closing', self.id) == true
end

function aio.system(argv, opts, on_exit)
	if type(opts) == 'function' and on_exit == nil then opts, on_exit = nil, opts end
	opts = opts or {}
	if type(opts) ~= 'table' then return nil, 'system options must be a table' end
	if on_exit ~= nil and type(on_exit) ~= 'function' then return nil, 'on_exit must be a function' end
	if type(argv) ~= 'table' or #argv == 0 then return nil, 'argv must be a nonempty array' end
	for _, arg in ipairs(argv) do
		if type(arg) ~= 'string' then return nil, 'argv entries must be strings' end
	end
	if opts.timeout ~= nil and (type(opts.timeout) ~= 'number' or opts.timeout < 0) then
		return nil, 'timeout must be nonnegative'
	end
	local id, pid = native.start(argv, opts)
	if not id then return nil, pid end
	local p = setmetatable({id = id, pid = pid, opts = opts, out = {}, err = {}, owner = current,
		detach = opts.detach, ctx = context(pane(), current and current.ctx.origin), on_exit = on_exit,
		kill_at = opts.timeout and native.clock() + opts.timeout}, Process)
	processes[id] = p
	return p
end

-- Declarations ----------------------------------------------------------------------------

-- init.lua's top level, and the files it requires, declare actions, key operations and modes.
-- state.odin reads them through runtime.declarations once the load returns. A bad call is
-- skipped and reported rather than raised, so one typo does not cost the rest of the file.
local declared = {serial = 0, actions = {}, keys = {}, modes = {}}
-- One function keeps one registry reference, so the host can match an unbind to its bind.
local function_refs = {}
local ARG_TYPES = {string = true, number = true, integer = true, boolean = true, object = true, array = true,
	any = true}

local function declaration(fn)
	if config.script or not declaring then error('aio.' .. fn .. ' works only while init.lua loads', 3) end
	local file, line = caller()
	return {file = file, line = line}
end

local function skip(fn, at, message)
	message = 'aio.' .. fn .. ': ' .. message
	report(at.file .. ':' .. at.line .. ': ' .. message)
	return nil, message
end

local function ref(fn)
	local id = function_refs[fn]
	if not id then
		id = native.ref(fn)
		function_refs[fn] = id
	end
	return id
end

local function record(list, entry)
	list[#list + 1] = entry
	declared.serial = declared.serial + 1
	return true
end

-- Fields travel as a JSON object, so an array or a value JSON cannot hold is refused here.
local function fields_text(args)
	if type(args) ~= 'table' then return nil, 'args must be a table' end
	local text, message = json.encode(args)
	if not text then return nil, 'args: ' .. message end
	if text:sub(1, 1) ~= '{' then return nil, 'args must be a table of named values' end
	return text
end

-- A table with a type key is a JSON Schema kept verbatim. Anything else maps names to type words,
-- or to a per-argument schema (a table with a type key), which is kept verbatim too.
local function action_args(args)
	if args == nil then return '' end
	if type(args) ~= 'table' then return nil, 'args must be a table' end
	if args.type == nil then
		for name, word in pairs(args) do
			if type(name) ~= 'string' then return nil, 'args names must be strings' end
			local schema = type(word) == 'table' and word.type ~= nil
			if not schema and (type(word) ~= 'string' or not ARG_TYPES[(word:gsub('%?$', ''))]) then
				return nil, 'args.' .. name .. ' must be string, number, integer, boolean, object, array or any, '
					.. 'with a trailing ? when optional, or a schema table with a type key'
			end
		end
	end
	return fields_text(args)
end

local function keywords_text(value)
	if value == nil then return '' end
	if type(value) == 'string' then return value end
	if type(value) ~= 'table' then return nil end
	local words = {}
	for i, word in ipairs(value) do
		if type(word) ~= 'string' then return nil end
		words[i] = word
	end
	return table.concat(words, ' ')
end

function aio.action(spec)
	local at = declaration('action')
	if type(spec) ~= 'table' then return skip('action', at, 'expects a table') end
	local name = spec.name
	if type(name) ~= 'string' or not name:find('^[a-z0-9_]+$') then
		return skip('action', at, 'name ' .. tostring(name) .. ' must use lowercase letters, digits and _')
	end
	if type(spec.title) ~= 'string' or spec.title == '' then
		return skip('action', at, name .. ': title must be a nonempty string')
	end
	if type(spec.run) ~= 'function' then return skip('action', at, name .. ': run must be a function') end
	if spec.description ~= nil and type(spec.description) ~= 'string' then
		return skip('action', at, name .. ': description must be a string')
	end
	if spec.category ~= nil and type(spec.category) ~= 'string' then
		return skip('action', at, name .. ': category must be a string')
	end
	if spec.repeats ~= nil and type(spec.repeats) ~= 'boolean' then
		return skip('action', at, name .. ': repeats must be a boolean')
	end
	local keywords = keywords_text(spec.keywords)
	if not keywords then
		return skip('action', at, name .. ': keywords must be a string or a list of strings')
	end
	local args, message = action_args(spec.args)
	if not args then return skip('action', at, name .. ': ' .. message) end
	local actions = declared.actions
	for i, earlier in ipairs(actions) do
		if earlier.name == name then
			report(at.file .. ':' .. at.line .. ': aio.action: ' .. name .. ' was already declared at ' .. earlier.file
				.. ':' .. earlier.line .. '; this later declaration replaces it')
			table.remove(actions, i)
			break
		end
	end
	return record(actions, {
		name = name, title = spec.title, description = spec.description or '', category = spec.category or '',
		keywords = keywords, args = args, repeats = spec.repeats == true, ref = ref(spec.run),
		file = at.file, line = at.line,
	})
end

-- Returns the key entry, or nil and the message. args are allowed only with a name target.
local function key_entry(fn, at, op, key, target, args)
	if type(key) ~= 'string' or key == '' then return skip(fn, at, 'key must be a nonempty string') end
	local entry = {op = op, key = key, command = '', fields = '', ref = 0, file = at.file, line = at.line}
	if type(target) == 'function' then
		if args ~= nil then return skip(fn, at, key .. ': args need a command or action name, not a function') end
		entry.fn, entry.ref = target, ref(target)
	elseif type(target) == 'string' and target ~= '' then
		entry.command = target
		if args ~= nil then
			local text, message = fields_text(args)
			if not text then return skip(fn, at, key .. ': ' .. message) end
			entry.fields = text
		end
	elseif target ~= nil or op == 'bind' then
		return skip(fn, at, key .. ': target must be a command or action name, or a function')
	end
	return entry
end

function aio.bind(key, target, args)
	local at = declaration('bind')
	local entry, message = key_entry('bind', at, 'bind', key, target, args)
	if not entry then return nil, message end
	return record(declared.keys, entry)
end

function aio.unbind(key, target)
	local at = declaration('unbind')
	local entry, message = key_entry('unbind', at, 'unbind', key, target, nil)
	if not entry then return nil, message end
	return record(declared.keys, entry)
end

function aio.mode(name, opts)
	local at = declaration('mode')
	if type(name) ~= 'string' or not name:find('^[a-z0-9_%-]+$') then
		return skip('mode', at, 'name ' .. tostring(name) .. ' must use lowercase letters, digits, _ and -')
	end
	if opts ~= nil and type(opts) ~= 'table' then
		return skip('mode', at, name .. ': options must be a table')
	end
	local exclusive = opts and opts.exclusive
	if exclusive ~= nil and type(exclusive) ~= 'boolean' then
		return skip('mode', at, name .. ': exclusive must be a boolean')
	end
	return record(declared.modes, {name = name, exclusive = exclusive == true, file = at.file, line = at.line})
end

-- Splits `mode/key` the way commands.parse_sequence does: only a valid mode name before the first
-- slash names a mode, since a slash is also a key.
local function split_mode(text)
	local trimmed = text:match('^%s*(.-)%s*$')
	local mode, key = trimmed:match('^([a-z0-9_%-]+)/(.*)$')
	if mode then return mode, key end
	return nil, trimmed
end

function aio.bindings(filter)
	local at = declaration('bindings')
	if filter ~= nil and type(filter) ~= 'table' then return skip('bindings', at, 'filter must be a table') end
	filter = filter or {}
	local result = {}
	for _, entry in ipairs(declared.keys) do
		local mode, key = split_mode(entry.key)
		local action = entry.command ~= '' and entry.command or nil
		if (filter.key == nil or filter.key == key) and (filter.mode == nil or filter.mode == mode)
			and (filter.action == nil or filter.action == action) then
			result[#result + 1] = {
				op = entry.op, key = key, mode = mode, action = action, fn = entry.fn,
				args = entry.fields ~= '' and json.decode(entry.fields) or nil, source = entry.file .. ':' .. entry.line,
			}
		end
	end
	return result
end

-- Host entry points -----------------------------------------------------------------------

local runtime = {}

local function finish(ok, finished, value)
	if not ok then return false, true, false, '', tostring(value) end
	local encoded = ''
	if finished and value ~= nil then
		local message
		encoded, message = json.encode(value)
		if not encoded then return false, true, false, '', message end
	end
	return true, finished, finished and value == false, encoded, ''
end

-- A chunk's top level: Config refuses to yield there, and processes it starts outlive it. Only a
-- loading Config top level may declare; the load cannot yield, so it is over when start returns.
-- A top level that suspends reports its later outcome through runtime.top.
function runtime.run(fn, ctx, args, loading, scoped)
	local refuse = loading and 'while init.lua loads' or nil
	declaring = loading and not config.script
	local task, ok, finished, value = start(fn, ctx or context(), refuse, scoped ~= false, ctx, args)
	declaring = false
	task.top = true
	return finish(ok, finished, value)
end

-- done, then finish's results, once a suspended top level has finished; nothing before that.
function runtime.top()
	local outcome = top_outcome
	if not outcome then return false end
	top_outcome = nil
	return true, finish(outcome.ok, true, outcome.value)
end

-- serial changes whenever a declaration is recorded, so the host knows when to read again.
function runtime.declarations() return declared.serial, declared.actions, declared.keys, declared.modes end

function runtime.call(fn, ctx, args)
	local decoded_ctx, ctx_error = json.decode(ctx)
	if type(decoded_ctx) ~= 'table' then return false, true, false, '', ctx_error or 'context must be an object' end
	decoded_ctx.pane = decoded_ctx.pane or config.pane
	decoded_ctx.origin = decoded_ctx.origin or origin
	local decoded_args, args_error
	if args ~= '' then decoded_args, args_error = json.decode(args) end
	if args_error then return false, true, false, '', args_error end
	local _, ok, finished, value = start(fn, decoded_ctx, nil, true, decoded_ctx, decoded_args)
	return finish(ok, finished, value)
end

local function matches(filter, ev, ctx)
	if type(filter) == 'table' then
		for k, v in pairs(filter) do if ev[k] ~= v then return false end end
		return true
	elseif type(filter) == 'function' then
		-- Filters are entry points too, so a hostile filter gets the same budget as a handler.
		local _, ok, finished, value = start(filter, ctx, 'in a wait filter', false, ev)
		if not ok then report(value) end
		return ok and finished and value == true
	end
	return true
end

function runtime.deliver(name, fields)
	local ev, message = json.decode(fields)
	if type(ev) ~= 'table' then
		report(message or 'invalid event fields')
		return
	end
	ev.type = name
	local waiting = {}
	for task in pairs(tasks) do if task.wait and task.wait.event == name then waiting[#waiting + 1] = task end end
	for _, task in ipairs(waiting) do
		if tasks[task] and task.wait and task.wait.event == name and matches(task.wait.filter, ev, task.ctx) then
			resume_async(task, ev)
		end
	end
	local list = handlers[name]
	if list then
		for i = 1, #list do
			local ctx = context(ev.pane or config.pane, 'event')
			callback(list[i], ctx, ctx, ev)
		end
	end
end

function runtime.step(host_now)
	local shift = host_now - native.clock() - offset
	offset = offset + shift
	if not anchored then
		-- Deadlines set before the first step assumed the native clock; move them to the host's.
		anchored = true
		for t in pairs(timers) do t.deadline = t.deadline + shift end
		for task in pairs(tasks) do
			if task.wait and task.wait.deadline then task.wait.deadline = task.wait.deadline + shift end
		end
	end
	local now = host_now
	local list = {}
	for _, p in pairs(processes) do list[#list + 1] = p end
	for _, p in ipairs(list) do poll_process(p) end
	-- Waiters resume before timers fire, so a periodic timer whose last run just ended can fire.
	list = {}
	for task in pairs(tasks) do list[#list + 1] = task end
	for _, task in ipairs(list) do
		local w = tasks[task] and task.wait
		if w then
			if w.process and w.process.result then
				resume_async(task, w.process.result)
			elseif w.deadline and w.deadline <= now then
				if w.process or w.event then resume_async(task, nil, 'timeout') else resume_async(task, true) end
			end
		end
	end
	list = {}
	for t in pairs(timers) do if t.deadline <= now then list[#list + 1] = t end end
	for _, t in ipairs(list) do
		if t.live then
			-- A periodic timer whose previous run is still suspended skips this tick.
			if t.interval then t.deadline = now + t.interval else t:cancel() end
			if not t.running then
				local task = callback(t.fn, t.ctx, t.ctx)
				if tasks[task] then
					t.running = task
					task.timer = t
				end
			end
		end
	end
	local next_time
	local function consider(value) if value and (not next_time or value < next_time) then next_time = value end end
	for t in pairs(timers) do consider(t.deadline) end
	for task in pairs(tasks) do if task.wait then consider(task.wait.deadline) end end
	-- Output and exits also arrive through the wake callback; polling covers hosts without one.
	if next(processes) then consider(now + 0.01) end
	return next_time
end

-- Registered handlers count: a script that listens runs until aio.stop, as C6 describes busy.
function runtime.busy()
	if stop_code then return false end
	if next(tasks) ~= nil or next(timers) ~= nil or next(processes) ~= nil then return true end
	for _, list in pairs(handlers) do
		if #list > 0 then return true end
	end
	return false
end

function runtime.stopped() return stop_code end

function runtime.errors()
	local result = errors
	errors = {}
	return result
end

return runtime
