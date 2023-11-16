local mp = require "mp"
local msg = require "mp.msg"
opt = require('mp.options')

local mkplayback = require "matroskaplayback"
local mkplay



-- disable mpv's internal ordered-chapters support!
mp.set_property_native("ordered-chapters", false)

-- uosc support for better handling menus and buttons
local uosc_is_installed = false
uosc_options = {
	time_precision = 0,
}

-- Register response handler
mp.register_script_message('uosc-version', function(version)
    uosc_is_installed = version ~= nil
end)



local function mp_file_loaded()
    -- get the stream id's
    mkplay.mpv_current_vid = mp.get_property_number("vid")
    mkplay.mpv_current_aid = mp.get_property_number("aid")
    mkplay.mpv_current_sid = mp.get_property_number("sid")

    -- check video rotation
    mkplay:video_rotation()
    
    -- init chapters
	mp.set_property_native("chapter-list", mkplay:get_mpv_chapters(true))
	msg.debug("Matroska Playback: init chapters done")
	
    -- set media title
    mkplay:mpv_set_media_title()

    -- check edition change
	if mkplay.edition_is_changing then
        mkplay.edition_is_changing = false -- end of edition changing
        mp.osd_message(mkplay:current_edition().current_name)
        return
    end

    -- register video observation
    mp.observe_property("vid", "number", function(_, val) mkplay:mpv_on_video_change(val) end)
    -- register audio observation
    mp.observe_property("aid", "number", function(_, val) mkplay:mpv_on_audio_change(val) end)
    -- register subtitle observation
    mp.observe_property("sid", "number", function(_, val) mkplay:mpv_on_subtitle_change(val) end)

    -- key binding: cycle-editions, override mpv's default "E" key for changing the editions
    mp.add_key_binding("E", "cycle-editions", function() mkplay:edition_changing(0) end)

    -- key binding: cycle content groups
    mp.add_key_binding("g", "cycle-contentgroups", function() mkplay:cycle_content_groups() end)


    mp.observe_property('playback-time', 'number', function(_, val) mkplay:observe_playback_time(val) end)
end


local function mp_on_load()
msg.info("Matroska Playback: on_load")
    -- mkplay is already running
    if mkplay then
        -- check edition change
        if mkplay.edition_is_changing then return end

        -- close the current instance
        mkplay:close()
    end

    mkplay = mkplayback.Mk_Playback:new(mp.get_property("stream-open-filename", ""))
	
    -- when the edl_path is not empty then Matroska features are present and mpvMatroska is used
    if mkplay.edl_path ~= "" then
        mp.register_event("file-loaded", mp_file_loaded)
        mp.set_property("stream-open-filename", mkplay.edl_path)
		
        mp.register_script_message("cycle-editions", function() mkplay:edition_changing(0) end)
        mp.register_script_message("set-edition", function(idx) mkplay:edition_changing(tonumber(idx)) end)
        mp.register_script_message("cycle-contentgroups", function() mkplay:cycle_content_groups() end)
        mp.register_script_message("set-contentgroup", function(idx) mkplay:_set_content_from_group(tonumber(idx)) end)

        -- uosc settings
        if uosc_is_installed then
			opt.read_options(uosc_options, 'uosc')
			
            mp.register_script_message("open-editions",
	            function() mp.commandv('script-message-to', 'uosc', 'open-menu', mkplay:uosc_get_editions_menu()) end)
            mp.add_key_binding("ALT+e", "open-editions",
				function() mp.commandv('script-message-to', 'uosc', 'open-menu', mkplay:uosc_get_editions_menu()) end)

            mp.register_script_message("open-contentgroups",
	            function() mp.commandv('script-message-to', 'uosc', 'open-menu', mkplay:uosc_get_contengroups_menu()) end)
            mp.add_key_binding("ALT+g", "open-contentgroups",
				function() mp.commandv('script-message-to', 'uosc', 'open-menu', mkplay:uosc_get_contengroups_menu()) end)
        end

    -- the loaded file is not Matroska, disable mpvMatroska
    else
        mkplay:close()
        mkplay = nil
    end
end



-- hooks
mp.add_hook("on_load", 50, mp_on_load)
--mp.add_hook("on_preloaded", 50, mp_on_preloaded)

