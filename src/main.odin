package main

import "core:log"
import "core:os"
import "core:path/filepath"

APP_ID :: "AIODev"

main :: proc() {
	logger, log_file := logger_create()
	context.logger = logger
	defer logger_destroy(logger, log_file)

	app: App
	switch app_init(&app) {
	case .Ready:
		run(&app)
		app_destroy(&app)
	case .Already_Running:
		log.info("activated the running AIODev instance")
	case .Failed:
		app_destroy(&app)
		os.exit(1)
	}
}

@(private)
Log_File :: struct {
	file: ^os.File,
	logger: log.Logger,
}

@(private)
logger_create :: proc() -> (log.Logger, Log_File) {
	level: log.Level = ODIN_DEBUG ? .Debug : .Info
	console := log.create_console_logger(level)
	root, found := os.lookup_env("LOCALAPPDATA", context.temp_allocator)
	if !found {
		return console, {}
	}
	directory, directory_error := filepath.join({root, APP_ID, "logs"}, context.temp_allocator)
	if directory_error != nil || os.mkdir_all(directory) != nil {
		return console, {}
	}
	path, path_error := filepath.join({directory, "aiodev.log"}, context.temp_allocator)
	if path_error != nil {
		return console, {}
	}
	file, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if err != nil {
		return console, {}
	}
	file_logger := log.create_file_logger(file, level)
	when ODIN_DEBUG {
		return log.create_multi_logger(console, file_logger), {file, file_logger}
	} else {
		log.destroy_console_logger(console)
		return file_logger, {file, file_logger}
	}
}

@(private)
logger_destroy :: proc(logger: log.Logger, file: Log_File) {
	if file.file == nil {
		log.destroy_console_logger(logger)
		return
	}
	when ODIN_DEBUG {
		multi := (^log.Multi_Logger_Data)(logger.data)
		log.destroy_console_logger(multi.loggers[0])
		log.destroy_multi_logger(logger)
	}
	log.destroy_file_logger(file.logger)
}
