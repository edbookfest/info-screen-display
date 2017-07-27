gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

node.alias("info-screen")

local json = require "json"

local settings = {
    IMAGE_PRELOAD = 2;
    VIDEO_PRELOAD = 2;
    PRELOAD_TIME = 4;
    FALLBACK_PLAYLIST = {
        {
            offset = 0;
            total_duration = 1;
            duration = 1;
            asset_name = "empty.png";
            type = "image";
        }
    }
}

local white = resource.create_colored_texture(1, 1, 1, 1)
local black = resource.create_colored_texture(0, 0, 0, 1)
local red = resource.create_colored_texture(1, 0, 0, 1)
local font = resource.load_font "roboto.ttf"

local month = 8
local use_fake_time = false

local clock = (function()
    local base_time = N.base_time or 0

    local function set(time)
        base_time = tonumber(time) - sys.now()
    end

    local function get()
        return base_time + sys.now()
    end

    util.data_mapper {
        ["clock/set"] = function(time)
            set(time)
            print("UPDATED TIME", base_time)
        end;
    }

    return {
        get = get;
        set = set;
    }
end)()

local fake_clock = (function()
    local base_time = 0

    local function set(time)
        base_time = tonumber(time)
    end

    local function get()
        return base_time
    end

    return {
        get = get;
        set = set;
    }
end)()

local function get_now()
    if use_fake_time then
         return fake_clock.get()
    end
    return clock.get()
end

local function ramp(t_s, t_e, t_c, ramp_time)
    if ramp_time == 0 then return 1 end
    local delta_s = t_c - t_s
    local delta_e = t_e - t_c
    return math.min(1, delta_s * 1 / ramp_time, delta_e * 1 / ramp_time)
end

local function cycled(items, offset)
    offset = offset % #items + 1
    return items[offset], offset
end

local function pts(ts)
    return os.date("%d/%m/%Y %H:%M:%S", ts)
end

local Loading = (function()
    local loading = "Loading..."
    local size = 80
    local w = font:width(loading, size)
    local alpha = 0

    local function draw()
        if alpha == 0 then
            return
        end
        font:write((WIDTH - w) / 2, (HEIGHT - size) / 2, loading, size, 1, 1, 1, alpha)
    end

    local function fade_in()
        alpha = math.min(1, alpha + 0.01)
    end

    local function fade_out()
        alpha = math.max(0, alpha - 0.01)
    end

    return {
        fade_in = fade_in;
        fade_out = fade_out;
        draw = draw;
    }
end)()

