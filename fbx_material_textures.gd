# This file is part of Unidot Importer. See LICENSE.txt for full MIT license.
# Copyright (c) 2021-present Lyuma <xn.lyuma@gmail.com> and contributors
# SPDX-License-Identifier: MIT
@tool
extends RefCounted

# Finds the diffuse (base color) texture of each material in an FBX file.
# Unity's default "Material Naming: By Base Texture Name" names model materials after this
# texture. The FBX2glTF path gets this from the glTF output; the built-in ufbx importer does
# not expose it, so we read the material, texture and connection records directly.
#
# Returns { material name: texture file name without directory or extension }.

# Connection properties that carry the diffuse / base color texture, in order of preference.
const DIFFUSE_PROPERTIES: PackedStringArray = ["DiffuseColor", "Diffuse", "Maya|baseColor", "Maya|base_color", "3dsMax|Parameters|base_color_map", "base_color", "BaseColor"]

const BINARY_MAGIC := "Kaydara FBX Binary  "


class FbxObjects:
	var materials: Dictionary # id -> material name
	var textures: Dictionary # id -> texture file name, or "" if the texture has none
	var texture_names: Dictionary # id -> texture object name
	var videos: Dictionary # id -> video file name
	var op_links: Array # [texture id, material id, property]
	var oo_links: Array # [source id, destination id]

	func add_object(obj_type: String, id: Variant, obj_name: String, file_path: String):
		match obj_type:
			"Material":
				materials[id] = obj_name
			"Texture":
				textures[id] = _texture_file_name(file_path)
				texture_names[id] = obj_name
			"Video":
				videos[id] = _texture_file_name(file_path)

	static func _texture_file_name(path: String) -> String:
		return path.replace("\\", "/").get_file().get_basename()

	func texture_file(tex_id: Variant) -> String:
		var file_name: String = textures.get(tex_id, "")
		if file_name.is_empty():
			# Some exporters only store the file name on the Video connected to the texture.
			for link in oo_links:
				if link[1] == tex_id and videos.has(link[0]) and not videos[link[0]].is_empty():
					return videos[link[0]]
			file_name = _texture_file_name(texture_names.get(tex_id, ""))
		return file_name


static func extract(fbx_file: PackedByteArray) -> Dictionary:
	var objs := FbxObjects.new()
	if len(fbx_file) > 27 and fbx_file.slice(0, len(BINARY_MAGIC)).get_string_from_ascii() == BINARY_MAGIC:
		_parse_binary(fbx_file, objs)
	else:
		_parse_ascii(fbx_file.get_string_from_utf8(), objs)

	var best_rank: Dictionary # material name -> rank of the property used
	var result: Dictionary
	for link in objs.op_links:
		var tex_id: Variant = link[0]
		var mat_id: Variant = link[1]
		var rank: int = DIFFUSE_PROPERTIES.find(link[2])
		if rank == -1 or not objs.materials.has(mat_id) or not objs.textures.has(tex_id):
			continue
		var mat_name: String = objs.materials[mat_id]
		if best_rank.has(mat_name) and best_rank[mat_name] <= rank:
			continue
		var tex_name: String = objs.texture_file(tex_id)
		if tex_name.is_empty():
			continue
		best_rank[mat_name] = rank
		result[mat_name] = tex_name
	return result


static func _parse_binary(buf: PackedByteArray, objs: FbxObjects) -> void:
	var spb := StreamPeerBuffer.new()
	spb.data_array = buf
	spb.big_endian = false
	spb.seek(23)
	var version: int = spb.get_u32()
	var wide: bool = version >= 7500
	var pos: int = 27
	while pos < len(buf):
		var node := _read_binary_node(spb, pos, wide)
		if node.is_empty() or node["end"] == 0:
			break
		if node["name"] == "Objects" or node["name"] == "Connections":
			for child in _read_binary_children(spb, node, wide):
				_handle_binary_object(spb, child, wide, objs)
		pos = node["end"]


static func _handle_binary_object(spb: StreamPeerBuffer, node: Dictionary, wide: bool, objs: FbxObjects) -> void:
	match node["name"]:
		"Material", "Texture", "Video":
			var props := _read_binary_props(spb, node)
			if len(props) < 2:
				return
			var file_path := ""
			if node["name"] != "Material":
				var file_name_path := ""
				for child in _read_binary_children(spb, node, wide):
					var child_name: String = child["name"].to_lower()
					if child_name == "relativefilename" or child_name == "filename":
						var child_props := _read_binary_props(spb, child)
						if not child_props.is_empty() and typeof(child_props[0]) == TYPE_STRING:
							if child_name == "relativefilename":
								file_path = child_props[0]
							else:
								file_name_path = child_props[0]
				if file_path.is_empty():
					file_path = file_name_path
			objs.add_object(node["name"], props[0], str(props[1]), file_path)
		"C":
			var props := _read_binary_props(spb, node)
			if len(props) >= 4 and props[0] == "OP":
				objs.op_links.append([props[1], props[2], str(props[3])])
			elif len(props) >= 3 and props[0] == "OO":
				objs.oo_links.append([props[1], props[2]])


