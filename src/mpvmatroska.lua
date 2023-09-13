local mp = require "mp"
local msg = require "mp.msg"

local mkplayback = require "matroskaplayback"
local mkplay



-- disable mpv's internal ordered-chapters support!
mp.set_property_native("ordered-chapters", false)

msg.debug("Matroska Playback loded: ", mkplayback ~= nil)


-- mp_observe_audio_id
local function mp_observe_audio_id(_, val)
	mkplay:mpv_on_audio_change(val)
end

-- mp_observe_subtitle_id
local function mp_observe_subtitle_id(_, val)
	mkplay:mpv_on_subtitle_change(val)
end


-- key bindings ----------------------------------------------------------------

-- edition change with short-cut "E"
local function mp_edition_change()
	if not mkplay:edition_changing(0) then return end -- toggle edition
	-- load the edition with the new edl path
    mp.commandv("loadfile", mkplay.edl_path, "replace")
end




local function mp_file_loaded()
    -- get the stream id's
    mkplay.mpv_current_vid = mp.get_property_native("current-tracks/video/id")
    mkplay.mpv_current_aid = mp.get_property_native("current-tracks/audio/id")
    mkplay.mpv_current_sid = mp.get_property_native("current-tracks/sub/id")
    
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

    -- register audio observation
    mp.observe_property("current-tracks/audio/id", "number", mp_observe_audio_id)
    -- register subtitle observation
    mp.observe_property("current-tracks/sub/id", "number", mp_observe_subtitle_id)

    -- key binding: edition_change, override mpv's default "E" key for changing the editions
    mp.add_key_binding("E", "edition_change", mp_edition_change)
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
		
    -- the loaded file is not Matroska, disable mpvMatroska
    else
        mkplay:close()
        mkplay = nil
    end
end

local function mp_on_preloaded()

end







-- hooks
mp.add_hook("on_load", 50, mp_on_load)
--mp.add_hook("on_preloaded", 50, mp_on_preloaded)
