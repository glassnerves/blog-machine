local fs = require 'filesystem'
local system = require 'system'
local stream = require 'stream'
local regex = require 'regex'
local file = require 'file'
local pipe = require 'pipe'
local json = require 'json'

local DATEATTRREGEX = regex.new{
    pattern = '^:revdate: *([0-9]{4})-([0-9]{2})-([0-9]{2})',
    grammar = 'extended',
    optimize = true
}

local INPUT = fs.current_working_directory()
local OUTPUT = INPUT / 'public'
local CSSPATH = system.environment['ASCIIDOCTORCSSPATH']

local function get_output_path(post_path)
    local scanner = stream.scanner.new{
        record_separator = '\n'
    }
    scanner.stream = file.stream.new()
    scanner.stream:open(post_path, file.open_flag.read_only)
    while true do
        local line = scanner:get_line()
        local year, month, day = regex.match(DATEATTRREGEX, line)
        if year then
            year, month, day = tostring(year), tostring(month), tostring(day)
            return OUTPUT / year / month / day / post_path.stem / 'index.html'
        end
    end
end

-- TODO: should merge with previous function to generate a get_attrs() function
-- that works in 1-pass
local function get_title(post_path)
    local scanner = stream.scanner.new{ record_separator = '\n' }
    scanner.stream = file.stream.new()
    scanner.stream:open(post_path, file.open_flag.read_only)
    while true do
        local line = scanner:get_line()
        if line:starts_with('= ') then
            return tostring(line:slice(3))
        end
    end
end

if not CSSPATH then
    stream.write_all(
        system.err,
        'set env ASCIIDOCTORCSSPATH with path to asciidoctor-default.css\n')
    system.exit(1)
end

local json_conf

do
    json_conf = file.stream.new()
    json_conf:open(fs.path.new('config.json'), file.open_flag.read_only)
    local buf = byte_span.new(json_conf.size)
    stream.read_all(json_conf, buf)
    json_conf = json.decode(tostring(buf))
end

local function generate_documents(document_type, document_extension, post, post_path, output)
    local p = system.spawn{
        program = document_type,
        arguments = {
            document_type,
            '--trace', '--verbose',
            '--base-dir', tostring(fs.current_working_directory() / 'content'),

            '--attribute', 'icons=font',
            '--attribute', 'icon-set=fas',

            '--require', 'asciidoctor-diagram',
            '--attribute', 'ditaa-format=svg',
            '--attribute', 'plantuml-format=svg',
            '--attribute', 'diagram-nocache-option',

            '--attribute', 'source-highlighter=rouge',	

            '--out-file', tostring(output:replace_filename(post.path.stem .. document_extension)),
            tostring(post_path)
        },
        environment = system.environment,
        stderr = 'share'
    }
    spawn(function()
        p:wait()
        if p.exit_code ~= 0 then
            stream.write_all(
                system.err, document_type .. 'returned ' .. p.exit_code .. '\n')
                system.exit(1)
        end
    end):detach()
end

local posts = {}

