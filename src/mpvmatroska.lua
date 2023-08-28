local mp = require "mp"
local msg = require "mp.msg"

local mkplayback = require "matroskaplayback"
local mkplay


-- disable mpv's internal ordered-chapters support!
mp.set_property_native("ordered-chapters", false)

msg.debug("Matroska Playback loded: ", mkplayback ~= nil)



local function mp_file_loaded()
    -- get the stream id's
    mkplay.mpv_current_vid = mp.get_property_native("current-tracks/video/id")
    mkplay.mpv_current_aid = mp.get_property_native("current-tracks/audio/id")
    mkplay.mpv_current_sid = mp.get_property_native("current-tracks/sub/id")
    -- init chapters
    mkplay:init_chapters()
	msg.debug("Matroska Playback: Edition count: ", #mkplay.mpv_editions)
	msg.debug("Matroska Playback: Chapters count: ", #mkplay.mpv_chapters)
	
    mp.set_property_native("edition-list", mkplay.mpv_editions)
	mp.set_property_native("chapter-list", mkplay.mpv_chapters)
	msg.debug("Matroska Playback: init chapters done")
	
	mp.unregister_event(mp_file_loaded)
end


local function mp_on_load()
msg.info("Matroska Playback: on_load")
    if mkplay then mkplay:close() end

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



local function mp_observe_current_edition(_, val)
	mkplay:on_edition_change(val)
	
	mp.set_property_native("chapter-list", mkplay.mpv_chapters)
end



-- hooks
mp.add_hook("on_load", 50, mp_on_load)
--mp.add_hook("on_preloaded", 50, mp_on_preloaded)
