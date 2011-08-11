--[[ usage
location /res/ {
    set $enable true;
    set $max_files 12;
    set $get_once 5;
    set unique true;
    set types "xx xx";

    access_by_lua_file conf/concat.lua;
}
]]


function itotable (i, tohash)
    if type(i) ~= 'function' then
        return {}
    end

    local r = {}
    local v
    local n

    v = i()
    if tohash then
        n = 0
        while v do
            r[v] = true
            v = i()
            n = n + 1
        end

        return r, n
    else
        while v do
            table.insert(r, v)
            v = i()
        end

        return r
    end
end

function main ()
    local url, args, m = ngx.var.uri, (ngx.var.args or ''), (ngx.var.request_method or '')

    if not (args:match('^%?.') and url:match('/$') and
            (m == 'GET' or m == 'HEAD')) then
        ngx.log(ngx.DEBUG, string.format('run concat.lua with args: %s, url: %s, m: %s',
            args, url, m))
        return
    end

    local config = {
        enable = ngx.var.enable == 'true',
        max_files = tonumber(ngx.var.max_files) or 100,
        get_once = tonumber(ngx.var.get_once) or 5,
        unique = ngx.var.unique == 'true',
    }
    local typenum
    local typestext = ngx.var.types or 'application/x-javascript, text/css'
    config.types, typenum = itotable(typestext:gmatch('([^, ]+)'), true)

    if config.enable ~= true or typenum < 1 then
        ngx.log(ngx.WARN, 'setup concat.lua but do not enabled or types < 1')
        return
    end

    if config.max_files > 300 then
        ngx.log(ngx.WARN, 'concat.max_files can not bigger than 300')
        config.max_files = 300
    end

    if config.get_once > config.max_files then
        config.get_once = config.max_files
    end

    -- 构建url并请求，合并需要判断返回类型和状态码
    -- 非200的状态码直接返回给客户端，非指定的类型返回bad_request错误
    -- 返回类型不一致，可能触发错误

    args = args:sub(2)
    local urls = itotable(args:gmatch('([^,]+)'), false)
    local i, step, max = 1, config.get_once, #urls
    local contype

    if max > config.max_files then
        ngx.log(ngx.DEBUG, string.format('max: %s > config.max_files: %s', max, config.max_files))
        return ngx.exit(400)
    end

    while i <= max do
        local j, tocaps = 0, {}
        while i <= max and j < step do
            table.insert(tocaps, {url .. urls[i]})
            i = i + 1
            j = j + 1
        end

        for _, res in ipairs({ngx.location.capture_multi(tocaps)}) do
            if res.status ~= 200 then
                ngx.log(ngx.DEBUG, string.format('url: %s got status: %s', tocaps[_][1], res.status))
                return ngx.exit(res.status)
            end

            local ct = (res.header['Content-Type'] or ''):match('^[^;]+')
            if not config.types[ct] then
                ngx.log(ngx.DEBUG, string.format('url: %s got wrong content type: %s, need: %s', tocaps[_][1], ct, typestext))
                return ngx.exit(400)
            end

            if contype then
                if unique and ct ~= contype then
                    ngx.log(ngx.DEBUG, string.format('url: %s got non-uniq content type: %s, last: %s', tocaps[_][1], ct, contype))
                    return ngx.exit(400)
                end
            else
                contype = ct
                ngx.header.content_type = contype
            end

            ngx.print(res.body)
        end
        ngx.flush()
    end

    return ngx.eof()
end

main()
