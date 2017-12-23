# The MIT License (MIT)
#
# Copyright (c) 2017 George Marques
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

tool
extends Reference

# Constants for tile flipping
# http://doc.mapeditor.org/reference/tmx-map-format/#tile-flipping
const FLIPPED_HORIZONTALLY_FLAG = 0x80000000
const FLIPPED_VERTICALLY_FLAG   = 0x40000000
const FLIPPED_DIAGONALLY_FLAG   = 0x20000000

# Polygon vertices sorter
const PolygonSorter = preload("polygon_sorter.gd")

# Main function
# Reads a source file and gives back a full PackedScene
func build(source_path, options):
	var map = read_file(source_path)
	if typeof(map) == TYPE_INT:
		return map
	if typeof(map) != TYPE_DICTIONARY:
		return ERR_INVALID_DATA

	var err = validate_map(map)
	if err != OK:
		return err

	var map_size = Vector2(int(map.width), int(map.height))
	var cell_size = Vector2(int(map.tilewidth), int(map.tileheight))
	var map_mode = TileMap.MODE_SQUARE
	if "orientation" in map:
		match map.orientation:
			"isometric": map_mode = TileMap.MODE_ISOMETRIC
			# TODO: staggered and hexagonal orientations

	var tileset = build_tileset(map.tilesets, source_path, options)
	if typeof(tileset) != TYPE_OBJECT:
		# Error happened
		return tileset

	var root = Node2D.new()
	root.set_name(source_path.get_file().get_basename())

	for layer in map.layers:
		err = validate_layer(layer)
		if err != OK:
			return err

		var opacity = float(layer.opacity) if "opacity" in layer else 1.0
		var visible = bool(layer.visible) if "visible" in layer else true

		if layer.type == "tilelayer":
			var layer_data = layer.data

			if "encoding" in layer and layer.encoding == "base64":
				if "compression" in layer:
					layer_data = decompress_layer(layer_data, layer.compression, map_size)
					if typeof(layer_data) == TYPE_INT:
						# Error happened
						return layer_data
				else:
					layer_data = read_base64_layer(layer_data)

			var tilemap = TileMap.new()
			tilemap.set_name(layer.name)
			tilemap.cell_size = cell_size
			tilemap.self_modulate = Color(1.0, 1.0, 1.0, opacity);
			tilemap.visible = visible
			tilemap.mode = map_mode
			tilemap.cell_clip_uv = options.uv_clip

			var offset = Vector2()
			if "offsetx" in layer:
				offset.x = int(layer.offsetx)
			if "offsety" in layer:
				offset.y = int(layer.offsety)

			tilemap.position = offset
			tilemap.tile_set = tileset

			var count = 0
			for tile_id in layer_data:
				var int_id = int(str(tile_id)) & 0xFFFFFFFF

				if int_id == 0:
					count += 1
					continue

				var flipped_h = bool(int_id & FLIPPED_HORIZONTALLY_FLAG)
				var flipped_v = bool(int_id & FLIPPED_VERTICALLY_FLAG)
				var flipped_d = bool(int_id & FLIPPED_DIAGONALLY_FLAG)

				var gid = int_id & ~(FLIPPED_HORIZONTALLY_FLAG | FLIPPED_VERTICALLY_FLAG | FLIPPED_DIAGONALLY_FLAG)

				var cell_pos = Vector2(count % int(map_size.x), int(count / map_size.x))
				tilemap.set_cellv(cell_pos, gid, flipped_h, flipped_v, flipped_d)

				count += 1

			root.add_child(tilemap)
			tilemap.set_owner(root)
		elif layer.type == "imagelayer":
			var image = load_image(layer.image, source_path, options.image_flags)
			if typeof(image) != TYPE_OBJECT:
				# Error happened
				return image

			var pos = Vector2()
			var offset = Vector2()

			if "x" in layer:
				pos.x = float(layer.x)
			if "y" in layer:
				pos.y = float(layer.y)
			if "offsetx" in layer:
				offset.x = float(layer.offsetx)
			if "offsety" in layer:
				offset.y = float(layer.offsety)

			var sprite = Sprite.new()
			sprite.set_name(layer.name)
			sprite.centered = false
			sprite.texture = image
			sprite.visible = visible
			sprite.self_modulate = Color(1.0, 1.0, 1.0, opacity)
			root.add_child(sprite)
			sprite.position = pos + offset
			sprite.set_owner(root)
		elif layer.type == "objectgroup":
			var object_layer = Node2D.new()
			root.add_child(object_layer)
			object_layer.set_owner(root)
			if "name" in layer and not layer.name.empty():
				object_layer.set_name(layer.name)
			for object in layer.objects:
				if "point" in object and object.point:
					var point = Position2D.new()
					if not "x" in object or not "y" in object:
						printerr("Missing coordinates for point in object layer.")
						continue
					point.position = Vector2(float(object.x), float(object.y))
					point.visible = bool(object.visible) if "visible" in object else true
					object_layer.add_child(point)
					point.set_owner(root)
					if "name" in object and not str(object.name).empty():
						point.set_name(str(object.name))
					elif "id" in object and not str(object.id).empty():
						point.set_name(str(object.id))

				elif not "gid" in object:
					# Not a tile object
					if "type" in object and object.type == "navigation":
						# Can't make navigation objects right now
						printerr("Navigation polygons aren't supported in an object layer.")
						continue # Non-fatal error
					var shape = shape_from_object(object)

					if typeof(shape) != TYPE_OBJECT:
						# Error happened
						return shape

					if "type" in object and object.type == "occluder":
						var occluder = LightOccluder2D.new()
						var pos = Vector2()
						var rot = 0

						if "x" in object:
							pos.x = float(object.x)
						if "y" in object:
							pos.y = float(object.y)
						if "rotation" in object:
							rot = float(object.rotation)

						occluder.visible = bool(object.visible) if "visible" in object else true
						occluder.position = pos
						occluder.rotation_degrees = rot
						occluder.occluder = shape
						if "name" in object and not str(object.name).empty():
							occluder.set_name(str(object.name))
						elif "id" in object and not str(object.id).empty():
							occluder.set_name(str(object.id))

						object_layer.add_child(occluder)
						occluder.set_owner(root)

					else:
						var body = StaticBody2D.new()

						var offset = Vector2()
						var collision
						var pos = Vector2()
						var rot = 0

						if not ("polygon" in object or "polyline" in object):
							# Regular shape
							collision = CollisionShape2D.new()
							collision.shape = shape
							if shape is RectangleShape2D:
								offset = shape.extents
							elif shape is CircleShape2D:
								offset = Vector2(shape.radius, shape.radius)
							elif shape is CapsuleShape2D:
								offset = Vector2(shape.radius, shape.height)
								if shape.radius > shape.height:
									var temp = shape.radius
									shape.radius = shape.height
									shape.height = temp
									collision.rotation_degrees = 90
								shape.height *= 2
							collision.position = offset
						else:
							collision = CollisionPolygon2D.new()
							var points = null
							if shape is ConcavePolygonShape2D:
								points = []
								var segments = shape.segments
								for i in range(0, segments.size()):
									if i % 2 != 0:
										continue
									points.push_back(segments[i])
								collision.build_mode = CollisionPolygon2D.BUILD_SEGMENTS
							else:
								points = shape.points
								collision.build_mode = CollisionPolygon2D.BUILD_SOLIDS
							collision.polygon = points

						if "x" in object:
							pos.x = float(object.x)
						if "y" in object:
							pos.y = float(object.y)
						if "rotation" in object:
							rot = float(object.rotation)

						object_layer.add_child(body)
						body.set_owner(root)
						body.add_child(collision)
						collision.set_owner(root)

						if "name" in object and not str(object.name).empty():
							body.set_name(str(object.name))
						elif "id" in object and not str(object.id).empty():
							body.set_name(str(object.id))
						body.visible = bool(object.visible) if "visible" in object else true
						body.position = pos
						body.rotation_degrees = rot

				else: # "gid" in object
					var tile_raw_id = int(str(object.gid)) & 0xFFFFFFFF
					var tile_id = tile_raw_id & ~(FLIPPED_HORIZONTALLY_FLAG | FLIPPED_VERTICALLY_FLAG | FLIPPED_DIAGONALLY_FLAG)

					var is_tile_object = tileset.tile_get_region(tile_id).get_area() == 0
					var sprite = Sprite.new()
					var pos = Vector2()
					var rot = 0
					sprite.texture = tileset.tile_get_texture(tile_id)

					if not is_tile_object:
						sprite.region_enabled = true
						sprite.region_rect = tileset.tile_get_region(tile_id)

					if "name" in object and not str(object.name).empty():
						sprite.set_name(str(object.name))
					elif "id" in object and not str(object.id).empty():
						sprite.set_name(str(object.id))

					sprite.flip_h = bool(tile_id & FLIPPED_HORIZONTALLY_FLAG)
					sprite.flip_v = bool(tile_id & FLIPPED_VERTICALLY_FLAG)

					if "x" in object:
						pos.x = float(object.x)
					if "y" in object:
						pos.y = float(object.y)
					if "rotation" in object:
						rot = float(object.rotation)

					if is_tile_object:
						# Tile object positions are oriented bottom left.
						# If we import their positioning data as is, their position ends up skewed incorrectly.
						pos.x = pos.x + float(object.width) / 2
						pos.y = pos.y - float(object.height) / 2

					sprite.position = pos
					sprite.rotation_degrees = rot
					sprite.visible = bool(object.visible) if "visible" in object else true

					object_layer.add_child(sprite)
					sprite.set_owner(root)

		else:
			printerr("Unknown layer type ('%s') in '%s'" % [layer.type, layer.name if "name" in layer else "[unnamed layer]"])

	var scene = PackedScene.new()
	scene.pack(root)
	return scene

