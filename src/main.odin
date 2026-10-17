package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "aio:instance"
import "aio:platform"

main :: proc() {
	code := start()
	if code != 0 { os.exit(code) }
}

@(private)
App_Logger :: struct {
	console, file: log.Logger,
}

@(private)
app_logger_proc :: proc(data: rawptr, level: log.Level, text: string,
	_: log.Options, location := #caller_location) {
	logger := cast(^App_Logger)data
	if ODIN_DEBUG || logger.file.data == nil {
		console := logger.console
		console.procedure(console.data, level, text, console.options, location)
	}
	if logger.file.data != nil {
		file := logger.file
		file.procedure(file.data, level, text, file.options, location)
	}
}

@(private, require_results)
start :: proc() -> int {
	args, argument_error := instance.command_line(context.allocator)
	if argument_error != .None {
		fmt.fprintln(os.stderr, "Reading the command line failed:", argument_error)
		return 2
	}
	defer instance.command_line_destroy(args, context.allocator)
	options, parse_error := instance.parse(args)
	if parse_error != .None {
		fmt.fprintln(os.stderr, instance.USAGE)
		fmt.fprintln(os.stderr, "Invalid command line:", parse_error)
		return 2
	}
	level: log.Level = ODIN_DEBUG ? .Debug : .Info
	logger := App_Logger{console = log.create_console_logger(level)}
	context.logger = log.Logger{procedure = app_logger_proc, data = &logger, lowest_level = level}
	defer {
		if logger.file.data != nil { log.destroy_file_logger(logger.file) }
		log.destroy_console_logger(logger.console)
	}
	app := App{options = options}
	defer app_destroy(&app)
	id, id_error := instance.app_id(options, context.allocator)
	if id_error != nil {
		log.errorf("constructing the app ID failed: %v", id_error)
		return 1
	}
	app.app_id = id
	switch platform.init(&app.platform, app.app_id) {
	case .Secondary:
		log.infof("activated the running %s instance", app.app_id)
		return 0
	case .Failed:
		log.error("platform initialization failed")
		return 1
	case .Primary:
		app.platform_ready = true
	}
	log_error: os.Error
	logger.file, app.log_path, log_error = file_logger_create(options, level)
	if log_error != nil {
		log.errorf("opening the log file failed: %v", log_error)
	}
	if !app_init(&app) { return 1 }
	run(&app)
	return 0
}

@(private, require_results)
file_logger_create :: proc(options: instance.Options, level: log.Level) -> (log.Logger, string, os.Error) {
	root := options.data_dir
	if root == "" {
		base, found := os.lookup_env("LOCALAPPDATA", context.temp_allocator)
		if !found { return {}, "", os.General_Error.Env_Var_Not_Found }
		path, err := filepath.join({base, instance.APP_NAME}, context.temp_allocator)
		if err != nil { return {}, "", err }
		root = path
	}
	directory, directory_error := filepath.join({root, "logs"}, context.temp_allocator)
	if directory_error != nil { return {}, "", directory_error }
	if err := os.mkdir_all(directory); err != nil { return {}, "", err }
	name, name_error := instance.log_file_name(options, context.temp_allocator)
	if name_error != nil { return {}, "", name_error }
	path, path_error := filepath.join({directory, name})
	if path_error != nil { return {}, "", path_error }
	file, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if err != nil { return {}, path, err }
	return log.create_file_logger(file, level), path, nil
}