for post in fs.directory_iterator(INPUT / 'content' / 'post') do
    if post.path.extension ~= '.adoc' then
        goto continue
    end

    local output = get_output_path(post.path)
    local title = get_title(post.path)

    posts[#posts + 1] = {
        title = title,
        path = output.parent_path:lexically_relative(OUTPUT)
    }

    fs.create_directories(output.parent_path)

    local uptodate = false
    pcall(function()
        if fs.last_write_time(output) > fs.last_write_time(post.path) then
            uptodate = true
        end
    end)

    if uptodate then
        goto continue
    end

    local adout, wp = pipe.pair()
    wp = wp:release()
    local p = system.spawn{
        program = 'asciidoctor',
        arguments = {
            'asciidoctor',
            '--trace', '--verbose',
            '--base-dir', tostring(fs.current_working_directory() / 'content'),

            '--no-header-footer',
            '--attribute', 'nofooter',
            '--attribute', 'docinfo=shared',

            '--attribute', 'icons=font',
            '--attribute', 'icon-set=fas',

            '--require', 'asciidoctor-diagram',
            '--attribute', 'ditaa-format=svg',
            '--attribute', 'plantuml-format=svg',
            '--attribute', 'diagram-nocache-option',

            '--attribute', 'source-highlighter=rouge',

            '--attribute', 'sectlinks',
            '--attribute', 'sectanchors',
            '--attribute', 'figure-caption!',
            '--attribute', 'toc-title!',

            '--safe',

            '--out-file=-',

            tostring(post.path)
        },
        environment = system.environment,
        stdout = wp,
        stderr = 'share'
    }
    wp:close()
    wp = nil
    spawn(function()
        p:wait()
        if p.exit_code ~= 0 then
            stream.write_all(
                system.err, 'asciidoctor returned ' .. p.exit_code .. '\n')
            system.exit(1)
        end
    end):detach()

    local output_file = file.stream.new()
    output_file:open(
        output,
        bit.bor(
            file.open_flag.write_only, file.open_flag.create,
            file.open_flag.truncate))

    stream.write_all(
        output_file, format([[
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="generator" content="super blog machine 0.0.1">
<title>{title}</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css?family=Open+Sans:300,300italic,400,400italic,600,600italic%7CNoto+Serif:400,400italic,700,700italic%7CDroid+Sans+Mono:400,700">
<link rel="alternate" type="application/feed+json" title="{blog_title}" href="{url}feed.json">
<style>
]],
        {'title', title}, {'blog_title', json_conf.title}, {'url', json_conf.baseURL}))

    do
        local css_file = file.stream.new()
        local buf = byte_span.new(4096)
        css_file:open(fs.path.new(CSSPATH), file.open_flag.read_only)
        -- TODO: Emilua should have a stream_copy algorithm
        while true do
            local nread
            local ok = pcall(function() nread = css_file:read_some(buf) end)
            if not ok then break end
            stream.write_all(output_file, buf:slice(1, nread))
        end
    end

    stream.write_all(
        output_file, format([[
</style>
<link rel="stylesheet" href="{url}syntax.css">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/4.7.0/css/font-awesome.min.css">
</head>
<body class="article toc2 toc-left">
<div id="header">
<h1>{title}</h1>
<div id="toc" class="toc2">
<div id="toctitle">Menu</div>
<ul class="sectlevel1">
<li><a href="/">Home</a></li>
</ul>
</div>
</div>
<div id="content">
]],
        {'title', title}, {'url', json_conf.baseURL}))

    do
        local buf = byte_span.new(4096)
        -- TODO: Emilua should have a stream_copy algorithm
        while true do
            local nread
            local ok = pcall(function() nread = adout:read_some(buf) end)
            if not ok then break end
            stream.write_all(output_file, buf:slice(1, nread))
        end
    end

    stream.write_all(output_file, format([[
</div>
</ul>
</div>
<div id="download-options" style="text-align: center; margin-top: 20px;">
  <p style="font-size: 14px;">Download Article:
    <a style="font-size: 12px; href="{url_pdf}">PDF</a> |
    <a style="font-size: 12px; href="{url_epub}">EPUB</a>
  </p>
</div>
<div id="footer">
<div id="footer-text">
{footer}
</div>
</div>
</body>
</html>
]], {'url_pdf', json_conf.baseURL .. '/' .. tostring(output.parent_path:lexically_relative(OUTPUT)) 
.. '/' .. tostring(output:replace_filename(post.path.stem .. '.pdf'))}, 
	{'url_epub', json_conf.baseURL .. post.path:to_generic() .. '/' .. post.path.stem .. '.epub'},
{'footer', json_conf.footerText}))

    local dArgs = {{"asciidoctor-pdf", ".pdf"}, {"asciidoctor-epub3", ".epub"}}

    for _, v in pairs(dArgs) do
        generate_documents(v[1], v[2], post, post.path, output)
    end

    ::continue::
end

