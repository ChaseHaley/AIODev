-- Where a function works is stated on it: Config is init.lua inside AIODev, Script is `aio exec`,
-- and the declaration functions work only while init.lua loads.

---The AIODev scripting API. `aio.<namespace>.<name>(fields)` runs the command `<namespace>.<name>`.
---@class aio
aio = {}

---Where a callback's work came from: how a command was run, or `event` and `timer` for handlers and
---timers.
---@alias aio.Origin "key"|"palette"|"menu"|"button"|"cli"|"script"|"config"|"event"|"timer"

---What a callback receives as ctx. An action, a key and a command run from a window name the window,
---workspace and tab they act on; event handlers and timers carry only pane and origin.
---@class aio.Ctx
---@field pane integer The pane the work acts on; 0 when there is none.
---@field origin aio.Origin
---@field tab? integer The tab's id.
---@field workspace? integer The workspace's id.
---@field window? integer The window's id.
---@field key? string The key sequence pressed, for a function bound with aio.bind.

-- Running commands ----------------------------------------------------------------------------

---Runs a command or an init.lua action by name with its fields. Returns the reply without ok, status
---and error, or nil, the message and the CLI exit status. Refused while init.lua loads.
---Config and Script.
--{{run}}
---@param name string A command name such as `pane.split`, or an action's name.
---@param fields? table The command's arguments, as `aio help <command>` lists them.
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.run(name, fields) end

---Runs a command or action and returns only its reply's `result`: what an init.lua action returned.
---Config and Script.
--{{invoke}}
---@param name string
---@param args? table
---@return any result
---@return string? message
---@return integer? status
function aio.invoke(name, args) end

---Every window, workspace, tab and pane, with each tab's tiled tree and floats nested.
---Config and Script.
---@return aio.View? view
---@return string? message
---@return integer? status
function aio.view() end

---What aio.view() returns: app.view's document with nested trees instead of a flat nodes list.
---@class aio.View
---@field revision integer The layout revision; layout.changed reports the same number.
---@field windows aio.ViewWindowReport[]
---@field workspaces aio.ViewWorkspace[]
---@field panes aio.PaneReport[]

---@class aio.ViewWorkspace
---@field id integer
---@field name string
---@field selected boolean Whether the focused-or-primary window shows this workspace.
---@field tabs aio.ViewTab[]

---@class aio.ViewTab
---@field id integer The tab's id, which events carry.
---@field index integer The tab's position in its workspace, from 1, as pane.list's `tab`.
---@field name string
---@field title string
---@field group integer
---@field selected boolean
---@field focused_pane integer
---@field view "split"|"zoom"|"fill"|"fullscreen"
---@field root? aio.ViewNode The tiled tree; nil when every pane floats or the tab shows none.
---@field floats aio.ViewFloat[]

---A leaf holds pane; a split holds split, ratio, first and second.
---@class aio.ViewNode
---@field pane? integer
---@field split? "right"|"down"
---@field ratio? number The first child's share.
---@field first? aio.ViewNode
---@field second? aio.ViewNode

---@class aio.ViewFloat
---@field bounds number[] x, y, width and height as shares of the window's floating work area.
---@field cells? integer[] The same rectangle in terminal cells, when a window shows the tab.
---@field stack integer
---@field minimized boolean
---@field root? aio.ViewNode

---@class aio.NotifyOptions
---@field title? string
---@field body string

---Shows an Info notice, or a system notification when no window is visible. Config and Script.
---@param opts aio.NotifyOptions
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.notify(opts) end

aio.clipboard = {}

---The clipboard's text. Config and Script.
---@return string? text
---@return string? message
---@return integer? status
function aio.clipboard.get() end

---Puts text on the clipboard. Config and Script.
---@param text string
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.clipboard.set(text) end

aio.settings = {}

---A setting's current value as settings.ini writes it, such as `aio.settings.get('font.size')`.
---Config and Script.
---@param key string
---@return string? value
---@return string? message
---@return integer? status
function aio.settings.get(key) end

---Checks, applies and saves a setting as the Settings page does. Config and Script.
---@param key string
---@param value any Written with tostring.
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.settings.set(key, value) end

---@alias aio.LogLevel "debug"|"trace"|"info"|"warn"|"warning"|"error"

---Writes to the app log; in init.lua, warn and error also show a notice. Config and Script.
---@param level aio.LogLevel
---@param message any
---@overload fun(message: any)
function aio.log(level, message) end

---JSON with Lua tables: a table with only positive integer keys is an array; null decodes as nil.
aio.json = {}

---@class aio.JsonOptions
---@field indent? integer|string Spaces (up to 16) or the text to indent each level with.

---@param value any
---@param opts? aio.JsonOptions
---@return string? text
---@return string? message
function aio.json.encode(value, opts) end

---@param text string
---@return any value
---@return string? message
function aio.json.decode(text) end

-- Layout --------------------------------------------------------------------------------------

---Builds layout.apply's nested tree in Lua.
aio.layout = {}

