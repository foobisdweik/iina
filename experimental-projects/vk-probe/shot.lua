-- Take one screenshot of the rendered window at a fixed time, then quit.
--
-- Use with --pause --start=<t> --hr-seek=yes. "window" mode renders the
-- frame at the window size with every shader applied, which is what the
-- viewer sees. "video" mode would skip the upscaling, so it is not used.
--
-- Option: --script-opts=shot-out=<path.png>

local mp = require 'mp'
local opts = { out = 'shot.png' }
require('mp.options').read_options(opts, 'shot')

local done = false
mp.register_event('playback-restart', function()
    if done then return end
    done = true
    -- Wait until the window has its full-screen size before rendering.
    mp.add_timeout(1.5, function()
        mp.commandv('screenshot-to-file', opts.out, 'window')
        -- The margins say where the video sits inside the window, so the
        -- scoring step can crop away the black bars.
        local d = mp.get_property_native('osd-dimensions')
        mp.msg.info(string.format('RESULT shot=%s w=%d h=%d ml=%d mt=%d mr=%d mb=%d',
            opts.out, d.w, d.h, d.ml, d.mt, d.mr, d.mb))
        mp.command('quit')
    end)
end)