local Config = (function()
    local config
    local switch_time = 1

    local config_file = "config.json"

    local function getTS(day, time)
        local hour = tonumber(string.sub(time, 0, 2))
        local min = tonumber(string.sub(time, 3, 4))

        -- everyday equates to today
        if day == "everyday" then
            day = tonumber(os.date("%d", get_now()))
            -- unless it's before 2am currently, when it's still 'yesterday'
            if tonumber(os.date("%H", get_now())) < 2 then
                day = day - 1
            end
        else
            day = tonumber(day)
        end

        -- if item is scheduled before 2am, increment the day to the next
        if hour < 2 then
            day = day + 1
        end

        local ts = os.time {
            year = os.date("%Y", get_now()),
            month = month,
            day = day,
            hour = hour,
            min = min,
            sec = 0
        }
        return ts
    end

    local function getStartTime(item)
        return getTS(item.day, item.display_from)
    end

    local function getEndTime(item)
        return getTS(item.day, item.display_until)
    end

    local function load_playlist()
        local playlist = {}
        if #config.playlist == 0 then
            playlist = settings.FALLBACK_PLAYLIST
            switch_time = 0
        else
            playlist = {}
            local total_duration = 0
            for idx = 1, #config.playlist do
                local item = config.playlist[idx]
                total_duration = total_duration + item.duration
            end

            local offset = 0
            for idx = 1, #config.playlist do
                local item = config.playlist[idx]
                if item.duration > 0 then

                    if getStartTime(item) <= get_now() and getEndTime(item) >= get_now() then
                        playlist[#playlist + 1] = {
                            offset = offset,
                            total_duration = total_duration,
                            duration = item.duration,
                            asset_name = item.file.asset_name,
                            type = item.file.type,
                        }
                        offset = offset + item.duration
                        print("USING    " .. item.file.asset_name .. " due to be shown from " .. pts(getStartTime(item)) .. " up until " .. pts(getEndTime(item)) .. " currently " .. pts(get_now()))
                    else
                        print("skipping " .. item.file.asset_name .. " due to be shown from " .. pts(getStartTime(item)) .. " up until " .. pts(getEndTime(item)) .. " currently " .. pts(get_now()))
                    end
                end
            end
            switch_time = config.switch_time
        end

        if #playlist == 0 then
            playlist = settings.FALLBACK_PLAYLIST
        end

        if #playlist <= 1 then
            switch_time = 0
        end

        return playlist
    end

    util.file_watch(config_file, function(raw)
        print("updated " .. config_file)
        config = json.decode(raw)

        progress = config.progress
        use_fake_time = config.fake_time

        if config.fake_time then
            fake_clock.set(os.time {
                year = os.date("%Y", clock.get()),
                month = month,
                day = config.fake_day,
                hour = config.fake_hour,
                min = config.fake_min,
                sec = 30
            });
        end

        if config.auto_resolution then
            gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)
        else
            gl.setup(config.width, config.height)
        end

        print("screen size is " .. WIDTH .. "x" .. HEIGHT)

        load_playlist()
    end)

    return {
        get_playlist = function() return load_playlist() end;
        get_switch_time = function() return switch_time end;
        get_progress = function() return progress end;
    }
end)()

local Scheduler = (function()
    local playlist_offset = 0

    local function get_next()
        local playlist = Config.get_playlist()

        local item
        item, playlist_offset = cycled(playlist, playlist_offset)

        print(string.format("next scheduled item is %s [%f]", item.asset_name, item.duration))
        return item
    end

    return {
        get_next = get_next;
    }
end)()

local function draw_progress(starts, ends, now)
    local mode = Config.get_progress()
    if mode == "no" then
        return
    end

    if ends - starts < 2 then
        return
    end

    local progress = 1.0 / (ends - starts) * (now - starts)
    if mode == "bar_thin_white" then
        white:draw(0, HEIGHT - 10, WIDTH * progress, HEIGHT, 0.5)
    elseif mode == "bar_thin_black" then
        black:draw(0, HEIGHT - 10, WIDTH * progress, HEIGHT, 0.5)
    elseif mode == "countdown" then
        local remaining = math.ceil(ends - now)
        local text
        if remaining >= 60 then
            text = string.format("%d:%02d", remaining / 60, remaining % 60)
        else
            text = remaining
        end
        local size = 32
        local w = font:width(text, size)
        black:draw(WIDTH - w - 4, HEIGHT - size - 4, WIDTH, HEIGHT, 0.6)
        font:write(WIDTH - w - 2, HEIGHT - size - 2, text, size, 1, 1, 1, 0.8)
    end
end

local ImageJob = function(item, ctx, fn)
    fn.wait_t(ctx.starts - settings.IMAGE_PRELOAD)

    local res = resource.load_image(ctx.asset)

    for now in fn.wait_next_frame do
        local state, err = res:state()
        if state == "loaded" then
            break
        elseif state == "error" then
            error("preloading failed: " .. err)
        end
    end

    print "waiting for start"
    local starts = fn.wait_t(ctx.starts)
    local duration = ctx.ends - starts

    print(">>> IMAGE", res, ctx.starts, ctx.ends)

    while true do
        local now = sys.now()

        util.draw_correct(res, 0, 0, WIDTH, HEIGHT, ramp(ctx.starts, ctx.ends, now, Config.get_switch_time()))
        draw_progress(ctx.starts, ctx.ends, now)

        if now > ctx.ends then
            break
        end

        fn.wait_next_frame()
    end

    print("<<< IMAGE", res, ctx.starts, ctx.ends)
    res:dispose()

    return true
