#!/usr/bin/env lua
-- labuild.lua — High-performance hybrid Lua/Crystal driver for abuild (apk v3)

local VERSION = "0.2.0"

-- Configuration and paths passed from the environment
local ROOT = os.getenv("LABUILD_ROOT") or "."
local LABUILD_CORE = os.getenv("LABUILD_CORE") or (ROOT .. "/bin/labuild-core")
local LABUILD_SH = os.getenv("LABUILD_SH") or (ROOT .. "../share/labuild/labuild-sh.sh")
local APK_BIN = os.getenv("APK") or (ROOT .. "/bin/apk")
local SHAREDIR = os.getenv("ABUILD_SHAREDIR") or (ROOT .. "/share")

-- ANSI color helpers
local use_color = true
local function col(c, str)
	if not use_color then return str end
	local codes = {
		green = "\27[1;32m",
		blue = "\27[1;34m",
		yellow = "\27[1;33m",
		red = "\27[1;31m",
		reset = "\27[0m",
		bold = "\27[1m"
	}
	return (codes[c] or "") .. str .. codes.reset
end

local function msg_ok(fmt, ...)
	io.stdout:write(col("green", ">>> ") .. string.format(fmt, ...) .. "\n")
end

local function msg_info(fmt, ...)
	io.stdout:write(col("blue", ">>> ") .. string.format(fmt, ...) .. "\n")
end

local function msg_warn(fmt, ...)
	io.stderr:write(col("yellow", ">>> WARNING: ") .. string.format(fmt, ...) .. "\n")
end

local function msg_err(fmt, ...)
	io.stderr:write(col("red", ">>> ERROR: ") .. string.format(fmt, ...) .. "\n")
end

local function die(fmt, ...)
	msg_err(fmt, ...)
	os.exit(1)
end

-- Execute a shell command and return success (boolean), exit code (number)
local function sh_exec(cmd)
	local res1, res2, res3 = os.execute(cmd)
	-- Compatibility between Lua 5.1/LuaJIT (returns status integer) and Lua 5.2+ (returns true/false, "exit", code)
	if type(res1) == "boolean" then
		return res1, res3
	else
		return (res1 == 0), res1
	end
end

-- Read command output into string
local function sh_capture(cmd)
	local pipe = io.popen(cmd, "r")
	if not pipe then return "" end
	local out = pipe:read("*a")
	pipe:close()
	return out or ""
end

-- Parse CLI options
local options = {
	force = false,
	nodeps = false,
	rootbld = false,
	keep = false,
	quiet = false,
	verbose = false,
	repodest = nil,
	srcdest = nil,
	targets = {},
	apkbuild = "APKBUILD"
}

