
setfenv(1, require'app')

local glue = require'glue'
local lp = require'luapower'
local pp = require'pp'
local lfs = require'lfs'
local tuple = require'tuple'
local zip = require'minizip'
local luapower_dir = config'luapower_dir'
package.loaded.grep = nil
local grep = require'grep'

lp.config('luapower_dir', luapower_dir)
lp.config('servers').linux64 = nil

--helpers --------------------------------------------------------------------

function render_main(name, data, env)
	return render('main.html',
		data,
		glue.merge({
			content = readfile(name),
		}, env)
	)
end

local function rel_time(s)
	if s > 2 * 365 * 24 * 3600 then
		return ('%d years'):format(math.floor(s / (365 * 24 * 3600)))
	elseif s > 2 * 30.5 * 24 * 3600 then
		return ('%d months'):format(math.floor(s / (30.5 * 24 * 3600)))
	elseif s > 1.5 * 24 * 3600 then
		return ('%d days'):format(math.floor(s / (24 * 3600)))
	elseif s > 2 * 3600 then
		return ('%d hours'):format(math.floor(s / 3600))
	elseif s > 2 * 60 then
		return ('%d minutes'):format(math.floor(s / 60))
	else
		return 'a minute'
	end
end

local function timeago(time)
	local s = os.difftime(os.time(), time)
	return string.format(s > 0 and '%s ago' or 'in %s', rel_time(math.abs(s)))
end

--actions --------------------------------------------------------------------

--doc rendering

local function older(file1, file2)
	local mtime1 = lfs.attributes(file1, 'modification')
	local mtime2 = lfs.attributes(file2, 'modification')
	if not mtime1 then return true end
	if not mtime2 then return false end
	return mtime1 < mtime2
end

local function md_refs()
	local t = {}
	local refs = {}
	local function addref(s)
		if refs[s] then return end
		table.insert(t, string.format('[%s]: /%s', s, s))
		refs[s] = true
	end
	--add refs in the order in which uris are dispatched.
	for pkg in pairs(lp.installed_packages()) do
		addref(pkg)
	end
	for doc in pairs(lp.docs()) do
		addref(doc)
	end
	for mod in pairs(lp.modules()) do
		addref(mod)
	end
	for file in lfs.dir(wwwpath'md') do
		if file:find'%.md$' then
			addref(file:match'^(.-)%.md$')
		end
	end
	table.insert(t, glue.readfile(wwwpath'ext-links.md'))
	return table.concat(t, '\n')
end

local function render_docfile(infile)
	local outfile = wwwpath('docs/'..escape_filename(infile)..'.html')
	if older(outfile, infile) then
		local s1 = glue.readfile(infile)
		local s2 = md_refs()
		local tmpfile = os.tmpname()
		glue.writefile(tmpfile, s1..'\n\n'..s2)
		local cmd = 'pandoc --tab-stop=3 -r markdown -w html '..
			tmpfile..' > '..outfile
		os.execute(cmd)
		os.remove(tmpfile)
	end
	return glue.readfile(outfile)
end

local function www_docfile(doc)
	local docfile = wwwpath('md/'..doc..'.md')
	if not lfs.attributes(docfile, 'mtime') then return end
	return docfile
end

local function action_docfile(docfile)
	local data = {}
	data.doc_html = render_docfile(docfile)
	local dtags = lp.docfile_tags(docfile)
	data.title = dtags.title
	data.tagline = dtags.tagline
	data.mtime = lfs.attributes(docfile, 'mtime')
	data.mtime_ago = timeago(data.mtime)
	out(render_main('doc.html', data))
end

------------------------------------------------------------------------------

local os_list = {'mingw', 'linux', 'osx'}
local platform_list = {'mingw32', 'mingw64', 'linux32', 'linux64', 'osx32', 'osx64'}

local platform_icon_titles = {
	mingw   = 'Windows',
	mingw32 = '32bit Windows',
	mingw64 = '64bit Windows',
	linux   = 'Linux',
	linux32 = '32bit Linux',
	linux64 = '64bit Linux',
	osx     = 'OS X',
	osx32   = '32bit OS X',
	osx64   = '64bit OS X',
}