# Make a tileset from a array of tilesets data
# Since Godot supports only one TileSet per TileMap, all tilesets from Tiled are combined
func build_tileset(tilesets, source_path, options):
	var result = TileSet.new()

	for ts in tilesets:
		var err = validate_tileset(ts)
		if err != OK:
			return err

		var has_global_image = "image" in ts

		var spacing = int(ts.spacing) if "spacing" in ts and str(ts.spacing).is_valid_integer() else 0
		var margin = int(ts.margin) if "margin" in ts and str(ts.margin).is_valid_integer() else 0
		var firstgid = int(ts.firstgid)

		var image = null
		var imagesize = Vector2()

		if has_global_image:
			image = load_image(ts.image, source_path, options.image_flags)
			if typeof(image) != TYPE_OBJECT:
				# Error happened
				return image
			imagesize = Vector2(int(ts.imagewidth), int(ts.imageheight))

		var tilesize = Vector2(int(ts.tilewidth), int(ts.tileheight))
		var tilecount = int(ts.tilecount)

		var gid = firstgid

		var x = margin
		var y = margin

		var i = 0
		while i < tilecount:
			var tilepos = Vector2(x, y)
			var region = Rect2(tilepos, tilesize)

			var rel_id = str(gid - firstgid)

			result.create_tile(gid)

			if has_global_image:
				result.tile_set_texture(gid, image)
				result.tile_set_region(gid, region)
			elif not rel_id in ts.tiles:
				gid += 1
				continue
			else:
				var image_path = ts.tiles[rel_id].image
				image = load_image(image_path, source_path, options.image_flags)
				if typeof(image) != TYPE_OBJECT:
					# Error happened
					return image
				result.tile_set_texture(gid, image)

			if "tiles" in ts and rel_id in ts.tiles and "objectgroup" in ts.tiles[rel_id] \
					and "objects" in ts.tiles[rel_id].objectgroup:
				for object in ts.tiles[rel_id].objectgroup.objects:

					var shape = shape_from_object(object)

					if typeof(shape) != TYPE_OBJECT:
						# Error happened
						return shape

					var offset = Vector2(float(object.x), float(object.y))
					if "width" in object and "height" in object:
						offset += Vector2(float(object.width) / 2, float(object.height) / 2)

					if object.type == "navigation":
						result.tile_set_navigation_polygon(gid, shape)
						result.tile_set_navigation_polygon_offset(gid, offset)
					elif object.type == "occluder":
						result.tile_set_light_occluder(gid, shape)
						result.tile_set_occluder_offset(gid, offset)
					else:
						result.tile_add_shape(gid, shape, Transform2D(0, offset))

			gid += 1
			i += 1
			x += int(tilesize.x) + spacing
			if x >= int(imagesize.x) - margin:
				x = margin
				y += int(tilesize.y) + spacing

		if str(ts.name) != "":
			result.resource_name = ts.name

	return result

