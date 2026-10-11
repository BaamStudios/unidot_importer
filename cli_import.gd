# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends Node

# Command line import: drives the regular import dialog in auto-import mode,
# reports progress on stdout and quits the editor when the import is done.
# Usage (see CLI.md):
#   godot --headless --editor --path <project> -- --unidot-import=<package> [options]

const package_import_dialog_class := preload("./package_import_dialog.gd")

const EXIT_OK = 0
const EXIT_IMPORT_ERRORS = 1
const EXIT_BAD_ARGS = 2
const EXIT_TIMEOUT = 3

# Frames without a filesystem scan before the import starts or the editor quits.
const SETTLE_FRAMES = 30

var plugin: EditorPlugin = null
var packages: PackedStringArray
var type_overrides: Dictionary # ".ext Type" -> bool
var quit_when_done: bool = true
var strict: bool = false
var timeout_sec: float = 0.0
var log_path: String = ""

var _started: bool = false
var _finished: bool = false
var _settle: int = 0
var _elapsed: float = 0.0
var _last_status: String = ""
var _dialog: RefCounted = null
var _summarized: Dictionary # dialog instance id -> true
var _failed_assets: PackedStringArray
var _global_fails: int = 0
var _log_lines: PackedStringArray
var _seen_types: Dictionary # type descriptions that occurred in any package


static func wants_cli_import() -> bool:
	for arg in _all_args():
		if arg.begins_with("--unidot-import"):
			return true
	return false


static func _all_args() -> PackedStringArray:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	return args


func _arg_value(arg: String, args: PackedStringArray, idx: int) -> String:
	# Supports both "--opt=value" and "--opt value".
	var eq := arg.find("=")
	if eq != -1:
		return arg.substr(eq + 1)
	if idx + 1 < len(args):
		return args[idx + 1]
	return ""


func parse_args() -> String:
	var args := _all_args()
	var seen: Dictionary
	var i := 0
	while i < len(args):
		var arg: String = args[i]
		var name := arg.get_slice("=", 0)
		var has_inline_value := arg.contains("=")
		var takes_value := name in ["--unidot-import", "--unidot-include-type", "--unidot-skip-type", "--unidot-timeout", "--unidot-log"]
		var value := ""
		if takes_value:
			value = _arg_value(arg, args, i)
			if not has_inline_value:
				i += 1
			if value.is_empty():
				return "Missing value for " + name
		match name:
			"--unidot-import":
				var path := _resolve_path(value)
				if seen.has(path):
					pass
				elif not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path):
					return "Package not found: " + path
				else:
					seen[path] = true
					packages.append(path)
			"--unidot-include-type":
				type_overrides[value] = true
			"--unidot-skip-type":
				type_overrides[value] = false
			"--unidot-timeout":
				timeout_sec = value.to_float()
			"--unidot-log":
				log_path = _resolve_path(value)
			"--unidot-strict":
				strict = true
			"--unidot-no-quit":
				quit_when_done = false
			_:
				if name.begins_with("--unidot-"):
					return "Unknown option: " + name
		i += 1
	if packages.is_empty():
		return "No package given (--unidot-import=<path>)"
	return ""


func _resolve_path(path: String) -> String:
	# Godot changes the working directory to the project, so relative paths
	# are relative to the project directory.
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	if path.is_absolute_path():
		return path.simplify_path()
	return ProjectSettings.globalize_path("res://").path_join(path).simplify_path()


func _ready():
	var err := parse_args()
	if not err.is_empty():
		printerr("[unidot-cli] " + err)
		_quit(EXIT_BAD_ARGS)
		return
	print("[unidot-cli] Waiting for the editor filesystem scan before importing: " + ", ".join(packages))