local function platform_icons(platforms, vis_only)
	local t = {}
	for _,p in ipairs(platform_list) do
		if not vis_only or platforms[p] then
			table.insert(t, {
				name = p,
				disabled = not platforms[p] and 'disabled' or nil,
			})
		end
	end
	--combine 32bit and 64bit icon pairs into OS icons
	local i = 1
	while i < #t do
		if t[i].name:match'^[^%d]+' == t[i+1].name:match'^[^%d]+' then
			if t[i].disabled == t[i+1].disabled then
				t[i].name = t[i].name:match'^([^%d]+)'
			else
				t[i].name = t[i].disabled and t[i+1].name or t[i].name
			end
			table.remove(t, i+1)
		end
		i = i + 1
	end
	--set the icon title
	for i,pt in ipairs(t) do
		pt.title = (pt.disabled and 'does\'nt work on ' or 'works on ')..
			platform_icon_titles[pt.name]
	end
	return t
end

--given {place1 = {item1 = val1, ...}, ...}, extract items that are
--found in all places into the place indicated by all_key.
local function extract_common_keys(maps, all_key)
	--count occurences for each item
	local maxn = glue.count(maps)
	local nt = {} --{item = n}
	local tt = {} --{item = val}
	for place, items in pairs(maps) do
		for item, val in pairs(items) do
			nt[item] = (nt[item] or 0) + 1
			tt[item] = tt[item] or val --val of 'all' is the val of the first item.
		end
	end
	--extract items found in all places
	local all = {}
	for item, n in pairs(nt) do
		if n == maxn then
			all[item] = tt[item]
		end
	end
	--add items not found in all places, to their original places
	local t = {[all_key] = next(all) and all}
	for place, items in pairs(maps) do
		for item, val in pairs(items) do
			if all[item] == nil then
				glue.attr(t, place)[item] = val
			end
		end
	end
	return t
end

--given {platform1 = {item1 = val1, ...}, ...}, extract items that are
--common to the same OS and common to all platforms to OS keys and all_key key.
local function platform_maps(maps, all_key)
	--combine 32 and 64 bit lists
	maps = glue.update({}, maps)
	for _,p in ipairs(os_list) do
		local t = {}
		for _,n in ipairs{32, 64} do
			t[p..n], maps[p..n] = maps[p..n], nil
		end
		t = extract_common_keys(t, p)
		glue.update(maps, t)
	end
	--extract common items across all places, if all_key given
	return all_key and extract_common_keys(maps, all_key) or maps, maps
end

local function package_icons(ptype, platforms, small)
	local has_lua = ptype:find'Lua'
	local has_ffi = ptype:find'ffi'
	local t = {}
	if has_ffi then
		table.insert(t, {
			name = 'luajit',
			title = 'written in Lua with ffi extension',
		})
	elseif has_lua then
		table.insert(t, {
			name = small and 'luas' or 'lua',
			title = 'written in pure Lua',
		})
	end
	--TODO: review this sorting
	local pn, ps = 0, ''
	if next(platforms) then
		local picons = platform_icons(platforms)
		pn = #picons
		for i,icon in ipairs(picons) do
			if not icon.disabled then
				ps = ps .. icon.name .. ';'
			end
		end
		glue.extend(t, picons)
	end
	if pn == 0 and has_lua then
		ps = #platforms .. (has_ffi and 1 or 2)
	elseif pn > 0 then
		ps = (has_lua and (has_ffi and 1 or 2) or 0) .. ';' .. ps
	end
	return t, ps
end