local index = file.stream.new()
index:open(OUTPUT / 'index.html', bit.bor(file.open_flag.write_only, file.open_flag.create, file.open_flag.truncate))
stream.write_all(index, format([[
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="generator" content="super blog machine 0.0.1">
<title>{title}</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css?family=Open+Sans:300,300italic,400,400italic,600,600italic%7CNoto+Serif:400,400italic,700,700italic%7CDroid+Sans+Mono:400,700">
<link rel="alternate" type="application/feed+json" title="{title}" href="{url}feed.json">
<style>
]], {'title', json_conf.title}, {'url', json_conf.baseURL}))

do
    local css_file = file.stream.new()
    local buf = byte_span.new(4096)
    css_file:open(fs.path.new(CSSPATH), file.open_flag.read_only)
    -- TODO: Emilua should have a stream_copy algorithm
    while true do
        local nread
        local ok = pcall(function() nread = css_file:read_some(buf) end)
        if not ok then break end
        stream.write_all(index, buf:slice(1, nread))
    end
end

stream.write_all(index, format([[
</style>
</head>
<body class="article">
<div id="header">
<h1>{title}</h1>
</div>
<div id="content">
<ul>
]], {'title', json_conf.title}))

table.sort(posts, function(lhs, rhs) return lhs.path > rhs.path end)

local json_feed = { items = {} }

for _, v in ipairs(posts) do
    json_feed.items[#json_feed.items + 1] = {
        id = v.path:to_generic(),
        title = tostring(v.title),
        url = json_conf.baseURL .. v.path:to_generic() .. '/',
        pdf = json_conf.baseURL .. v.path:to_generic() .. '/' .. v.path.stem .. '.pdf',
        epub = json_conf.baseURL .. v.path:to_generic() .. '/' .. v.path.stem .. '.epub'
    }
    stream.write_all(
        index,
        format(
            '<li><a href="/{href}/">{title}</a></li>',
            {'href', v.path:to_generic()},
            {'title', tostring(v.title)}))
end

stream.write_all(index, format([[
</ul>
</div>
<div id="footer">
<div id="footer-text">
{footer}
</div>
</div>
</body>
</html>]], {'footer', json_conf.footerText}))

json_feed.version = 'https://jsonfeed.org/version/1.1'
json_feed.title = json_conf.title
json_feed.home_page_url = json_conf.baseURL
json_feed.language = json_conf.languageCode
json_feed.feed_url = json_conf.baseURL .. 'feed.json'
json_feed = json.encode(json_feed)

local feed_file = file.stream.new()
feed_file:open(OUTPUT / 'feed.json', bit.bor(file.open_flag.write_only, file.open_flag.create, file.open_flag.truncate))
stream.write_all(feed_file, json_feed)

for file in fs.directory_iterator(INPUT / 'static') do
    fs.copy(file.path, OUTPUT, { existing = 'update' })
end

for file in fs.directory_iterator(INPUT / 'content') do
    if file.path.extension == '.svg' then
        fs.rename(file.path,  OUTPUT / file.path.filename)
    end
end

local rougifyout, wp = pipe.pair()
wp = wp:release()

system.spawn{
    program = 'rougify',
    arguments = {'rougify', 'style', 'github'},
    stdout = wp,
    stderr = 'share'
}:wait()
wp:close()

-- Calling line by line instead of using `record_separator='\0'` due to this issue
-- https://github.com/chriskohlhoff/asio/issues/1442
local rougifyout = stream.scanner.new{
    stream = rougifyout,
    record_separator = '\n',
}

local syntax_css_output = ''

while true do
    local ok, line = pcall(function()
        return rougifyout:get_line()
    end)

    if not ok then
        break
    end

    syntax_css_output = syntax_css_output .. tostring(line)
end

local rougecss = file.stream.new()
rougecss:open(fs.path.from_generic('public/syntax.css'), bit.bor(file.open_flag.write_only, file.open_flag.create, file.open_flag.truncate))
stream.write_all(rougecss, syntax_css_output)
