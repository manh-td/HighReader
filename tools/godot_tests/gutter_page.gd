extends SceneTree
## Re-runs the analyzer's column-gap search on one page, from saved word positions.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var data = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	for pg_s in args.slice(1):
		var pg := int(pg_s)
		var pw: float = data["pages"][pg][0]
		var words := []
		for l in data["lines"]:
			if int(l["p"]) != pg:
				continue
			for k in l["ws"].size():
				words.append([float(l["wx"][2 * k]) * pw, float(l["wx"][2 * k + 1]) * pw, float(l["s"])])
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
		var cov := []
		for x in range(left, right + 1):
			cov.append(bins[x])
		cov.sort()
		var peak: int = cov[mini(int(cov.size() * 0.9), cov.size() - 1)]
		var threshold := maxi(1, int(peak * 0.12))
		var sizes := words.map(func(w): return w[2]); sizes.sort()
		var size: float = sizes[sizes.size() / 2]
		print("page %d: words=%d pw=%.0f left=%d right=%d peak=%d threshold=%d size=%.1f margin=%d" % [pg + 1, words.size(), pw, left, right, peak, threshold, size, int((right - left) * 0.1)])
		var lowruns := []
		var x := left
		while x <= right:
			if bins[x] <= threshold:
				var s := x
				while x <= right and bins[x] <= threshold:
					x += 1
				lowruns.append("%d-%d" % [s, x])
			x += 1
		print("  low-coverage runs: ", lowruns)
		var row := ""
		for xx in range(int(pw * 0.6), int(pw * 0.8)):
			row += "%d " % bins[xx]
		print("  coverage %d..%d: %s" % [int(pw * 0.6), int(pw * 0.8), row])
	quit()