local function package_info(pkg, doc)
	local lp = require'luapower'
	local glue = require'glue'

	doc = doc or pkg
	local t = {package = pkg}
	t.type = lp.package_type(pkg)
	local platforms = lp.platforms(pkg)
	t.icons = package_icons(t.type, platforms)
	if not next(platforms) then
		platforms = glue.update({}, lp.config'platforms')
	end
	local docs = lp.docs(pkg)
	t.docs = {}
	for name in glue.sortedpairs(docs) do
		table.insert(t.docs, {
			name = name,
			selected = name == doc,
		})
	end
	t.title = doc
	t.docfile = docs[doc]
	if t.docfile then
		local dtags = lp.doc_tags(pkg, doc)
		t.title = dtags.title
		t.tagline = dtags.tagline
	end
	local ctags = lp.c_tags(pkg) or {}
	t.license = ctags.license or 'Public Domain'
	t.version = lp.git_version(pkg)
	t.mtime = lp.git_mtime(pkg)
	t.mtime_ago = timeago(t.mtime)
	t.cname = ctags.realname
	t.cversion = ctags.version
	t.curl = ctags.url
	t.cat = lp.package_cat(pkg)
	local origin_url = lp.git_origin_url(pkg)
	t.github_url = origin_url:find'github.com' and origin_url
	t.github_title = t.github_url and t.github_url:gsub('^%w+://', '')
	t.meta_package = pkg == 'luapower-git'

	local modmap = {}
	for mod, file in pairs(lp.modules(pkg)) do
		modmap[mod] = {module = mod, file = file}
	end

	--create specific platform icons in front of the modules that have
	--load errors on supported platforms.
	for mod, mt in pairs(modmap) do
		local platforms = {}
		--[[
		local load_errors
		for platform in pairs(t.platforms(pkg)) do
			local err = lp.module_load_error(mod, pkg, platform)
			if err then
				platforms[platform] = true
			elseif t.platforms[platform] then
				load_errors = true
			end
		end
		if not load_errors then
			platforms = {}
		end
		]]
		mt.icons = platform_icons(platforms, true)
	end

	--package dependencies ----------------------------------------------------

	--dependency lists, sorted by (kind, name).
	local function sorted_names(deps)
		return glue.keys(deps, function(name1, name2)
			local kind1 = deps[name1].kind
			local kind2 = deps[name2].kind
			if kind1 == kind2 then return name1 < name2 end
			return kind1 < kind2
		end)
	end
	local function pdep_list(pdeps)
		local packages = {}
		local names = sorted_names(pdeps)
		for _,pkg in ipairs(names) do
			local pdep = pdeps[pkg]
			table.insert(packages, glue.update({
				dep_package = pkg,
				external = pdep and pdep.kind == 'external',
			}, pdep))
		end
		return packages
	end

	local pts = {}
	for platform in pairs(platforms) do
		local pt = {}
		pts[platform] = pt
		local pext = lp.package_requires_packages_for('module_requires_loadtime_ext', pkg, platform, true)
		local pall = lp.package_requires_packages_for('module_requires_loadtime_all', pkg, platform, true)
		for p in pairs(pall) do
			pt[p] = {kind = pext[p] and 'external' or 'indirect'}
		end
	end
	local pdeps, pdeps_pl = platform_maps(pts, 'common')
	t.package_deps = {}
	for platform, pdeps in glue.sortedpairs(pdeps) do
		table.insert(t.package_deps, {
			icon = platform ~= 'common' and platform,
			packages = pdep_list(pdeps),
		})
	end
	t.has_package_deps = #t.package_deps > 0

	--package reverse dependency lists
	local rpdeps = {}
	for platform in pairs(platforms) do
		local pt = {}
		rpdeps[platform] = lp.package_requires_packages_for(
			'module_required_loadtime_all', pkg, platform, true)
	end
	local rpdeps, rpdeps_pl = platform_maps(rpdeps, 'common')
	t.package_rdeps = {}
	for platform, rpdeps in glue.sortedpairs(rpdeps) do
		table.insert(t.package_rdeps, {
			icon = platform ~= 'common' and platform,
			packages = glue.keys(rpdeps, true),
		})
	end
	t.has_package_rdeps = #t.package_rdeps > 0

	--package dependency matrix
	local names = {}
	local icons = {}
	t.depmat = {}
	for platform, pmap in glue.sortedpairs(pdeps_pl) do
		table.insert(icons, platform)
		for pkg in pairs(pmap) do
			names[pkg] = true
		end
	end
	t.depmat_names = glue.keys(names, true)
	for i, icon in ipairs(icons) do
		t.depmat[i] = {pkg = {}, icon = icon}
		for j, pkg in ipairs(t.depmat_names) do
			local pt = pdeps_pl[icon][pkg]
			t.depmat[i].pkg[j] = {
				checked = pt ~= nil,
				kind = pt and pt.kind,
			}
		end
	end

	--module list -------------------------------------------------------------

	local function mdep_list(mdeps)
		local modules = {}
		local names = sorted_names(mdeps)
		for _,mod in ipairs(names) do
			local mt = mdeps[mod]
			table.insert(modules, glue.update({
				dep_module = mod,
			}, mt))
		end
		return modules
	end

	t.modules = {}
	local has_autoloads
	for mod, mt in glue.sortedpairs(modmap) do
		table.insert(t.modules, mt)

		--package deps
		local pdeps = {}
		for platform in pairs(platforms) do
			local pext = lp.module_requires_packages_for('module_requires_loadtime_ext', mod, pkg, platform, true)
			local pall = lp.module_requires_packages_for('module_requires_loadtime_all', mod, pkg, platform, true)
			--pp(mod, pkg, platform, pall)
			local pt = {}
			for p in pairs(pall) do
				pt[p] = {kind = pext[p] and 'direct' or 'indirect'}
			end
			pdeps[platform] = pt
		end
		pdeps = platform_maps(pdeps, 'all')
		mt.package_deps = {}
		for platform, pdeps in glue.sortedpairs(pdeps) do
			table.insert(mt.package_deps, {
				icon = platform ~= 'all' and platform,
				packages = pdep_list(pdeps),
			})
		end

		--module deps
		local mdeps = {}
		for platform in pairs(platforms) do
			local mext = lp.module_requires_loadtime_ext(mod, pkg, platform)
			local mall = lp.module_requires_loadtime_all(mod, pkg, platform)
			local mt = {}
			for m in pairs(mall) do
				local pkg = lp.module_package(m)
				local path = lp.modules(pkg)[m]
				mt[m] = {
					kind = mext[m] and 'external' or modmap[m]
					and 'internal' or 'indirect',
					dep_package = pkg,
					dep_file = path,
				}
			end
			mdeps[platform] = mt
		end
		mdeps = platform_maps(mdeps, 'all')
		mt.module_deps = {}
		for platform, mdeps in glue.sortedpairs(mdeps) do
			table.insert(mt.module_deps, {
				icon = platform ~= 'all' and platform,
				modules = mdep_list(mdeps),
			})
		end

		--autoloads
		local auto = {}
		for platform in pairs(platforms) do
			local autoloads = lp.module_autoloads(mod, pkg, platform)
			if next(autoloads) then
				for k, mod in pairs(autoloads) do
					glue.attr(auto, platform)[tuple(k, mod)] = true
				end
			end
		end
		auto = platform_maps(auto, 'all')
		mt.autoloads = {}
		local function autoload_list(platform, auto)
			local t = {}
			local function cmp(k1, k2) --sort by (module_name, key)
				local k1, mod1 = k1()
				local k2, mod2 = k2()
				if mod1 == mod2 then return k1 < k2 end
				return mod1 < mod2
			end
			for k in glue.sortedpairs(auto, cmp) do
				local k, mod = k()
				local pkg = lp.module_package(mod)
				local file = pkg and lp.modules(pkg)[mod]
				table.insert(t, {
					platform ~= 'all' and platform,
					key = k,
					impl_module = mod,
					impl_file = file,
				})
			end
			return t
		end
		for platform, auto in glue.sortedpairs(auto) do
			glue.extend(mt.autoloads, autoload_list(platform, auto))
		end
		mt.module_has_autoloads = #mt.autoloads > 0
		has_autoloads = has_autoloads or mt.module_has_autoloads

		--load errors
		local errs = {}
		for platform in pairs(lp.module_platforms(mod, pkg)) do
			local err = lp.module_load_error(mod, pkg, platform)
			if err then
				errs[platform] = {[err] = true}
			end
		end
		errs = platform_maps(errs)
		mt.error_class = glue.count(errs, 1) > 0 and 'error' or nil
		mt.load_errors = {}
		for platform, errs in pairs(errs) do
			table.insert(mt.load_errors, {
				icon = platform,
				errors = glue.keys(errs, true),
			})
		end
	end
	t.has_modules = glue.count(t.modules, 1) > 0
	t.has_autoloads = has_autoloads

	--script list
	t.scripts = glue.keys(lp.scripts(pkg), true)
	t.has_scripts = glue.count(t.scripts) > 0

	return t