local function parse_args(arg)
	local i = 1
	while i <= #arg do
		local a = arg[i]
		if a == "-f" or a == "--force" then
			options.force = true
		elseif a == "-d" or a == "--nodeps" then
			options.nodeps = true
		elseif a == "-r" or a == "--rootbld" then
			options.rootbld = true
		elseif a == "-k" or a == "--keep" then
			options.keep = true
		elseif a == "-q" or a == "--quiet" then
			options.quiet = true
		elseif a == "-v" or a == "--verbose" then
			options.verbose = true
		elseif a == "--nocolor" then
			use_color = false
		elseif a == "-P" or a == "--pkgdir" or a == "--repodest" then
			i = i + 1
			options.repodest = arg[i]
		elseif a == "-s" or a == "--srcdest" then
			i = i + 1
			options.srcdest = arg[i]
		elseif a == "-h" or a == "--help" then
			print("labuild " .. VERSION .. " — fast hybrid abuild for apk v3")
			print("Usage: labuild [options] [target...]")
			print("\nTargets:")
			print("  all          Full build pipeline (default)")
			print("  fetch        Download source files")
			print("  verify       Verify source checksums")
			print("  checksum     Update checksums in APKBUILD")
			print("  unpack       Extract sources to $srcdir")
			print("  prepare      Apply patches and run prepare()")
			print("  build        Compile software")
			print("  check        Run test suite")
			print("  package      Install files and create apk v3 packages")
			print("  rootpkg      Package using fakeroot")
			print("  index        Update Packages.adb repository index")
			print("  srcpkg       Create source tarball (.src.tar.gz)")
			print("  clean        Remove build directories")
			print("  cleancache   Remove downloaded source files")
			print("\nOptions:")
			print("  -f, --force      Force rebuild even if packages exist")
			print("  -P <dir>         Target repository directory (REPODEST)")
			print("  -s <dir>         Download directory for sources (SRCDEST)")
			print("  -k, --keep       Keep build directory after build")
			print("  -d, --nodeps     Skip dependency checks")
			print("  -r, --rootbld    Install missing dependencies with apk")
			print("  --nocolor        Disable colored terminal output")
			print("  -h, --help       Show this help message")
			print("  -V, --version    Show version")
			os.exit(0)
		elseif a == "-V" or a == "--version" then
			print("labuild " .. VERSION)
			os.exit(0)
		elseif a:sub(1, 1) == "-" then
			die("Unknown option: %s", a)
		else
			table.insert(options.targets, a)
		end
		i = i + 1
	end
	if #options.targets == 0 then
		table.insert(options.targets, "all")
	end
end

parse_args(arg or {})

-- Load APKBUILD metadata through labuild-sh.sh dump
local function load_pkg(apkbuild_path)
	local cmd = string.format("%q dump %q", LABUILD_SH, apkbuild_path)
	local dump_out = sh_capture(cmd)
	if dump_out == "" then
		die("Failed to parse %s", apkbuild_path)
	end

	local meta = {
		vars = {},
		funcs = {}
	}
	for line in dump_out:gmatch("[^\r\n]+") do
		local kind, k, v = line:match("^(%w+)\t([^\t]+)\t?(.*)$")
		if kind == "VAR" then
			meta.vars[k] = v or ""
		elseif kind == "FUNC" then
			meta.funcs[k] = true
		end
	end

	return meta
end

local meta = load_pkg(options.apkbuild)
local vars = meta.vars
local funcs = meta.funcs

-- Apply CLI overrides
if options.repodest then
	vars.REPODEST = options.repodest
end
if options.srcdest then
	vars.SRCDEST = options.srcdest
	vars.srcdir = vars.SRCDEST .. "/src"
end

local pkgname = vars.pkgname or ""
local pkgver = vars.pkgver or ""
local pkgrel = vars.pkgrel or "0"
local arch = vars.arch or "all"
local carch = vars.CARCH or "x86_64"
local repodest = vars.REPODEST or os.getenv("REPODEST") or (vars.startdir .. "/packages")
local srcdir = vars.srcdir or (vars.startdir .. "/src")
local pkgbasedir = vars.pkgbasedir or (vars.startdir .. "/pkg")
local pkgdir = pkgbasedir .. "/" .. pkgname

-- Directory where built packages for this architecture go
local function repo_arch_dir()
	local a = (arch == "noarch") and "noarch" or carch
	return repodest .. "/" .. a
end

-- File helpers
local function file_exists(p)
	local f = io.open(p, "rb")
	if f then f:close(); return true end
	return false
end

local function dir_exists(p)
	local ok, _ = sh_exec(string.format("test -d %q", p))
	return ok
end

local function mkdir_p(p)
	sh_exec(string.format("mkdir -p %q", p))
end

local function rm_rf(p)
	sh_exec(string.format("rm -rf %q", p))
end

-- Check if options string contains an option (e.g. "!check", "!archcheck")
local function has_option(opt)
	if not vars.options then return false end
	for word in vars.options:gmatch("%S+") do
		if word == opt then return true end
	end
	return false
end

-- Check if packages are already built
local function package_target_path(pname, pver, prel, parch)
	local actual_arch = (parch == "noarch" or parch == "all") and carch or parch
	local dest_dir = repodest .. "/" .. actual_arch
	local fname = string.format("%s-%s-r%s.apk", pname, pver, prel)
	return dest_dir .. "/" .. fname