# Loads an image from a given path
# Returns a Texture
func load_image(rel_path, source_path, flags = Texture.FLAGS_DEFAULT):
	var ext = rel_path.get_extension().to_lower()
	if ext != "png" and ext != "jpg":
		printerr("Unsupported image format: %s. Use PNG or JPG instead." % [ext])
		return ERR_FILE_UNRECOGNIZED

	var total_path = rel_path if rel_path.is_abs_path() else source_path.get_base_dir().plus_file(rel_path)
	var dir = Directory.new()
	if not dir.file_exists(total_path):
		printerr("Image not found: %s" % [total_path])
		return ERR_FILE_NOT_FOUND

	var image = ImageTexture.new()
	image.load(total_path)
	image.set_flags(flags)

	return image

# Reads a file and returns its contents as a dictionary
# Returns an error code if fails
func read_file(path):
	var file = File.new()
	var err = file.open(path, File.READ)
	if err != OK:
		return err

	var content = JSON.parse(file.get_as_text())
	if content.error != OK:
		printerr("Error parsing JSON: ", content.error_string)
		return content.error

	return content.result

# Creates a shape from an object data
# Returns a valid shape depending on the object type (collision/occluder/navigation)
func shape_from_object(object):
	var shape = ERR_INVALID_DATA

	if "polygon" in object or "polyline" in object:
		var vertices = PoolVector2Array()

		if "polygon" in object:
			for point in object.polygon:
				vertices.push_back(Vector2(float(point.x), float(point.y)))
		else:
			for point in object.polyline:
				vertices.push_back(Vector2(float(point.x), float(point.y)))

		if object.type == "navigation":
			shape = NavigationPolygon.new()
			shape.vertices = vertices
			shape.add_outline(vertices)
			shape.make_polygons_from_outlines()
		elif object.type == "occluder":
			shape = OccluderPolygon2D.new()
			shape.polygon = vertices
			shape.closed = "polygon" in object
		else:
			if is_convex(vertices):
				shape = ConvexPolygonShape2D.new()
				var sorter = PolygonSorter.new()
				shape.points = sorter.sort_polygon(vertices)
			else:
				shape = ConcavePolygonShape2D.new()
				var segments = [vertices[0]]
				for x in range(1, vertices.size()):
					segments.push_back(vertices[x])
					segments.push_back(vertices[x])
				segments.push_back(vertices[0])
				shape.segments = segments
	elif "ellipse" in object:
		if object.type == "navigation" or object.type == "occluder":
			printerr("Ellipse shapes are not supported as navigation or occluder. Use polygon/polyline instead.")
			return ERR_INVALID_DATA

		if not "width" in object or not "height" in object:
			printerr("Missing width or height in ellipse shape.")
			return ERR_INVALID_DATA

		var w = abs(float(object.width))
		var h = abs(float(object.height))

		if w == h:
			shape = CircleShape2D.new()
			shape.radius = w / 2.0
		else:
			# Using a capsule since it's the closest from an ellipse
			shape = CapsuleShape2D.new()
			shape.radius = w / 2.0
			shape.height = h / 2.0

	else: # Rectangle
		if not "width" in object or not "height" in object:
			printerr("Missing width or height in rectangle shape.")
			return ERR_INVALID_DATA

		var size = Vector2(float(object.width), float(object.height))

		if object.type == "navigation" or object.type == "occluder":
			# Those types only accept polygons, so make one from the rectangle
			var vertices = PoolVector2Array([
					Vector2(0, 0),
					Vector2(size.x, 0),
					size,
					Vector2(0, size.y)
			])
			if object.type == "navigation":
				shape = NavigationPolygon.new()
				shape.vertices = vertices
				shape.add_outline(vertices)
				shape.make_polygons_from_outlines()
			else:
				shape = OccluderPolygon2D.new()
				shape.polygon = vertices
		else:
			shape = RectangleShape2D.new()
			shape.extents = size / 2.0

	return shape