end

function action_package(pkg, doc, what)
	local t = package_info(pkg, doc)
	if what == 'info' then
		t.info = true
	elseif what == 'download' then
		t.download = true
	elseif not what then
		local docfile = doc and lp.docs(pkg)[doc] or t.docfile
		if docfile then
			docfile = lp.powerpath(docfile)
			t.doc_html = render_docfile(docfile)
			t.doc_mtime = lfs.attributes(docfile, 'mtime')
			t.doc_mtime_ago = timeago(t.doc_mtime)
		end
	end
	out(render_main('package.html', t))
end

function action_home()
	local data = {}
	local pt = {}
	data.packages = pt
	for pkg in glue.sortedpairs(lp.installed_packages()) do
		local t = {name = pkg}
		t.type = lp.package_type(pkg)
		t.platforms = lp.platforms(pkg)
		t.icons, t.platform_string = package_icons(t.type, t.platforms, true)
		local dtags = lp.doc_tags(pkg, pkg)
		t.tagline = dtags and dtags.tagline
		local cat = lp.package_cat(pkg)
		t.cat = cat and cat.name
		t.version = lp.git_version(pkg)
		t.mtime = lp.git_mtime(pkg)
		t.mtime_ago = timeago(t.mtime)
		local ctags = lp.c_tags(pkg)
		t.license = ctags and ctags.license or 'PD'
		table.insert(pt, t)
		t.hot = math.abs(os.difftime(os.time(), t.mtime)) < 3600 * 24 * 7
	end
	data.github_title = 'github.com/luapower'
	data.github_url = 'https://'..data.github_title

	local pkgmap = {}
	for _,pkg in ipairs(data.packages) do
		pkgmap[pkg.name] = pkg
	end
	data.cats = {}
	for i, cat in ipairs(lp.cats()) do
		local t = {}
		for i, pkg in ipairs(cat.packages) do
			local pt = pkgmap[pkg]
			table.insert(t, pt)
		end
		table.insert(data.cats, {cat = cat.name, packages = t})
	end

	local t = {}
	data.download_buttons = t
	for _,pl in ipairs{'mingw32', 'linux32', 'osx32', 'mingw64', 'linux64', 'osx64'} do
		local file = 'luapower-'..pl..'.zip'
		local size = lfs.attributes(wwwpath(file), 'size')
		if size then
			table.insert(t, {
				platform = pl,
				file = file,
				size = string.format('%d MB', size / 1024 / 1024),
			})
		end
	end

	out(render_main('home.html', data))