end

-- Pipeline Actions

local function do_clean()
	msg_info("Cleaning build directories...")
	rm_rf(srcdir)
	rm_rf(pkgbasedir)
end

local function do_cleancache()
	msg_info("Cleaning downloaded source cache...")
	for s in (vars.source or ""):gmatch("%S+") do
		local fname = s:match("^([^:]+)::") or s:match("([^/]+)$") or s
		local fpath = (vars.SRCDEST or vars.startdir) .. "/" .. fname
		if file_exists(fpath) then
			os.remove(fpath)
		end
	end
end

local function do_fetch()
	msg_info("Fetching sources for %s-%s-r%s...", pkgname, pkgver, pkgrel)
	local dest = vars.SRCDEST or vars.startdir
	mkdir_p(dest)

	for item in (vars.source or ""):gmatch("%S+") do
		local custom_name, url = item:match("^([^:]+)::(https?://.+)$")
		if not custom_name then
			url = item
			custom_name = item:match("([^/]+)$") or item
		end

		if url:match("^https?://") or url:match("^ftp://") then
			local target_file = dest .. "/" .. custom_name
			if not file_exists(target_file) then
				msg_info("Downloading %s -> %s", url, custom_name)
				local cmd = string.format("curl -sSL -f -o %q %q || wget -q -O %q %q",
					target_file, url, target_file, url)
				local ok = sh_exec(cmd)
				if not ok or not file_exists(target_file) then
					die("Failed to download %s", url)
				end
			else
				if options.verbose then
					msg_info("Already downloaded: %s", custom_name)
				end
			end
		end
	end
end

local function do_verify()
	msg_info("Verifying source checksums...")
	local src_root = vars.SRCDEST or vars.startdir

	local function verify_with_algo(algo)
		local sums = {}
		local in_sums = false
		local apk_file = io.open(options.apkbuild, "r")
		if not apk_file then return false end
		for line in apk_file:lines() do
			if line:match("^" .. algo .. "sums=") then
				in_sums = true
			elseif in_sums then
				if line:match("^[\"']") then
					break
				end
				local hash, fn = line:match("^%s*([%x]+)%s+(%S+)")
				if hash and fn then
					sums[fn] = hash
				end
				if line:match("[\"']%s*$") then
					break
				end
			end
		end
		apk_file:close()

		local verified = 0
		for fn, expected in pairs(sums) do
			local p = src_root .. "/" .. fn
			if not file_exists(p) then
				p = vars.startdir .. "/" .. fn
			end
			if not file_exists(p) then
				die("Source file %s not found for checksum verification", fn)
			end
			local cmd = string.format("%q verify --algo %s %q %q", LABUILD_CORE, algo, p, expected)
			local ok = sh_exec(cmd)
			if not ok then
				die("Checksum mismatch for %s", fn)
			end
			verified = verified + 1
		end
		return (verified > 0)
	end

	local ok = verify_with_algo("sha512")
	if not ok then
		ok = verify_with_algo("sha256")
	end
	if not ok then
		ok = verify_with_algo("md5")
	end
	if ok then
		msg_ok("All source checksums verified.")
	else
		msg_warn("No checksums found in %s to verify.", options.apkbuild)
	end
end

local function do_checksum()
	do_fetch()
	msg_info("Updating checksums in %s...", options.apkbuild)
	local files = {}
	local src_root = vars.SRCDEST or vars.startdir
	for item in (vars.source or ""):gmatch("%S+") do
		local custom_name = item:match("^([^:]+)::") or item:match("([^/]+)$") or item
		local p = src_root .. "/" .. custom_name
		if not file_exists(p) then
			p = vars.startdir .. "/" .. custom_name
		end
		if file_exists(p) then
			table.insert(files, p)
		end
	end

	local quoted_files = {}
	for _, f in ipairs(files) do
		table.insert(quoted_files, string.format("%q", f))
	end

	local cmd = string.format("%q checksum-write %q %s",
		LABUILD_CORE, options.apkbuild, table.concat(quoted_files, " "))
	local ok = sh_exec(cmd)
	if not ok then
		die("Failed to update checksums in %s", options.apkbuild)
	end
	msg_ok("Updated checksums in %s", options.apkbuild)