end

local VideoJob = function(item, ctx, fn)
    fn.wait_t(ctx.starts - settings.VIDEO_PRELOAD)

    local raw = sys.get_ext "raw_video"
    local res = raw.load_video {
        file = ctx.asset,
        audio = false,
        looped = false,
        paused = true,
    }

    for now in fn.wait_next_frame do
        local state, err = res:state()
        if state == "paused" then
            break
        elseif state == "error" then
            error("preloading failed: " .. err)
        end
    end

    print "waiting for start"
    fn.wait_t(ctx.starts)

    print(">>> VIDEO", res, ctx.starts, ctx.ends)
    res:start()

    while true do
        local now = sys.now()
        local state, width, height = res:state()
        if state ~= "finished" then
            local layer = -2
            if now > ctx.starts + 0.1 then
                -- after the video started, put it on a more
                -- foregroundy layer. that way two videos
                -- played after one another are sorted in a
                -- predictable way and no flickering occurs.
                layer = -1
            end

            local x1, y1, x2, y2 = util.scale_into(NATIVE_WIDTH, NATIVE_HEIGHT, width, height)
            res:layer(layer):target(x1, y1, x2, y2, ramp(ctx.starts, ctx.ends, now, Config.get_switch_time()))

            draw_progress(ctx.starts, ctx.ends, now)
        end
        if now > ctx.ends then
            break
        end
        fn.wait_next_frame()
    end

    print("<<< VIDEO", res, ctx.starts, ctx.ends)
    res:dispose()

    return true
end

local Queue = (function()
    local jobs = {}
    local scheduled_until = sys.now()

    local function enqueue(starts, ends, item)
        local co = coroutine.create(({
            image = ImageJob,
            video = VideoJob,
            child = ChildJob,
            module = ModuleJob,
        })[item.type])

        local success, asset = pcall(resource.open_file, item.asset_name)
        if not success then
            print("CANNOT GRAB ASSET: ", asset)
            return
        end

        -- an image may overlap another image
        if #jobs > 0 and jobs[#jobs].type == "image" and item.type == "image" then
            starts = starts - Config.get_switch_time()
        end

        local ctx = {
            starts = starts,
            ends = ends,
            asset = asset;
        }

        local success, err = coroutine.resume(co, item, ctx, {
            wait_next_frame = function()
                return coroutine.yield(false)
            end;
            wait_t = function(t)
                while true do
                    local now = coroutine.yield(false)
                    if now > t then
                        return now
                    end
                end
            end;
        })

        if not success then
            print("CANNOT START JOB: ", err)
            return
        end

        jobs[#jobs + 1] = {
            co = co;
            ctx = ctx;
            type = item.type;
        }

        scheduled_until = ends
        print("added job. scheduled program until ", scheduled_until)
    end

    local function tick()
        gl.clear(0, 0, 0, 0)

        for try = 1, 3 do
            if sys.now() + settings.PRELOAD_TIME < scheduled_until then
                break
            end
            local item = Scheduler.get_next()
            enqueue(scheduled_until, scheduled_until + item.duration, item)
        end

        if #jobs == 0 then
            Loading.fade_in()
        else
            Loading.fade_out()
        end

        local now = sys.now()
        for idx = #jobs, 1, -1 do -- iterate backwards so we can remove finished jobs
            local job = jobs[idx]
            local success, is_finished = coroutine.resume(job.co, now)
            if not success then
                print("CANNOT RESUME JOB: ", is_finished)
                table.remove(jobs, idx)
            elseif is_finished then
                table.remove(jobs, idx)
            end
        end

        Loading.draw()
    end

    return {
        tick = tick;
    }
end)()

util.set_interval(1, node.gc)

function node.render()
    gl.clear(0, 0, 0, 1)
    Queue.tick()

    if use_fake_time then
        red:draw(0, 0, WIDTH, 60)
        local time = os.date("!%d/%m/%y %H:%M", get_now())
        font:write(10, 10, "USING FAKE TIME: " .. time, 40, 0, 0, 0, 1)
    end

end