end

function action.default(s, ...)
	if not s then
		return action_home()
	elseif lp.installed_packages()[s] then
		return action_package(s, nil, ...)
	elseif lp.docs()[s] then
		local pkg = lp.doc_package(s)
		return action_package(pkg, s, ...)
	elseif lp.modules()[s] then
		local pkg = lp.module_package(s)
		return action_package(pkg, nil, s, ...)
	else
		local docfile = www_docfile(s)
		if docfile then
			return action_docfile(docfile, ...)
		else
			redirect'/'
		end
	end
end

--status page ----------------------------------------------------------------

function action.status()
	local statuses = {}
	for platform, server in glue.sortedpairs(lp.config'servers') do
		local ip, port = unpack(server)
		local t = {platform = platform, ip = ip, port = port}
		local rlp, err = lp.connect(platform, nil, connect)
		t.status = rlp and 'up' or 'down'
		t.error = err and err:match'^.-:.-: ([^\n]+)'
		if rlp then
			t.installed_package_count = glue.count(rlp.installed_packages())
			t.known_package_count = glue.count(rlp.known_packages())
			t.load_errors = {}
			for mod, err in glue.sortedpairs(lp.load_errors(nil, platform)) do
				table.insert(t.load_errors, {
					module = mod,
					error = err,
				})
			end
			t.load_error_count = #t.load_errors
		end
		table.insert(statuses, t)
	end
	out(render_main('status.html', {statuses = statuses}))