end

local function do_unpack()
	msg_info("Unpacking sources into %s...", srcdir)
	mkdir_p(srcdir)
	local src_root = vars.SRCDEST or vars.startdir

	for item in (vars.source or ""):gmatch("%S+") do
		local fn = item:match("^([^:]+)::") or item:match("([^/]+)$") or item
		local path = src_root .. "/" .. fn
		if not file_exists(path) then
			path = vars.startdir .. "/" .. fn
		end

		if file_exists(path) then
			if fn:match("%.tar%.gz$") or fn:match("%.tgz$") then
				sh_exec(string.format("tar -xzf %q -C %q", path, srcdir))
			elseif fn:match("%.tar%.bz2$") or fn:match("%.tbz2$") then
				sh_exec(string.format("tar -xjf %q -C %q", path, srcdir))
			elseif fn:match("%.tar%.xz$") or fn:match("%.txz$") then
				sh_exec(string.format("tar -xJf %q -C %q", path, srcdir))
			elseif fn:match("%.tar%.zst$") or fn:match("%.tzst$") then
				sh_exec(string.format("zstd -dc %q | tar -xf - -C %q", path, srcdir))
			elseif fn:match("%.zip$") then
				sh_exec(string.format("unzip -q -o %q -d %q", path, srcdir))
			else
				-- Plain file or patch: copy to srcdir
				sh_exec(string.format("cp -f %q %q/", path, srcdir))
			end
		end
	end
end

local function do_prepare()
	if funcs["prepare"] then
		msg_info("Running prepare()...")
		local ok = sh_exec(string.format("%q run prepare %q", LABUILD_SH, options.apkbuild))
		if not ok then die("prepare() failed") end
	else
		-- Default prepare: apply *.patch from source
		sh_exec(string.format("%q run default_prepare %q", LABUILD_SH, options.apkbuild))
	end
end

local function do_build()
	if funcs["build"] then
		msg_info("Running build()...")
		local ok = sh_exec(string.format("%q run build %q", LABUILD_SH, options.apkbuild))
		if not ok then die("build() failed") end
	end
end

local function do_check()
	if has_option("!check") then
		if options.verbose then msg_info("Tests disabled by !check option") end
		return
	end
	if funcs["check"] then
		msg_info("Running check()...")
		local ok = sh_exec(string.format("%q run check %q", LABUILD_SH, options.apkbuild))
		if not ok then die("check() failed") end
	end
end

-- Scan ELF binaries, resolve needed and provided sonames
local function analyze_elf(dir)
	local elf_cmd = string.format("%q elf %q", LABUILD_CORE, dir)
	local out = sh_capture(elf_cmd)

	local sonames = {}
	local needed = {}
	local rpaths = {}

	for line in out:gmatch("[^\r\n]+") do
		local kind, val, rel = line:match("^([^\t]+)\t([^\t]+)\t?(.*)$")
		if kind == "soname" then
			sonames[val] = true
		elseif kind == "needed" then
			needed[val] = true
		elseif kind == "rpath" then
			table.insert(rpaths, val)
		end
	end

	return sonames, needed, rpaths
end