---@class aio.LayoutPane
---@field name? string
---@field command? string[] The program, then its arguments.
---@field cwd? string
---@field profile? string

---@class aio.LayoutSplit
---@field split "right"|"down"
---@field ratio number The first child's share, between 0 and 1.
---@field first aio.LayoutNode
---@field second aio.LayoutNode

---@alias aio.LayoutNode aio.LayoutPane|aio.LayoutSplit

---@class aio.LayoutFloat
---@field bounds number[] x, y, width and height.
---@field unit? "share"|"cells"
---@field pane? aio.LayoutPane

---@class aio.Layout
---@field tab? string The new tab's name.
---@field cwd? string The directory relative pane directories start from.
---@field root aio.LayoutNode
---@field floats? aio.LayoutFloat[]

---A leaf of the tree. Config and Script.
---@param opts aio.LayoutPane
---@return aio.LayoutPane? pane
---@return string? message
function aio.layout.pane(opts) end

---A split of two nodes. Config and Script.
---@param direction "right"|"down"
---@param ratio number
---@param first aio.LayoutNode
---@param second aio.LayoutNode
---@return aio.LayoutSplit? split
---@return string? message
function aio.layout.split(direction, ratio, first, second) end

---A floating pane. Config and Script.
---@param opts aio.LayoutFloat
---@return aio.LayoutFloat? float
---@return string? message
function aio.layout.float(opts) end

---Opens a tab laid out as the tree describes, through the layout.apply command. Config and Script.
---@param opts aio.Layout
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.layout.apply(opts) end

-- Events and timers ---------------------------------------------------------------------------

---Any event: its name in `type` and the fields its aio.event class lists.
---@class aio.Event
---@field type aio.EventName
---@field [string] any

---Calls fn(ctx, ev) for every event of that name, after the tick that caused it. Returns fn. An
---unknown name raises an error. Config and Script.
--{{on}}
---@param name aio.EventName
---@param fn fun(ctx: aio.Ctx, ev: aio.Event)
---@return fun(ctx: aio.Ctx, ev: aio.Event) fn
function aio.on(name, fn) end

---Suspends the calling entry point until an event of that name matches the filter: a table of field
---values, or a function returning true. Returns the event, or nil and 'timeout' after timeout
---seconds. Cannot run while init.lua loads. Config and Script.
--{{wait}}
---@param name aio.EventName
---@param filter? table|(fun(ev: aio.Event): boolean)
---@param timeout? number
---@return aio.Event? ev
---@return string? message
function aio.wait(name, filter, timeout) end

---Suspends the calling entry point for seconds. Cannot run while init.lua loads. Config and Script.
---@param seconds number
---@return true? done
---@return string? message
function aio.sleep(seconds) end

---A timer from aio.after or aio.every. At most 1024 are live at once.
---@class aio.Timer
local Timer = {}

---Stops the timer; a running callback finishes.
function Timer:cancel() end

---Whether the timer will still fire.
---@return boolean
function Timer:active() end

---Calls fn(ctx) once, after seconds. Config and Script.
---@param seconds number
---@param fn fun(ctx: aio.Ctx)
---@return aio.Timer? timer
---@return string? message
function aio.after(seconds, fn) end

---Calls fn(ctx) every seconds; a run still suspended skips its turn. Config and Script.
---@param seconds number Positive.
---@param fn fun(ctx: aio.Ctx)
---@return aio.Timer? timer
---@return string? message
function aio.every(seconds, fn) end

-- Prompts -------------------------------------------------------------------------------------

aio.ui = {}

---@class aio.SelectOptions
---@field prompt? string The list's title.
---@field format_item? (fun(item: any): string) Each item's label; tostring by default.

---Opens a filtered list of items, in the shape of vim.ui.select. Without on_choice it suspends the
---entry point and returns the chosen item and its index, or nil when dismissed; with it, it returns
---the prompt id and calls on_choice later. Config and Script.
---@generic T
---@param items T[]
---@param opts? aio.SelectOptions
---@param on_choice? fun(item: T?, index: integer?)
---@return T|integer|nil item The chosen item, or the prompt id when on_choice is given.
---@return integer|string|nil index The index, or the failure message.
function aio.ui.select(items, opts, on_choice) end

---@class aio.InputOptions
---@field prompt? string The dialog's title.
---@field default? string The text the dialog starts with, selected.

---Opens a single-line text dialog, in the shape of vim.ui.input. Without on_confirm it suspends the
---entry point and returns the text, or nil when dismissed; with it, it returns the prompt id and
---calls on_confirm later. Config and Script.
---@param opts? aio.InputOptions
---@param on_confirm? fun(text: string?)
---@return string|integer|nil text The text, or the prompt id when on_confirm is given.
---@return string? message
function aio.ui.input(opts, on_confirm) end

-- Processes -----------------------------------------------------------------------------------

