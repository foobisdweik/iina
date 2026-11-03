-- Print render statistics when playback ends, for vk-probe runs.
--
-- vo-passes lists every render pass of the last frames with its GPU time.
-- "fresh" passes run once per new video frame (decoding, scaling, shaders);
-- "redraw" passes run when an old frame is shown again. The sum of the
-- average fresh times is the cost of the shader chain per video frame.

local mp = require 'mp'

local function report()
    local passes = mp.get_property_native('vo-passes')
    local total_avg, total_peak = 0, 0
    if passes and passes.fresh then
        for _, p in ipairs(passes.fresh) do
            -- avg and peak are in nanoseconds.
            total_avg = total_avg + (p.avg or 0)
            total_peak = total_peak + (p.peak or 0)
            mp.msg.info(string.format('pass %-60s avg %7.3f ms  peak %7.3f ms',
                p.desc or '?', (p.avg or 0) / 1e6, (p.peak or 0) / 1e6))
        end
    end
    mp.msg.info(string.format('RESULT fresh_total_avg_ms=%.3f fresh_total_peak_ms=%.3f',
        total_avg / 1e6, total_peak / 1e6))
    mp.msg.info(string.format('RESULT frame_drop=%s vo_delayed=%s mistimed=%s hwdec=%s gpu=%s',
        tostring(mp.get_property('frame-drop-count')),
        tostring(mp.get_property('vo-delayed-frame-count')),
        tostring(mp.get_property('mistimed-frame-count')),
        tostring(mp.get_property('hwdec-current')),
        tostring(mp.get_property('current-gpu-context'))))
    local osd = mp.get_property_native('osd-dimensions')
    if osd then
        mp.msg.info(string.format('RESULT output=%dx%d', osd.w, osd.h))
    end
end

-- Read the statistics just before the end, while the VO still has them.
mp.register_event('end-file', function() end)
mp.add_hook('on_unload', 50, report)