-- Create an apk v3 package file via apk mkpkg
local function build_apk_file(pname, pver, prel, parch, pdir, pmeta)
	local actual_arch = parch
	if actual_arch == "all" or actual_arch == "noarch" then
		actual_arch = carch
	end
	local out_arch = (parch == "noarch") and carch or actual_arch
	local out_dir = repodest .. "/" .. out_arch
	mkdir_p(out_dir)

	local out_pkg = string.format("%s/%s-%s-r%s.apk", out_dir, pname, pver, prel)
	local full_ver = string.format("%s-r%s", pver, prel)

	-- Arch check for noarch
	if parch == "noarch" and not has_option("!archcheck") then
		local archbin_cmd = string.format("%q archbin %q", LABUILD_CORE, pdir)
		local ok = sh_exec(archbin_cmd)
		if ok then
			die("Arch specific binaries found in noarch package %s", pname)
		end
	end

	-- Size calculation
	local size_cmd = string.format("%q size %q", LABUILD_CORE, pdir)
	local size_str = sh_capture(size_cmd):match("(%d+)") or "0"

	local pkg_arch = (parch == "all") and carch or parch

	-- Build mkpkg arguments
	local args = {
		string.format("-I name:%q", pname),
		string.format("-I version:%q", full_ver),
		string.format("-I arch:%q", pkg_arch),
		string.format("-I description:%q", pmeta.desc or vars.pkgdesc or ""),
		string.format("-I url:%q", vars.url or ""),
		string.format("-I license:%q", vars.license or ""),
		string.format("-I origin:%q", vars.origin or vars.pkgname or pname),
		string.format("-I maintainer:%q", vars.maintainer or vars.PACKAGER or ""),
		string.format("-I build-time:%q", os.time())
	}

	if vars.provider_priority and vars.provider_priority ~= "" then
		table.insert(args, string.format("-I provider-priority:%q", vars.provider_priority))
	end
	if vars.replaces_priority and vars.replaces_priority ~= "" then
		table.insert(args, string.format("-I replaces-priority:%q", vars.replaces_priority))
	end
	if vars.install_if and vars.install_if ~= "" then
		table.insert(args, string.format("-I install-if:%q", vars.install_if))
	end

	-- Dependencies (including auto-discovered ELF sonames)
	local deps = {}
	for d in (pmeta.depends or vars.depends or ""):gmatch("%S+") do
		table.insert(deps, d)
	end
	for soname in pairs(pmeta.needed_sonames or {}) do
		table.insert(deps, "so:" .. soname)
	end
	if #deps > 0 then
		table.insert(args, string.format("-I \"depends:%s\"", table.concat(deps, " ")))
	end

	-- Provides (including provided sonames)
	local provides = {}
	for pr in (pmeta.provides or vars.provides or ""):gmatch("%S+") do
		table.insert(provides, pr)
	end
	for soname in pairs(pmeta.provided_sonames or {}) do
		if has_option("!sover") then
			table.insert(provides, "so:" .. soname)
		else
			table.insert(provides, string.format("so:%s=%s", soname, pver))
		end
	end
	if #provides > 0 then
		table.insert(args, string.format("-I \"provides:%s\"", table.concat(provides, " ")))
	end

	if vars.replaces and vars.replaces ~= "" then
		table.insert(args, string.format("-I \"replaces:%s\"", vars.replaces))
	end

	-- Trigger files
	if vars.triggers and vars.triggers ~= "" then
		for t in vars.triggers:gmatch("%S+") do
			table.insert(args, string.format("--trigger %q", t))
		end
	end

	-- Install scripts: .pre-install, .post-install, etc.
	local script_types = {
		"pre-install", "post-install", "pre-upgrade", "post-upgrade",
		"pre-deinstall", "post-deinstall", "trigger"
	}
	for _, st in ipairs(script_types) do
		local sfile = vars.startdir .. "/" .. pname .. "." .. st
		if file_exists(sfile) then
			table.insert(args, string.format("-s %s:%q", st, sfile))
		end
	end

	-- Signing key
	local privkey = vars.PACKAGER_PRIVKEY
	if privkey and privkey ~= "" and file_exists(privkey) then
		table.insert(args, string.format("--sign-key %q", privkey))
	end

	-- Compression
	local comp = vars.APK_COMPRESSION or "zstd"
	table.insert(args, string.format("-c %s", comp))

	-- Package filesystem and output
	table.insert(args, string.format("-F %q", pdir))
	table.insert(args, string.format("-o %q", out_pkg))

	local mkpkg_cmd = string.format("%q mkpkg %s", APK_BIN, table.concat(args, " "))
	if options.verbose then
		print("Running: " .. mkpkg_cmd)
	end
	local ok = sh_exec(mkpkg_cmd)
	if not ok then
		die("Failed to create package %s with apk mkpkg", out_pkg)
	end
	msg_ok("Created package: %s", out_pkg)
	return out_pkg