end

--grepping through the source code and documentation -------------------------

local disallow = glue.index{'{}', '()', '))', '}}', '==', '[[', ']]', '--'}
function action.grep(s)
	local results = {search = s}
	if not s or #glue.trim(s) < 2 or disallow[s] then
		results.message = 'Type two or more non-space characters and not '..
			table.concat(glue.keys(disallow), ', ')..'.'
	else
		sleep(1) --sorry about this
		glue.update(results, grep(s, 10))
		results.title = 'grepping for '..(s or '')
		results.message = #results.results > 0 and '' or 'Nothing found.'
		results.searched = true
	end
	out(render_main('grep.html', results))
end

--update via github ----------------------------------------------------------

function action.github(...)
	if not POST then return end
	local repo = POST.repository.name
	if not repo then return end
	if not lp.installed_packages()[repo] then return end
	os.exec(luapower.git(repo, 'pull')) --TODO: this is blocking the server!!!
	luapower.update_db(repo) --TODO: this is blocking the server!!!
end

--dependency lister for git clone --------------------------------------------

function action.deps(pkg)
	setmime'txt'
	local deps = lp.package_requires_packages_for(
		'module_requires_loadtime_all', pkg, nil, true)
	for k in glue.sortedpairs(deps) do
		print(k)
	end
end

--updating the deps db -------------------------------------------------------

function action.update_db(package)
	lp.clear_cache(package)
	lp.update_db(package)
	lp.save_db()
	print'ok'
end

--creating rockspecs ---------------------------------------------------------

function action.rockspec(pkg)
	pkg = pkg:match'^luapower%-([%w_]+)'
	local dtags = lp.doc_tags(pkg, pkg)
	local tagline = dtags and dtags.tagline or pkg
	local homepage = 'http://luapower.com/'..pkg
	local ctags = lp.c_tags(pkg)
	local license = ctags and ctags.license or 'Public Domain'
	local pext = lp.package_requires_packages_for(
		'module_requires_loadtime_ext', pkg, platform, true)
	local deps = {}
	for pkg in glue.sortedpairs(pext) do
		table.insert(deps, 'luapower-'..pkg)
	end
	local plat = {}
	local plats = {
		mingw32 = 'windows', mingw64 = 'windows',
		linux32 = 'linux', linux64 = 'linux',
		osx32 = 'macosx', osx64 = 'macosx',
	}
	for pl in pairs(lp.platforms(pkg)) do
		plat[plats[pl]] = true
	end
	plat = next(plat) and glue.keys(plat, true) or nil
	local ver = lp.git_version(pkg)
	local maj, min = ver:match('^([^%-]+)%-([^%-]+)')
	if maj then
		maj = maj:gsub('[^%d]', '')
		min = min:gsub('[^%d]', '')
		ver = '0.'..maj..'-'..min
	end
	local lua_modules = {}
	local luac_modules = {}
	for mod, path in pairs(lp.modules(pkg)) do
		local mtags = lp.module_tags(pkg, mod)
		if mtags.lang == 'C' then
			luac_modules[mod] = path
		elseif mtags.lang == 'Lua' or mtags.lang == 'Lua/ASM' then
			lua_modules[mod] = path
		end
	end
	local t = {
		package = 'luapower-'..pkg,
		supported_platforms = plat,
		version = ver,
		source = {
			url = lp.git_origin_url(pkg),
		},
		description = {
			summary = tagline,
			homepage = homepage,
			license = license,
		},
		dependencies = deps,
		build = {
			type = 'none',
			install = {
				lua = lua_modules,
				lib = luac_modules,
			},
		},
		--copy_directories = {},
	}
	setmime'txt'
	for k,v in glue.sortedpairs(t) do
		out(k)
		out' = '
		out(pp.format(v, '   '))
		out'\n'
	end
end