func _process(delta: float):
	if _finished:
		return
	_elapsed += delta
	if timeout_sec > 0.0 and _elapsed > timeout_sec:
		printerr("[unidot-cli] Timeout after " + str(timeout_sec) + " s")
		_finish(EXIT_TIMEOUT)
		return

	var editor_filesystem := EditorInterface.get_resource_filesystem()
	if editor_filesystem.is_scanning():
		_settle = 0
	else:
		_settle += 1

	if not _started:
		if _settle >= SETTLE_FRAMES:
			_start_import()
		return

	# The dialog replaces itself with a new instance for every further package in the batch.
	var dialog: RefCounted = plugin.package_import_dialog
	if dialog == null:
		return
	if dialog != _dialog:
		_watch(dialog)
	if dialog.status_bar != null and dialog.status_bar.text != _last_status:
		_last_status = dialog.status_bar.text
		print("[unidot-cli] " + _last_status)
	if _summarized.has(dialog.get_instance_id()):
		if dialog.batch_import_file_list.is_empty() and _settle >= SETTLE_FRAMES:
			var code := EXIT_OK
			if strict and (not _failed_assets.is_empty() or _global_fails > 0):
				code = EXIT_IMPORT_ERRORS
			_finish(code)


func _start_import():
	_started = true
	_elapsed = 0.0
	var dialog = package_import_dialog_class.new()
	dialog.editor_plugin = plugin
	dialog._show_importer_common()
	dialog.batch_import_file_list = packages.slice(1)
	dialog.batch_import_types = type_overrides.duplicate()
	dialog.auto_import = true
	dialog._keep_open_on_import = false
	_watch(dialog)
	print("[unidot-cli] Importing " + packages[0])
	dialog._selected_package(packages[0])


func _watch(dialog: RefCounted):
	_dialog = dialog
	# Summarize from the signal: the next package of a batch clears the shared logs right after it.
	dialog.import_completed.connect(_summarize.bind(dialog))
	if not dialog.current_selected_package.is_empty():
		print("[unidot-cli] Importing " + dialog.current_selected_package)


func _summarize(dialog: RefCounted):
	var key := dialog.get_instance_id()
	if _summarized.has(key):
		return
	_summarized[key] = true
	var fails := 0
	for tw in dialog.asset_all:
		var meta = tw.asset.parsed_meta
		if meta == null:
			continue
		var holder = meta.log_message_holder
		if holder.has_fails():
			fails += 1
			_failed_assets.append(tw.asset.pathname)
		if not log_path.is_empty():
			_log_lines.append_array(holder.warnings_fails)
	var global_holder = dialog.asset_database.log_message_holder
	_global_fails += len(global_holder.fails)
	if not log_path.is_empty():
		_log_lines.append_array(global_holder.warnings_fails)
	# select_by_type_items holds only the types that occur in this package.
	var types: PackedStringArray
	for desc in dialog.select_by_type_items:
		_seen_types[desc] = true
		types.append(desc + (" (imported)" if dialog.batch_import_types.get(desc, true) else " (skipped)"))
	types.sort()
	print("[unidot-cli] Types in package: " + ", ".join(types))
	print("[unidot-cli] Finished " + str(dialog.current_selected_package) + ": " + str(len(dialog.asset_all)) + " assets, " + str(fails) + " with errors, " + str(len(global_holder.fails)) + " global errors")


func _finish(code: int):
	_finished = true
	for path in _failed_assets:
		print("[unidot-cli] Errors in " + path)
	for desc in type_overrides:
		if not _seen_types.has(desc):
			printerr("[unidot-cli] Warning: type \"" + desc + "\" did not occur in any package")
	if not log_path.is_empty():
		var fa := FileAccess.open(log_path, FileAccess.WRITE)
		if fa == null:
			printerr("[unidot-cli] Cannot write log file " + log_path)
		else:
			_log_lines.sort()
			fa.store_string("\n".join(_log_lines) + "\n")
			print("[unidot-cli] Wrote warnings and errors to " + log_path)
	print("[unidot-cli] Done, exit code " + str(code))
	if quit_when_done:
		_quit(code)


func _quit(code: int):
	get_tree().quit(code)