end

local function do_package()
	msg_info("Running package()...")
	rm_rf(pkgbasedir)
	mkdir_p(pkgdir)

	if funcs["package"] then
		local ok = sh_exec(string.format("%q run package %q", LABUILD_SH, options.apkbuild))
		if not ok then die("package() failed") end
	end

	-- Process subpackages
	local created_packages = {}
	local subpkg_list = {}
	for sp in (vars.subpackages or ""):gmatch("%S+") do
		local sname, sfunc = sp:match("^([^:]+):?(.*)$")
		if sfunc == "" then sfunc = nil end
		table.insert(subpkg_list, {name = sname, func = sfunc})
	end

	for _, sp in ipairs(subpkg_list) do
		local sname = sp.name
		local sfunc = sp.func
		local sdir = pkgbasedir .. "/" .. sname
		mkdir_p(sdir)

		if sname:match("%-doc$") then
			msg_info("Processing doc subpackage: %s", sname)
			-- Move man, doc, info
			for _, d in ipairs({"usr/share/man", "usr/share/doc", "usr/share/info"}) do
				local src = pkgdir .. "/" .. d
				if dir_exists(src) then
					mkdir_p(sdir .. "/" .. d:match("(.+)/[^/]+$"))
					sh_exec(string.format("mv %q %q", src, sdir .. "/" .. d))
				end
			end
			-- Compress man pages via labuild-core doc
			local doc_comp = vars.DOC_COMPRESSION or "zstd"
			sh_exec(string.format("%q doc %q %s", LABUILD_CORE, sdir, doc_comp))

		elseif sname:match("%-dev$") then
			msg_info("Processing dev subpackage: %s", sname)
			for _, d in ipairs({"usr/include", "usr/lib/pkgconfig", "usr/share/pkgconfig", "usr/share/aclocal"}) do
				local src = pkgdir .. "/" .. d
				if dir_exists(src) then
					mkdir_p(sdir .. "/" .. (d:match("(.+)/[^/]+$") or ""))
					sh_exec(string.format("mv %q %q", src, sdir .. "/" .. d))
				end
			end
			-- Move static libraries (*.a) and development .so symlinks
			sh_exec(string.format("find %q -name '*.a' -exec mv {} %q/ \\; 2>/dev/null || true", pkgdir, sdir))
		elseif sfunc and funcs[sfunc] then
			msg_info("Running custom subpackage function %s()...", sfunc)
			local ok = sh_exec(string.format("%q run %q %q %q", LABUILD_SH, sfunc, options.apkbuild, sdir))
			if not ok then die("Subpackage function %s() failed", sfunc) end
		end

		local sonames, needed = analyze_elf(sdir)
		local pmeta = {
			desc = (vars.pkgdesc or "") .. " (" .. sname .. ")",
			provided_sonames = sonames,
			needed_sonames = needed
		}
		local sarch = (sname:match("%-doc$") and "noarch") or arch
		local apk = build_apk_file(sname, pkgver, pkgrel, sarch, sdir, pmeta)
		table.insert(created_packages, apk)
	end

	-- Package main package
	local sonames, needed = analyze_elf(pkgdir)
	local pmeta = {
		desc = vars.pkgdesc,
		provided_sonames = sonames,
		needed_sonames = needed
	}
	local main_apk = build_apk_file(pkgname, pkgver, pkgrel, arch, pkgdir, pmeta)
	table.insert(created_packages, main_apk)

	return created_packages
