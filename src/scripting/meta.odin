package scripting

// The hand-written core of the aio API's LuaCATS definitions for lua-language-server: everything
// runtime.lua defines on `aio`. The app adds the commands, events and replies it generates (WORK-485).
META_CORE :: #load("meta.lua", string)