# Determines if the set of vertices is convex or not
# Returns a boolean
func is_convex(vertices):
	var size = vertices.size()
	if size <= 3:
		# Less than 3 verices can't be concave
		return true

	var cp = 0

	for i in range(0, size + 2):
		var p1 = vertices[(i + 0) % size]
		var p2 = vertices[(i + 1) % size]
		var p3 = vertices[(i + 2) % size]

		var prev_cp = cp
		cp = (p2.x - p1.x) * (p3.y - p2.y) - (p2.y - p1.y) * (p3.x - p2.x)
		if i > 0 and sign(cp) != sign(prev_cp):
			return false

	return true

# Decompress the data of the layer
# Compression argument is a string, either "gzip" or "zlib"
func decompress_layer(layer_data, compression, map_size):
	if compression != "gzip" and compression != "zlib":
		printerr("Unrecognized compression format: %s" % [compression])
		return ERR_INVALID_DATA

	var compression_type = File.COMPRESSION_DEFLATE if compression == "zlib" else File.COMPRESSION_GZIP
	var expected_size = int(map_size.x) * int(map_size.y) * 4
	var raw_data = Marshalls.base64_to_raw(layer_data).decompress(expected_size, compression_type)

	return decode_layer(raw_data)

# Reads the layer as a base64 data
# Returns an array of ints as the decoded layer would be
func read_base64_layer(layer_data):
	var decoded = Marshalls.base64_to_raw(layer_data)
	return decode_layer(decoded)

