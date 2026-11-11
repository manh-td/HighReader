extends Node
## Autoload "Pdf": thin wrapper around the Android "PdfReader" plugin.
## On desktop the plugin is missing and is_available() returns false.

var _plugin: Object = null


func _ready() -> void:
	if Engine.has_singleton("PdfReader"):
		_plugin = Engine.get_singleton("PdfReader")
	else:
		push_warning("PdfReader plugin not found: PDF features only work in the Android build.")


func is_available() -> bool:
	return _plugin != null


func pick_pdf() -> void:
	if _plugin:
		_plugin.pickPdf()


## "" while idle, "pending", "cancelled", "error:<msg>" or "ok:<path>".
func poll_pick() -> String:
	return _plugin.pollPick() if _plugin else ""


func list_library() -> Array:
	if not _plugin:
		return []
	var data = JSON.parse_string(_plugin.listLibrary())
	return data if data is Array else []


func delete_from_library(path: String) -> bool:
	return _plugin.deleteFromLibrary(path) if _plugin else false


## Returns {"name":..., "pages":[[w,h],...]} or {} on failure.
func open_pdf(path: String) -> Dictionary:
	if not _plugin:
		return {}
	var raw: String = _plugin.openPdf(path)
	if raw.is_empty():
		return {}
	var data = JSON.parse_string(raw)
	return data if data is Dictionary else {}


## Renders one page `width` pixels wide. Returns null on failure.
func render_page(index: int, width: int) -> Texture2D:
	if not _plugin:
		return null
	var bytes: PackedByteArray = _plugin.renderPage(index, width)
	if bytes.is_empty():
		return null
	var height := bytes.size() / (4 * width)
	var img := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, bytes)
	return ImageTexture.create_from_image(img)


func close_pdf() -> void:
	if _plugin:
		_plugin.closePdf()


func start_analysis() -> bool:
	return _plugin.startAnalysis() if _plugin else false


## "idle", "running", "done" or "error".
func analysis_state() -> String:
	return _plugin.getAnalysisState() if _plugin else "error"


func analysis_progress() -> float:
	return _plugin.getAnalysisProgress() if _plugin else 0.0


func analysis_result() -> Dictionary:
	if not _plugin:
		return {}
	var data = JSON.parse_string(_plugin.getAnalysisResult())
	return data if data is Dictionary else {}


## Folder with papers, cache and progress (Documents/HighReader on Android), or "".
func storage_dir() -> String:
	return _plugin.getStorageDir() if _plugin else ""


## Path for a small data file: in the storage folder when it is writable, else user://.
func data_path(file_name: String) -> String:
	var dir := storage_dir()
	if not dir.is_empty():
		var path := dir.path_join(file_name)
		var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
		if f:
			f.close()
			return path
	return "user://" + file_name


func last_error() -> String:
	return _plugin.getLastError() if _plugin else "PDF plugin is only available on Android."