# Returns {name, end, num_props, props, children} or {} on malformed data; {"end": 0} for the end marker.
static func _read_binary_node(spb: StreamPeerBuffer, pos: int, wide: bool) -> Dictionary:
	if pos + (25 if wide else 13) > spb.get_size():
		return {}
	spb.seek(pos)
	var end: int = spb.get_u64() if wide else spb.get_u32()
	var num_props: int = spb.get_u64() if wide else spb.get_u32()
	var props_len: int = spb.get_u64() if wide else spb.get_u32()
	var name_len: int = spb.get_u8()
	if end == 0:
		return {"end": 0}
	if end <= pos or end > spb.get_size():
		return {}
	var node_name: String = spb.get_data(name_len)[1].get_string_from_ascii()
	var props_pos: int = spb.get_position()
	return {"name": node_name, "end": end, "num_props": num_props, "props": props_pos, "children": props_pos + props_len}


static func _read_binary_children(spb: StreamPeerBuffer, node: Dictionary, wide: bool) -> Array:
	var children: Array
	var child_pos: int = node["children"]
	while child_pos < node["end"]:
		var child := _read_binary_node(spb, child_pos, wide)
		if child.is_empty() or child["end"] == 0:
			break
		children.append(child)
		child_pos = child["end"]
	return children


static func _read_binary_props(spb: StreamPeerBuffer, node: Dictionary) -> Array:
	var props: Array
	spb.seek(node["props"])
	for i in range(node["num_props"]):
		if spb.get_position() >= node["children"]:
			break
		var type_code: String = char(spb.get_u8())
		match type_code:
			"Y":
				props.append(spb.get_16())
			"C":
				props.append(spb.get_u8() != 0)
			"I":
				props.append(spb.get_32())
			"F":
				props.append(spb.get_float())
			"D":
				props.append(spb.get_double())
			"L":
				props.append(spb.get_64())
			"S":
				var data: PackedByteArray = spb.get_data(spb.get_u32())[1]
				# Object names are stored as "name\u0000\u0001Class"; keep only the name.
				for j in range(len(data) - 1):
					if data[j] == 0 and data[j + 1] == 1:
						data = data.slice(0, j)
						break
				props.append(data.get_string_from_utf8())
			"R":
				props.append(spb.get_data(spb.get_u32())[1])
			"f", "d", "l", "i", "b":
				spb.get_u32() # array length
				spb.get_u32() # encoding
				var compressed_length: int = spb.get_u32()
				spb.seek(spb.get_position() + compressed_length)
				props.append(null)
			_:
				break
	return props


static func _parse_ascii(text: String, objs: FbxObjects) -> void:
	# FBX 7: Material: 123, "Material::rock1", "" {   and   C: "OP",456,123, "DiffuseColor"
	# FBX 6: Material: "Material::rock1", "" {        and   Connect: "OP", "Texture::a", "Material::rock1", "DiffuseColor"
	var object_re := RegEx.create_from_string('(?m)^\\s*(Material|Texture|Video):\\s*(?:(-?\\d+)\\s*,\\s*)?"(?:Material|Texture|Video)::([^"]*)"[^{\\n]*\\{')
	var relative_re := RegEx.create_from_string('(?i)RelativeFilename:\\s*"([^"]*)"')
	var filename_re := RegEx.create_from_string('(?im)^\\s*FileName:\\s*"([^"]*)"')
	for m in object_re.search_all(text):
		var obj_type: String = m.get_string(1)
		var id: Variant = m.get_string(2).to_int() if not m.get_string(2).is_empty() else obj_type + "::" + m.get_string(3)
		var file_path := ""
		if obj_type != "Material":
			var block := _ascii_block(text, m.get_end() - 1)
			var rel := relative_re.search(block)
			var full := filename_re.search(block)
			if rel != null and not rel.get_string(1).is_empty():
				file_path = rel.get_string(1)
			elif full != null:
				file_path = full.get_string(1)
		objs.add_object(obj_type, id, m.get_string(3), file_path)
	var c_re := RegEx.create_from_string('(?m)^\\s*C:\\s*"(OP|OO)"\\s*,\\s*(-?\\d+)\\s*,\\s*(-?\\d+)[ \\t]*(?:,[ \\t]*"([^"]*)")?')
	for m in c_re.search_all(text):
		if m.get_string(1) == "OP":
			objs.op_links.append([m.get_string(2).to_int(), m.get_string(3).to_int(), m.get_string(4)])
		else:
			objs.oo_links.append([m.get_string(2).to_int(), m.get_string(3).to_int()])
	var connect_re := RegEx.create_from_string('(?m)^\\s*Connect:\\s*"(OP|OO)"\\s*,\\s*"([^"]*)"\\s*,\\s*"([^"]*)"[ \\t]*(?:,[ \\t]*"([^"]*)")?')
	for m in connect_re.search_all(text):
		if m.get_string(1) == "OP":
			objs.op_links.append([m.get_string(2), m.get_string(3), m.get_string(4)])
		else:
			objs.oo_links.append([m.get_string(2), m.get_string(3)])


# Returns the text between the brace at open_pos and its matching closing brace.
static func _ascii_block(text: String, open_pos: int) -> String:
	var depth := 0
	var i := open_pos
	while i < len(text):
		var c := text[i]
		if c == "{":
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0:
				return text.substr(open_pos, i - open_pos)
		elif c == '"':
			var close := text.find('"', i + 1)
			if close == -1:
				break
			i = close
		i += 1
	return text.substr(open_pos)