# Reads a PoolByteArray and returns the layer array
# Used for base64 encoded and compressed layers
func decode_layer(layer_data):
	var result = []
	for i in range(0, layer_data.size(), 4):
		var num = (layer_data[i]) | \
				(layer_data[i + 1] << 8) | \
				(layer_data[i + 2] << 16) | \
				(layer_data[i + 3] << 24)
		result.push_back(num)
	return result

# Validates the map dictionary content for missing or invalid keys
# Returns an error code
func validate_map(map):
	if not "type" in map or map.type != "map":
		printerr("Missing or invalid type property.")
		return ERR_INVALID_DATA
	elif not "version" in map or int(map.version) != 1:
		printerr("Missing or invalid map version.")
		return ERR_INVALID_DATA
	elif not "height" in map or not str(map.height).is_valid_integer():
		printerr("Missing or invalid height property.")
		return ERR_INVALID_DATA
	elif not "width" in map or not str(map.width).is_valid_integer():
		printerr("Missing or invalid width property.")
		return ERR_INVALID_DATA
	elif not "tileheight" in map or not str(map.tileheight).is_valid_integer():
		printerr("Missing or invalid tileheight property.")
		return ERR_INVALID_DATA
	elif not "tilewidth" in map or not str(map.tilewidth).is_valid_integer():
		printerr("Missing or invalid tilewidth property.")
		return ERR_INVALID_DATA
	elif not "layers" in map or typeof(map.layers) != TYPE_ARRAY:
		printerr("Missing or invalid layers property.")
		return ERR_INVALID_DATA
	elif not "tilesets" in map or typeof(map.tilesets) != TYPE_ARRAY:
		printerr("Missing or invalid tilesets property.")
		return ERR_INVALID_DATA
	return OK

# Validates the tileset dictionary content for missing or invalid keys
# Returns an error code
func validate_tileset(tileset):
	if not "firstgid" in tileset or not str(tileset.firstgid).is_valid_integer():
		printerr("Missing or invalid firstgid tileset property.")
		return ERR_INVALID_DATA
	elif not "tilewidth" in tileset or not str(tileset.tilewidth).is_valid_integer():
		printerr("Missing or invalid tilewidth tileset property.")
		return ERR_INVALID_DATA
	elif not "tileheight" in tileset or not str(tileset.tileheight).is_valid_integer():
		printerr("Missing or invalid tileheight tileset property.")
		return ERR_INVALID_DATA
	elif not "tilecount" in tileset or not str(tileset.tilecount).is_valid_integer():
		printerr("Missing or invalid tilecount tileset property.")
		return ERR_INVALID_DATA
	elif not "image" in tileset:
		for tile in tileset.tiles:
			if not "image" in tileset.tiles[tile]:
				printerr("Missing or invalid image in tileset property.")
				return ERR_INVALID_DATA
	elif not "imagewidth" in tileset or not str(tileset.imagewidth).is_valid_integer():
		printerr("Missing or invalid imagewidth tileset property.")
		return ERR_INVALID_DATA
	elif not "imageheight" in tileset or not str(tileset.imageheight).is_valid_integer():
		printerr("Missing or invalid imageheight tileset property.")
		return ERR_INVALID_DATA
	return OK

# Validates the layer dictionary content for missing or invalid keys
# Returns an error code
func validate_layer(layer):
	if not "type" in layer:
		printerr("Missing or invalid type layer property.")
		return ERR_INVALID_DATA
	elif not "name" in layer:
		printerr("Missing or invalid name layer property.")
		return ERR_INVALID_DATA
	elif layer.type == "tilelayer":
		if not "data" in layer:
			printerr("Missing data layer property.")
			return ERR_INVALID_DATA
		elif "encoding" in layer:
			if layer.encoding == "base64" and typeof(layer.data) != TYPE_STRING:
				printerr("Invalid data layer property.")
				return ERR_INVALID_DATA
		elif typeof(layer.data) != TYPE_ARRAY:
			printerr("Invalid data layer property.")
			return ERR_INVALID_DATA
		elif "compression" in layer:
			if layer.compression != "gzip" and layer.compression != "zlib":
				printerr("Invalid compression type.")
				return ERR_INVALID_DATA
	elif layer.type == "imagelayer":
		if not "image" in layer or typeof(layer.image) != TYPE_STRING:
			printerr("Missing or invalid image path for layer.")
			return ERR_INVALID_DATA
	elif layer.type == "objectgroup":
		if not "objects" in layer or typeof(layer.objects) != TYPE_ARRAY:
			printerr("Missing or invalid objects array for layer.")
			return ERR_INVALID_DATA
	return OK