---@class aio.SystemOptions
---@field cwd? string
---@field env? table<string, string|false> Variables to set; false removes one.
---@field clear_env? boolean Start from an empty environment.
---@field stdin? string|true Text to write, or true to keep stdin open for write.
---@field text? boolean false keeps CRLF line endings.
---@field stdout? false|(fun(err: nil, data: string)) false discards; a function streams each chunk.
---@field stderr? false|(fun(err: nil, data: string)) false discards; a function streams each chunk.
---@field timeout? number Seconds before the process tree is killed.
---@field detach? boolean Outlive the callback that started it.

---@class aio.SystemResult
---@field code integer
---@field stdout string
---@field stderr string
---@field ok boolean Exit code 0 and no timeout.
---@field timed_out boolean

---A program aio.system started.
---@class aio.SystemHandle
---@field pid integer
local SystemHandle = {}

---Waits for the program to exit. In a coroutine it suspends; in a Script host's top level it blocks;
---in init.lua's top level it raises an error.
---@param timeout? number
---@return aio.SystemResult? result
---@return string? message 'timeout' or why it cannot wait.
function SystemHandle:wait(timeout) end

---@param data string
---@return true? ok
---@return string? message
function SystemHandle:write(data) end

---@return true? ok
---@return string? message
function SystemHandle:close_stdin() end

---Kills the whole process tree.
---@return true? ok
---@return string? message
function SystemHandle:kill() end

---@return boolean
function SystemHandle:is_closing() end

---Starts a program without a shell, in the shape of vim.system; only .exe and .com programs start.
---on_exit receives the result. A program that is not detached is killed when the callback that
---started it ends. Config and Script.
---@param argv string[] The program, then its arguments.
---@param opts? aio.SystemOptions
---@param on_exit? fun(result: aio.SystemResult)
---@return aio.SystemHandle? handle
---@return string? message
---@overload fun(argv: string[], on_exit: (fun(result: aio.SystemResult))): aio.SystemHandle?, string?
function aio.system(argv, opts, on_exit) end

-- Declarations --------------------------------------------------------------------------------

---A type word for an action argument; a trailing ? makes it optional.
---@alias aio.ArgType
---| "string" | "number" | "integer" | "boolean" | "object" | "array" | "any"
---| "string?" | "number?" | "integer?" | "boolean?" | "object?" | "array?" | "any?"

---@class aio.ActionSpec
---@field name string Lowercase letters, digits and _; the command's name.
---@field title string What the palette and Settings show.
---@field run (fun(ctx: aio.Ctx, args: table?): any) Its return value is the reply's result.
---@field description? string
---@field category? string The palette category; Actions by default.
---@field keywords? string|string[] More words the palette matches.
---@field args? table<string, aio.ArgType|table>|table Type words by name, checked before run starts, or a JSON Schema (a table with a type key), kept but not checked.
---@field repeats? boolean

---Declares a user action: a command the palette, Settings, keys and `aio exec` reach. A later action
---of the same name replaces it. Config only, while init.lua loads.
---@param spec aio.ActionSpec
---@return true? ok
---@return string? message
function aio.action(spec) end

---Binds a key, such as `Ctrl+Alt+H`, a sequence `Ctrl+B>C` or `mode/Key`, to a command or action by
---name with args as its fields, or to a function called as fn(ctx); a function returning false passes
---the key on. Config only, while init.lua loads.
---@param key string
---@param target string|(fun(ctx: aio.Ctx): boolean?)
---@param args? table Fields for a named target.
---@return true? ok
---@return string? message
function aio.bind(key, target, args) end

---Removes a key's binding, to target only when given. Config only, while init.lua loads.
---@param key string
---@param target? string|(fun(ctx: aio.Ctx): boolean?)
---@return true? ok
---@return string? message
function aio.unbind(key, target) end

---@class aio.ModeOptions
---@field exclusive? boolean Keys without a binding in the mode do nothing.

---Declares a key mode; `mode/Key` binds inside it and mode.enter enters it. Config only, while
---init.lua loads.
---@param name string Lowercase letters, digits, _ and -.
---@param opts? aio.ModeOptions
---@return true? ok
---@return string? message
function aio.mode(name, opts) end

---@class aio.BindingFilter
---@field key? string
---@field mode? string
---@field action? string

---@class aio.Binding
---@field op "bind"|"unbind"
---@field key string
---@field mode? string
---@field action? string The command or action name.
---@field fn? function The function target.
---@field args? table
---@field source string Where it was declared, as `file:line`.

---The key operations init.lua declared so far that match the filter. Config only, while init.lua
---loads.
---@param filter? aio.BindingFilter
---@return aio.Binding[]? bindings
---@return string? message
function aio.bindings(filter) end

-- Script host ---------------------------------------------------------------------------------

---Ends the script with code, 0 by default. Script only.
---@param code? integer
---@return nil
---@return string? message
function aio.stop(code) end

---The script's arguments, from `key=value` words or `--args`. Script only.
---@type table<string, any>
aio.args = {}

---The pane `aio exec` ran in, 0 outside AIODev. Script only.
---@type integer
aio.pane_id = 0