end

local function do_index()
	msg_info("Updating repository index (Packages.adb)...")
	local actual_arch = (arch == "noarch" or arch == "all") and carch or arch
	local repo_dir = repodest .. "/" .. actual_arch
	if not dir_exists(repo_dir) then
		msg_warn("Repository directory %s does not exist, skipping index", repo_dir)
		return
	end

	local index_file = vars.APK_INDEX_FILE or "Packages.adb"
	local index_path = repo_dir .. "/" .. index_file
	local comp = vars.APK_COMPRESSION or "zstd"

	local args = {
		string.format("-c %s", comp),
		string.format("--output %q", index_path),
		string.format("--description %q", "labuild repository " .. actual_arch)
	}

	if file_exists(index_path) then
		table.insert(args, string.format("--index %q", index_path))
	end

	local privkey = vars.PACKAGER_PRIVKEY
	if privkey and privkey ~= "" and file_exists(privkey) then
		table.insert(args, string.format("--sign-key %q", privkey))
	end

	table.insert(args, string.format("%s/*.apk", repo_dir))

	local cmd = string.format("%q --allow-untrusted mkndx %s", APK_BIN, table.concat(args, " "))
	local ok = sh_exec(cmd)
	if not ok then
		die("Failed to update index %s", index_path)
	end
	msg_ok("Repository index updated: %s", index_path)
end

local function do_srcpkg()
	msg_info("Building source package (.src.tar.gz)...")
	local out_arch = (arch == "noarch" or arch == "all") and carch or arch
	local out_dir = repodest .. "/" .. out_arch
	mkdir_p(out_dir)

	local src_tar = string.format("%s/%s-%s-r%s.src.tar.gz", out_dir, pkgname, pkgver, pkgrel)
	local prefix = pkgname

	local files = {"APKBUILD"}
	for item in (vars.source or ""):gmatch("%S+") do
		local fn = item:match("^([^:]+)::") or item:match("([^/]+)$") or item
		table.insert(files, fn)
	end

	local quoted = {}
	for _, f in ipairs(files) do
		table.insert(quoted, string.format("%q", f))
	end

	local cmd = string.format("cd %q && %q srcpkg %q %q %s",
		vars.startdir, LABUILD_CORE, src_tar, prefix, table.concat(quoted, " "))
	local ok = sh_exec(cmd)
	if not ok then
		die("Failed to build source package %s", src_tar)
	end
	msg_ok("Source package created: %s", src_tar)
end

-- Target Dispatcher
for _, target in ipairs(options.targets) do
	if target == "clean" then
		do_clean()
	elseif target == "cleancache" then
		do_cleancache()
	elseif target == "fetch" then
		do_fetch()
	elseif target == "verify" then
		do_verify()
	elseif target == "checksum" then
		do_checksum()
	elseif target == "unpack" then
		do_unpack()
	elseif target == "prepare" then
		do_unpack()
		do_prepare()
	elseif target == "build" then
		do_unpack()
		do_prepare()
		do_build()
	elseif target == "check" then
		do_check()
	elseif target == "package" or target == "rootpkg" then
		do_package()
	elseif target == "index" then
		do_index()
	elseif target == "srcpkg" then
		do_srcpkg()
	elseif target == "all" then
		-- Check if package already exists
		local main_target = package_target_path(pkgname, pkgver, pkgrel, arch)
		if file_exists(main_target) and not options.force then
			msg_info("Package %s is already up to date. (Use -f to rebuild)", main_target)
		else
			do_clean()
			do_fetch()
			do_verify()
			do_unpack()
			do_prepare()
			do_build()
			do_check()
			do_package()
			do_index()
			if not options.keep then
				rm_rf(srcdir)
				rm_rf(pkgbasedir)
			end
			msg_ok("Build complete for %s-%s-r%s!", pkgname, pkgver, pkgrel)
		end
	else
		die("Unknown target: %s", target)
	end
end
