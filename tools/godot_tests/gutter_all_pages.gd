extends SceneTree
## Full column-gap detection (same rules as the analyzer) over every page.

func detect(words: Array, pw: float, min_w_factor: float, min_abs: float) -> Array:
	if words.size() < 60:
		return []
	var n := int(pw) + 2
	var bins := []
	bins.resize(n)
	bins.fill(0)
	for w in words:
		for x in range(clampi(int(w[0]), 0, n - 1), clampi(int(w[1]), 0, n - 1) + 1):
			bins[x] += 1
	var x0s := words.map(func(w): return w[0]); x0s.sort()
	var x1s := words.map(func(w): return w[1]); x1s.sort()
	var left := int(x0s[int(x0s.size() * 0.03)])
	var right := int(x1s[mini(int(x1s.size() * 0.97), x1s.size() - 1)])
	if right - left < pw * 0.3:
		return []
	var cov := []
	for x in range(left, right + 1):
		cov.append(bins[x])
	cov.sort()
	var peak: int = cov[mini(int(cov.size() * 0.9), cov.size() - 1)]
	if peak < 10:
		return []
	var threshold := maxi(1, int(peak * 0.12))
	var sizes := words.map(func(w): return w[2]); sizes.sort()
	var size: float = sizes[sizes.size() / 2]
	var min_width: float = max(min_abs, min_w_factor * size)
	var margin := int((right - left) * 0.1)
	var out := []
	var x := left + margin
	while x <= right - margin:
		if bins[x] > threshold:
			x += 1
			continue
		var s := x
		while x <= right - margin and bins[x] <= threshold:
			x += 1
		var e := x
		if e - s < min_width:
			continue
		var ending := words.filter(func(w): return w[1] >= s - 2.5 * size and w[1] <= s + 1).size()
		var starting := words.filter(func(w): return w[0] >= e - 1 and w[0] <= e + 2.5 * size).size()
		var lw := words.filter(func(w): return w[1] <= s + 1).size()
		var rw := words.filter(func(w): return w[0] >= e - 1).size()
		if ending >= 8 and starting >= 8 and lw >= 30 and rw >= 30:
			out.append([(s + e) / 2.0, e - s])
	# Columns must be at least 12% of the page wide: of gaps closer than that, keep the wider.
	out.sort_custom(func(a, b): return a[1] > b[1])
	var kept := []
	for c in out:
		var ok: bool = c[0] - left >= pw * 0.12 and right - c[0] >= pw * 0.12
		for k in kept:
			if absf(c[0] - k) < pw * 0.12:
				ok = false
		if ok:
			kept.append(c[0])
	kept.sort()
	return kept

func _init() -> void:
	for path in OS.get_cmdline_user_args():
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		var per_page := {}
		for l in data["lines"]:
			var p := int(l["p"])
			if not per_page.has(p):
				per_page[p] = []
			var pw: float = data["pages"][p][0]
			for k in l["ws"].size():
				per_page[p].append([float(l["wx"][2 * k]) * pw, float(l["wx"][2 * k + 1]) * pw, float(l["s"])])
		for variant in [[0.5, 4.0], [0.25, 2.5]]:
			var found := 0
			var multi := 0
			var mid_hits := 0
			for p in per_page:
				var g := detect(per_page[p], data["pages"][p][0], variant[0], variant[1])
				if g.size() > 0:
					found += 1
				if g.size() > 1:
					multi += 1
					if variant[0] < 0.3:
						print("  page %d gaps at %s (page width %.0f)" % [p + 1, str(g), data["pages"][p][0]])
			print("%s minWidth=max(%.1f, %.2f*size): gaps on %d of %d pages (%d with 2+ gaps)" % [path.get_file().left(24), variant[1], variant[0], found, data["pages"].size(), multi])
	quit()
